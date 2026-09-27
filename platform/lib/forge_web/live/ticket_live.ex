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

  alias Forge.{Artifacts, Conversations, Engine, Events, Git, Jobs, Projects, Proposals, Queue}
  alias Forge.{Spend, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Diff, Format, Indicators, JobStream, WorkScreen}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board

  @tabs ~w(decide timeline changes docs activity)

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
       following: nil
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

  defp load(%{assigns: %{ticket_id: id, project: project}} = socket) do
    ticket = Tickets.get!(id)
    workflow = Tickets.workflow(ticket)
    jobs = Jobs.for_ticket(ticket.id)
    current = List.last(jobs)

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
      steps: steps(jobs, artifacts, ticket, workflow),
      waits: waits(jobs),
      artifacts: artifacts,
      docs: docs(project, ticket, artifacts),
      diff: diff,
      commits: commits(project, ticket),
      chats: Conversations.summaries(ticket_id: ticket.id),
      events: ticket.id |> Events.for_ticket() |> Enum.reverse() |> Enum.take(4),
      activity: if(current, do: Events.for_job(current.id), else: []),
      transitions:
        workflow |> Workflow.transitions_from(ticket.state) |> Enum.map(& &1.to) |> Enum.uniq(),
      human_state:
        ticket.status in [:active, :stuck] and
          not Workflow.State.job?(Workflow.state(workflow, ticket.state)),
      proposals: Proposals.open_for_ticket(ticket.id),
      reviewable: reviewable?(ticket, workflow),
      changeset: Artifacts.latest(ticket.id, Workflow.changeset_artifact()),
      paused: ticket.status == :active and Spend.paused?(),
      until_midnight: until_midnight(),
      now: DateTime.utc_now()
    )
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

  # Every document the ticket has, rendered, its latest version first and the earlier ones
  # linked. The changeset is not a document: it is the Changes tab.
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

  # *Ask about this* on a ticket has no composer to put the reference in, so it goes to one: the
  # ticket's most recent live conversation, with the reference in its draft, or a new one about
  # the ticket with the reference as its first message. The reference travels in the address and
  # nothing is sent until the operator sends it (`docs/design/ui.md` § Changes).
  @impl true
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
        stuck_or_human?(assigns)

  # The changeset approval, at the foot of the diff it approves — only when that approval is what
  # the ticket waits on.
  defp approving_changeset?(%{ticket: %{pending_transition: pending}} = assigns)
       when is_map(pending),
       do: Workflow.changeset_artifact() in Engine.awaiting_approval(assigns.ticket)

  defp approving_changeset?(_assigns), do: false

  @impl true
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
          approve={approve_pairs(@ticket, @artifacts)}
        />

        <.link
          :if={@reviewable}
          navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/review"}
          class="mt-2 flex min-h-[46px] items-center text-sm text-primary hover:underline"
        >
          Read the change first ›
        </.link>
        <div :if={!@ticket.pending_transition and blocking(assigns) != []} class="flex flex-col gap-6">
          <.questions
            :for={
              {version_id, questions} <- Enum.group_by(blocking(assigns), & &1.artifact_version_id)
            }
            questions={questions}
            ticket_id={@ticket.id}
            version_id={version_id}
          />
        </div>
        <.transition_card
          :if={!@ticket.pending_transition and blocking(assigns) == [] and stuck_or_human?(assigns)}
          ticket={@ticket}
          transitions={@transitions}
        />
      </div>
    </section>

    <p :if={not deciding?(assigns)} id="nothing-to-decide" class="text-sm/[1.55] opacity-70">
      Nothing here is waiting on you. A job that stops to ask a question, a transition that needs
      approving, or the ticket coming to rest where only a person can move it would put it here.
    </p>

    <%!-- What an agent assumed and carried on from: answerable here, where the queue's digest
          sends it, and drawn without accent because nothing waits on the answer. --%>
    <section :if={assumed(assigns) != []} id="assumed" class="mt-8 border-t border-base-300 pt-5">
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
        Assumed, and carried on
      </h2>
      <div class="mt-3 flex flex-col gap-6">
        <div :for={question <- assumed(assigns)} class="flex flex-col gap-2">
          <p class="text-[12.5px]/[1.5] opacity-70">Assumed: {question.assumption}</p>
          <.question_card question={question} ticket_id={@ticket.id} />
        </div>
      </div>
    </section>
    """
  end

  defp blocking(%{questions: {blocking, _assumed}}), do: blocking
  defp assumed(%{questions: {_blocking, assumed}}), do: assumed

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
          <ol :if={step.jobs != []} class="mt-2 flex flex-col">
            <li :for={job <- step.jobs}>
              <.link
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
          approve={approve_pairs(@ticket, @artifacts)}
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
              <span class="shrink-0 opacity-60">{job.outcome || job.status}</span>
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
        <span class="truncate">{event.type}</span>
      </li>
    </ol>
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

  defp turns(jobs), do: jobs |> Enum.map(& &1.turns) |> Enum.sum()

  defp stuck_or_human?(assigns),
    do: (assigns.ticket.status == :stuck or assigns.human_state) and assigns.transitions != []

  defp waiting_clause(%{ticket: %{status: :stuck}}), do: "Stuck, and waiting for you to choose."

  defp waiting_clause(%{ticket: %{pending_transition: p}}) when is_map(p),
    do: "Waiting for approval."

  defp waiting_clause(%{questions: {[_ | _], _assumed}}),
    do: "A job stopped to ask you something."

  defp waiting_clause(_assigns), do: nil

  # A decision that pins the changeset is a merge decision, which has a page of its own — whether
  # it is waiting as a pending approval or as the transition out of the state the ticket rests in.
  defp reviewable?(%{pending_transition: pending} = ticket, _workflow) when is_map(pending),
    do: Workflow.changeset_artifact() in Engine.awaiting_approval(ticket)

  defp reviewable?(ticket, workflow) do
    workflow
    |> Workflow.transitions_from(ticket.state)
    |> Enum.any?(&(Workflow.changeset_artifact() in &1.approve))
  end

  defp approve_pairs(ticket, artifacts) do
    for name <- Engine.awaiting_approval(ticket),
        entry = Enum.find(artifacts, &(&1.artifact.name == name)),
        entry && entry.latest,
        do: {name, entry.latest.version}
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
