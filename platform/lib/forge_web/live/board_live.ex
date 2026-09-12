defmodule ForgeWeb.BoardLive do
  @moduledoc "Tickets by state, per project."

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.{Events, Projects, Tickets}
  alias ForgeCore.Workflow

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(:page_title, "Board") |> load()}
  end

  defp load(socket) do
    boards =
      for project <- Projects.list() do
        tickets = Tickets.list(project)
        states = states(tickets)
        by_state = Enum.group_by(tickets, & &1.state)
        %{project: project, columns: Enum.map(states, &{&1, Map.get(by_state, &1, [])})}
      end

    assign(socket, :boards, boards)
  end

  # Column order follows the first ticket's pinned workflow, walked from its initial state;
  # states only other tickets know are appended.
  defp states([]), do: []

  defp states([first | _] = tickets) do
    workflow = Tickets.workflow(first)
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

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col gap-8">
        <h1 class="text-xl font-semibold">Board</h1>
        <p :if={@boards == []} class="opacity-60">No projects yet.</p>
        <section :for={board <- @boards} class="flex flex-col gap-2">
          <h2 class="font-medium">{board.project.name}</h2>
          <div class="flex gap-3 overflow-x-auto pb-2">
            <div :for={{state, tickets} <- board.columns} class="w-56 shrink-0 flex flex-col gap-2">
              <div class="text-xs uppercase tracking-wide opacity-60 font-mono">
                {state} · {length(tickets)}
              </div>
              <div :for={ticket <- tickets} class="card bg-base-200 shadow-sm">
                <div class="card-body p-3 gap-1 text-sm">
                  <.ticket_link ticket={ticket} project={board.project.name} />
                  <div class="flex gap-2 items-center">
                    <.status_badge status={ticket.status} />
                    <span class="opacity-60">${ticket.cost_usd}</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
