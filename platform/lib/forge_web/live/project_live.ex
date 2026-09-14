defmodule ForgeWeb.ProjectLive do
  @moduledoc """
  One project: what it is, what its workflow says, and its own board.

  The board here is `/board`'s, for one project and uncapped — the four-row cap exists so a
  column never grows its own scrollbar and hides its count, and with one project on the page
  there is room to let the page scroll instead. See `ForgeWeb.Operator.Board`.

  The workflow is shown and never edited. It lives in the project's repository at
  `.forge/workflow.yml`, so this page carries the clone URL: the operator who wants to change a
  workflow is standing exactly here, and git is the only way to do it.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Events, Projects, Tickets}
  alias Forge.Git.Url
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias ForgeWeb.Operator.Admission
  alias ForgeWeb.Operator.Board

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    project = Projects.by_name(name) || raise Ecto.NoResultsError, queryable: Projects.Project
    if connected?(socket), do: Events.subscribe()

    {:ok, socket |> assign(project_id: project.id, page_title: project.name) |> load()}
  end

  defp load(%{assigns: %{project_id: id}} = socket) do
    project = Projects.get!(id)
    tickets = Tickets.list(project)

    assign(socket,
      project: project,
      tickets: tickets,
      columns: Board.columns(tickets, Board.workflow(tickets)),
      # The repository's current workflow, which is what the *next* ticket will pin — not the
      # board's, which is the workflow the tickets on it were admitted with. On a project whose
      # workflow has just changed these are different, and saying so is the point.
      current: Tickets.admissible(project),
      clone_url: Url.for(project),
      mirror: Projects.mirror(project),
      open: Enum.count(tickets, &(&1.status in [:active, :stuck])),
      waiting: Enum.count(tickets, &(&1.status == :stuck)),
      spent: Enum.reduce(tickets, Decimal.new(0), &Decimal.add(&2, &1.cost_usd)),
      events: Events.for_project(project.id, 8),
      paused: Forge.Spend.paused?(),
      now: DateTime.utc_now()
    )
  end

  # Only this project's tickets. `load/1` shells out to git several times — the workflow, each
  # state's prompt, the mirror — so reloading on every ticket in the system would spend that on
  # events belonging to other projects.
  #
  # The project is read from the row rather than matched against the tickets already loaded: a
  # ticket admitted *since* this page mounted is exactly the one that has to appear, and it is
  # not in that list. One indexed read is far less than what it saves.
  @impl true
  def handle_info({:ticket_changed, id}, socket) do
    project_id = socket.assigns.project.id

    case Forge.Repo.get(Forge.Tickets.Ticket, id) do
      %{project_id: ^project_id} -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  # In the order the workflow reaches them, which is the order the board above draws its columns
  # in. Alphabetical would put `merged` before `planning` on a page whose whole subject is what
  # happens in what order.
  defp state_rows(%Workflow{} = workflow) do
    for name <- Board.order(workflow),
        state = workflow.states[name],
        not is_nil(state) do
      %{
        name: name,
        state: state,
        topology: Board.topology(workflow, name),
        out: Workflow.transitions_from(workflow, name)
      }
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:board} measure={nil}>
      <.link navigate={~p"/board"} class="font-mono text-[12.5px] opacity-60 hover:opacity-100">
        ‹ Board
      </.link>

      <header class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">{@project.name}</h1>
        <span class="font-mono text-[12.5px] opacity-60">{@open} open</span>
        <span :if={@waiting > 0} class="font-mono text-[12.5px] text-accent">
          {@waiting} waiting on you
        </span>
        <.paused :if={@paused} reason="spend" />
        <.link
          navigate={~p"/tickets/new?project=#{@project.name}"}
          class="ml-auto flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          New ticket ›
        </.link>
      </header>

      <div class="mt-6 flex flex-col gap-10 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Board</h2>

          <p :if={@tickets == []} class="mt-3 text-sm opacity-60">
            No tickets yet.
            <.link
              navigate={~p"/tickets/new?project=#{@project.name}"}
              class="text-primary hover:underline"
            >
              Admit the first one ›
            </.link>
          </p>

          <div :if={@tickets != []} class="mt-3 flex gap-px overflow-x-auto bg-base-300">
            <Board.column
              :for={column <- @columns}
              column={column}
              project={@project.name}
              now={@now}
            />
          </div>

          <h2 class="mt-8 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Workflow the next ticket will pin
          </h2>

          <div
            :if={not Admission.ready?(@current)}
            class="mt-3 rounded-box border border-warning/40 bg-warning/5 p-4"
          >
            <p class="text-sm/[1.55]">
              This project cannot take a ticket: {Admission.explain(elem(@current, 1))}.
            </p>
            <p class="mt-2 text-sm/[1.55] opacity-70">
              A workflow lives in the repository, so it is pushed rather than edited here.
            </p>
          </div>

          <table :if={Admission.ready?(@current)} class="mt-3 w-full text-[12.5px]">
            <tbody>
              <tr
                :for={row <- state_rows(elem(@current, 1))}
                class="border-b border-base-300/60 align-top"
              >
                <td class="py-2 pr-3">
                  <.state name={row.name} topology={row.topology} />
                  <div
                    :if={row.name == elem(@current, 1).initial}
                    class="font-mono text-[11px] opacity-50"
                  >
                    initial
                  </div>
                </td>
                <td class="py-2 pr-3 font-mono opacity-70">
                  <div :if={row.state.prompt}>{row.state.prompt}</div>
                  <div :if={row.state.produces != []} class="opacity-60">
                    → {Enum.join(row.state.produces, ", ")}
                  </div>
                  <div :if={is_nil(row.state.prompt)} class="opacity-50">no job</div>
                </td>
                <td class="py-2 pr-3 font-mono opacity-70">
                  <div :if={row.state.budget}>
                    {row.state.budget.turns} turns · {Format.windows(row.state.budget.cost) || "—"}
                  </div>
                </td>
                <td class="py-2 font-mono opacity-70">
                  <div :for={t <- row.out}>
                    {t.to}
                    <span class="opacity-50">on {ForgeCore.Workflow.Transition.outcome(t)}</span>
                    <span :if={t.approve != []} class="text-primary">
                      · approves {Enum.join(t.approve, ", ")}
                    </span>
                  </div>
                  <div :if={row.out == []} class="opacity-50">terminal</div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Repository</h2>
          <div class="mt-3 rounded-box bg-base-200 px-3 py-2">
            <p class="font-mono text-[12.5px] break-all">{@clone_url}</p>
          </div>
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <.fact label="default branch">{@project.default_branch}</.fact>
            <.fact label="mirror">{@mirror || "none"}</.fact>
            <.fact label="worker seed">
              {(@project.seed_id && String.slice(@project.seed_id, 0, 16)) || "none"}
            </.fact>
            <.fact label="tickets">{length(@tickets)}</.fact>
            <.fact label="spent">{Format.windows(@spent) || "—"}</.fact>
          </dl>

          <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            Latest activity
          </h2>
          <ol class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
            <li :for={event <- @events} class="flex min-w-0 gap-2">
              <span class="shrink-0 opacity-50">
                {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
              </span>
              <span class="min-w-0 truncate">{event.type}</span>
            </li>
            <li :if={@events == []} class="opacity-50">nothing yet</li>
          </ol>
        </aside>
      </div>
    </Layouts.app>
    """
  end
end
