defmodule ForgeWeb.ProjectLive do
  @moduledoc """
  One project: what it is, what its workflows say — one per ticket type, or the one — and its
  own board.

  The board here is `/board`'s, for one project and uncapped — the four-row cap exists so a
  column never grows its own scrollbar and hides its count, and with one project on the page
  there is room to let the page scroll instead. See `ForgeWeb.Operator.Board`.

  The workflow is shown and never edited. It lives in the project's repository at
  `.forge/workflow.yml`, or `.forge/workflows/<type>.yml` per type, so this page carries the clone
  URL: the operator who wants to change a
  workflow is standing exactly here, and git is the only way to do it.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Conversations, Events, Operator, Projects, Proposals, Tickets}
  alias Forge.Git.Url
  alias ForgeCore.Workflow
  alias ForgeWeb.Format
  alias ForgeWeb.Operator.Admission
  alias ForgeWeb.Operator.Board
  alias ForgeWeb.Operator.Drafts

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(project_id: project.id, page_title: project.name, drafts: Drafts.init())
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  defp load(%{assigns: %{project_id: id}} = socket) do
    project = Projects.get!(id)
    tickets = Tickets.list(project)

    assign(socket,
      project: project,
      tickets: tickets,
      lanes: Board.lanes(tickets),
      # The repository's current workflow, which is what the *next* ticket will pin — not the
      # board's, which is the workflow the tickets on it were admitted with. On a project whose
      # workflow has just changed these are different, and saying so is the point.
      current: Tickets.types(project),
      clone_url: Url.for(project),
      mirrors: Projects.list_mirrors(project),
      open: Enum.count(tickets, &(&1.status in Forge.Tickets.Ticket.open_statuses())),
      waiting: Enum.count(tickets, &(&1.status == :stuck)),
      # Every ticket's, a cancelled one's too: cancelling hides a ticket, it does not unspend it.
      spent:
        project |> Tickets.all() |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.cost_usd)),
      events: Events.for_project(project.id, 8),
      # The board is the workflow, and a conversation is not on it — it has no state to be in.
      # Without this a chat is a thing you can start from this page and then cannot find from it.
      chats: Conversations.summaries(project_id: project.id),
      proposals: open_proposals(project),
      paused: Forge.Spend.paused?(),
      now: DateTime.utc_now()
    )
  end

  # A fact row, not the table — the table is the settings page's. One mirror having stopped
  # working is worth a word here because this is the page somebody actually opens;
  # `docs/design/git-hosting.md` § What the mirrors say about themselves.
  defp mirror_summary([]), do: "none"

  defp mirror_summary(mirrors) do
    mirrors
    |> Enum.map_join(", ", fn
      %{name: name, last_status: "failed"} -> "#{name} (failing)"
      %{name: name} -> name
    end)
  end

  # Flattened here rather than in the component, so the component takes a list of plain maps and
  # can be rendered from a test without a database.
  defp open_proposals(project) do
    # Every ticket's number, a cancelled one's too: its proposals are still its.
    numbers = Map.new(Tickets.all(project), &{&1.id, &1.number})

    Enum.map(Proposals.open(project.id), fn found ->
      {title, body, readable, suggested} =
        case ForgeCore.Proposal.parse(found.version.content || "") do
          {:ok, proposal} -> {proposal.title, proposal.body, true, proposal.ticket_type}
          {:error, errors} -> {nil, ForgeCore.Error.format(errors), false, nil}
        end

      %{
        version_id: found.version.id,
        file: found.artifact.name,
        title: title,
        body: body,
        readable: readable,
        suggested: suggested,
        project: project.name,
        ticket_number: Map.get(numbers, found.job.ticket_id)
      }
    end)
  end

  # Typing into a proposal's comment or choosing its type (`ForgeWeb.Operator.Drafts`). This page
  # does not route through `ForgeWeb.Operator.Actions`, so it carries the clause itself.
  @impl true
  def handle_event("draft:change", params, socket) do
    case Drafts.handle("draft:change", params, socket) do
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  def handle_event(
        "decide_proposal",
        %{"version_id" => id, "decision" => decision} = params,
        socket
      ) do
    user = socket.assigns.current_scope.user
    comment = params["comment"]

    result =
      case decision do
        "accepted" -> Operator.accept_proposal(id, user, comment, params["ticket_type"])
        "declined" -> Operator.decline_proposal(id, user, comment)
      end

    # Decided, so the draft goes; refused, so what was typed stays to be sent again.
    case result do
      {:ok, %Forge.Tickets.Ticket{number: number}} ->
        {:noreply, socket |> decided(params, "Admitted as ticket #{number}.") |> load()}

      {:ok, _decision} ->
        {:noreply, socket |> decided(params, "Declined.") |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, explain(reason)) |> load()}
    end
  end

  defp decided(socket, params, message),
    do: socket |> Drafts.forget(params["draft"]) |> put_flash(:info, message)

  defp explain(:already_decided), do: "Someone has already decided that one."
  defp explain({:invalid_proposal, errors}), do: ForgeCore.Error.format(errors)

  # Anything else is why the project could not admit it, in the sentence the ticket form uses — a
  # type not chosen on a project with several, most often, or a workflow that does not parse.
  defp explain(reason), do: "Not admitted: " <> Admission.explain(reason) <> "."

  # Only this project's tickets. `load/1` shells out to git several times — the workflow, each
  # state's prompt, the mirror — so reloading on every ticket in the system would spend that on
  # events belonging to other projects.
  #
  # The project is read from the row rather than matched against the tickets already loaded: a
  # ticket admitted *since* this page mounted is exactly the one that has to appear, and it is
  # not in that list. One indexed read is far less than what it saves.
  # A project chat's changes are broadcast with no ticket, and are not this page's.
  @impl true
  def handle_info({:ticket_changed, nil}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, socket) do
    project_id = socket.assigns.project.id

    case Forge.Repo.get(Forge.Tickets.Ticket, id) do
      %{project_id: ^project_id} -> {:noreply, load(socket)}
      _other -> {:noreply, socket}
    end
  end

  defp current_types({:ok, %{types: types}}), do: types
  defp current_types(_error), do: []

  defp multiple?(current), do: length(current_types(current)) > 1

  # The types an Accept is asked to choose between, each marked when its workflow does not parse:
  # only when there is more than one.
  defp choosable(current) do
    case current_types(current) do
      [_, _ | _] = types ->
        Enum.map(types, &%{name: &1.name, parses: Admission.ready?(&1.workflow)})

      _none_or_one ->
        []
    end
  end

  defp not_types({:ok, %{not_types: not_types}}), do: not_types
  defp not_types(_error), do: []

  defp description(%{workflow: {:ok, workflow}}), do: workflow.description
  defp description(_type), do: nil

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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:board}
      measure={nil}
    >
      <.link
        navigate={~p"/board"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
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
          navigate={~p"/projects/#{@project.name}/settings"}
          class="ml-auto flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Settings ›
        </.link>
        <.link
          navigate={~p"/projects/#{@project.name}/repo"}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Repository ›
        </.link>
        <.link
          navigate={~p"/tickets/new?project=#{@project.name}"}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          New ticket ›
        </.link>
        <.link
          navigate={~p"/chats/new?project=#{@project.name}"}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          New chat ›
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

          <div :if={@tickets != []} class="mt-3">
            <Board.board lanes={@lanes} project={@project.name} now={@now} />
          </div>

          <h2 class="mt-8 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            {if multiple?(@current),
              do: "Workflows the next tickets will pin",
              else: "Workflow the next ticket will pin"}
          </h2>

          <div
            :if={match?({:error, _reason}, @current)}
            class="mt-3 rounded-box border border-warning/40 bg-warning/5 p-4"
          >
            <p class="text-sm/[1.55]">
              This project cannot take a ticket: {Admission.explain(elem(@current, 1))}.
            </p>
            <p class="mt-2 text-sm/[1.55] opacity-70">
              A workflow lives in the repository, so it is pushed rather than edited here.
            </p>
          </div>

          <%!-- One per ticket type, each with its own states; a broken one says why, beside the
                rest. See docs/design/ticket-types.md § The project page. --%>
          <section :for={type <- current_types(@current)} id={"type-#{type.name || "workflow"}"}>
            <div :if={type.name} class="mt-5 flex flex-wrap items-baseline gap-x-3">
              <h3 class="font-mono text-[12.5px] font-medium">{type.name}</h3>
              <span :if={description(type)} class="text-[12.5px] opacity-70">
                {description(type)}
              </span>
            </div>

            <div
              :if={not Admission.ready?(type.workflow)}
              class="mt-3 rounded-box border border-warning/40 bg-warning/5 p-4"
            >
              <p class="text-sm/[1.55]">
                {if type.name, do: "This type", else: "This project"} cannot take a ticket: {Admission.explain(
                  elem(type.workflow, 1)
                )}.
              </p>
            </div>

            <table
              :if={Admission.ready?(type.workflow)}
              id={if type.name, do: "workflow-#{type.name}", else: "workflow"}
              class="reflow mt-3 w-full text-[12.5px]"
            >
              <tbody>
                <tr
                  :for={row <- state_rows(elem(type.workflow, 1))}
                  class="border-b border-base-300/60 align-top"
                >
                  <td class="py-2 pr-3">
                    <.state name={row.name} topology={row.topology} />
                    <div
                      :if={row.name == elem(type.workflow, 1).initial}
                      class="font-mono text-[11px] opacity-50"
                    >
                      initial
                    </div>
                  </td>
                  <td data-label="Job" class="py-2 pr-3 font-mono opacity-70">
                    <div :if={row.state.prompt}>{row.state.prompt}</div>
                    <div :if={row.state.produces != []} class="opacity-60">
                      → {Enum.join(row.state.produces, ", ")}
                    </div>
                    <div :if={is_nil(row.state.prompt)} class="opacity-50">no job</div>
                  </td>
                  <td data-label="Budget" class="py-2 pr-3 font-mono opacity-70">
                    <div :if={row.state.budget}>
                      {row.state.budget.turns} turns · {Format.windows(row.state.budget.cost) || "—"}
                    </div>
                  </td>
                  <td data-label="Goes to" class="py-2 font-mono opacity-70">
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
          </section>

          <div :if={not_types(@current) != []} id="not-types" class="mt-5 text-[12.5px]">
            <h3 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              In .forge/workflows/ but not a type
            </h3>
            <p :for={entry <- not_types(@current)} class="mt-1 font-mono opacity-70">
              {entry.path} <span class="opacity-60">— {entry.why}</span>
            </p>
          </div>

          <section :if={@proposals != []} class="mt-10">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              Proposals ({length(@proposals)})
            </h2>

            <p class="mt-2 text-[12.5px]/[1.5] opacity-60">
              Work a job or a conversation said should exist. Nothing runs until you accept one.
            </p>

            <div class="mt-3">
              <.proposals proposals={@proposals} types={choosable(@current)} drafts={@drafts} />
            </div>
          </section>

          <section class="mt-10">
            <div class="flex flex-wrap items-baseline justify-between gap-3">
              <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
                Conversations
              </h2>
              <.link
                navigate={~p"/chats/new?project=#{@project.name}"}
                class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
              >
                New chat ›
              </.link>
            </div>

            <ForgeWeb.Conversations.list
              summaries={@chats}
              now={@now}
              project={false}
              empty="None yet. A chat is for the work that does not fit a ticket."
            />
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <.copyable id="clone-url" value={@clone_url} label="Repository" />
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <.fact label="default branch">{@project.default_branch}</.fact>
            <.fact label="mirror">{mirror_summary(@mirrors)}</.fact>
            <.fact label="worker seed">
              {(@project.seed_id && String.slice(@project.seed_id, 0, 16)) || "none"}
            </.fact>
            <.fact label="tickets">{length(@tickets)}</.fact>
            <.fact :if={@proposals != []} label="proposals">{length(@proposals)}</.fact>
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
