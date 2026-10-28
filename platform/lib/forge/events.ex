defmodule Forge.Events do
  @moduledoc """
  The append-only event log. Every mutation in the platform writes an event in the same
  transaction; contexts build an `Ecto.Multi` and call `log/4` on it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Events.Event
  alias Forge.Repo

  @type actor ::
          :system | {:user, String.t()} | {:job, String.t()} | {:api, String.t(), String.t()}

  @doc """
  Adds an event insert to `multi` under `name`. `attrs` may hold `:project_id`, `:ticket_id`,
  `:job_id` and `:payload`; `payload` may also be a function of the multi's changes so far, for
  events that reference rows inserted earlier in the same transaction.

  `project_id` is filled in from the ticket or the job when the caller does not pass it, so
  reads can be scoped to membership without thirty call sites having to remember. A caller with
  neither is a node-wide event and stays null.
  """
  @spec log(Multi.t(), atom(), String.t(), actor(), map() | (map() -> map())) :: Multi.t()
  def log(%Multi{} = multi, name, type, actor, attrs \\ %{}) do
    Multi.insert(multi, name, fn changes ->
      attrs = if is_function(attrs, 1), do: attrs.(changes), else: attrs

      Event.changeset(
        %Event{},
        attrs |> with_project() |> Map.merge(%{type: type, actor: encode_actor(actor)})
      )
    end)
  end

  @doc "Inserts one event outside any other transaction."
  @spec append(String.t(), actor(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def append(type, actor, attrs \\ %{}) do
    %Event{}
    |> Event.changeset(
      attrs
      |> with_project()
      |> Map.merge(%{type: type, actor: encode_actor(actor)})
    )
    |> Repo.insert()
  end

  # Derived once, here, rather than at every call site. Both lookups run inside the caller's
  # transaction, so a ticket or job inserted earlier in the same multi is already visible.
  defp with_project(attrs) do
    case {project_key(attrs), attrs[:ticket_id] || attrs["ticket_id"],
          attrs[:job_id] || attrs["job_id"]} do
      {nil, ticket_id, _job_id} when is_binary(ticket_id) ->
        Map.put(attrs, :project_id, lookup(Forge.Tickets.Ticket, ticket_id))

      {nil, _ticket_id, job_id} when is_binary(job_id) ->
        Map.put(attrs, :project_id, lookup(Forge.Jobs.Job, job_id))

      _already_set_or_node_wide ->
        attrs
    end
  end

  defp project_key(attrs), do: attrs[:project_id] || attrs["project_id"]

  defp lookup(schema, id) do
    Repo.one(from r in schema, where: r.id == ^id, select: r.project_id)
  end

  # **Recorded, and not listed.** A job that opens three hundred files writes three hundred of
  # these, and every list of events here is something an operator reads: the job page, the ticket's
  # latest events, a project's feed, a chat. `docs/design/archive.md` § What is recorded says the
  # operator sees the count and nothing else (the job page's, and no list), so the lists leave them
  # out and `archive_reads/1` is the one way to read them.
  @unlisted ["job.archive_read"]

  @doc "The events of one job that record which archive versions it opened, oldest first."
  @spec archive_reads(String.t()) :: [Event.t()]
  def archive_reads(job_id) do
    Repo.all(
      from e in Event,
        where: e.job_id == ^job_id and e.type == "job.archive_read",
        order_by: e.seq
    )
  end

  @spec for_ticket(String.t()) :: [Event.t()]
  def for_ticket(ticket_id) do
    Repo.all(
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type not in ^@unlisted,
        order_by: e.seq
    )
  end

  @spec for_job(String.t()) :: [Event.t()]
  def for_job(job_id) do
    Repo.all(
      from e in Event, where: e.job_id == ^job_id and e.type not in ^@unlisted, order_by: e.seq
    )
  end

  @doc "The newest event of `type` for a job, or nil."
  @spec latest_for_job(String.t(), String.t()) :: Event.t() | nil
  def latest_for_job(job_id, type) do
    Repo.one(
      from e in Event,
        where: e.job_id == ^job_id and e.type == ^type,
        order_by: [desc: e.seq],
        limit: 1
    )
  end

  @doc """
  The oldest event of `type` for a job, or nil.

  The mirror of `latest_for_job/2`, for the facts a job's *first* event settles: who opened a
  conversation, which is the actor every transition it asks for is attributed to
  (`docs/design/conversations.md` § Taking a transition).
  """
  @spec earliest_for_job(String.t(), String.t()) :: Event.t() | nil
  def earliest_for_job(job_id, type) do
    Repo.one(
      from e in Event,
        where: e.job_id == ^job_id and e.type == ^type,
        order_by: [asc: e.seq],
        limit: 1
    )
  end

  @doc "The newest event of `type` for a ticket, or nil."
  @spec latest_for_ticket(String.t(), String.t()) :: Event.t() | nil
  def latest_for_ticket(ticket_id, type) do
    Repo.one(
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type == ^type,
        order_by: [desc: e.seq],
        limit: 1
    )
  end

  @doc """
  The newest events of a project, newest first.

  This reads the denormalised `project_id` rather than joining through the ticket. The join was
  what made a project's own events — `project.registered`, a membership change — unreachable,
  because they have no ticket; and once reads are scoped to membership, an event nothing can
  attribute to a project is an event nothing can decide the visibility of.
  """
  @spec for_project(String.t(), pos_integer()) :: [Event.t()]
  def for_project(project_id, limit) do
    Repo.all(
      from e in Event,
        where: e.project_id == ^project_id and e.type not in ^@unlisted,
        order_by: [desc: e.seq],
        limit: ^limit
    )
  end

  @topic "tickets"

  @doc "Tells subscribers that `ticket_id` changed. Pages reload on it."
  @spec notify(String.t()) :: :ok
  def notify(ticket_id) do
    Phoenix.PubSub.broadcast(Forge.PubSub, @topic, {:ticket_changed, ticket_id})
  end

  @doc "Subscribes the caller to `{:ticket_changed, ticket_id}` messages for every ticket."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Forge.PubSub, @topic)

  @doc """
  Tells a page watching one job that an event arrived, with the event itself.

  Per job rather than on the global topic, deliberately: `CLAUDE.md` says a handler subscribed to
  a global topic filters before it does any work, and a page appending live output would be woken
  by every event on the node. Per-job, that filtering is the subscription — a page is only sent
  what it is showing. The event travels with the message so the page appends instead of
  reloading, which is what makes output arrive as it is produced.
  """
  @spec notify_job(String.t(), Event.t()) :: :ok
  def notify_job(job_id, %Event{} = event) do
    Phoenix.PubSub.broadcast(Forge.PubSub, job_topic(job_id), {:job_event, job_id, event})
  end

  @doc "Subscribes the caller to `{:job_event, job_id, event}` for one job."
  @spec subscribe_job(String.t()) :: :ok | {:error, term()}
  def subscribe_job(job_id), do: Phoenix.PubSub.subscribe(Forge.PubSub, job_topic(job_id))

  @doc "Stops the caller hearing one job's events, when a page moves on to another job."
  @spec unsubscribe_job(String.t()) :: :ok
  def unsubscribe_job(job_id), do: Phoenix.PubSub.unsubscribe(Forge.PubSub, job_topic(job_id))

  defp job_topic(job_id), do: "job:" <> job_id

  @doc """
  A tool call as one bounded line: its tool's name, then its input as the harness sent it. The
  agent wrote both, so a name that is not text is left out rather than raised on.
  """
  @spec tool_summary(term(), term()) :: String.t()
  def tool_summary(name, input) do
    name = if is_binary(name), do: name, else: ""
    "#{name} #{input |> Jason.encode!() |> String.slice(0, 160)}"
  end

  @doc "A one-line, bounded rendering of an event's payload for lists and logs."
  @spec summary(Event.t()) :: String.t()
  def summary(%Event{} = event), do: describe(event, :bounded)

  @doc """
  The same rendering unbounded, for a page that wraps and clips the line itself — the job's
  stream, which shows the first 200 characters and opens the rest in place (`ForgeWeb.Actions.clip/1`,
  `docs/design/ui.md` § Activity). Whole here where `summary/1` cuts them short: an agent's text,
  a message, and a payload with no sentence of its own. A tool call is not among them: that page
  draws it as an action line (`ForgeWeb.Actions`), never as this.
  """
  @spec detail(Event.t()) :: String.t()
  def detail(%Event{} = event), do: describe(event, :whole)

  defp describe(%Event{type: "job.harness.text", payload: %{"text" => text}}, bound),
    do: bounded(text, 200, bound)

  defp describe(
         %Event{type: "job.harness.tool_use", payload: %{"name" => name, "input" => input}},
         _bound
       ),
       do: tool_summary(name, input)

  defp describe(
         %Event{type: "job.harness.tool_result", payload: %{"bytes" => bytes} = p},
         _bound
       ),
       do: "#{bytes} bytes#{if p["is_error"], do: " (error)"}"

  defp describe(%Event{type: "job.harness.finished", payload: p}, _bound),
    do: "#{p["subtype"]} · #{p["num_turns"]} turns · $#{p["total_cost_usd"]}"

  defp describe(%Event{type: "job.harness.started", payload: p}, _bound),
    do: "#{p["model"]} · session #{p["session_id"]}"

  # What the worker read of the job's memory (`docs/design/claude-code-events.md` § Memory), in
  # the words the job's header and a conversation's now line use (`Forge.Jobs.Memory`).
  defp describe(%Event{type: "job.harness.memory", payload: payload}, _bound),
    do: Forge.Jobs.Memory.sentence(payload)

  # A harness that has not said it started: how long, whether the worker gave up, the last thing
  # it wrote and — so the row says whether memory is why — what the job holds against its ceiling.
  defp describe(%Event{type: "job.harness.starting", payload: p}, _bound) do
    [
      "not started after #{p["waited_s"]}s#{if p["gave_up"] == true, do: ", gave up"}",
      last_line(p["stderr"]),
      Forge.Jobs.Memory.snapshot(p["memory"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Without this a message renders as an inspected map, which is how a conversation's own words
  # would read in the timeline and the queue.
  defp describe(%Event{type: "chat.message", payload: %{"text" => text}}, bound),
    do: bounded(text, 200, bound)

  defp describe(%Event{type: "chat.turn", payload: %{"turn" => turn}}, _bound), do: "turn #{turn}"

  # The scheduler's sentence (`Forge.Jobs.record_wait/3`). The reason code beside it is for
  # comparing one pass with the next, not for reading; without this the operator would read
  # `reason="at_capacity" text="Waiting for room: …"` under a job.
  defp describe(%Event{type: "job.waiting", payload: %{"text" => text}}, _bound), do: text

  # Commands (`docs/design/commands.md` § Events and the timeline), as the sentence a person reads
  # rather than the inspected map the fallback would draw.
  defp describe(%Event{type: "command.invoked", payload: %{"command" => command} = p}, _bound),
    do: "$ #{command}#{argv(p["args"])} at #{short(p["commit"])}"

  defp describe(%Event{type: "command.finished", payload: %{"command" => command} = p}, _bound),
    do: "#{command}#{argv(p["args"])}: #{ended(p)}"

  defp describe(%Event{type: "job.parked", payload: %{"invocations" => invocations}}, _bound) do
    {refused, run} = Enum.split_with(invocations, &Map.has_key?(&1, "refused"))

    "parked on #{count(length(run), "command")}" <>
      if(refused == [], do: "", else: ", #{length(refused)} refused")
  end

  defp describe(%Event{type: "commands.started", payload: %{"jobs" => jobs} = p}, _bound),
    do: "#{count(length(jobs), "command")} at #{short(p["at"])}"

  defp describe(
         %Event{
           type: "commands.decided",
           payload: %{"statuses" => statuses, "outcome" => outcome}
         },
         _bound
       ),
       do: "statuses #{Enum.map_join(statuses, ", ", &(&1 || "none"))} → #{outcome}"

  defp describe(%Event{type: "ticket.stuck", payload: %{"reason" => reason}}, _bound), do: reason

  defp describe(%Event{type: "ticket.renamed", payload: %{"to" => to} = p}, _bound),
    do: "renamed to #{to}, from #{p["document"]}"

  # Why a conversation's request to move its ticket moved nothing
  # (`docs/design/conversations.md` § Taking a transition). The reason, not the request: the
  # request is in the payload for whoever opens the event, and the row is read for what went
  # wrong.
  defp describe(%Event{type: "chat.transition_refused", payload: %{"reason" => reason}}, bound),
    do: bounded(reason, 160, bound)

  defp describe(
         %Event{type: "transition.taken", payload: %{"from" => from, "to" => to} = p},
         _bound
       ),
       do: "#{from} → #{to}#{if p["outcome"], do: " on #{p["outcome"]}"}"

  # The state that would have merged, and what conflicted: the first path, and how many more.
  defp describe(
         %Event{type: "ticket.merge_conflicted", payload: %{"state" => state, "paths" => paths}},
         _bound
       ) do
    case paths do
      [only] -> "#{only} conflicted on the way into #{state}"
      [first | rest] -> "#{first} and #{length(rest)} more conflicted on the way into #{state}"
      [] -> "conflicted on the way into #{state}"
    end
  end

  defp describe(%Event{payload: payload}, _bound) when map_size(payload) == 0, do: ""

  defp describe(%Event{payload: payload}, bound) do
    payload
    |> Map.drop(["raw", "harness", "input", "excerpt", "usage"])
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> bounded(160, bound)
  end

  defp bounded(text, most, :bounded), do: String.slice(text, 0, most)
  defp bounded(text, _most, :whole), do: text

  # The tail the worker sent is up to two kilobytes of several lines; the last is the one that
  # names what it was stuck on.
  defp last_line(text) when is_binary(text) do
    case text |> String.split("\n", trim: true) |> List.last() do
      nil -> nil
      line -> "stderr: " <> String.slice(line, 0, 120)
    end
  end

  defp last_line(_none), do: nil

  defp argv([_ | _] = args), do: " " <> ForgeCore.Workflow.Command.argv(args)
  defp argv(_none), do: ""

  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short(_none), do: "?"

  defp ended(%{"exit_status" => status}) when is_integer(status), do: "exit #{status}"
  defp ended(%{"outcome" => outcome}), do: to_string(outcome)

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  @spec encode_actor(actor()) :: map()
  def encode_actor(:system), do: %{"kind" => "system", "id" => nil}
  def encode_actor({:user, id}), do: %{"kind" => "user", "id" => id}
  def encode_actor({:job, id}), do: %{"kind" => "job", "id" => id}

  def encode_actor({:api, id, name}), do: %{"kind" => "api", "id" => id, "name" => name}
end
