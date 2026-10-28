defmodule ForgeWeb.TicketLive do
  @moduledoc """
  One ticket, as a work screen (`docs/design/ui.md` § The work screen): Decide, Timeline,
  Changes, Docs and Activity, with its facts as the rail — or the details sheet below `lg`.

  **Decide** is the ticket's *Waiting on you*, drawn with the queue's own components, and it is
  the tab a ticket opens on while anything waits; otherwise it opens on the **Timeline**, whose
  spine is ordered by **time, not topology** — a step is a visit to a state, so a revisit is
  another step further down with the same name. Stuck is drawn on the step it happened in, never
  as a step of its own, because there is no such state.

  **Activity is live while the ticket's job runs.** Someone reading a ticket whose job is running
  is deciding whether to wait, answer or steer (`ui.md` § Motion and structure), so the page is
  subscribed to that one job's topic and appends what it streams. It follows the ticket to its
  next job when one starts.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components
  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1]

  alias Forge.{Artifacts, Conversations, Engine, Events, Git, Jobs, Projects, Proposals, Queue}
  alias Forge.{Merge, Spend, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Diff, FileType, Format, Indicators, JobStream, WorkScreen}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board
  alias ForgeWeb.Operator.Drafts
  alias ForgeWeb.Operator.QuestionForm

  @tabs ~w(decide timeline changes docs activity)

  # How much of a failed command's log the timeline shows: the end, where a build says why it
  # stopped. The whole log is one tap away on the command's page.
  @tail_bytes 4096

  @impl true
  def mount(%{"project" => name, "number" => number}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(
       project: project,
       ticket_id: ticket.id,
       tab: nil,
       following: nil,
       forms: QuestionForm.init(),
       drafts: Drafts.init()
     )
     |> JobStream.init()
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  # A named tab is the one shown; with none named, Decide while anything waits and the Timeline
  # otherwise — decided again on each load, so a ticket answered in place moves on to its
  # timeline rather than holding an empty Decide open.
  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: nil
    {:noreply, assign(socket, tab: tab)}
  end

  # **A pin is read as it was admitted** (`docs/design/workflow-grammar-v1.md` § Pinning), so this
  # is not where the validator's newer rules are asked again: that is what gave every ticket
  # admitted before 0.16.0 a 500. A pin the grammar can no longer build has no steps to draw and
  # no topology, so it gets a page of its own that says so rather than a half-drawn work screen.
  defp load(%{assigns: %{ticket_id: id}} = socket) do
    ticket = Tickets.get!(id)

    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> load(socket, ticket, workflow)
      {:error, errors} -> load_unreadable(socket, ticket, errors)
    end
  end

  # What the page can still say with no workflow: the ticket, what its jobs wrote and what
  # happened to it. Nothing that asks the workflow is assigned, and `handle_event/3` refuses what
  # would.
  defp load_unreadable(%{assigns: %{project: project}} = socket, ticket, errors) do
    artifacts =
      for artifact <- Artifacts.list(ticket.id) do
        latest = Artifacts.latest(ticket.id, artifact.name)
        %{artifact: artifact, latest: latest, approved: false, approvable: false}
      end

    socket
    |> follow(nil)
    |> assign(
      page_title: "#{project.name}##{ticket.number}",
      ticket: ticket,
      workflow: nil,
      errors: errors,
      docs: docs(project, ticket, artifacts),
      events: ticket.id |> Events.for_ticket() |> Enum.reverse() |> Enum.take(10),
      drift: Tickets.drift(ticket, project),
      paused: false,
      until_midnight: nil,
      now: DateTime.utc_now()
    )
  end

  defp load(%{assigns: %{project: project}} = socket, ticket, workflow) do
    jobs = Jobs.for_ticket(ticket.id)
    current = List.last(jobs)

    # Commands are the ticket's work too, and sit in the step their state is in: an agent's beneath
    # it, a command state's as that state's (`docs/design/ui.md` § Decide and Timeline).
    work = Enum.sort_by(jobs ++ Jobs.commands_for_ticket(ticket.id), & &1.inserted_at, DateTime)

    # Approval state is shown only where approval is possible: an artifact no transition lists in
    # `approve:` would otherwise be marked `unapproved` for ever, flagging a job the operator does
    # not have. See docs/design/ui.md § Semantics that must not be lost.
    approvable = Artifacts.approvable(workflow)

    artifacts =
      for artifact <- Artifacts.list(ticket.id) do
        latest = Artifacts.latest(ticket.id, artifact.name)

        %{
          artifact: artifact,
          latest: latest,
          approved: Artifacts.approved?(latest),
          approvable: artifact.kind != :presentation and MapSet.member?(approvable, artifact.name)
        }
      end

    diff = ticket_diff(project, ticket)

    # Subscribed before the stream is read, so an event written between the two is heard rather
    # than missing until the next reload; one read and heard both is skipped as seen.
    socket = follow(socket, current)

    socket
    |> assign(
      page_title: "#{project.name}##{ticket.number}",
      ticket: ticket,
      workflow: workflow,
      # Blocking questions wait on a person; the rest were assumed and worked past, and are
      # answered here without anything waiting on the answer (`ui.md` § Not waiting on you).
      questions: Artifacts.open_questions(ticket.id) |> Enum.split_with(& &1.blocking),
      decisions: ticket |> Queue.for_ticket() |> Enum.count(&Queue.waiting?/1),
      jobs: jobs,
      current: current,
      steps: steps(work, artifacts, ticket, workflow),
      waits: waits(work),
      # Why the last batch sent the ticket where it is, under the commands that failed in it.
      tails: Forge.Jobs.Commands.failure_tails(ticket.id, @tail_bytes),
      artifacts: artifacts,
      docs: docs(project, ticket, artifacts),
      diff: diff,
      commits: commits(project, ticket),
      chats: Conversations.summaries(ticket_id: ticket.id),
      events: ticket.id |> Events.for_ticket() |> Enum.reverse() |> Enum.take(4),
      activity: if(current, do: Events.for_job(current.id), else: []),
      transitions: Engine.offered_transitions(ticket, workflow),
      retry: Engine.retryable?(ticket),
      stuck_reason: Engine.why_stuck(ticket),
      drift: Tickets.drift(ticket, project),
      conflict: Forge.Merge.Watch.notice(ticket),
      human_state:
        ticket.status in Forge.Tickets.Ticket.open_statuses() and
          Workflow.State.human?(Workflow.state(workflow, ticket.state)),
      writable: writable(ticket, workflow),
      proposals: Proposals.open_for_ticket(ticket.id),
      reviewable: reviewable?(ticket, workflow),
      approve: approve_pins(project, ticket, artifacts),
      commit_message: Merge.commit_message(ticket),
      changeset: Artifacts.latest(ticket.id, Workflow.changeset_artifact()),
      paused: ticket.status == :active and Spend.paused?(),
      until_midnight: until_midnight(),
      now: DateTime.utc_now()
    )
  end

  # The documents the state the ticket rests in declares, for a person to write: a human state's
  # `produces`, with the latest version of each when there is one (`docs/design/ui.md` § Decide
  # and Timeline). A job state's are the job's to write, so it offers none.
  defp writable(ticket, workflow) do
    # Nothing is written into a ticket that is done or cancelled: it rests where no one decides.
    state = if ticket.status in Forge.Tickets.Ticket.open_statuses(), do: ticket.state

    case state && Workflow.state(workflow, state) do
      %Workflow.State{prompt: nil, invoke: [], produces: produces} ->
        Enum.map(produces, &{&1, Artifacts.latest(ticket.id, &1)})

      _job_or_gone ->
        []
    end
  end

  # The one job whose topic the page listens on: the ticket's current one. When the ticket moves
  # on to a new job the old subscription is dropped, so a page open for a day is not woken by
  # every job the ticket ever ran.
  defp follow(%{assigns: %{following: id}} = socket, %{id: id}), do: socket

  defp follow(socket, current) do
    if connected?(socket) do
      if old = socket.assigns.following, do: Events.unsubscribe_job(old)
      if current, do: Events.subscribe_job(current.id)
    end

    assign(socket, following: current && current.id)
  end

  # What the branch holds against its base: the ticket's own work, whether or not it has been
  # recorded as a changeset yet.
  defp ticket_diff(project, ticket) do
    repo = Projects.repo_path(project)

    case Git.resolve(repo, "refs/heads/" <> ticket.branch) do
      {:ok, head} -> Diff.build(repo, ticket.base_commit, head)
      _gone -> nil
    end
  end

  defp commits(project, ticket),
    do:
      Diff.commits(
        Projects.repo_path(project),
        ticket.base_commit,
        "refs/heads/" <> ticket.branch
      )

  # Every artifact the ticket has, a row each — a document's rendered when opened — its latest
  # version first and the earlier ones linked. The changeset is not one: it is the Changes tab.
  defp docs(project, ticket, artifacts) do
    for %{artifact: artifact, latest: latest} = entry <- artifacts,
        latest != nil,
        artifact.name != Workflow.changeset_artifact() do
      href = fn version ->
        ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version}"
      end

      WorkScreen.doc(
        artifact,
        Artifacts.versions(ticket.id, artifact.name),
        href,
        entry.approvable
      )
    end
  end

  # The rail names what this ticket's jobs proposed and sends the decision to the project page,
  # where every proposal on the project is in one place. Deciding here too would put the same
  # affordance in two places, and one of them would be the one you did not open.
  defp proposal_title(version) do
    case ForgeCore.Proposal.parse(version.content || "") do
      {:ok, proposal} -> proposal.title
      {:error, _errors} -> "(could not be read)"
    end
  end

  # One step per state visit, in the order the jobs ran. A state the ticket reached without a
  # job — a human state it is resting in — still gets its step, because the operator is looking
  # for where the ticket is, not only for where work happened.
  defp steps(jobs, artifacts, ticket, workflow) do
    visits =
      jobs
      |> Enum.chunk_by(& &1.state)
      |> Enum.map(fn group ->
        %{
          name: hd(group).state,
          jobs: group,
          artifacts: Enum.filter(artifacts, &written_in?(&1, group)),
          cost: Enum.reduce(group, Decimal.new(0), &Decimal.add(&2, &1.cost_usd))
        }
      end)

    if Enum.any?(visits, &(&1.name == ticket.state)) do
      visits
    else
      visits ++ [%{name: ticket.state, jobs: [], artifacts: [], cost: Decimal.new(0)}]
    end
    |> Enum.map(&Map.put(&1, :topology, Board.topology(workflow, &1.name)))
  end

  # Why each pending job has not gone out, in the scheduler's own sentence — only a pending job
  # has one (`docs/design/ui.md` § A job waiting for a machine).
  defp waits(jobs) do
    Enum.flat_map(jobs, fn job ->
      case Jobs.current_wait(job) do
        nil -> []
        wait -> [{job.id, Events.summary(wait)}]
      end
    end)
    |> Map.new()
  end

  defp written_in?(%{latest: nil}, _jobs), do: false

  defp written_in?(%{latest: latest}, jobs) do
    case latest.author do
      %{"kind" => "job", "id" => id} -> Enum.any?(jobs, &(&1.id == id))
      _other -> false
    end
  end

  # The current job's stream is added to the log the page holds as it arrives
  # (`ForgeWeb.JobStream`), and so is the rail's list of the latest events; after a call's result
  # the branch is read again shortly. Anything else on the job's topic — a wait, the run ending —
  # reloads, and so does every change announced for this ticket.
  #
  # Adding rather than reloading is a saving here and not a behaviour: this page holds nothing a
  # reload takes away, and a reload reads the same log and the branch a moment sooner. So the
  # `streamed?/1` test answering false on this page is an equivalent mutant — what it saves is
  # every query of `load/1`, per event, for as long as a job streams. (On the conversation's page
  # it is not equivalent, and a test says so.)
  @impl true
  def handle_info({:job_event, id, event}, %{assigns: %{following: id}} = socket) do
    if JobStream.streamed?(event) do
      case JobStream.add(socket.assigns.activity, event) do
        :seen ->
          {:noreply, socket}

        {:ok, activity} ->
          {:noreply,
           socket
           |> assign(activity: activity)
           |> update(:events, &Enum.take([event | &1], 4))
           |> JobStream.catch_up(event)}
      end
    else
      {:noreply, load(socket)}
    end
  end

  def handle_info({:job_event, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  # What the branch holds, read again after a call that may have committed to it.
  def handle_info(:catch_up, %{assigns: %{project: project, ticket: ticket}} = socket) do
    {:noreply,
     assign(socket,
       diff: ticket_diff(project, ticket),
       commits: commits(project, ticket),
       catching_up: false
     )}
  end

  @impl true
  # A ticket whose pin cannot be read can be cancelled, restored and re-pinned, and nothing else:
  # the page draws no other control, and the rest either asks the workflow or reads what
  # `load_unreadable/3` does not assign.
  def handle_event(event, _params, %{assigns: %{workflow: nil}} = socket)
      when event not in ["cancel-ticket", "restore-ticket", "repin"] do
    {:noreply,
     put_flash(
       socket,
       :error,
       "That is not available while this ticket's workflow cannot be read."
     )}
  end

  # *Ask about this* on a ticket has no composer to put the reference in, so it goes to one: the
  # ticket's most recent live conversation, with the reference in its draft, or a new one about
  # the ticket with the reference as its first message. The reference travels in the address and
  # nothing is sent until the operator sends it (`docs/design/ui.md` § Changes).
  def handle_event("ask", %{"ref" => ref}, socket) do
    %{project: project, ticket: ticket, chats: chats} = socket.assigns

    to =
      case Enum.find(chats, & &1.live) do
        %{chat: chat} -> ~p"/chats/#{chat.id}?#{[tab: "talk", ask: ref]}"
        nil -> ~p"/chats/new?#{[project: project.name, ticket: ticket.number, text: ref]}"
      end

    {:noreply, push_navigate(socket, to: to)}
  end

  def handle_event("more", params, socket), do: JobStream.handle_event("more", params, socket)

  def handle_event("notices", params, socket),
    do: JobStream.handle_event("notices", params, socket)

  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  defp tab(%{tab: nil, decisions: n}) when n > 0, do: "decide"
  defp tab(%{tab: nil}), do: "timeline"
  defp tab(%{tab: tab}), do: tab

  defp tabs(assigns) do
    [
      {"decide", "Decide", assigns.decisions},
      {"timeline", "Timeline", nil},
      {"changes", "Changes", Diff.file_count(assigns.diff)},
      {"docs", "Docs", length(assigns.docs)},
      {"activity", "Activity", WorkScreen.activity_count(assigns.activity)}
    ]
  end

  # What Decide draws: the queue's own cards for this ticket, whatever is waiting.
  defp deciding?(assigns),
    do:
      assigns.ticket.pending_transition != nil or blocking(assigns) != [] or
        stuck_or_human?(assigns) or assigns.retry or assigns.writable != []

  # The changeset approval, at the foot of the diff it approves — only when that approval is what
  # the ticket waits on.
  defp approving_changeset?(%{ticket: %{pending_transition: pending}} = assigns)
       when is_map(pending),
       do: Workflow.changeset_artifact() in Engine.awaiting_approval(assigns.ticket)

  defp approving_changeset?(_assigns), do: false

  @impl true
  def render(%{workflow: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="46rem">
      <.link
        navigate={~p"/projects/#{@project.name}"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100 sm:min-h-0"
      >
        ‹ {@project.name}
      </.link>
      <h1 class="text-xl font-semibold break-words -tracking-[.03em] sm:text-2xl">
        {@ticket.title}
      </h1>
      <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1">
        <span :if={@ticket.ticket_type} id="ticket-type" class="font-mono text-[12.5px] opacity-60">
          {@ticket.ticket_type}
        </span>
        <span id="ticket-state" class="font-mono text-[12.5px]">{@ticket.state}</span>
        <.status_flag status={@ticket.status} age={Format.ago(@ticket.updated_at, @now)} />
      </div>

      <%!-- Said once, in plain words, with the way on: neither Re-pin nor Cancel reads the pin
            that cannot be built (`workflow-grammar-v1.md` § Pinning). --%>
      <section id="unreadable-pin" class="mt-6">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">
          Cannot be read
        </h2>
        <p class="mt-2 text-sm/[1.55]">
          The workflow this ticket was pinned to can no longer be read, so its steps cannot be
          shown and it cannot move on. Its documents and history are below.
        </p>
        <details class="mt-2 text-[12.5px]">
          <summary class="flex min-h-[46px] cursor-pointer items-center opacity-70">
            What stopped it
          </summary>
          <pre class="overflow-x-auto font-mono whitespace-pre-wrap opacity-70">{ForgeCore.Error.format(@errors)}</pre>
        </details>
        <div :if={@drift && @ticket.status in Forge.Tickets.Ticket.open_statuses()} id="pin-drift">
          <p class="text-sm/[1.55] opacity-70">
            {@project.default_branch} has a workflow it can be pinned to instead.
          </p>
          <button
            type="button"
            id="repin-ticket"
            phx-click="repin"
            phx-value-ticket={@ticket.id}
            data-confirm={"Re-pin at #{String.slice(@drift.head, 0, 12)}? Every job from now on reads the workflow, its prompts and its command scripts from there."}
            class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
          >
            Re-pin at {String.slice(@drift.head, 0, 12)}
          </button>
        </div>
        <button
          :if={@ticket.status in Forge.Tickets.Ticket.open_statuses()}
          type="button"
          id="cancel-ticket"
          phx-click="cancel-ticket"
          phx-value-ticket={@ticket.id}
          data-confirm="Cancel this ticket? Its jobs stop and it is hidden everywhere but this page, where Restore brings it back."
          class="flex min-h-[46px] items-center text-sm text-error hover:underline"
        >
          Cancel ticket
        </button>
        <button
          :if={@ticket.status == :cancelled}
          type="button"
          id="restore-ticket"
          phx-click="restore-ticket"
          phx-value-ticket={@ticket.id}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Restore
        </button>
      </section>

      <section id="docs" class="mt-6">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Documents</h2>
        <WorkScreen.docs docs={@docs} empty="No job wrote a document on this ticket." />
      </section>

      <section id="timeline" class="mt-6">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">History</h2>
        <ol class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
          <li :for={event <- @events} class="flex gap-2">
            <span class="shrink-0 opacity-50">
              {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
            </span>
            <span class="block min-w-0 truncate">{event.type}</span>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns = assign(assigns, shown_tab: tab(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      measure="74rem"
      frame={:work}
    >
      <WorkScreen.frame
        tabs={tabs(assigns)}
        tab={@shown_tab}
        path={~p"/tickets/#{@project.name}/#{@ticket.number}"}
        capacity={@capacity}
      >
        <:header>
          <.link
            navigate={~p"/projects/#{@project.name}"}
            class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100 sm:min-h-0"
          >
            ‹ {@project.name}
          </.link>
          <h1 class="truncate text-xl font-semibold -tracking-[.03em] sm:text-2xl">
            {@ticket.title}
          </h1>
          <div class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1">
            <span
              :if={@ticket.ticket_type}
              id="ticket-type"
              class="font-mono text-[12.5px] opacity-60"
            >
              {@ticket.ticket_type}
            </span>
            <.state name={@ticket.state} topology={Board.topology(@workflow, @ticket.state)} />
            <.status_flag status={@ticket.status} age={Format.ago(@ticket.updated_at, @now)} />
            <.paused :if={@paused} reason="spend" until={@until_midnight} />
            <span :if={waiting_clause(assigns)} class="text-sm opacity-70">
              {waiting_clause(assigns)}
            </span>
          </div>
        </:header>

        <:strip>
          <span>{@ticket.branch}</span>
          <Diff.stat diff={@diff} />
          <span>{turns(@jobs)} turns</span>
          <span>{Format.windows(@ticket.cost_usd) || "—"}</span>
        </:strip>

        <WorkScreen.body :if={@shown_tab == "decide"} id="decide">
          <.decide {assigns} />
        </WorkScreen.body>

        <WorkScreen.body :if={@shown_tab == "timeline"} id="timeline">
          <.timeline {assigns} />
        </WorkScreen.body>

        <WorkScreen.body :if={@shown_tab == "changes"} id="changes">
          <.changes {assigns} />
        </WorkScreen.body>

        <WorkScreen.body :if={@shown_tab == "docs"} id="docs">
          <WorkScreen.docs docs={@docs} empty="The first job writes the first document." />
        </WorkScreen.body>

        <WorkScreen.body :if={@shown_tab == "activity"} id="activity">
          <.activity {assigns} />
        </WorkScreen.body>

        <:rail>
          <.rail {assigns} />
        </:rail>
      </WorkScreen.frame>
    </Layouts.app>
    """
  end

  # The queue's components exactly, answering in place and never navigating.
  defp decide(assigns) do
    ~H"""
    <section :if={deciding?(assigns)} id="hoisted-decision">
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">Waiting on you</h2>
      <div class="mt-3">
        <.approval_card
          :if={@ticket.pending_transition}
          ticket={@ticket}
          pending={@ticket.pending_transition}
          approve={@approve}
          drafts={@drafts}
          commit_message={@commit_message}
        />

        <.link
          :if={@reviewable}
          navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/review"}
          class="mt-2 flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Read the change first ›
        </.link>
        <div :if={!@ticket.pending_transition and blocking(assigns) != []} class="flex flex-col gap-6">
          <.question_form
            :for={{version_id, questions} <- forms(assigns, :waiting)}
            id={version_id}
            questions={questions}
            forms={@forms}
            submit="questions:send"
            hidden={[{"ticket", @ticket.id}, {"version", version_id}]}
          />
        </div>
        <div
          :if={!@ticket.pending_transition and @writable != []}
          class="mb-6 flex flex-col gap-6"
        >
          <.document_editor
            :for={{name, latest} <- @writable}
            ticket={@ticket}
            name={name}
            latest={latest}
            drafts={@drafts}
          />
        </div>
        <.transition_card
          :if={!@ticket.pending_transition and blocking(assigns) == [] and stuck_or_human?(assigns)}
          ticket={@ticket}
          transitions={@transitions}
        />
        <div :if={@retry} class="mt-2">
          <.retry_row ticket={@ticket} />
        </div>
      </div>
    </section>

    <p :if={not deciding?(assigns)} id="nothing-to-decide" class="text-sm/[1.55] opacity-70">
      Nothing here is waiting on you. A job that stops to ask a question, a transition that needs
      approving, or the ticket coming to rest where only a person can move it would put it here.
    </p>

    <%!-- What an agent assumed and carried on from: answerable here, where the queue's digest
          sends it, and drawn without accent because nothing waits on the answer. --%>
    <section
      :if={forms(assigns, :assumed) != []}
      id="assumed"
      class="mt-8 border-t border-base-300 pt-5"
    >
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
        Assumed, and carried on
      </h2>
      <div class="mt-3 flex flex-col gap-6">
        <.question_form
          :for={{version_id, questions} <- forms(assigns, :assumed)}
          id={version_id}
          questions={questions}
          forms={@forms}
          submit="questions:send"
          hidden={[{"ticket", @ticket.id}, {"version", version_id}]}
        />
      </div>
    </section>
    """
  end

  defp blocking(%{questions: {blocking, _assumed}}), do: blocking

  # One form per document version (`docs/design/ui.md` § Answering questions). A version holding a
  # blocking question is waiting, and its assumptions join its form, optional; a version with only
  # assumptions is answered beneath, where nothing waits on it. Oldest version first.
  defp forms(%{questions: {blocking, assumed}}, which) do
    {joined, alone} = QuestionForm.join_assumed(blocking, assumed)
    questions = if which == :waiting, do: blocking ++ joined, else: alone

    questions
    |> Enum.group_by(& &1.artifact_version_id)
    |> Enum.sort_by(fn {_version, [first | _]} -> first.inserted_at end, DateTime)
  end

  defp timeline(assigns) do
    ~H"""
    <p :if={@ticket.body != ""} class="mb-6 text-sm/[1.55] whitespace-pre-line opacity-80">
      {@ticket.body}
    </p>

    <ol>
      <li :for={step <- @steps} class="grid grid-cols-[26px_1fr] pb-5 lg:pb-[26px]">
        <div class="flex flex-col items-center">
          <span class={[
            "mt-1.5 size-[11px] rounded-full",
            if(step.name == @ticket.state,
              do: "bg-accent ring-4 ring-accent/20",
              else: "bg-base-300"
            )
          ]} />
          <span class="mt-1 w-px flex-1 bg-base-300" />
        </div>

        <div class="min-w-0 pb-2">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <.state name={step.name} topology={step.topology} />
            <span :if={step.jobs != []} class="font-mono text-[12.5px] opacity-50">
              {length(step.jobs)} {if length(step.jobs) == 1, do: "job", else: "jobs"} · {Format.windows(
                step.cost
              ) || "—"}
            </span>
          </div>

          <%!-- The whole row is the target, at the full 46px: hunting for a 20px `#3` is the
                failure docs/design/ui.md § The affordance rule names. Nothing inside a job row
                commits anything, so the row may be a link. --%>
          <%!-- One list in the order the work was made, so an agent's commands follow the row
                of the agent that invoked them rather than all sitting above it. --%>
          <ol :if={step.jobs != []} class="mt-2 flex flex-col">
            <li :for={job <- step.jobs}>
              <.command_row
                :if={job.kind == :command}
                job={job}
                project={@project}
                ticket={@ticket}
                wait={@waits[job.id]}
              />
              <%!-- `job.kind == :command` is an equivalent mutant: a batch's `commands.started`
                    names only its command jobs, which is all `failure_tails/2` keys by. --%>
              <pre
                :if={job.kind == :command and @tails[job.id]}
                id={"command-#{job.id}-tail"}
                class="max-h-72 overflow-auto border-l-2 border-error/60 bg-base-200/60 px-3 py-2 font-mono text-[12px]/[1.5] whitespace-pre-wrap break-words"
              >{@tails[job.id]}</pre>
              <.link
                :if={job.kind != :command}
                navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
                class="flex min-h-[46px] items-center gap-3 border-b border-base-300/60 py-1.5 text-[12.5px] hover:bg-base-200"
              >
                <span class="w-8 shrink-0 font-mono">#{job.attempt}</span>
                <span class="min-w-0 flex-1">
                  <.outcome
                    :if={job.declared_outcome || job.outcome}
                    value={job.declared_outcome || to_string(job.outcome)}
                    bucket={job.declared_outcome && Indicators.bucket(job.outcome)}
                  />
                  <.job_status :if={is_nil(job.outcome)} status={job.status} />
                  <.ceiling job={job} />
                  <%!-- Language, not an identifier: sans at body size, and never accent — a
                        machine is being waited on, not the operator. --%>
                  <span
                    :if={@waits[job.id]}
                    id={"job-#{job.id}-waiting"}
                    class="block text-sm/[1.4] opacity-60"
                  >
                    {@waits[job.id]}
                  </span>
                </span>
                <span class="shrink-0 font-mono opacity-60">{job.turns} turns</span>
                <span class="w-20 shrink-0 text-right font-mono opacity-60">
                  {Format.windows(job.cost_usd) || "—"}
                </span>
                <span class="shrink-0 font-mono opacity-40" aria-hidden="true">›</span>
              </.link>
            </li>
          </ol>

          <div :if={step.artifacts != []} class="mt-2 flex flex-wrap gap-2">
            <.artifact_chip
              :for={entry <- step.artifacts}
              entry={entry}
              project={@project.name}
              number={@ticket.number}
            />
          </div>
        </div>
      </li>
    </ol>

    <%!-- A conversation started from a ticket was findable from the project page and not from
          the ticket it is about. Live first: that one is costing something. --%>
    <section id="ticket-chats" class="mt-4 border-t border-base-300 pt-5">
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Conversations</h2>
        <.link
          navigate={~p"/chats/new?project=#{@project.name}&ticket=#{@ticket.number}"}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          New chat ›
        </.link>
      </div>
      <ForgeWeb.Conversations.list
        summaries={@chats}
        now={@now}
        project={false}
        empty="No conversation about this ticket yet."
      />
    </section>
    """
  end

  # `docs/design/ui.md` § Decide and Timeline: `$` where an attempt goes, the command and its
  # arguments, the exit status where an outcome goes, the duration where turns and cost go. One an
  # agent invoked is indented beneath it.
  attr :job, :map, required: true
  attr :project, :map, required: true
  attr :ticket, :map, required: true
  attr :wait, :string, default: nil

  defp command_row(assigns) do
    command = Jobs.spec(assigns.job).command
    assigns = assign(assigns, name: command["name"], args: command["args"] || [])

    ~H"""
    <.link
      navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@job.id}"}
      id={"command-#{@job.id}"}
      class={[
        "flex min-h-[46px] items-center gap-3 border-b border-base-300/60 py-1.5 text-[12.5px] hover:bg-base-200",
        @job.parent_job_id && "pl-8"
      ]}
    >
      <span class="w-8 shrink-0 font-mono opacity-60" aria-hidden="true">$</span>
      <span class="min-w-0 flex-1">
        <span class="font-mono">
          {@name}<span :if={@args != []} class="opacity-60">{ForgeCore.Workflow.Command.argv(@args)}</span>
        </span>
        <.exit_status job={@job} />
        <span :if={@wait} id={"job-#{@job.id}-waiting"} class="block text-sm/[1.4] opacity-60">
          {@wait}
        </span>
      </span>
      <span class="shrink-0 font-mono opacity-60">{Format.duration(@job)}</span>
      <span class="shrink-0 font-mono opacity-40" aria-hidden="true">›</span>
    </.link>
    """
  end

  defp changes(assigns) do
    ~H"""
    <section>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
          What the branch holds
        </h2>
        <.link
          :if={@changeset}
          navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/review"}
          class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Review page ›
        </.link>
      </div>
      <div class="mt-3">
        <Diff.file_table :if={@diff} diff={@diff} ask="ask" />
        <p :if={!@diff} class="text-sm/[1.55] opacity-70">Its branch is not in the repository.</p>
      </div>
    </section>

    <WorkScreen.commits commits={@commits} now={@now} />

    <%!-- Reading a change and approving it are adjacent; they are still two gestures. The same
          card Decide draws, from the same component and the same pending transition. --%>
    <section
      :if={approving_changeset?(assigns)}
      id="changes-approval"
      class="mt-8 border-t border-accent pt-5"
    >
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">Waiting on you</h2>
      <div class="mt-3">
        <.approval_card
          ticket={@ticket}
          pending={@ticket.pending_transition}
          approve={@approve}
          drafts={@drafts}
          commit_message={@commit_message}
        />
      </div>
    </section>
    """
  end

  defp activity(assigns) do
    ~H"""
    <p :if={is_nil(@current)} class="text-sm opacity-60">No job has run on this ticket.</p>

    <div :if={@current}>
      <.link
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@current.id}"}
        class="mb-3 flex min-h-[46px] items-center font-mono text-[12.5px] hover:underline"
      >
        {@current.state} #{@current.attempt} ›
      </.link>
      <WorkScreen.activity
        events={@activity}
        shown={@shown}
        notices={@notices}
        heading={WorkScreen.stream_heading(@current, @activity)}
      />

      <section :if={length(@jobs) > 1} class="mt-8">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Earlier jobs</h2>
        <ul class="mt-3 flex flex-col">
          <li :for={job <- @jobs |> Enum.drop(-1) |> Enum.reverse()}>
            <.link
              navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{job.id}"}
              class="flex min-h-[46px] items-center gap-3 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
            >
              <span class="min-w-0 flex-1 truncate">{job.state} #{job.attempt}</span>
              <%!-- Through `Indicators`, like every other row: `ui.md` § The three axes says
                    nothing else may draw a job outcome, and this row drew it as plain demoted
                    text — which left the ceiling beside it at exactly the same weight. --%>
              <span class="shrink-0">
                <.outcome :if={job.outcome} value={to_string(job.outcome)} />
                <.job_status :if={is_nil(job.outcome)} status={job.status} />
              </span>
              <.ceiling job={job} />
              <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
            </.link>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  defp rail(assigns) do
    ~H"""
    <%!-- The strip's gauge written out, where a phone reaches it: below `lg` this is the
          details sheet, and the top bar that carries the gauge's title is not drawn. --%>
    <Layouts.capacity_written
      :if={@capacity not in [nil, %{}]}
      capacity={@capacity}
      prefix="details-capacity"
      class="mb-6 border-b border-base-300 pb-3 lg:hidden"
    />
    <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Usage</h2>
    <div class="mt-3">
      <div class="font-mono text-[17px]">{Format.windows(@ticket.cost_usd) || "—"}</div>
      <div class="mt-2 h-[5px] w-full bg-base-300">
        <div class="h-full bg-accent" style={"width: #{usage_pct(@ticket, @workflow)}%"} />
      </div>
      <div class="mt-1 font-mono text-[11px] opacity-50">
        allowance {Format.windows(@workflow.limits.ticket_cost) || "—"}
      </div>
    </div>

    <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Facts</h2>
    <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
      <.fact label="branch">{@ticket.branch}</.fact>
      <.fact label="base">{String.slice(@ticket.base_commit || "", 0, 12)}</.fact>
      <.fact label="workflow">{String.slice(@ticket.workflow_commit || "", 0, 12)}</.fact>
      <.fact label="admitted">{Format.ago(@ticket.inserted_at, @now)} ago</.fact>
    </dl>
    <%!-- A ticket reads its workflow, prompts and command scripts at its pin for its whole life,
          so a fix that lands on the default branch does not reach it until a person says so
          (`workflow-grammar-v1.md` § Pinning). Said where the pin is, with the way to take it. --%>
    <div :if={@drift} id="pin-drift" class="mt-3 text-[12.5px]">
      <p class="opacity-70">
        {@project.default_branch} has changed what this ticket runs since it was pinned:
      </p>
      <ul class="mt-1 flex flex-col gap-0.5 font-mono break-all opacity-70">
        <li :for={path <- @drift.paths}>{path}</li>
      </ul>
      <button
        :if={@ticket.status in Forge.Tickets.Ticket.open_statuses()}
        type="button"
        id="repin-ticket"
        phx-click="repin"
        phx-value-ticket={@ticket.id}
        data-confirm={"Re-pin at #{String.slice(@drift.head, 0, 12)}? Every job from now on reads the workflow, its prompts and its command scripts from there."}
        class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
      >
        Re-pin at {String.slice(@drift.head, 0, 12)}
      </button>
    </div>
    <%!-- A merge moved the default branch into conflict with this ticket's changeset: said before
          anybody approves it, with the way down the conflict route — and nothing started until
          it is pressed (`docs/design/ui.md` § Decide and Timeline). --%>
    <div :if={@conflict} id="merge-conflict" class="mt-3 text-[12.5px]">
      <p class="opacity-70">
        {@project.default_branch} no longer merges with this ticket's changeset{since(@conflict.cause)}:
      </p>
      <ul class="mt-1 flex flex-col gap-0.5 font-mono break-all opacity-70">
        <li :for={path <- @conflict.paths}>{path}</li>
      </ul>
      <button
        :if={@conflict.send_to}
        type="button"
        id="integrate-ticket"
        phx-click="integrate"
        phx-value-ticket={@ticket.id}
        data-confirm={send_confirm(@conflict.send_to, @workflow, @project.default_branch)}
        class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
      >
        Send to {@conflict.send_to}
      </button>
    </div>

    <h2
      :if={@proposals != []}
      class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60"
    >
      Proposed here
    </h2>
    <ul :if={@proposals != []} class="mt-3 flex flex-col gap-2 text-[12.5px]">
      <li :for={p <- @proposals} class="opacity-70">{proposal_title(p.version)}</li>
    </ul>
    <p :if={@proposals != []} class="mt-2 text-[12.5px] opacity-50">
      Waiting on you, on <.link navigate={~p"/projects/#{@project.name}"} class="hover:underline">
        the project page
      </.link>.
    </p>

    <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Artifacts</h2>
    <div class="mt-3 flex flex-wrap gap-2">
      <.artifact_chip
        :for={entry <- @artifacts}
        entry={entry}
        project={@project.name}
        number={@ticket.number}
      />
      <p :if={@artifacts == []} class="text-sm opacity-50">
        The first job writes the first document.
      </p>
    </div>

    <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
      Last four events
    </h2>
    <ol class="mt-3 flex flex-col gap-1 font-mono text-[12.5px]">
      <li :for={event <- @events} class="flex gap-2">
        <span class="shrink-0 opacity-50">
          {Calendar.strftime(event.inserted_at, "%m-%d %H:%M")}
        </span>
        <span class="min-w-0">
          <span class="block truncate">{event.type}</span>
          <span :if={Format.author(event.actor)} class="block truncate text-[11.5px] opacity-60">
            {Format.author(event.actor)}
          </span>
          <span :if={said(event)} class="block break-words font-sans text-sm/[1.4] opacity-70">
            {said(event)}
          </span>
        </span>
      </li>
    </ol>
    <%!-- Cancelling is rare and undoable, so it sits at the foot of the rail rather than beside
          the decisions: `workflow-grammar-v1.md` § Cancelling a ticket. --%>
    <div :if={@ticket.status in Forge.Tickets.Ticket.open_statuses()} class="mt-6">
      <button
        type="button"
        id="cancel-ticket"
        phx-click="cancel-ticket"
        phx-value-ticket={@ticket.id}
        data-confirm="Cancel this ticket? Its jobs stop and it is hidden everywhere but this page, where Restore brings it back."
        class="flex min-h-[46px] items-center text-sm text-error hover:underline"
      >
        Cancel ticket
      </button>
    </div>
    <div :if={@ticket.status == :cancelled} class="mt-6">
      <p class="text-[12.5px] opacity-60">
        Cancelled: hidden everywhere but here. Restoring leaves it stuck in {@ticket.state}.
      </p>
      <button
        type="button"
        id="restore-ticket"
        phx-click="restore-ticket"
        phx-value-ticket={@ticket.id}
        class="flex min-h-[46px] items-center text-sm text-primary hover:underline"
      >
        Restore
      </button>
    </div>
    """
  end

  # There is no chip without a version: approval attaches to an exact version, and a human edit
  # creating v3 does not carry v2's approval. A presentation has no approval slot at all, and
  # neither has an artifact the pinned workflow never approves — see docs/design/ui.md.
  #
  # The chip is a link to the exact version's bytes, which is also why it is bordered: a border
  # means you can tap it. A changeset is a commit rather than a file and the controller sends it
  # to the review page, where a diff is rendered.
  attr :entry, :map, required: true
  attr :project, :string, required: true
  attr :number, :integer, required: true

  defp artifact_chip(assigns) do
    ~H"""
    <.link
      :if={@entry.latest}
      href={
        ~p"/tickets/#{@project}/#{@number}/artifacts/#{@entry.artifact.name}/#{@entry.latest.version}"
      }
      class={[
        "inline-flex min-h-[46px] items-center gap-1.5 rounded-field px-2 py-1 font-mono text-[12.5px] hover:bg-base-200",
        if(@entry.artifact.kind == :presentation,
          do: "border border-dashed border-base-300",
          else: "border border-base-300"
        )
      ]}
    >
      <FileType.file_icon artifact={@entry.artifact} size={:chip} />
      {@entry.artifact.name}
      <span class="opacity-60">v{@entry.latest.version}</span>
      <span :if={@entry.artifact.kind == :presentation} class="tracking-[.14em] uppercase opacity-50">
        view only
      </span>
      <span :if={@entry.approvable and @entry.approved} class="text-success">✓ approved</span>
      <span :if={@entry.approvable and not @entry.approved} class="text-warning">◇ unapproved</span>
    </.link>
    """
  end

  # The events whose type alone does not say what happened: which outcome a batch decided, why the
  # ticket stuck, where it went, why a conversation's request to move it moved nothing. Every
  # other type is its own sentence here.
  @said ~w(commands.decided ticket.stuck transition.taken ticket.merge_conflicted
           chat.transition_refused)

  defp said(%{type: type} = event) when type in @said, do: Forge.Events.summary(event)
  defp said(_event), do: nil

  defp turns(jobs), do: jobs |> Enum.map(& &1.turns) |> Enum.sum()

  # Which merge put the ticket in conflict, when it was one: one that conflicted already names none.
  defp since(%{"ticket" => number}), do: " since ##{number} merged"
  defp since(%{"chat" => _id}), do: " since a conversation merged"
  defp since(_none), do: ""

  # The confirm says what pressing it spends: a job, when the state it sends to runs one.
  defp send_confirm(target, workflow, branch) do
    case Workflow.state(workflow, target) do
      %Workflow.State{prompt: prompt} when is_binary(prompt) ->
        "Send this ticket to #{target}? A job starts there to merge #{branch} into its branch, " <>
          "and spends a credential."

      _human ->
        "Send this ticket to #{target}? It waits there for a person."
    end
  end

  defp stuck_or_human?(assigns),
    do: (assigns.ticket.status == :stuck or assigns.human_state) and assigns.transitions != []

  defp waiting_clause(%{ticket: %{status: :stuck}, stuck_reason: reason}) when is_binary(reason),
    do: "Stuck: #{reason}. Waiting for you to choose."

  defp waiting_clause(%{ticket: %{status: :stuck}}), do: "Stuck, and waiting for you to choose."

  defp waiting_clause(%{ticket: %{pending_transition: p}}) when is_map(p),
    do: "Waiting for approval."

  defp waiting_clause(%{questions: {[_ | _], _assumed}}),
    do: "A job stopped to ask you something."

  defp waiting_clause(_assigns), do: nil

  # A merge decision has a page of its own — whether it is waiting as a pending approval or as the
  # transition out of the state the ticket rests in, and whatever it pins: what makes it one is
  # that the state it enters merges (`Forge.Engine.merge_decision?/2`).
  defp reviewable?(ticket, workflow), do: Engine.merge_decision?(ticket, workflow)

  defp approve_pins(project, ticket, artifacts) do
    for name <- Engine.awaiting_approval(ticket),
        entry = Enum.find(artifacts, &(&1.artifact.name == name)),
        entry && entry.latest,
        do: pinned(project.name, ticket, name, entry.latest)
  end

  # The daily cap is resolved by the clock, so the figure beside it is a countdown, not an age.
  defp until_midnight do
    now = DateTime.utc_now()
    {:ok, midnight} = DateTime.new(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")

    case DateTime.diff(midnight, now, :second) do
      s when s < 3600 -> "#{div(s, 60)}m"
      s -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
    end
  end

  defp usage_pct(ticket, workflow) do
    cap = workflow.limits.ticket_cost

    if is_number(cap) and cap > 0 do
      ticket.cost_usd
      |> Decimal.to_float()
      |> Kernel./(cap)
      |> Kernel.*(100)
      |> min(100)
      |> round()
    else
      0
    end
  end
end
