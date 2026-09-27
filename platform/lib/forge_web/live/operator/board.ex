defmodule ForgeWeb.Operator.Board do
  @moduledoc """
  A project's tickets arranged as the columns of its workflow.

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
  no longer parses.

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
      Workflow.State.job?(state) -> :job
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
      next = workflow |> Workflow.transitions_from(state) |> Enum.map(& &1.to)
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
  attr :now, :any, required: true

  def column(assigns) do
    assigns = assign(assigns, id: column_id(assigns.project, assigns.column.name))

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

      <.board_ticket :for={ticket <- @column.shown} ticket={ticket} project={@project} now={@now} />

      <div :if={@column.more > 0} id={@id <> "-more"} class="hidden flex-col gap-3">
        <.board_ticket
          :for={ticket <- Enum.drop(@column.tickets, length(@column.shown))}
          ticket={ticket}
          project={@project}
          now={@now}
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

  attr :ticket, :map, required: true
  attr :project, :string, required: true
  attr :now, :any, required: true

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
    </div>
    """
  end
end
