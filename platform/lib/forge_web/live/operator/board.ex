defmodule ForgeWeb.Operator.Board do
  @moduledoc """
  A project's tickets arranged as the columns of its workflow — one lane of columns per ticket
  type, since each type is a workflow of its own (`docs/design/ticket-types.md` § The board).

  Shared by `/board`, which draws every project at once, and `/projects/:name`, which draws one.
  The two differ in exactly one way — how many rows a column shows before it says how many
  remain — and in nothing else, which is why the arrangement lives here rather than twice.
  """

  use Phoenix.Component

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.Tickets
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias Phoenix.LiveView.JS

  @type column :: %{
          name: String.t(),
          topology: :job | :human | :terminal | :unknown,
          tickets: [Tickets.Ticket.t()],
          shown: [Tickets.Ticket.t()],
          more: non_neg_integer()
        }

  @type lane :: %{ticket_type: String.t() | nil, heading: String.t() | nil, columns: [column()]}

  @doc """
  The lanes of a project's board: one per ticket type, each with the columns of its own workflow,
  the single file's tickets first and then the types by name.

  A type's lane is always headed by its name — with several types and tickets of only one of
  them on the board, the columns would otherwise not say whose they are. The single file's lane
  is headed only beside others, as `workflow.yml`, which is what a project that has moved to types
  still has tickets of; alone it is drawn exactly as before types. A type with no tickets has no
  lane: a lane of empty columns is a workflow, and the project page already shows those.
  """
  @spec lanes([Tickets.Ticket.t()], keyword()) :: [lane()]
  def lanes(tickets, opts \\ []) do
    # `nil` sorts before every string, so the single file's lane comes first. The sort is an
    # equivalent mutant up to 32 types — a map that small iterates in key order already, so taking
    # it away changes nothing a test can build a board to see — and is kept for the 33rd.
    groups =
      tickets
      |> Enum.group_by(& &1.ticket_type)
      |> Enum.sort_by(fn {type, _tickets} -> type end)

    for {type, lane_tickets} <- groups do
      %{
        ticket_type: type,
        heading: type || if(length(groups) > 1, do: "workflow.yml"),
        columns: columns(lane_tickets, workflow(lane_tickets), opts)
      }
    end
  end

  @doc """
  Columns for `tickets`, in the order their workflow reaches the states.

  `:cap` is how many rows a column shows; `nil` shows all of them. `/board` caps at four because
  a column that scrolls independently hides its own count and breaks the board as a shape — the
  objection is to a column with its own scrollbar, not to a long one, so a single project's board
  leaves them uncapped and lets the page scroll.
  """
  @spec columns([Tickets.Ticket.t()], Workflow.t() | nil, keyword()) :: [column()]
  def columns(tickets, workflow, opts \\ []) do
    cap = Keyword.get(opts, :cap)
    by_state = Enum.group_by(tickets, & &1.state)

    for state <- states(tickets, workflow) do
      rows = Map.get(by_state, state, [])
      shown = if cap, do: Enum.take(rows, cap), else: rows

      %{
        name: state,
        topology: topology(workflow, state),
        tickets: rows,
        shown: shown,
        more: length(rows) - length(shown)
      }
    end
  end

  @doc """
  The workflow to arrange by: the first ticket's pinned copy, or `nil` when there is none or it
  no longer parses. Asked of one lane's tickets, which share a type.

  A ticket's own pinned workflow rather than the repository's current one, because the board is
  drawing tickets and a ticket's states are the ones it was admitted with.
  """
  @spec workflow([Tickets.Ticket.t()]) :: Workflow.t() | nil
  def workflow([]), do: nil

  def workflow([first | _rest]) do
    case Tickets.parsed_workflow(first) do
      {:ok, workflow} -> workflow
      {:error, _errors} -> nil
    end
  end

  @doc "What kind of state this is, for the glyph that distinguishes them."
  @spec topology(Workflow.t() | nil, String.t()) :: :job | :human | :terminal | :unknown
  def topology(nil, _name), do: :unknown

  def topology(workflow, name) do
    state = Workflow.state(workflow, name)

    cond do
      is_nil(state) -> :unknown
      # A command state runs work on entry as a job state does, and draws as one: `▸`.
      Workflow.State.runs?(state) -> :job
      Workflow.terminal?(workflow, name) -> :terminal
      true -> :human
    end
  end

  @doc """
  A workflow's state names in the order it reaches them, from `initial` outwards.

  Public because the board is not the only thing that lists a workflow's states: the project
  page shows the workflow itself directly beneath its board, and the two reading in different
  orders on one page is worse than either order being wrong.
  """
  @spec order(Workflow.t()) :: [String.t()]
  def order(%Workflow{} = workflow), do: walk(workflow, [workflow.initial], [])

  # Column order follows the workflow, walked from its initial state; states only some tickets
  # know — left behind by an older pinned workflow — are appended rather than dropped.
  defp states([], _workflow), do: []
  defp states(tickets, nil), do: tickets |> Enum.map(& &1.state) |> Enum.uniq()

  defp states(tickets, workflow) do
    ordered = order(workflow)
    ordered ++ (tickets |> Enum.map(& &1.state) |> Enum.uniq() |> Enum.reject(&(&1 in ordered)))
  end

  defp walk(_workflow, [], seen), do: Enum.reverse(seen)

  defp walk(workflow, [state | rest], seen) do
    if state in seen do
      walk(workflow, rest, seen)
    else
      # Along `on_conflict` too: an integrating state is reached by nothing else.
      next = workflow |> Workflow.edges_from(state) |> Enum.map(& &1.to)
      walk(workflow, rest ++ next, [state | seen])
    end
  end

  @doc """
  One column of a board.

  Both boards render this. Extracting only the arithmetic and leaving thirty-five lines of
  markup copied between two pages would have left them free to drift in every way an operator
  can actually see, which is the drift that matters.

  **Below `sm` a column is a section** of a board that stacks (`docs/design/ui.md` § The phone):
  full width, in the order the columns take on a laptop, so the workflow reads top to bottom as
  it reads left to right. A state with nothing in it is its heading and a muted 0.

  **"N more" is a control, at every width**, and the tickets it reveals are already on the page:
  it shows them in place. The cap exists so a column never grows its own scrollbar; expanding one
  lets the page scroll instead.
  """
  attr :column, :map, required: true
  attr :project, :string, required: true
  attr :ticket_type, :string, default: nil
  attr :now, :any, required: true
  attr :places, :map, default: %{}, doc: "`Forge.MergeQueue.places/1`, for the queued flag"

  def column(assigns) do
    assigns =
      assign(assigns, id: column_id(assigns.project, assigns.ticket_type, assigns.column.name))

    ~H"""
    <div
      id={@id}
      class={[
        "flex w-full shrink-0 flex-col gap-3 p-3 sm:w-60",
        if(@column.topology == :human, do: "bg-base-200", else: "bg-base-100"),
        @column.topology == :terminal && "opacity-60"
      ]}
    >
      <div class="flex items-baseline justify-between gap-2">
        <.state name={@column.name} topology={@column.topology} />
        <span class={[
          "font-mono text-[11px]",
          if(@column.tickets == [], do: "opacity-30", else: "opacity-50")
        ]}>
          {length(@column.tickets)}
        </span>
      </div>

      <.board_ticket
        :for={ticket <- @column.shown}
        ticket={ticket}
        project={@project}
        now={@now}
        place={@places[ticket.id]}
      />

      <div :if={@column.more > 0} id={@id <> "-more"} class="hidden flex-col gap-3">
        <.board_ticket
          :for={ticket <- Enum.drop(@column.tickets, length(@column.shown))}
          ticket={ticket}
          project={@project}
          now={@now}
          place={@places[ticket.id]}
        />
      </div>

      <button
        :if={@column.more > 0}
        type="button"
        id={@id <> "-expand"}
        phx-click={JS.show(to: "#" <> @id <> "-more", display: "flex") |> JS.hide()}
        class="flex min-h-[46px] items-center font-mono text-[11px] text-primary hover:underline"
      >
        {@column.more} more ↓
      </button>
    </div>
    """
  end

  @doc """
  A column's id: the project and the state, encoded, because "N more" finds the column's hidden
  tickets by it and a state name may hold what a CSS selector reads as syntax — `code.review` is
  an id and a class. Unpadded URL-safe base64 is letters, digits, `-` and `_`, which a selector
  takes as they are after the prefix.
  """
  @spec column_id(String.t(), String.t()) :: String.t()
  def column_id(project, state),
    do: "column-" <> Base.url_encode64(project <> "\0" <> state, padding: false)

  @doc """
  A column's id in a type's lane: `implementing` in two types is two columns. The single file's
  lane keeps `column_id/2`'s, so a project without types addresses its columns as it always did.
  """
  @spec column_id(String.t(), String.t() | nil, String.t()) :: String.t()
  def column_id(project, nil, state), do: column_id(project, state)

  def column_id(project, type, state),
    do: "column-" <> Base.url_encode64(project <> "\0" <> type <> "\0" <> state, padding: false)

  @doc """
  A board: its lanes, each under its heading when there is more than one, each a row of columns
  that stacks below `sm`. Both boards draw this, so a lane looks the same on either.
  """
  attr :lanes, :list, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true
  attr :places, :map, default: %{}, doc: "`Forge.MergeQueue.places/1`, for the queued flag"

  def board(assigns) do
    ~H"""
    <div :for={lane <- @lanes} class="flex flex-col gap-2">
      <h3 :if={lane.heading} data-lane class="mt-2 font-mono text-[12.5px] font-medium">
        {lane.heading}
      </h3>
      <div class="flex flex-col gap-px bg-base-300 sm:flex-row sm:overflow-x-auto">
        <.column
          :for={column <- lane.columns}
          column={column}
          project={@project}
          ticket_type={lane.ticket_type}
          now={@now}
          places={@places}
        />
      </div>
    </div>
    """
  end

  attr :ticket, :map, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true
  attr :place, :map, default: nil

  defp board_ticket(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-1 pl-2",
      if(@ticket.status == :stuck,
        do: "border-l-2 border-accent",
        else: "border-l border-base-300"
      )
    ]}>
      <.ticket_link ticket={@ticket} project={@project} />
      <span
        :if={@ticket.status == :stuck}
        class="font-mono text-[11px] tracking-[.14em] uppercase text-accent"
      >
        stuck {Format.ago(@ticket.updated_at, @now)}
      </span>
      <%!-- A flag, as `stuck` is: the ticket keeps its state and its column. --%>
      <span :if={@place} class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
        queued {@place.index}/{@place.total}
      </span>
    </div>
    """
  end
end
