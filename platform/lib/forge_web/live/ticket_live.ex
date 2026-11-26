defmodule ForgeWeb.TicketLive do
  @moduledoc """
  One ticket in the frame (`docs/design/ui.md` § The ticket): **Steps · Changes · Docs ·
  Activity**, and Talk while it has a live or step conversation; the details drop from its title,
  the decision row is pinned under it, and a document's questions sit in the pane above the
  strip.

  **The view it opens on is the one holding what waits**: Changes for a changeset approval, Docs
  for a document approval, Steps for everything else. A named view is the one shown, and a view
  the ticket no longer has — `?tab=decide`, from before the Decide tab went — lands on that
  default too. Chosen when the page is opened or navigated, and not on the reloads a change
  brings: an approval arriving, or one decided elsewhere, does not move a reader off their view.

  **There is no Decide view.** What it held is where the thing is: the approval in the decision
  row, questions in the question pane, the ways forward, a human state's editors and the merge
  queue on the current step, assumptions under Steps (`ForgeWeb.TicketViews`).

  **Activity is live while the ticket's job runs.** Someone reading a ticket whose job is running
  is deciding whether to wait, answer or steer (`ui.md` § Motion and structure), so the page is
  subscribed to that one job's topic and appends what it streams. It follows the ticket to its
  next job when one starts.
  """

  use ForgeWeb, :live_view

  alias Forge.{Artifacts, Conversations, Engine, Events, Git, Jobs, Projects, Proposals}
  alias Forge.{ReleaseTickets, Spend, Tickets}
  alias Forge.Tickets.Views
  alias ForgeCore.Workflow
  alias ForgeWeb.{Changes, Diff, Format, JobStream, TicketViews, WorkScreen}
  alias ForgeWeb.Components.TakeoverBand
  alias ForgeWeb.Operator.{Actions, Decision, Drafts, QuestionForm}

  @views ~w(steps changes docs activity)

  # How much of a failed command's log Steps shows: the end, where a build says why it stopped.
  # The whole log is one tap away on the command's page.
  # One figure for the Steps view and the queue (`Forge.Tickets.Past.tail_bytes/0`).
  @tail_bytes Forge.Tickets.Past.tail_bytes()

  # How often the spend countdown is drawn again: the minute it is drawn to.
  @spend_tick :timer.minutes(1)

  @impl true
  def mount(%{"project" => name, "number" => number}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    # A look is recorded once the reader is known to be a member, and only on the connected
    # mount: the dead render and the live one are one visit, and recording both would make the
    # second's previous look the first's (`Forge.Tickets.Views`). A rejoin is one visit too.
    last_looked =
      if connected?(socket) do
        Events.subscribe()
        Events.subscribe_chats()
        Process.send_after(self(), :spend_tick, @spend_tick)
        look(socket, ticket)
      end

    {:ok,
     socket
     |> assign(
       project: project,
       ticket_id: ticket.id,
       tab: nil,
       following: nil,
       # The person's previous look at this ticket, which marks what is new since (`ui.md`
       # § Steps, § Activity): recorded above, nil on a first look and on the dead render.
       since: last_looked,
       looked: connected?(socket),
       default_view: nil,
       forward: nil,
       # The fold of other states, open or not: a field of the ways form, held with the pick.
       other: false,
       forms: QuestionForm.init(),
       drafts: Drafts.init(),
       refusal: nil,
       reach: reach(socket)
     )
     |> Decision.init()
     |> Changes.init()
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  # **A rejoin of the page records no look** (`docs/design/ui.md` § The end of the pass, and
  # *All*). The page carries the look it was opened with in `#ticket-look`, which only a connected
  # render draws, and the socket sends it back when it joins (`assets/js/app.js`): a mount that
  # receives it for this ticket is the same visit rejoining, and draws from it rather than
  # recording another. A dead render, a page of another ticket and a fresh visit send none, and
  # record.
  # What is sent is the person's own look at a ticket they are a member of; sending a false one
  # moves only their own marks.
  defp look(socket, ticket) do
    case get_connect_params(socket) do
      %{"look" => %{"ticket" => id} = look} when id == ticket.id -> parse_look(look["since"])
      _fresh -> Views.touch(socket.assigns.current_scope.user, ticket)
    end
  end

  defp parse_look(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} -> at
      _first_look -> nil
    end
  end

  defp parse_look(_none), do: nil

  # A view the ticket has is the one shown; anything else — none, or one it no longer has — is
  # nil, and the default is the one holding what waits, chosen here, as the page is opened or
  # navigated, and not again on a reload (`docs/design/ui.md` § The ticket).
  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @views, do: params["tab"], else: nil

    {:noreply,
     socket
     |> assign(
       tab: tab,
       default_view: default_view(socket.assigns),
       changes_params: Changes.params(params)
     )
     |> Changes.choose_again()
     |> load_changes()
     |> load_activity()}
  end

  # What Changes shows is read only while it is the view on screen (`ForgeWeb.Changes`).
  defp load_changes(%{assigns: %{workflow: nil}} = socket), do: socket

  defp load_changes(socket),
    do: if(view(socket.assigns) == "changes", do: Changes.load(socket), else: socket)

  # **A pin is read as it was admitted** (`docs/design/workflow-grammar-v1.md` § Pinning), so this
  # is not where the validator's newer rules are asked again: that is what gave every ticket
  # admitted before 0.16.0 a 500. A pin the grammar can no longer build has no steps to draw and
  # no topology, so Steps says so rather than drawing half a ticket.
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
      docs: docs(project, ticket, artifacts, [], %{}),
      opens: nil,
      attached_events: %{},
      ticket_files: [],
      ticket_text: nil,
      events: Events.newest_for_ticket(ticket.id, 10),
      activity: nil,
      transcripts: [],
      drift: Tickets.drift(ticket, project),
      paused: false,
      now: DateTime.utc_now()
    )
  end

  defp load(%{assigns: %{project: project}} = socket, ticket, workflow) do
    jobs = Jobs.for_ticket(ticket.id)
    current = List.last(jobs)

    # Commands are the ticket's work too, and sit in the step their state is in: an agent's beneath
    # it, a command state's as that state's (`docs/design/ui.md` § Steps). A chat step's
    # conversations sit in the step they are, beside the jobs of other states.
    work =
      Enum.sort_by(
        jobs ++ Jobs.commands_for_ticket(ticket.id) ++ Jobs.step_chats_for_ticket(ticket.id),
        & &1.inserted_at,
        DateTime
      )

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
    conflict = Forge.Merge.Watch.notice(ticket)
    step = step_view(ticket)
    {events, attached_events} = ticket_events(ticket)

    # The ticket's text and the files that came with it are read once, so they are one version's
    # (`docs/design/ui.md` § Steps): a second read could meet a version written in between.
    text_version = Artifacts.latest(ticket.id, Workflow.ticket_artifact())

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
      jobs: jobs,
      current: current,
      step: step,
      accepted: accepted_steps(ticket),
      # A page's files are not chips of a step: the page is one thing, listed in Docs.
      steps:
        steps(
          work,
          without_page_files(artifacts, ticket),
          ticket,
          workflow,
          socket.assigns.current_scope.user.id
        ),
      waits: waits(work),
      # Why the last batch sent the ticket where it is, under the commands that failed in it.
      tails: Forge.Jobs.Commands.failure_tails(ticket.id, @tail_bytes),
      artifacts: artifacts,
      diff: diff,
      commits: commits(project, ticket),
      events: events,
      # What came with the notes and answers listed, by event (`Forge.Attachments`).
      attached_events: attached_events,
      # The files that came with the ticket's text, named under it on Steps.
      ticket_files: came_with(project, ticket, text_version),
      # The text itself, drawn as Markdown at the head of Steps and in a release's note.
      ticket_text: ticket_text(project, ticket, text_version),
      addresses:
        Forge.Accounts.addresses(for %{actor: %{"kind" => "user", "id" => id}} <- events, do: id),
      queue_events: queue_events(ticket),
      activity: activity(socket, current),
      transcripts: transcripts(project, ticket, current),
      transitions: Engine.offered_transitions(ticket, workflow),
      jumps: jumps(ticket, workflow),
      retry: Engine.retryable?(ticket),
      # What a job that ran out may be given, and the cap it is judged against: the Extend and Run
      # again forms are drawn from these (`ForgeWeb.Components.MoreRoom`).
      extend: Forge.Jobs.Extensions.offer(ticket),
      room: Forge.Jobs.Extensions.cap_facts(ticket, workflow),
      # Where the ticket stands in its project's merge queue, or nil (`ui.md` § Steps).
      queue: Forge.MergeQueue.places(project.id)[ticket.id],
      stuck_reason: Engine.why_stuck(ticket),
      drift: Tickets.drift(ticket, project),
      conflict: conflict,
      rebase_outcome: conflict && conflict.send_to && Engine.rebase_outcome(ticket, workflow),
      human_state:
        ticket.status in Forge.Tickets.Ticket.open_statuses() and
          Workflow.State.human?(Workflow.state(workflow, ticket.state)),
      writable: writable(ticket, workflow),
      opens: opens(project, ticket, workflow),
      proposals: Proposals.open_for_ticket(ticket.id),
      changeset: Artifacts.latest(ticket.id, Workflow.changeset_artifact()),
      release: release(ticket),
      scheduled: scheduled(ticket),
      warm_build: warm_build(ticket),
      # The hold (`docs/design/workflow-grammar-v1.md` § Holding a ticket): what releasing does, and
      # whether a run is still going that Stop now would stop. The open milestones are what the
      # details' select offers.
      on_release: Engine.waiting_on_release_or_job(ticket),
      stoppable: Engine.stoppable?(ticket),
      # A taken-over ticket's band: who, since when, what was pushed, and the steps a hand-back
      # may continue from (`ForgeWeb.Components.TakeoverBand`). A run going is what *Take over*
      # asks a choice about.
      takeover: TakeoverBand.facts(ticket, project),
      moved: TakeoverBand.moved(ticket, project),
      hand_steps: if(ticket.takeover_id, do: TakeoverBand.steps(ticket, workflow), else: []),
      running: Engine.running?(ticket),
      taker_addresses: taker_addresses(ticket),
      milestones:
        Forge.Milestones.list(project.id) |> Enum.filter(&Forge.Milestones.Milestone.open?/1),
      paused: paused?(ticket, jobs),
      now: DateTime.utc_now()
    )
    |> assign_decision()
    |> assign_docs(artifacts, jobs)
    |> load_chats()
    |> load_changes()
    |> load_activity()
  end

  # The current job's stream, counted on every load and read only while Activity is on screen, as
  # Changes is (`docs/design/ui.md` § Activity). The one the page already holds for this job is
  # reloaded — what arrived above it is read, and the figures counted again — never read afresh;
  # a new current job starts a new stream.
  defp activity(_socket, nil), do: nil

  defp activity(%{assigns: assigns}, current) do
    case Map.get(assigns, :activity) do
      %JobStream{job_id: id} = held when id == current.id -> JobStream.reload(held)
      _another -> JobStream.new(current.id)
    end
  end

  # What a swept job's line links; read only for a job that was swept.
  defp transcripts(_project, _ticket, nil), do: []

  defp transcripts(project, ticket, current),
    do: WorkScreen.transcript_links(current, project, ticket)

  defp load_activity(%{assigns: %{activity: nil}} = socket), do: socket

  defp load_activity(%{assigns: %{activity: stream} = assigns} = socket) do
    if view(assigns) == "activity" and not JobStream.open?(stream) do
      position = JobStream.reach(socket.assigns.reach["activity"], stream.job_id)

      assign(socket,
        activity:
          if(position, do: JobStream.rejoin(stream, position), else: JobStream.open(stream))
      )
    else
      socket
    end
  end

  # Where each stream was read back to before a dropped socket rejoined, if it did
  # (`docs/design/ui.md` § A reconnect is not a reload).
  defp reach(socket) do
    with true <- connected?(socket),
         %{"reach" => %{} = reach} <- get_connect_params(socket) do
      reach
    else
      _none -> %{}
    end
  end

  # The one decision row the ticket has (`docs/design/ui.md` § The decision row): its pending
  # approval, or else its chat step's Accept, whose *Answer first* goes to the conversation.
  defp assign_decision(%{assigns: assigns} = socket) do
    decision =
      Decision.approval(assigns.project, assigns.ticket, assigns.diff) ||
        Decision.step(assigns.step, step_questions(assigns.step), step_href(assigns.step))

    Decision.put(socket, decision)
  end

  # Docs is grouped by what each document asks of you (`ui.md` § Docs), so which ones the decision
  # on screen waits on is the decision's to say: the versions an approval pins, or the documents a
  # chat step's Accept would approve.
  defp assign_docs(%{assigns: %{project: project, ticket: ticket} = assigns} = socket, art, jobs) do
    jobs = Map.new(jobs ++ Jobs.step_chats_for_ticket(ticket.id), &{&1.id, &1})
    scope = Forge.Accounts.Scope.for_project(assigns.current_scope, project)
    user = assigns.current_scope.user

    assign(socket,
      docs: docs(project, ticket, art, waiting(assigns.decision), jobs, scope, user)
    )
  end

  defp waiting(%{kind: :approval, pins: pins}), do: for(p <- pins, not p.changeset, do: p.name)

  defp waiting(%{kind: :step, step: step}),
    do: for(d <- step.documents, d.version != nil, do: d.name)

  defp waiting(_none), do: []

  # What the conversation's last reply asked and nobody has answered: they stay unanswered if the
  # step is accepted now, and Accept's panel says so. Read only when there is a row to say it in.
  defp step_questions(step) do
    if ForgeWeb.Components.StepAccept.row?(step) do
      step.chat.id |> Conversations.last_said() |> Conversations.questions()
    else
      []
    end
  end

  defp step_href(nil), do: nil
  defp step_href(step), do: ~p"/chats/#{step.chat.id}"

  # Apart from `load/3` because something said in a conversation is far more frequent than
  # anything else on this page, and the rest of it is several reads and some git.
  defp load_chats(%{assigns: %{ticket_id: id}} = socket),
    do: assign(socket, chats: Conversations.summaries(ticket_id: id), now: DateTime.utc_now())

  # What the merge queue did to the ticket, oldest first, and the merge it ended in — and nothing
  # for a ticket the queue never held: a merge on a workflow that queues nothing is no part of
  # this section's story.
  defp queue_events(ticket), do: Events.merge_queue_for_ticket(ticket.id)

  # The ticket's own events that say something its jobs do not — a decision and its note, a
  # transition, why it stuck — newest first, for Activity (`ui.md` § Activity).
  # What Activity lists on the ticket, and what came with each: the events it says in words, and an
  # answer **that came with files**, which is listed so that the names are under it
  # (`docs/design/ui.md` § Attaching files) — an answer without files is in the document it answers.
  defp ticket_events(ticket) do
    said = Events.said_for_ticket(ticket.id, TicketViews.said_types(), 12)
    answered = Events.answered_with_files(ticket.id)

    files = Forge.Attachments.entries_for_events(Enum.map(said ++ answered, & &1.seq))
    answered = Enum.filter(answered, &Map.has_key?(files, &1.seq))

    events = (said ++ answered) |> Enum.sort_by(& &1.seq, :desc) |> Enum.take(12)
    {events, Map.take(files, Enum.map(events, & &1.seq))}
  end

  # The Accept area's model while the ticket rests in a chat step that has a conversation.
  defp step_view(%Forge.Tickets.Ticket{status: status} = ticket)
       when status in [:active, :stuck] do
    with true <- Forge.Steps.step?(ticket),
         %Jobs.Job{} = chat <- Forge.Steps.chat_for(ticket) do
      Forge.Steps.view(ticket, chat)
    else
      _no_step -> nil
    end
  end

  defp step_view(_ticket), do: nil

  # What each step's conversation was accepted with, by conversation id: Steps' entry for the
  # outcome, as a job's row has one. Who pressed it is the event's actor.
  defp accepted_steps(ticket) do
    ticket.id
    |> Events.of_type_for_ticket("step.accepted")
    |> Map.new(&{&1.job_id, &1.payload})
  end

  # The schedule that admitted the ticket and the admin it acted for, from the `ticket.admitted` event,
  # or nil for a ticket a person admitted (`docs/design/schedules.md` § The pages).
  defp scheduled(ticket) do
    case Events.latest_for_ticket(ticket.id, "ticket.admitted") do
      %{payload: %{"schedule" => %{"name" => name} = schedule}} ->
        %{
          name: name,
          due: schedule["due_at"] && Forge.Schedules.due_date(schedule["due_at"]),
          by: schedule["admin"]
        }

      _admitted_by_a_person ->
        nil
    end
  end

  # A release ticket's band and the head of its Steps (`ui.md` § Steps, `21e`): who started it,
  # the workflow it runs, and what has merged since the previous release.
  defp release(ticket) do
    if ReleaseTickets.release?(ticket) do
      admitted = Events.latest_for_ticket(ticket.id, "ticket.admitted")
      %{by: admitted && admitted.actor, since: ReleaseTickets.since(ticket)}
    end
  end

  # The documents the state the ticket rests in declares, for a person to write: a human state's
  # `produces`, with the latest version of each when there is one (`docs/design/ui.md` § Steps).
  # A job state's are the job's to write, so it offers none.
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

  # What the fold of other states lists: every state a jump reaches, with whether it merges and what
  # its job would find missing. Read here, on a load, and not in a render.
  #
  # **The clause for a cancelled ticket is an equivalent mutant**: `TicketViews.fold/1` draws
  # nothing for one whatever is read (`moves?/1` is false for it), so this only spares reading the
  # repository for a page that will not draw the result.
  defp jumps(%{status: :cancelled}, _workflow), do: []

  defp jumps(ticket, workflow) do
    for to <- Engine.jumps(ticket, workflow) do
      %{
        to: to,
        merges: Workflow.merges_on_enter?(workflow, to),
        missing: Forge.Jobs.missing_inputs(ticket, workflow, to)
      }
    end
  end

  # The address of the person who took the ticket over, for the band (Activity names a person by
  # address too). A token is named by the row itself.
  defp taker_addresses(%{takeover_id: nil}), do: %{}

  defp taker_addresses(%{takeover_id: id}) do
    case Forge.Repo.get(Forge.Tickets.Takeover, id) do
      %{user_id: user_id} when is_binary(user_id) -> Forge.Accounts.addresses([user_id])
      _token_or_gone -> %{}
    end
  end

  # What the branch holds against its base: the ticket's own work, whether or not it has been
  # recorded as a changeset yet — and, while an approval of the changeset waits, the commit that
  # approval pins and no other, which is what Approve is pressed on (`ui.md` § Changes).
  defp ticket_diff(project, ticket) do
    repo = Projects.repo_path(project)

    case pinned_head(ticket) || Git.resolve(repo, "refs/heads/" <> ticket.branch) do
      {:ok, head} -> Diff.build(repo, ticket.base_commit, head)
      # A pinned version that names no commit is said, never replaced by the branch's diff: that
      # would be a change shown for approval that the approval does not pin.
      {:not_a_commit, uri} -> %{error: {:not_a_commit, uri}}
      _gone -> nil
    end
  end

  defp pinned_head(%{pending_transition: nil}), do: nil

  defp pinned_head(ticket) do
    changeset = Workflow.changeset_artifact()

    with true <- changeset in Engine.awaiting_approval(ticket),
         %{} = version <- Artifacts.latest(ticket.id, changeset) do
      case Artifacts.commit(version) do
        nil -> {:not_a_commit, version.blob_uri}
        head -> {:ok, head}
      end
    else
      _none -> nil
    end
  end

  defp commits(project, ticket),
    do:
      Diff.commits(
        Projects.repo_path(project),
        ticket.base_commit,
        "refs/heads/" <> ticket.branch
      )

  defp without_page_files(artifacts, ticket) do
    pages = ForgeWeb.PageViews.names({:ticket, ticket.id})
    Enum.reject(artifacts, &ForgeWeb.PageViews.member?(pages, &1.artifact.name))
  end

  # The page a human state names to open while the ticket rests in it, or nil: a link to it when it
  # has a version, and `href: nil` — drawn as *no version yet* — when it has none
  # (`docs/design/ui.md` § The ticket). Not a decision, and not counted.
  defp opens(project, ticket, %Workflow{} = workflow) do
    with true <- ticket.status in Forge.Tickets.Ticket.open_statuses(),
         %{opens: name} when is_binary(name) <- Workflow.state(workflow, ticket.state) do
      ForgeWeb.PageViews.opens(%{project: project, ticket: ticket, chat: nil}, name)
    else
      _no_page -> nil
    end
  end

  defp opens(_project, _ticket, nil), do: nil

  # Every artifact the ticket has, a row each — a document's rendered when opened — its latest
  # version first and the earlier ones linked, grouped by what it asks of the person. The
  # changeset is not one: it is Changes.
  defp docs(project, ticket, artifacts, waiting, jobs, scope \\ nil, user \\ nil) do
    where = %{project: project, ticket: ticket, chat: nil}
    pages = ForgeWeb.PageViews.names({:ticket, ticket.id})

    # A page is one row of its own (`ForgeWeb.PageViews`), and its files are not.
    files =
      for %{artifact: artifact, latest: latest} = entry <- artifacts,
          TicketViews.doc?(entry),
          not ForgeWeb.PageViews.member?(pages, artifact.name) do
        href = fn version ->
          ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version}"
        end

        # Read once, for the row's body and for the files named under it, so both are one
        # version's. No test can drive a write between two reads in one process, which is why
        # this has no test that fails without it.
        versions = Artifacts.versions(ticket.id, artifact.name)

        doc =
          WorkScreen.doc(
            artifact,
            versions,
            href,
            entry.approvable,
            Forge.References.ticket_scope(project.name, ticket)
          )

        doc
        |> Map.put(:group, group(doc, latest, waiting))
        |> Map.put(:by, TicketViews.written_by(latest.author, jobs))
        |> WorkScreen.mark_attached(versions, scope, user)
        |> Map.put(:came_with, came_with(project, ticket, List.last(versions)))
      end

    # What a ticket's jobs wrote, so under *Produced*.
    files ++ Enum.map(ForgeWeb.PageViews.docs(where, jobs), &Map.put(&1, :group, :produced))
  end

  # The ticket's latest text as it is drawn, or nil when there is none to draw. Every version
  # admission writes opens with the title as a `# ` line, so a ticket admitted with no body, or a
  # release with no note, has text that is not empty and says only what the page's heading says:
  # that is drawn as no text, as an empty body was (`docs/design/ui.md` § Steps). There is no
  # fallback to `tickets.body`, since every ticket has a `ticket` version from admission on.
  defp ticket_text(_project, _ticket, nil), do: nil

  defp ticket_text(project, ticket, version) do
    if title_only?(version.content),
      do: nil,
      else:
        ForgeWeb.FileType.render_document(
          Workflow.ticket_artifact(),
          version,
          Forge.References.ticket_scope(project.name, ticket)
        )
  end

  defp title_only?(content) do
    lines =
      content
      |> ForgeCore.Document.body()
      |> String.split("\n")
      |> Enum.reject(&(String.trim(&1) == ""))

    case lines do
      [] -> true
      [first] -> String.starts_with?(first, "# ")
      _more -> false
    end
  end

  # The files that came with this version of a document or the ticket's text, named under its row
  # (`docs/design/ui.md` § Attaching files), each live one carrying its address.
  defp came_with(_project, _ticket, nil), do: []

  defp came_with(project, ticket, latest) do
    for entry <- Map.get(Forge.Attachments.entries_for_versions([latest.id]), latest.id, []) do
      if entry.state == :live,
        do:
          Map.put(
            entry,
            :href,
            ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{entry.name}/#{entry.version}"
          ),
        else: entry
    end
  end

  # Waiting: what the decision on screen waits on. Built from: what a person approved or wrote.
  # Produced: the rest, what the ticket's jobs wrote.
  defp group(doc, latest, waiting) do
    cond do
      doc.name in waiting -> :waiting
      # A person's file is what the ticket was built from, whoever attached it — a token too.
      Workflow.attachment?(doc.name) -> :built_from
      doc.approved or match?(%{"kind" => "user"}, latest.author) -> :built_from
      true -> :produced
    end
  end

  # One step per state visit, in the order the jobs ran, and an update step's visits among them: a
  # visit of its own each, never folded into a neighbour, in the order the events were written
  # (`events.inserted_at` is whole seconds, so `seq` decides). A state the ticket reached without a
  # job — a human state it is resting in — still gets its step, because the operator is looking
  # for where the ticket is, not only for where work happened.
  # A visit per run of jobs in one state, **broken at a jump**: two visits to `implementing` either
  # side of one are two steps, and the jump is a row of its own between them
  # (`docs/design/ui.md` § Steps). Each job falls in the segment of jumps made before it — by the
  # order of the events (`Events.job_created_seqs/1`: every job has a creation event, of one type
  # or another), and by the clock only for a job none is found for (`jumped_before?/3`) — and each
  # update step's visit by the order of the events; within a segment
  # the jobs and visits are in the order they were made (`in_order/3`). The rows are the segments'
  # visits in turn with the jump that ends each. The ticket's own state is always the last step,
  # resting with no job when nothing has run in it since.
  defp steps(jobs, artifacts, ticket, workflow, me) do
    jumps = jump_events(ticket)
    created = Events.job_created_seqs(ticket.id)
    updates = Forge.Update.visits(ticket.id)

    job_segments =
      Enum.group_by(jobs, fn job -> Enum.count(jumps, &jumped_before?(&1, job, created)) end)

    update_segments =
      Enum.group_by(updates, fn {seq, _payload} -> Enum.count(jumps, &(&1.seq < seq)) end)

    rows =
      for segment <- 0..length(jumps)//1,
          row <-
            visits(
              Map.get(job_segments, segment, []),
              Map.get(update_segments, segment, []),
              artifacts,
              created
            ) ++
              Enum.map(Enum.slice(jumps, segment, 1), &jump_row(&1, me)),
          do: row

    rows =
      if match?(%{name: name} when name == ticket.state, List.last(rows)),
        do: rows,
        else: rows ++ [%{name: ticket.state, jobs: [], artifacts: [], cost: 0, update: nil}]

    rows
    |> Enum.map(fn
      %{jump: _} = jump -> jump
      visit -> Map.put(visit, :topology, ForgeWeb.Topology.of(workflow, visit.name))
    end)
    |> name_merges(ticket)
  end

  defp visits(jobs, updates, artifacts, created) do
    jobs
    |> in_order(updates, created)
    |> chunk_visits()
    |> Enum.map(fn
      {:jobs, group} ->
        %{
          name: hd(group).state,
          jobs: group,
          artifacts: Enum.filter(artifacts, &written_in?(&1, group)),
          cost: Enum.reduce(group, 0, &(&2 + &1.usage)),
          update: nil
        }

      {:update, payload} ->
        %{name: payload["state"], jobs: [], artifacts: [], cost: 0, update: payload}
    end)
  end

  # Whether the jump was made before the job: by where each was written in the log when the job's
  # creation is there (every job's is: `Events.job_created_seqs/1`), and else by the clock, in whole
  # seconds — a job's row is stamped to the microsecond and an event's to the second, and both are
  # cut to the second here, so a job made in the jump's own second reads as after it. The clock is
  # a defence for a job whose event is gone, not a path the platform takes.
  defp jumped_before?(%{seq: seq}, %{id: id}, created) when is_map_key(created, id),
    do: seq < Map.fetch!(created, id)

  defp jumped_before?(%{inserted_at: at}, %{inserted_at: made}, _created),
    do: stamp(at) <= stamp(made)

  defp stamp(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> stamp()
  defp stamp(%DateTime{} = at), do: DateTime.to_unix(at)

  # The jumps the ticket was moved by, oldest first: what Steps draws between the visits it split.
  defp jump_events(%{id: id}), do: Events.jumps_for_ticket(id)

  defp jump_row(%{actor: actor, payload: payload}, me) do
    %{
      jump: %{
        from: payload["from"],
        to: payload["to"],
        comment: payload["comment"],
        reopened: payload["reopened"] == true,
        by: TicketViews.jumper(actor, me)
      }
    }
  end

  # Jobs and visits in the order they were made: a job by the seq of its creation event
  # (`Events.job_created_seqs/1`: a command and a step chat have one too), a visit by its own. A job
  # with no such event keeps its place after the ones that have one, in the order it came. Commands
  # of one `commands.started` share a seq, and the sort is stable, so they keep their order.
  defp in_order(jobs, [], _created), do: Enum.map(jobs, &{:job, &1})

  defp in_order(jobs, visits, created) do
    jobs
    |> Enum.with_index()
    |> Enum.map(fn {job, i} -> {Map.get(created, job.id, 1_000_000_000_000 + i), {:job, job}} end)
    |> Enum.concat(Enum.map(visits, fn {seq, payload} -> {seq, {:update, payload}} end))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  # Consecutive jobs of one state are one visit; an update step's visit is always its own.
  @doc false
  def chunk_visits(items) do
    items
    |> Enum.reduce([], fn
      {:update, payload}, acc ->
        [{:update, payload} | acc]

      {:job, job}, [{:jobs, [%{state: state} | _] = group} | rest] when job.state == state ->
        [{:jobs, [job | group]} | rest]

      {:job, job}, acc ->
        [{:jobs, [job]} | acc]
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:jobs, group} -> {:jobs, Enum.reverse(group)}
      update -> update
    end)
  end

  # What each merge an update step brought in is called: the title of the ticket whose merge it was,
  # read once for the page. A conversation's merge and one nothing recorded have no title.
  defp name_merges(visits, ticket) do
    numbers =
      for %{update: %{"merges" => merges}} <- visits,
          %{"ticket" => number} <- merges,
          uniq: true,
          do: number

    titles = Forge.Update.titles(ticket.project_id, numbers)

    Enum.map(visits, &Map.put(&1, :titles, titles))
  end

  # The details' Warm build block: nothing when no command of the pinned workflow keeps its build,
  # otherwise `%{copy: nil | the copy the ticket's next command will be sent to}` as the block
  # draws it (`docs/design/ui.md` § The details). The machine is named as a command's page names
  # it, and the command as `ForgeCore.Workflow.Command.argv/1` shows its arguments.
  defp warm_build(ticket) do
    if Forge.WarmBuilds.declared?(ticket),
      do: %{copy: ticket |> Forge.WarmBuilds.current() |> warm_copy()}
  end

  defp warm_copy(nil), do: nil

  defp warm_copy(%{job: job, worker: worker, size: size, kept_at: at}) do
    command = Jobs.spec(job).command || %{}

    %{
      size: size,
      machine: "machine " <> String.slice(worker.id, 0, 8),
      command: command["name"],
      args: command["args"],
      commit: Diff.short(command["at"]),
      at: at
    }
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
  # (`ForgeWeb.JobStream`); after a call's result the branch is read again shortly. Anything else
  # on the job's topic — a wait, the run ending — reloads, and so does every change announced for
  # this ticket.
  #
  # Adding rather than reloading is a saving here and not a behaviour: this page holds nothing a
  # reload takes away, and a reload reads the same log and the branch a moment sooner. So the
  # `streamed?/1` test answering false on this page is an equivalent mutant — what it saves is
  # every query of `load/1`, per event, for as long as a job streams. (On the conversation's page
  # it is not equivalent, and a test says so.)
  @impl true
  def handle_info(
        {:job_event, id, event},
        %{assigns: %{following: id, activity: %JobStream{}}} = socket
      ) do
    if JobStream.streamed?(event) do
      case JobStream.add(socket.assigns.activity, event) do
        :seen ->
          {:noreply, socket}

        {:ok, activity} ->
          {:noreply, socket |> assign(activity: activity) |> JobStream.catch_up(event)}
      end
    else
      {:noreply, load(socket)}
    end
  end

  def handle_info({:job_event, _id, _event}, socket), do: {:noreply, socket}

  def handle_info({:ticket_changed, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  # Only this ticket's conversations redraw the list, matched in the head before anything is read.
  def handle_info({:chat_changed, _id, _project, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load_chats(socket)}

  def handle_info({:chat_changed, _id, _project, _other}, socket), do: {:noreply, socket}

  # What the branch holds, read again after a call that may have committed to it.
  # The spend countdown moves on the minute, as the usage lines do (`ForgeWeb.Frame`), and whether
  # the cap still holds is read again with it: it can lift before midnight, when a running job's
  # budget is released.
  def handle_info(:spend_tick, socket) do
    Process.send_after(self(), :spend_tick, @spend_tick)

    case socket.assigns do
      %{workflow: nil} ->
        {:noreply, assign(socket, now: DateTime.utc_now())}

      %{ticket: ticket, jobs: jobs} ->
        {:noreply, assign(socket, now: DateTime.utc_now(), paused: paused?(ticket, jobs))}
    end
  end

  def handle_info(:catch_up, %{assigns: %{project: project, ticket: ticket}} = socket) do
    {:noreply,
     socket
     |> assign(
       diff: ticket_diff(project, ticket),
       commits: commits(project, ticket),
       catching_up: false
     )
     |> load_changes()}
  end

  @impl true
  # A ticket whose pin cannot be read can be cancelled, restored and re-pinned, and nothing else:
  # the page draws no other control, and the rest either asks the workflow or reads what
  # `load_unreadable/3` does not assign.
  def handle_event(event, _params, %{assigns: %{workflow: nil}} = socket)
      when event not in ["cancel-ticket", "restore-ticket", "repin"] do
    {:noreply,
     Actions.refuse(
       socket,
       "unavailable",
       "That is not available while this ticket's workflow cannot be read."
     )}
  end

  # *Ask about this* on a ticket has no composer to put the reference in, so it goes to one: the
  # ticket's most recently used live conversation (the list's order), with the reference in its
  # draft, or a new one about the ticket with the reference as its first message. The reference
  # travels in the address and nothing is sent until the operator sends it
  # (`docs/design/ui.md` § Changes).
  def handle_event("ask", %{"ref" => ref}, socket) do
    %{project: project, ticket: ticket, chats: chats} = socket.assigns

    to =
      case Enum.find(chats, & &1.live) do
        %{chat: chat} -> ~p"/chats/#{chat.id}?#{[tab: "talk", ask: ref]}"
        nil -> ~p"/chats/new?#{[project: project.name, ticket: ticket.number, text: ref]}"
      end

    {:noreply, push_navigate(socket, to: to)}
  end

  def handle_event("more", _params, %{assigns: %{activity: %JobStream{} = stream}} = socket),
    do: {:noreply, assign(socket, activity: JobStream.older(stream))}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  def handle_event("attachments:withdraw", params, socket),
    do:
      {:noreply, ForgeWeb.Attaching.withdraw(socket, {:ticket, socket.assigns.ticket.id}, params)}

  def handle_event("notices", _params, %{assigns: %{activity: %JobStream{} = stream}} = socket) do
    drawn = stream |> JobStream.held() |> WorkScreen.entries(stream.notices) |> length()
    {:noreply, assign(socket, activity: JobStream.toggle_notices(stream, drawn))}
  end

  def handle_event("notices", _params, socket), do: {:noreply, socket}

  # The person's own decision moves the ticket on, and the page with it: the default view is chosen
  # again when their press changed what waits (`docs/design/ui.md` § The ticket). A refused press
  # changes nothing, and neither does someone else's decision. A view the address names would
  # outrank the new default (`view/1`) — every strip tab and the queue's link name one — so the
  # address loses its `tab`, and `handle_params/3` chooses the default from what waits now.
  def handle_event("decision:" <> _ = event, params, socket) do
    before = socket.assigns.decision_key
    {:noreply, socket} = Decision.handle_event(event, params, socket, &load/1)

    cond do
      socket.assigns.decision_key == before or socket.assigns.decision_error != nil ->
        {:noreply, socket}

      socket.assigns.tab != nil ->
        %{project: project, ticket: ticket} = socket.assigns
        {:noreply, push_patch(socket, to: ~p"/tickets/#{project.name}/#{ticket.number}")}

      true ->
        {:noreply,
         socket
         |> assign(default_view: default_view(socket.assigns))
         # Changes' sub-view is chosen again with the view. Dropping this is an equivalent mutant
         # as far as a test can tell: a decision that leaves Changes the default leaves what
         # waits in review, which keeps the sub-view chosen before it.
         |> Changes.choose_again()
         |> load_changes()}
    end
  end

  # The wide screen's pane beside the presentation: which file it shows. Reads, writes nothing.
  def handle_event("changes:follow", params, socket),
    do: {:noreply, Changes.follow(socket, params)}

  # The way forward picked, held so the dock button names it and a rejoin gives it back
  # (`docs/design/ui.md` § A reconnect is not a reload). Picking commits nothing.
  def handle_event("forward:pick", params, socket),
    do:
      {:noreply,
       socket
       |> assign(forward: params["way"], other: params["other"] == "open")
       |> hold_typed(params)}

  # The dock button: the way picked, taken by the operation that takes it anywhere — a transition
  # or running the state again, each guarded in `Forge.Operator`.
  def handle_event("forward", params, socket) do
    case forward(params, socket.assigns.ticket) do
      {event, params} -> forward_act(event, params, socket)
      nil -> {:noreply, socket}
    end
  end

  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  # A way forward taken: the pick is let go when it was done, and kept when it was refused, so that
  # the refusal is drawn under the form with what was typed still in it (`ui.md` § Errors stay where
  # you acted). The fold of other states goes with the pick, so a refused jump stays in sight.
  defp forward_act(event, params, socket) do
    {:noreply, socket} = handle_event(event, params, socket)

    if socket.assigns.refusal == nil,
      do: {:noreply, assign(socket, forward: nil, other: false)},
      else: {:noreply, socket}
  end

  # Taken by the operation that takes it anywhere — each guarded in `Forge.Operator`. What was
  # typed under the row rides along: the note and the cap raise of both, the tokens, turns and time of
  # Extend, and the job the person was shown, which is the one the act checks.
  defp forward(%{"way" => "again"} = params, ticket),
    do: {"retry", params |> Map.take(~w(note raise draft)) |> Map.put("ticket", ticket.id)}

  defp forward(%{"way" => "extend"} = params, ticket),
    do:
      {"extend",
       params
       |> Map.take(~w(tokens turns timeout note raise job draft))
       |> Map.put("ticket", ticket.id)}

  # Each press says what kind of move it was drawn as, so one drawn before the ticket moved is
  # refused and not taken as the other kind (`Forge.Engine.choose/4`).
  defp forward(%{"way" => "to:" <> to}, ticket),
    do: {"transition", %{"ticket" => ticket.id, "to" => to, "jump" => "false"}}

  defp forward(%{"way" => "jump:" <> to}, ticket),
    do: {"transition", %{"ticket" => ticket.id, "to" => to, "jump" => "true"}}

  defp forward(_nothing, _ticket), do: nil

  # What is typed under the way picked, held in the page's drafts so that a rejoin gives it back and
  # the raise box can be drawn from it. The raise is the shortfall until the person types in it:
  # picking another way or changing the tokens drops what an earlier shortfall filled in, so it
  # follows them; a change to anything else leaves a raise the person typed alone.
  defp hold_typed(socket, params) do
    params =
      if params["_target"] in [["tokens"], ["way"]], do: Map.delete(params, "raise"), else: params

    case Drafts.handle("draft:change", Map.put(params, "draft", "ways-forward"), socket) do
      {:state, socket} -> socket
      :unknown -> socket
    end
  end

  # The view shown: the one named, else the one that held what waited when the page was opened.
  defp view(%{tab: tab}) when tab != nil, do: tab
  defp view(%{default_view: view}) when view != nil, do: view
  defp view(assigns), do: default_view(assigns)

  defp default_view(%{decision: %{kind: :approval} = decision}), do: approval_view(decision)
  defp default_view(_assigns), do: "steps"

  # A changeset approval is read on Changes, and so is any approval that merges; a document's on
  # Docs.
  defp approval_view(%{merges: true}), do: "changes"

  defp approval_view(%{pins: pins}),
    do: if(Enum.any?(pins, & &1.changeset), do: "changes", else: "docs")

  defp views(assigns) do
    TicketViews.strip(
      assigns.project,
      assigns.ticket,
      %{
        changes: Diff.file_count(assigns.diff),
        docs: length(assigns.docs),
        activity: if(assigns.activity, do: assigns.activity.count, else: 0)
      },
      TicketViews.talk(assigns.step, assigns.chats),
      :patch
    )
  end

  defp subline(assigns) do
    topology =
      if assigns.workflow, do: ForgeWeb.Topology.of(assigns.workflow, assigns.ticket.state)

    [
      "##{assigns.ticket.number} · #{ForgeWeb.Topology.mark(topology)} #{assigns.ticket.state}",
      assigns.ticket.status != :active && to_string(assigns.ticket.status),
      Forge.Tickets.Ticket.held?(assigns.ticket) &&
        if(Forge.Tickets.Ticket.taken_over?(assigns.ticket), do: "taken over", else: "on hold"),
      # No "waiting on you": the decision row says it, in amber, and on a phone it was the part
      # the ellipsis cut (`ui.md` § The ticket).
      assigns.paused && spend_paused(assigns.now)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # The daily cap holds back a job that has not started (`ui.md` § The projects page says it the
  # same way): a ticket with nothing pending is not paused by it, whatever the cap says.
  defp paused?(%{status: :active}, jobs),
    do: Enum.any?(jobs, &(&1.status == :pending)) and Spend.paused?()

  defp paused?(_ticket, _jobs), do: false

  # The daily cap lifts at midnight UTC, so beside it is a countdown, not an age
  # (`docs/design/capacity.md` § Four exhaustions, three treatments): the one thing a person
  # waiting on it can be told, as every countdown is (`Format.until/2`). Under a minute there is
  # none to give, and the line is the ticket list's bare one.
  @doc false
  @spec spend_paused(DateTime.t()) :: String.t()
  def spend_paused(now) do
    {:ok, midnight} = DateTime.new(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")

    case Format.until(midnight, now) do
      "now" -> "paused · spend"
      left -> "paused · spend " <> left
    end
  end

  @impl true
  def render(%{workflow: nil} = assigns) do
    assigns = assign(assigns, subline: subline(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@ticket.title}
      subline={@subline}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      views={
        WorkScreen.views([{"steps", "Steps", nil}], ~p"/tickets/#{@project.name}/#{@ticket.number}")
      }
      view="steps"
      measure={nil}
    >
      <%!-- Not a work screen: no view of it needs a scroller of its own. --%>
      <div id="steps">
        <TicketViews.unreadable {assigns} />
      </div>
      <.look_carried :if={@looked} ticket_id={@ticket_id} since={@since} />
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        view: view(assigns),
        subline: subline(assigns),
        ways: TicketViews.ways(assigns)
      )

    assigns = assign(assigns, fold: TicketViews.fold(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@ticket.title}
      subline={@subline}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      views={views(assigns)}
      view={@view}
      measure={nil}
      fill
      resizable
    >
      <:decision :if={@decision || @release || @decision_error || @ticket.held_at}>
        <TicketViews.release_band :if={@release} ticket={@ticket} release={@release} />
        <TakeoverBand.band
          :if={@takeover}
          ticket={@ticket}
          takeover={@takeover}
          steps={@hand_steps}
          stoppable={@stoppable}
          refusal={@refusal}
          drafts={@drafts}
          me={@current_scope.user.id}
          addresses={Map.merge(@addresses, @taker_addresses)}
          now={@now}
        />
        <TicketViews.hold_band
          :if={@ticket.held_at && !@takeover}
          ticket={@ticket}
          on_release={@on_release}
          stoppable={@stoppable}
          refusal={@refusal}
        />
        <Decision.gone :if={is_nil(@decision) && @decision_error} error={@decision_error} />
        <Decision.row
          :if={@decision}
          decision={@decision}
          open={@decision_open}
          note={@decision_note}
          pick={@decision_pick}
          error={@decision_error}
        />
      </:decision>
      <:details>
        <TicketViews.details {assigns} />
      </:details>
      <:composer :if={TicketViews.dock?(assigns)}>
        <TicketViews.dock {assigns} />
      </:composer>
      <:aside :if={TicketViews.aside?(assigns)}>
        <TicketViews.aside {assigns} />
      </:aside>

      <%!-- A link to the page a human state asks to be opened, at the head of every view and
            never a decision (`docs/design/ui.md` § The ticket). A page opens on a screen of its
            own, so it is a full page load. --%>
      <div :if={@opens} id="open-page" class="work-open-page">
        <.button
          :if={@opens.href}
          id="open-page-link"
          variant="outline"
          chevron
          href={@opens.href}
        >
          Open {@opens.name}
        </.button>
        <.button :if={!@opens.href} id="open-page-link" variant="outline" disabled>
          Open {@opens.name} · no version yet
        </.button>
      </div>

      <WorkScreen.body :if={@view == "steps"} id="steps">
        <TicketViews.steps {assigns} />
      </WorkScreen.body>

      <WorkScreen.body :if={@view == "changes"} id="changes">
        <Changes.view {assigns} />
      </WorkScreen.body>

      <WorkScreen.body :if={@view == "docs"} id="docs">
        <WorkScreen.docs
          docs={@docs}
          now={@now}
          refusal={@refusal}
          empty="A document an agent writes appears here when its job declares it."
        />
      </WorkScreen.body>

      <WorkScreen.body :if={@view == "activity"} id="activity">
        <TicketViews.activity {assigns} />
      </WorkScreen.body>
      <.look_carried :if={@looked} ticket_id={@ticket_id} since={@since} />
    </Layouts.app>
    """
  end

  attr :ticket_id, :string, required: true
  attr :since, :any, required: true

  # The look this visit was opened with, for the socket to send back when it rejoins (`look/2`).
  # Drawn only by a connected render, so a dead render's DOM carries none.
  defp look_carried(assigns) do
    ~H"""
    <div
      id="ticket-look"
      hidden
      data-ticket={@ticket_id}
      data-since={@since && DateTime.to_iso8601(@since)}
    />
    """
  end
end
