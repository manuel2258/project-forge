defmodule ForgeWeb.QueueLive do
  @moduledoc "The home screen: everything waiting on the operator, answerable in place."

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.Components

  alias Forge.{Events, Projects, Queue}
  alias ForgeWeb.Operator.Actions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(:page_title, "Queue") |> load()}
  end

  defp load(socket) do
    projects = Map.new(Projects.list(), &{&1.id, &1.name})
    items = Enum.map(Queue.items(), &Map.put(&1, :project, projects[&1.ticket.project_id]))
    assign(socket, :items, items)
  end

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      :unknown -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl flex flex-col gap-4">
        <h1 class="text-xl font-semibold">Queue</h1>
        <p :if={@items == []} class="opacity-60" id="queue-empty">Nothing needs you right now.</p>
        <div
          :for={item <- @items}
          class="flex flex-col gap-1"
          id={"item-#{item.kind}-#{item.ticket.id}-#{item.question && item.question.id}"}
        >
          <.ticket_link ticket={item.ticket} project={item.project} />
          <.question_card
            :if={item.kind == :question}
            question={item.question}
            ticket_id={item.ticket.id}
          />
          <.approval_card :if={item.kind == :approval} ticket={item.ticket} pending={item.detail} />
          <.transition_card
            :if={item.kind in [:stuck, :review]}
            ticket={item.ticket}
            transitions={transitions(item)}
            label={if item.kind == :stuck, do: "Stuck", else: "Ready for review"}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp transitions(%{kind: :review, detail: %{transitions: transitions}}), do: transitions

  defp transitions(%{kind: :stuck, ticket: ticket}) do
    workflow = Forge.Tickets.workflow(ticket)

    workflow
    |> ForgeCore.Workflow.transitions_from(ticket.state)
    |> Enum.map(& &1.to)
    |> Enum.uniq()
  end
end
