defmodule Forge.Events.Stream do
  @moduledoc """
  A job's event stream, read from the database a page at a time and counted there
  (`docs/design/ui.md` § Activity, § The job page; `docs/design/storage.md` § Retention).

  A page used to hold the whole log of the job it drew and take the part it showed in Elixir. It
  now asks for the part: **the newest `limit` entries** below a position, the entries newer than
  what it holds, everything from a position up, and the figures it is headed by.

  **An entry head** is a listed event that is not a notice (unless notices are shown) and not a
  `tool_result` whose call exists in the job — a call and its result are one line
  (`ForgeWeb.WorkScreen.entries/2`), and a result has the position of its call. A page is the
  range from its oldest head up to the position it was asked below, read whole, **except** a result
  whose call is older than the range (it arrives with its call's page), **plus** the results of the
  range's calls wherever they are (a result may have come after newer pages were read). That is
  what makes a call and its result one line whichever pages they fall on.

  A result with no call id is never paired — SQL `=` does not match NULL, and the pairing in
  `ForgeWeb.WorkScreen.entries/2` does not either; the two must agree.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Events.Event
  alias Forge.Repo

  @unlisted ["job.archive_read"]
  @notice "job.harness.notice"
  @call "job.harness.tool_use"
  @result "job.harness.tool_result"

  @type page :: %{events: [Event.t()], more: boolean()}

  # Every event of the job that a list draws.
  defp listed(job_id),
    do: from(e in Event, where: e.job_id == ^job_id and e.type not in ^@unlisted)

  defp shown(query, true), do: query
  defp shown(query, false), do: from(e in query, where: e.type != ^@notice)

  defp before(query, nil), do: query
  defp before(query, position), do: from(e in query, where: e.seq < ^position)

  # A result whose call is in the job: its own row is not drawn, the call's line says it.
  defmacrop paired?(e) do
    quote do
      fragment(
        """
        ? = 'job.harness.tool_result' AND EXISTS (
          SELECT 1 FROM events c
           WHERE c.job_id = ? AND c.type = 'job.harness.tool_use'
             AND c.payload->>'id' = ?->>'tool_use_id')
        """,
        unquote(e).type,
        unquote(e).job_id,
        unquote(e).payload
      )
    end
  end

  defp heads(job_id, notices),
    do: from(e in shown(listed(job_id), notices), where: not paired?(e))

  # A result whose call is older than `position`: it is read with its call, on the page that holds it.
  defp strays(query, position) do
    from(e in query,
      where:
        not fragment(
          """
          ? = 'job.harness.tool_result' AND EXISTS (
            SELECT 1 FROM events c
             WHERE c.job_id = ? AND c.type = 'job.harness.tool_use' AND c.seq < ?
               AND c.payload->>'id' = ?->>'tool_use_id')
          """,
          e.type,
          e.job_id,
          ^position,
          e.payload
        )
    )
  end

  @doc """
  The newest `limit` entries below `position` (nil: from the newest), as the events that draw them
  in `seq` order, and whether older entries wait behind them.
  """
  @spec page(String.t(), pos_integer() | nil, pos_integer(), boolean()) :: page()
  def page(job_id, position, limit, notices) do
    seqs =
      Repo.all(
        from e in before(heads(job_id, notices), position),
          order_by: [desc: e.seq],
          limit: ^(limit + 1),
          select: e.seq
      )

    case Enum.split(seqs, limit) do
      {[], []} ->
        %{events: [], more: false}

      {kept, rest} ->
        oldest = List.last(kept)
        range = rows(job_id, oldest, position, notices)
        %{events: range ++ later_results(job_id, range, position), more: rest != []}
    end
  end

  @doc """
  Everything from `seq` up — a stream reread as far back as it was (a rejoin), or back to the first
  failure — and whether older entries wait behind it.
  """
  @spec from(String.t(), pos_integer(), boolean()) :: page()
  def from(job_id, seq, notices) do
    more = Repo.exists?(from e in heads(job_id, notices), where: e.seq < ^seq)
    %{events: rows(job_id, seq, nil, notices), more: more}
  end

  @doc """
  What arrived above `after_seq`, the newest event a page holds, for a page that reloads: the
  events, `strays/2` of its oldest held position left out as everywhere.
  """
  @spec newer(String.t(), pos_integer(), pos_integer(), boolean()) :: [Event.t()]
  def newer(job_id, after_seq, oldest_held, notices) do
    Repo.all(
      from e in strays(shown(listed(job_id), notices), oldest_held),
        where: e.seq > ^after_seq,
        order_by: e.seq
    )
  end

  defp rows(job_id, oldest, position, notices) do
    Repo.all(
      from e in strays(before(shown(listed(job_id), notices), position), oldest),
        where: e.seq >= ^oldest,
        order_by: e.seq
    )
  end

  # The results of the range's calls that are above it: they were not read with the pages above,
  # which leave a result to its call's page.
  defp later_results(_job_id, _range, nil), do: []

  defp later_results(job_id, range, position) do
    ids = for %Event{type: @call, payload: %{"id" => id}} <- range, is_binary(id), do: id

    if ids == [] do
      []
    else
      Repo.all(
        from e in Event,
          where: e.job_id == ^job_id and e.type == ^@result and e.seq >= ^position,
          where: fragment("?->>'tool_use_id' = ANY(?)", e.payload, ^ids),
          order_by: e.seq
      )
    end
  end

  @doc "The `seq` of the job's newest listed event, or 0: how far a count has read."
  @spec newest(String.t()) :: non_neg_integer()
  def newest(job_id), do: Repo.aggregate(listed(job_id), :max, :seq) || 0

  @doc "What arrived above `after_seq`, for a raw log that reloads."
  @spec raw_newer(String.t(), pos_integer()) :: [Event.t()]
  def raw_newer(job_id, after_seq),
    do: Repo.all(from e in listed(job_id), where: e.seq > ^after_seq, order_by: e.seq)

  @doc "The entries the Activity tab counts: heads, without the notices."
  @spec count(String.t()) :: non_neg_integer()
  def count(job_id), do: Repo.aggregate(heads(job_id, false), :count)

  @doc """
  How many notices the harness recorded about itself, and the `seq` of the newest of them (0 when
  none): **one statement**, so that the figure and the position it covers are of the same snapshot.
  A notice committed after it is numbered above the position, each job's harness events being
  written by one process in order.
  """
  @spec notice_figures(String.t()) :: {non_neg_integer(), non_neg_integer()}
  def notice_figures(job_id) do
    {count, newest} =
      Repo.one(
        from e in listed(job_id),
          where: e.type == ^@notice,
          select: {count(e.seq), max(e.seq)}
      )

    {count, newest || 0}
  end

  @doc "Whether the job has a call by this id: a result whose call is not held is read with its call's page."
  @spec call_exists?(String.t(), String.t() | nil) :: boolean()
  # The clause for a nil id is an equivalent mutant: `payload->>'id' = NULL` is never true, so the
  # query below answers false as well. It spares the query.
  def call_exists?(_job_id, nil), do: false

  def call_exists?(job_id, id) do
    Repo.exists?(
      from e in Event,
        where: e.job_id == ^job_id and e.type == ^@call,
        where: fragment("?->>'id' = ?", e.payload, ^id)
    )
  end

  # -- the raw log: every event as it was recorded, nothing paired and nothing hidden -------------

  @doc "The newest `limit` listed events below `position`, oldest first, and whether older ones wait."
  @spec raw_page(String.t(), pos_integer() | nil, pos_integer()) :: page()
  def raw_page(job_id, position, limit) do
    rows =
      Repo.all(
        from e in before(listed(job_id), position), order_by: [desc: e.seq], limit: ^(limit + 1)
      )

    {kept, rest} = Enum.split(rows, limit)
    %{events: Enum.reverse(kept), more: rest != []}
  end

  @doc "Every listed event from `seq` up, oldest first, and whether older ones wait."
  @spec raw_from(String.t(), pos_integer()) :: page()
  def raw_from(job_id, seq) do
    %{
      events: Repo.all(from e in listed(job_id), where: e.seq >= ^seq, order_by: e.seq),
      more: Repo.exists?(from e in listed(job_id), where: e.seq < ^seq)
    }
  end

  @doc "Every listed event of the job."
  @spec raw_count(String.t()) :: non_neg_integer()
  def raw_count(job_id), do: Repo.aggregate(listed(job_id), :count)

  # -- what a page says of the whole job, apart from the page it holds ------------------------------

  @doc """
  What failed in the job: `{count, first_seq}`. A call whose result is an error is one, at its own
  position; so is an event whose type ends in `error`. `{0, nil}` when nothing did.
  """
  @spec failures(String.t()) :: {non_neg_integer(), pos_integer() | nil}
  def failures(job_id) do
    failed =
      from c in Event,
        where: c.job_id == ^job_id and c.type == ^@call,
        where:
          fragment(
            """
            EXISTS (SELECT 1 FROM events r
                     WHERE r.job_id = ? AND r.type = 'job.harness.tool_result'
                       AND r.payload->>'tool_use_id' = ?->>'id'
                       AND r.payload->>'is_error' = 'true')
            """,
            c.job_id,
            c.payload
          ),
        select: c.seq

    errored =
      from e in listed(job_id),
        where: like(e.type, "%error"),
        select: e.seq

    seqs = Repo.all(failed) ++ Repo.all(errored)
    {length(seqs), Enum.min(seqs, fn -> nil end)}
  end

  @doc """
  The newest `TodoWrite` call of the job, or nil: its plan. `top_level?` leaves out a subagent's
  (`parent_tool_use_id`), which is a conversation's plan band.
  """
  @spec latest_todo(String.t(), boolean()) :: Event.t() | nil
  def latest_todo(job_id, top_level?) do
    query =
      from e in Event,
        where: e.job_id == ^job_id and e.type == ^@call,
        where: fragment("?->>'name' = 'TodoWrite'", e.payload),
        order_by: [desc: e.seq],
        limit: 1

    query =
      if top_level?,
        do: from(e in query, where: fragment("?->>'parent_tool_use_id' IS NULL", e.payload)),
        else: query

    Repo.one(query)
  end
end
