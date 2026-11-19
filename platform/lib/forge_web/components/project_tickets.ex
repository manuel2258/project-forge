defmodule ForgeWeb.ProjectTickets do
  @moduledoc """
  A project's tickets as its page draws them (`docs/design/ui.md` § Tickets, `7a`, `7g`, `7h`):
  **every open ticket, what waits on you first, then the rest by last change**, and the history
  of done and cancelled tickets folded beneath.

  `rows/2` makes one map per ticket from reads the page has already made — the project's share of
  the queue, `Forge.Tickets.Doing`'s live jobs and last lines, the merge queue's places — so a
  row costs no query of its own. `list/1` draws them as three-line rows below 768px and `table/1`
  as one table from it; both are drawn and CSS shows one (`areas/project.css`).

  **Colour follows meaning only**: amber waits on you (and edges the row) — stuck included, since
  a stuck ticket waits for you to choose — and info is running.
  """

  use ForgeWeb, :html

  alias Forge.Queue
  alias Forge.Tickets.Ticket
  alias ForgeWeb.{Format, Indicators, Topology}

  @typedoc "Everything a row draws."
  @type row :: %{
          ticket: Ticket.t(),
          waiting: boolean(),
          steps: [String.t()] | nil,
          current: integer(),
          topology: :job | :human | :terminal | :unknown,
          doing: String.t(),
          doing_tone: String.t() | nil,
          usage: String.t() | nil,
          usage_high: boolean(),
          aged: boolean(),
          running: boolean(),
          held: boolean(),
          milestone: String.t() | nil,
          latest: String.t() | nil,
          decision: boolean(),
          changed: DateTime.t(),
          tone: atom()
        }

  @doc """
  One row per open ticket, ordered: the tickets waiting on you, then the rest, each by last change,
  newest first. `facts` holds `:items` (the project's queue items), `:live`, `:said`, `:places`,
  `:paused`, `:milestones` (milestone names by id) and `:now`.

  **A ticket on hold is drawn quietly, below the rest**, unless something on it waits on a person:
  then it is with what waits on you, where the decision is (`docs/design/ui.md` § Tickets).
  """
  @spec rows([Ticket.t()], map()) :: [row()]
  def rows(tickets, facts) do
    items =
      Enum.group_by(Enum.filter(facts.items, &Queue.waiting?/1), &(&1.ticket && &1.ticket.id))

    workflows = Topology.workflows(tickets)

    tickets
    |> Enum.map(&row(&1, Map.get(items, &1.id, []), workflows, facts))
    |> Enum.sort_by(&{group(&1), -DateTime.to_unix(&1.changed)})
  end

  # What waits on you, then the rest, then what is on hold with nothing waiting.
  defp group(%{waiting: true}), do: 0
  defp group(%{held: true}), do: 2
  defp group(_row), do: 1

  defp row(ticket, items, workflows, facts) do
    workflow = Topology.pinned(workflows, ticket)
    steps = workflow && Topology.order(workflow)
    live = facts.live[ticket.id]
    {doing, doing_tone, tone} = doing(ticket, items, live, facts)
    running = is_nil(facts.places[ticket.id]) and match?(%{status: :running}, live)
    {latest, decision} = latest(items, facts.said[ticket.id])

    %{
      ticket: ticket,
      waiting: items != [],
      steps: steps,
      current: (steps && Enum.find_index(steps, &(&1 == ticket.state))) || -1,
      topology: Topology.of(workflow, ticket.state),
      doing: doing,
      doing_tone: doing_tone,
      # Nothing spent is no figure, never `0 windows` (ui.md § Tickets).
      usage: Format.spent(ticket.usage),
      usage_high: usage_high?(ticket, workflow),
      # The doing-word carries its own age (`stuck 25m`, `waiting 12m`, `running 4m`), so the row
      # does not say the same age again at its end.
      aged: running or doing_tone in ["warning", "accent"],
      # Running means a job running now: not one queued to merge or one waiting for a machine,
      # which `tone` puts on the map with the running ones.
      running: running,
      held: Ticket.held?(ticket),
      milestone: Map.get(facts[:milestones] || %{}, ticket.milestone_id),
      latest: latest,
      decision: decision,
      changed: ticket.updated_at,
      tone: tone
    }
  end

  # Whether a ticket has spent more than half of what its workflow allows it: the phone row shows
  # its spend only then, since a figure on every row that is the same on every row is noise.
  defp usage_high?(
         %Ticket{usage: spent} = ticket,
         %ForgeCore.Workflow{limits: %{ticket_tokens: _}} = workflow
       ) do
    cap = Forge.Spend.ticket_cap(ticket, workflow)
    cap > 0 and (spent || 0) * 2 > cap
  end

  defp usage_high?(_ticket, _workflow), do: false

  # What the ticket is doing, its colour, and the tone the map's dot takes.
  defp doing(%Ticket{status: :stuck} = ticket, _items, _live, facts),
    do: {"stuck #{Format.lasted(ticket.updated_at, facts.now)}", "accent", :stuck}

  defp doing(_ticket, [first | _] = items, _live, facts) do
    since = items |> Enum.map(& &1.since) |> Enum.min(DateTime, fn -> first.since end)
    {"waiting #{Format.lasted(since, facts.now)}", "accent", :waiting}
  end

  # On hold, with nothing waiting on a person: neither amber nor info, because nothing is waiting
  # and nothing is moving. A run it started before the hold is still finishing, and says so.
  defp doing(%Ticket{held_at: held_at}, [], live, _facts) when held_at != nil do
    finishing = if match?(%{status: :running}, live), do: " · its run is finishing", else: ""
    {"on hold" <> finishing, nil, :held}
  end

  defp doing(ticket, [], live, facts) do
    case {facts.places[ticket.id], live} do
      {%{} = place, _live} ->
        {queued(place), "info", :running}

      {nil, %{status: :running} = job} ->
        {"running #{Format.lasted(job.started_at || job.inserted_at, facts.now)}#{attempt(job)}",
         "info", :running}

      {nil, %{status: :pending} = job} ->
        # The cap gates a workflow job and not a command (`Forge.Tickets.Doing.live/1`).
        if facts.paused and job.kind == :workflow,
          do: {"paused · spend", nil, :idle},
          else: {"waiting for a machine", nil, :running}

      {nil, nil} ->
        {"changed #{Format.ago_phrase(ticket.updated_at, facts.now)}", nil, :idle}
    end
  end

  defp queued(%{status: status} = place) when status in [:integrating, :merging],
    do: "queued #{place.index}/#{place.total} · #{status}"

  defp queued(place), do: "queued #{place.index}/#{place.total}"

  defp attempt(%{attempt: attempt}) when is_integer(attempt) and attempt > 1,
    do: " · attempt #{attempt}"

  defp attempt(_job), do: ""

  # The decision a waiting ticket needs, at full strength; else the agent's last line.
  defp latest([item | _] = items, _said), do: {decision(item, items), true}
  defp latest([], {text, _at}) when text != "", do: {"agent · " <> text, false}
  defp latest([], _said), do: {nil, false}

  defp decision(%{kind: :approval, detail: detail}, _items) do
    names = Enum.join(detail["approve"] || [], ", ")
    "Approve #{names} to move it to #{detail["to"]}."
  end

  defp decision(%{kind: :question}, items) do
    questions = Enum.filter(items, &(&1.kind == :question))
    n = length(questions)
    "Answer #{n} #{if n == 1, do: "question", else: "questions"}: #{hd(questions).detail.text}"
  end

  defp decision(%{kind: :stuck, detail: detail}, _items),
    do: "Stuck in #{detail.state}#{if detail.reason, do: ": #{detail.reason}"}."

  defp decision(%{kind: :review, detail: detail}, _items),
    do: "Waits in #{detail.state} for you to move it on."

  defp decision(%{kind: :chat}, _items), do: "Its conversation waits for your reply."

  defp decision(_item, _items), do: "Waits on you."

  @doc """
  The open tickets' states for the workflow map's dots: per state, one tone per ticket.
  """
  @spec dots([row()]) :: %{String.t() => [atom()]}
  def dots(rows) do
    Enum.group_by(rows, & &1.ticket.state, & &1.tone)
  end

  @doc "The rows as three-line list rows (`7a`)."
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :project, :string, default: nil, doc: "The project's name, for rows of one project."

  attr :named, :map,
    default: nil,
    doc:
      "Project names by id, for rows of several projects (the queue's Open tickets): each row " <>
        "reads `forge#53`, links into its own project and takes its DOM id from the ticket's id."

  attr :usage_always, :boolean,
    default: false,
    doc: "Draw the usage whenever there is one, not only past half the allowance."

  attr :now, :any, required: true

  def list(assigns) do
    ~H"""
    <ol id={@id} class="ticket-rows">
      <li :for={row <- @rows}>
        <.link
          id={if @named, do: "#{@id}-#{row.ticket.id}", else: "#{@id}-#{row.ticket.number}"}
          navigate={~p"/tickets/#{project_of(row, @project, @named)}/#{row.ticket.number}"}
          class={[
            "ui-row ticket-row",
            row.waiting && "ui-row--accent",
            row.held && "ticket-row--held"
          ]}
        >
          <div class="ui-row-body">
            <div class="ticket-row-head">
              <span class="ticket-row-number">
                {if @named, do: project_of(row, @project, @named)}#{row.ticket.number}
              </span>
              <span class="ui-row-title ticket-row-title">{row.ticket.title}</span>
              <span :if={row.ticket.ticket_type} class="ui-type-badge">{row.ticket.ticket_type}</span>
              <span :if={row.milestone} class="ticket-milestone">{row.milestone}</span>
              <span :if={not row.aged} class="ticket-row-age">{Format.ago(row.changed, @now)}</span>
            </div>
            <div class="ui-row-meta ticket-row-meta">
              <.workflow_track
                :if={row.steps && row.current >= 0}
                steps={row.steps}
                current={row.current}
                waiting={row.waiting}
                compact
              />
              <Indicators.state name={row.ticket.state} topology={row.topology} waiting={row.waiting} />
              <span class={["ticket-doing", row.doing_tone && "ticket-doing--#{row.doing_tone}"]}>
                {row.doing}
              </span>
              <span
                :if={row.usage && (row.usage_high || @usage_always)}
                class={["ticket-usage", row.usage_high && "ticket-usage--high"]}
              >
                {row.usage}
              </span>
            </div>
            <span
              :if={row.latest}
              class={["ui-row-latest", row.decision && "ticket-latest--decision"]}
            >
              {row.latest}
            </span>
          </div>
        </.link>
      </li>
    </ol>
    """
  end

  # The project a row belongs to: the one the list is of, or — in a list of several — its own.
  defp project_of(_row, project, nil), do: project
  defp project_of(row, _project, named), do: Map.fetch!(named, row.ticket.project_id)

  @doc "The rows as one table (`7g`, `7h`): the phone's three lines as columns."
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true

  def table(assigns) do
    ~H"""
    <div id={@id} class="tickets-table" role="table" aria-label="Open tickets">
      <div class="tickets-table-head" role="row">
        <span role="columnheader">#</span>
        <span role="columnheader">title · latest</span>
        <span role="columnheader">step</span>
        <span role="columnheader">doing</span>
        <span role="columnheader">usage</span>
        <span role="columnheader">changed</span>
      </div>
      <.link
        :for={row <- @rows}
        id={"#{@id}-#{row.ticket.number}"}
        navigate={~p"/tickets/#{@project}/#{row.ticket.number}"}
        role="row"
        class={[
          "tickets-table-row",
          row.waiting && "tickets-table-row--waiting",
          row.held && "ticket-row--held"
        ]}
      >
        <span role="cell" class="ticket-row-number">#{row.ticket.number}</span>
        <span role="cell" class="tickets-table-title">
          <span class="ticket-row-title">
            {row.ticket.title}
            <span :if={row.ticket.ticket_type} class="ui-type-badge">{row.ticket.ticket_type}</span>
            <span :if={row.milestone} class="ticket-milestone">{row.milestone}</span>
          </span>
          <span :if={row.latest} class={["ui-row-latest", row.decision && "ticket-latest--decision"]}>
            {row.latest}
          </span>
        </span>
        <span role="cell" class="tickets-table-step">
          <Indicators.state name={row.ticket.state} topology={row.topology} waiting={row.waiting} />
          <.workflow_track
            :if={row.steps && row.current >= 0}
            steps={row.steps}
            current={row.current}
            waiting={row.waiting}
            compact
          />
        </span>
        <span
          role="cell"
          class={["ticket-doing", row.doing_tone && "ticket-doing--#{row.doing_tone}"]}
        >
          {row.doing}
        </span>
        <span role="cell" class={["ticket-usage", row.usage_high && "ticket-usage--high"]}>
          {row.usage || "—"}
        </span>
        <span role="cell" class="ticket-row-age">{Format.ago(row.changed, @now)}</span>
      </.link>
    </div>
    """
  end

  @doc """
  The history (`7a`, `7g`): done and cancelled tickets, newest first, folded beneath the open
  ones — a `<details>`, so opening it is the browser's and costs no round trip.
  """
  attr :tickets, :list, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true

  def history(assigns) do
    assigns = assign(assigns, :kinds, Topology.kinds(assigns.tickets))

    ~H"""
    <details :if={@tickets != []} id="ticket-history" class="ticket-history">
      <summary class="ticket-history-summary">
        <span class="ticket-history-mark" aria-hidden="true">▸</span>
        <.eyebrow>History · {length(@tickets)}</.eyebrow>
        <span class="ticket-history-hint">newest first</span>
      </summary>
      <ol class="ticket-rows">
        <li :for={ticket <- @tickets} id={"history-#{ticket.number}"}>
          <.link
            navigate={~p"/tickets/#{@project}/#{ticket.number}"}
            class="ui-row ticket-row ticket-row--history"
          >
            <div class="ui-row-body">
              <div class="ticket-row-head">
                <span class="ticket-row-number">#{ticket.number}</span>
                <span class="ui-row-title ticket-row-title">{ticket.title}</span>
                <span class="ticket-row-age">{Format.ago(ticket.updated_at, @now)}</span>
              </div>
              <div class="ui-row-meta ticket-row-meta">
                <Indicators.state name={ticket.state} topology={@kinds[ticket.id]} />
                <Indicators.status status={ticket.status} />
                <span :if={Format.spent(ticket.usage)} class="ticket-usage">
                  {Format.spent(ticket.usage)}
                </span>
              </div>
            </div>
          </.link>
        </li>
      </ol>
    </details>
    """
  end
end
