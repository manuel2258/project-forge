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

  alias Forge.{Events, Projects, Tickets}
  alias ForgeWeb.Operator.Board

  @rows 4

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()
    {:ok, socket |> assign(:page_title, "Board") |> load()}
  end

  defp load(socket) do
    boards =
      for project <- Projects.list(socket.assigns.current_scope.user) do
        tickets = Tickets.list(project)

        %{
          project: project,
          columns: Board.columns(tickets, Board.workflow(tickets), cap: @rows),
          open: Enum.count(tickets, &(&1.status in [:active, :stuck])),
          waiting: Enum.count(tickets, &(&1.status == :stuck))
        }
      end

    assign(socket, boards: boards, paused: Forge.Spend.paused?(), now: DateTime.utc_now())
  end

  @impl true
  def handle_info({:ticket_changed, _id}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure={nil}>
      <div class="flex flex-wrap items-center gap-3">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Board</h1>
        <%!-- Neutral, and only here and on the ticket: a pause is resolved by the clock, so it
              never enters the queue. See docs/design/capacity.md. --%>
        <.paused :if={@paused} reason="spend" />
      </div>
      <p :if={@boards == []} class="mt-4 text-sm opacity-60">
        No projects yet.
        <.link navigate={~p"/projects/new"} class="text-primary hover:underline">
          Register the first one ›
        </.link>
      </p>

      <section :for={board <- @boards} class="mt-8 flex flex-col gap-3">
        <header class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <.link navigate={~p"/projects/#{board.project.name}"} class="font-medium hover:underline">
            {board.project.name}
          </.link>
          <span class="font-mono text-[12.5px] opacity-60">{board.open} open</span>
          <span :if={board.waiting > 0} class="font-mono text-[12.5px] text-accent">
            {board.waiting} waiting on you
          </span>
        </header>

        <div class="flex gap-px overflow-x-auto bg-base-300">
          <Board.column
            :for={column <- board.columns}
            column={column}
            project={board.project.name}
            now={@now}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
