defmodule Forge.References do
  @moduledoc """
  What a name in Markdown means: `![alt](screenshots/queue.png)` and `[text](plan.md)` pointing at
  an artifact of the ticket (or project chat) the text belongs to, or of another ticket of the
  same project (`archive/34/…`). The rules are `docs/design/ui.md` § Documents → References.

  A reference is `name`, `name@N` or `name@latest`, optionally behind `archive/<n>/`. Which version
  a bare name means depends on *when the referring text was written*, its **moment**:

      %{at: DateTime.t() | :now, job: job_id | nil, turn_seq: integer | nil}

  A version is visible to a moment when it is the text's own scope's and was written by
  `moment.job` — and then by event order (`turn_seq`), or always when there is none, since a
  job's pictures are kept in the transaction of its document and a clock alone would catch them
  only by the second — or otherwise when it existed at `at` (`<=`: timestamps are whole seconds, so
  a tie counts as before). Another ticket's versions are cut by the clock alone.

  `resolve/2` answers any number of references in a number of queries that does not grow with them, and none when
  there are none. The choice itself, `pick/4`, is pure.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Artifacts
  alias Forge.Artifacts.{Artifact, Version}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Repo
  alias Forge.Tickets.Ticket

  @typedoc """
  Where a text belongs: a project and the ticket (`{id, number}`) or the project chat (`id`) whose
  artifacts a bare name is looked up in. Exactly one of `ticket` and `chat` is searched.
  """
  @type scope :: %{
          project_id: String.t(),
          project: String.t(),
          ticket: {String.t(), pos_integer()} | nil,
          chat: String.t() | nil
        }

  @type moment :: %{at: DateTime.t() | :now, job: String.t() | nil, turn_seq: integer() | nil}

  @type found :: %{
          where: {:ticket, String.t(), pos_integer()} | {:chat, String.t()},
          name: String.t(),
          version: pos_integer(),
          raster?: boolean()
        }

  @type reason ::
          :outside
          | {:no_ticket, pos_integer()}
          | {:missing, :ticket | :chat | pos_integer()}
          | {:no_version, pos_integer()}

  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.\-]*:/
  @archive ~r/\Aarchive\/([1-9]\d{0,8})\/(.+)\z/s
  @selector ~r/\A(.+)@(latest|[1-9]\d{0,8})\z/s

  @doc "The scope of a ticket's text: its artifacts are searched."
  @spec ticket_scope(String.t(), %{id: String.t(), number: pos_integer(), project_id: String.t()}) ::
          scope()
  def ticket_scope(project_name, ticket),
    do: %{
      project_id: ticket.project_id,
      project: project_name,
      ticket: {ticket.id, ticket.number},
      chat: nil
    }

  @doc "The scope of a project chat's text (or a chat's own artifacts): the chat's are searched."
  @spec chat_scope(%{id: String.t(), name: String.t()}, String.t()) :: scope()
  def chat_scope(project, chat_id),
    do: %{project_id: project.id, project: project.name, ticket: nil, chat: chat_id}

  @doc """
  The ways a reference can be read, most preferred first: `{ticket_number | nil, name, selector}`
  with a selector of `:bare`, `:latest` or `{:n, n}`; or `:outside` for a URL, a `data:` URI and a
  path into the app. The exact name comes first so that a name holding an `@` wins.
  """
  @spec readings(String.t()) :: :outside | [{pos_integer() | nil, String.t(), term()}]
  def readings(ref) when is_binary(ref) do
    if String.starts_with?(ref, "/") or Regex.match?(@scheme, ref) do
      :outside
    else
      {number, rest} =
        case Regex.run(@archive, ref) do
          [_all, n, rest] -> {String.to_integer(n), rest}
          nil -> {nil, ref}
        end

      selected =
        case Regex.run(@selector, rest) do
          [_all, name, "latest"] -> [{number, name, :latest}]
          [_all, name, n] -> [{number, name, {:n, String.to_integer(n)}}]
          nil -> []
        end

      Enum.uniq([{nil, ref, :bare}] ++ selected ++ [{number, rest, :bare}])
    end
  end

  @doc """
  The moment a version stands for when it is the referring text: its own clock, its author job, and
  for a job that is a conversation, the first `chat.turn` recorded after the version was — so that
  a later turn's versions are not seen by it. One to three queries when a job wrote it, none
  otherwise.
  """
  @spec moment(Version.t()) :: moment()
  def moment(%Version{author: %{"kind" => "job", "id" => job}} = version) when is_binary(job) do
    base = %{at: version.inserted_at, job: job, turn_seq: nil}

    with :chat <- Repo.one(from j in Job, where: j.id == ^job, select: j.kind),
         seq when is_integer(seq) <- written_seq(job, version.id),
         turn when is_integer(turn) <-
           Repo.one(
             from e in Event,
               # Equivalent mutant: `>=` for `>`. The version's own event is a
               # `version_written` and this one a `chat.turn`, so the two seqs are never equal.
               where: e.job_id == ^job and e.type == "chat.turn" and e.seq > ^seq,
               select: min(e.seq)
           ) do
      %{base | turn_seq: turn}
    else
      _ -> base
    end
  end

  def moment(%Version{} = version), do: %{at: version.inserted_at, job: nil, turn_seq: nil}

  # Scoped to the job that wrote it, so `events(job_id, seq)` serves it and a chat's history is
  # not a scan of every `version_written` event on the node. (Equivalent mutant: dropping the
  # `job_id` test changes the cost, not the answer, since a version id is unique.)
  defp written_seq(job, version_id) do
    Repo.one(
      from e in Event,
        where:
          e.job_id == ^job and e.type == "artifact.version_written" and
            fragment("?->>'version_id' = ?", e.payload, ^version_id),
        select: e.seq
    )
  end

  @doc """
  Resolves every reference of every text: `entries` is `[{key, moment, [reference]}]`, and the
  answer `%{key => %{reference => {:ok, found} | {:error, reason}}}`. The queries do not
  grow with the number of references: the project's tickets, the versions of every name asked for,
  and the event order of the conversation versions that need it. A text given as a `Version`
  stands for `moment/1` of it, which is its own one to three queries, once, and only when it has
  something to resolve; a caller with many texts of one moment passes the moment.
  """
  @spec resolve(scope(), [{term(), moment() | Version.t(), [String.t()]}]) :: %{term() => map()}
  def resolve(scope, entries) do
    # A version becomes its moment first, so the event order it needs is looked up with the rest.
    entries =
      for {key, moment, refs} <- entries,
          do: {key, if(refs == [], do: moment, else: to_moment(moment)), refs}

    refs = entries |> Enum.flat_map(fn {_key, _moment, refs} -> refs end) |> Enum.uniq()

    if refs == [] do
      Map.new(entries, fn {key, _moment, _refs} -> {key, %{}} end)
    else
      readings = Map.new(refs, &{&1, readings(&1)})
      data = load(scope, readings, entries)

      Map.new(entries, fn {key, moment, refs} ->
        {key, Map.new(refs, &{&1, pick(readings[&1], moment, scope, data)})}
      end)
    end
  end

  # A version stands for its own moment, worked out only when something in it needs resolving.
  defp to_moment(%Version{} = version), do: moment(version)
  defp to_moment(moment), do: moment

  defp load(scope, readings, entries) do
    all = for {_ref, list} <- readings, is_list(list), reading <- list, do: reading

    numbers =
      for {n, _name, _sel} <- all, is_integer(n), n != own_number(scope), uniq: true, do: n

    names = for {_n, name, _sel} <- all, uniq: true, do: name

    tickets =
      if numbers == [] do
        %{}
      else
        Map.new(
          Repo.all(
            from t in Ticket,
              where: t.project_id == ^scope.project_id and t.number in ^numbers,
              select: {t.number, t.id}
          )
        )
      end

    own = own_key(scope)
    keys = [own | for({_n, id} <- tickets, do: {:ticket, id})] |> Enum.reject(&is_nil/1)
    rows = rows(keys, names)

    %{tickets: tickets, rows: rows, seqs: seqs(rows, entries)}
  end

  defp own_number(%{ticket: {_id, number}}), do: number
  defp own_number(_scope), do: nil

  defp own_key(%{ticket: {id, _number}}), do: {:ticket, id}
  defp own_key(%{chat: chat}) when is_binary(chat), do: {:job, chat}

  defp rows(keys, names) do
    ticket_ids = for {:ticket, id} <- keys, do: id
    job_ids = for {:job, id} <- keys, do: id

    Repo.all(
      from a in Artifact,
        join: v in Version,
        on: v.artifact_id == a.id,
        where:
          a.name in ^names and
            (a.ticket_id in ^ticket_ids or a.job_id in ^job_ids),
        select: %{
          name: a.name,
          ticket_id: a.ticket_id,
          job_id: a.job_id,
          id: v.id,
          version: v.version,
          inserted_at: v.inserted_at,
          author: v.author,
          blob_uri: v.blob_uri
        }
    )
    |> Enum.group_by(&{(&1.ticket_id && {:ticket, &1.ticket_id}) || {:job, &1.job_id}, &1.name})
  end

  # The event order of the versions a conversation wrote, for the moments that cut by it. Only
  # asked for when a moment has a `turn_seq`.
  defp seqs(rows, entries) do
    jobs =
      for {_key, %{turn_seq: seq, job: job}, [_ | _]} <- entries, seq != nil, uniq: true, do: job

    ids =
      for {_k, list} <- rows,
          v <- list,
          v.author["kind"] == "job" and v.author["id"] in jobs,
          do: v.id

    if ids == [] do
      %{}
    else
      Map.new(
        Repo.all(
          from e in Event,
            # Equivalent mutant: dropping `e.job_id in ^jobs`. It only lets an index serve the
            # query; `ids` are already the versions of those jobs, so the rows are the same.
            where:
              e.job_id in ^jobs and e.type == "artifact.version_written" and
                fragment("?->>'version_id' = ANY(?)", e.payload, ^ids),
            select: {fragment("?->>'version_id'", e.payload), e.seq}
        )
      )
    end
  end

  @doc false
  @spec pick(:outside | list(), moment(), scope(), map()) :: {:ok, found()} | {:error, reason()}
  def pick(:outside, _moment, _scope, _data), do: {:error, :outside}

  def pick(readings, moment, scope, data) do
    results = Enum.map(readings, &pick_one(&1, moment, scope, data))

    # The first reading that finds the artifact decides, the exact name first; when none does, the
    # most specific reason is the one for the reading the text most probably meant (the last).
    Enum.find(results, &match?({:ok, _}, &1)) ||
      Enum.find(Enum.reverse(results), &(not match?({:error, {:missing, _}}, &1))) ||
      List.last(results)
  end

  defp pick_one({number, name, selector}, moment, scope, data) do
    cond do
      number == nil or number == own_number(scope) ->
        rows = Map.get(data.rows, {own_key(scope), name})
        choose(rows, selector, moment, scope, own_target(scope), {true, data.seqs})

      id = data.tickets[number] ->
        rows = Map.get(data.rows, {{:ticket, id}, name})
        choose(rows, selector, moment, scope, {:ticket, number}, {false, data.seqs})

      true ->
        {:error, {:no_ticket, number}}
    end
  end

  defp own_target(%{ticket: {_id, number}}), do: {:ticket, number}
  defp own_target(%{chat: chat}), do: {:chat, chat}

  defp choose(nil, _selector, _moment, scope, target, {own?, _seqs}),
    do: {:error, {:missing, missing(scope, target, own?)}}

  defp choose(versions, selector, moment, scope, target, {own?, seqs}) do
    chosen =
      case selector do
        :latest -> Enum.max_by(versions, & &1.version)
        {:n, n} -> Enum.find(versions, &(&1.version == n))
        :bare -> versions |> Enum.filter(&visible?(&1, moment, own?, seqs)) |> newest()
      end

    case {chosen, selector} do
      {nil, {:n, n}} -> {:error, {:no_version, n}}
      {nil, _} -> {:error, {:missing, missing(scope, target, own?)}}
      {row, _} -> {:ok, found(row, scope, target)}
    end
  end

  defp newest([]), do: nil
  defp newest(rows), do: Enum.max_by(rows, & &1.version)

  # What the note says the name is missing from: this ticket, this chat, or ticket `n`.
  defp missing(_scope, {:chat, _id}, true), do: :chat
  defp missing(_scope, {:ticket, _number}, true), do: :ticket
  defp missing(_scope, {:ticket, number}, false), do: number

  defp found(row, scope, target) do
    where =
      case target do
        {:ticket, number} -> {:ticket, scope.project, number}
        {:chat, id} -> {:chat, id}
      end

    %{
      where: where,
      name: row.name,
      version: row.version,
      raster?: Artifacts.raster?(row.name, row)
    }
  end

  # The cut. A version the text's own job wrote is cut by event order when the moment has one (a
  # conversation, whose later turns must not be seen) and always visible otherwise; every other
  # version, and every version of another ticket, by the clock, a tie counting as before.
  defp visible?(row, moment, own?, seqs) do
    if own? and moment.job != nil and row.author["kind"] == "job" and
         row.author["id"] == moment.job,
       do: written_before?(row, moment, seqs),
       else: existed?(row, moment)
  end

  defp written_before?(_row, %{turn_seq: nil}, _seqs), do: true

  defp written_before?(row, moment, seqs) do
    case Map.fetch(seqs, row.id) do
      # Equivalent mutant: `<=` for `<`. A version's event and the `chat.turn` or `chat.message`
      # that stands for the text are distinct events, so their seqs are never equal.
      {:ok, seq} -> seq < moment.turn_seq
      :error -> existed?(row, moment)
    end
  end

  defp existed?(_row, %{at: :now}), do: true
  defp existed?(row, moment), do: DateTime.compare(row.inserted_at, moment.at) != :gt
end
