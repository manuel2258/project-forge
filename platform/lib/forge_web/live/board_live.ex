defmodule ForgeWeb.BoardLive do
  @moduledoc """
  Tickets by state, per project, at the full viewport width.

  The columns are the workflow topology, so capping the measure would destroy the artefact.
  Columns cap at four rows and then say how many remain: a column that scrolls independently
  hides its own count and breaks the board as a shape. Finding a specific ticket is a job for a
  finder, not for this page.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Events, Projects, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.Format

  @rows 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(:page_title, "Board") |> load()}
  end

  defp load(socket) do
    boards =
      for project <- Projects.list() do
        tickets = Tickets.list(project)
        by_state = Enum.group_by(tickets, & &1.state)
        workflow = workflow(tickets)

        columns =
          for state <- states(tickets, workflow) do
            rows = Map.get(by_state, state, [])

            %{
              name: state,
              topology: topology(workflow, state),
              tickets: rows,
              shown: Enum.take(rows, @rows),
              more: max(length(rows) - @rows, 0)
            }
          end

        %{
          project: project,
          columns: columns,
          open: Enum.count(tickets, &(&1.status in [:active, :stuck])),
          waiting: Enum.count(tickets, &(&1.status == :stuck))
        }
      end

    assign(socket, boards: boards, now: DateTime.utc_now())
  end

  defp workflow([]), do: nil

  defp workflow([first | _rest]) do
    case Tickets.parsed_workflow(first) do
      {:ok, workflow} -> workflow
      {:error, _errors} -> nil
    end
  end

  # Column order follows the first ticket's pinned workflow, walked from its initial state;
  # states only other tickets know are appended.
  defp states([], _workflow), do: []
  defp states(tickets, nil), do: tickets |> Enum.map(& &1.state) |> Enum.uniq()

  defp states(tickets, workflow) do
    ordered = walk(workflow, [workflow.initial], [])
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

  defp topology(nil, _name), do: :unknown

  defp topology(workflow, name) do
    state = Workflow.state(workflow, name)

    cond do
      is_nil(state) -> :unknown
      Workflow.State.job?(state) -> :job
      Workflow.terminal?(workflow, name) -> :terminal
      true -> :human
    end
  end

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure={nil}>
      <h1 class="text-2xl font-semibold -tracking-[.025em]">Board</h1>
      <p :if={@boards == []} class="mt-4 text-sm opacity-60">
        No projects yet. A project appears here once one is registered.
      </p>

      <section :for={board <- @boards} class="mt-8 flex flex-col gap-3">
        <header class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <h2 class="font-medium">{board.project.name}</h2>
          <span class="font-mono text-[12.5px] opacity-60">{board.open} open</span>
          <span :if={board.waiting > 0} class="font-mono text-[12.5px] text-accent">
            {board.waiting} waiting on you
          </span>
        </header>

        <div class="flex gap-px overflow-x-auto bg-base-300">
          <div
            :for={column <- board.columns}
            class={[
              "flex w-60 shrink-0 flex-col gap-3 p-3",
              if(column.topology == :human, do: "bg-base-200", else: "bg-base-100"),
              column.topology == :terminal && "opacity-60"
            ]}
          >
            <div class="flex items-baseline justify-between gap-2">
              <.state name={column.name} topology={column.topology} />
              <span class="font-mono text-[11px] opacity-50">{length(column.tickets)}</span>
            </div>

            <p :if={column.tickets == []} class="text-[13px] opacity-40">nothing in this state</p>

            <div
              :for={ticket <- column.shown}
              class={[
                "flex flex-col gap-1 pl-2",
                if(ticket.status == :stuck,
                  do: "border-l-2 border-accent",
                  else: "border-l border-base-300"
                )
              ]}
            >
              <.ticket_link ticket={ticket} project={board.project.name} />
              <span
                :if={ticket.status == :stuck}
                class="font-mono text-[11px] tracking-[.14em] uppercase text-accent"
              >
                stuck {Format.ago(ticket.updated_at, @now)}
              </span>
            </div>

            <span :if={column.more > 0} class="font-mono text-[11px] opacity-50">
              {column.more} more →
            </span>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
