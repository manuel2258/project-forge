defmodule Forge.Events do
  @moduledoc """
  The append-only event log. Every mutation in the platform writes an event in the same
  transaction; contexts build an `Ecto.Multi` and call `log/4` on it.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Events.Event
  alias Forge.Repo

  @type actor :: :system | {:user, String.t()} | {:job, String.t()}

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

  @spec for_ticket(String.t()) :: [Event.t()]
  def for_ticket(ticket_id) do
    Repo.all(from e in Event, where: e.ticket_id == ^ticket_id, order_by: e.seq)
  end

  @spec for_job(String.t()) :: [Event.t()]
  def for_job(job_id) do
    Repo.all(from e in Event, where: e.job_id == ^job_id, order_by: e.seq)
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
        where: e.project_id == ^project_id,
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
  def summary(%Event{type: "job.harness.text", payload: %{"text" => text}}),
    do: String.slice(text, 0, 200)

  def summary(%Event{type: "job.harness.tool_use", payload: %{"name" => name, "input" => input}}),
    do: tool_summary(name, input)

  def summary(%Event{type: "job.harness.tool_result", payload: %{"bytes" => bytes} = p}),
    do: "#{bytes} bytes#{if p["is_error"], do: " (error)"}"

  def summary(%Event{type: "job.harness.finished", payload: p}),
    do: "#{p["subtype"]} · #{p["num_turns"]} turns · $#{p["total_cost_usd"]}"

  def summary(%Event{type: "job.harness.started", payload: p}),
    do: "#{p["model"]} · session #{p["session_id"]}"

  # Without this a message renders as an inspected map, which is how a conversation's own words
  # would read in the timeline and the queue.
  def summary(%Event{type: "chat.message", payload: %{"text" => text}}),
    do: String.slice(text, 0, 200)

  def summary(%Event{type: "chat.turn", payload: %{"turn" => turn}}), do: "turn #{turn}"

  # The scheduler's sentence (`Forge.Jobs.record_wait/3`). The reason code beside it is for
  # comparing one pass with the next, not for reading; without this the operator would read
  # `reason="at_capacity" text="Waiting for room: …"` under a job.
  def summary(%Event{type: "job.waiting", payload: %{"text" => text}}), do: text

  # Commands (`docs/design/commands.md` § Events and the timeline), as the sentence a person reads
  # rather than the inspected map the fallback would draw.
  def summary(%Event{type: "command.invoked", payload: %{"command" => command} = p}),
    do: "$ #{command}#{argv(p["args"])} at #{short(p["commit"])}"

  def summary(%Event{type: "command.finished", payload: %{"command" => command} = p}),
    do: "#{command}#{argv(p["args"])}: #{ended(p)}"

  def summary(%Event{type: "job.parked", payload: %{"invocations" => invocations}}) do
    {refused, run} = Enum.split_with(invocations, &Map.has_key?(&1, "refused"))

    "parked on #{count(length(run), "command")}" <>
      if(refused == [], do: "", else: ", #{length(refused)} refused")
  end

  def summary(%Event{type: "commands.started", payload: %{"jobs" => jobs} = p}),
    do: "#{count(length(jobs), "command")} at #{short(p["at"])}"

  def summary(%Event{
        type: "commands.decided",
        payload: %{"statuses" => statuses, "outcome" => outcome}
      }),
      do: "statuses #{Enum.map_join(statuses, ", ", &(&1 || "none"))} → #{outcome}"

  def summary(%Event{payload: payload}) when map_size(payload) == 0, do: ""

  def summary(%Event{payload: payload}) do
    payload
    |> Map.drop(["raw", "harness", "input", "excerpt", "usage"])
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> String.slice(0, 160)
  end

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
end
