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
  alias ForgeWeb.Operator.{Actions, Decision, Drafts, QuestionForm}

  @views ~w(steps changes docs activity)

  # How much of a failed command's log Steps shows: the end, where a build says why it stopped.
  # The whole log is one tap away on the command's page.
  @tail_bytes 4096

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
       forms: QuestionForm.init(),
       drafts: Drafts.init(),
       refusal: nil
     )
     |> Decision.init()
     |> Changes.init()
     |> JobStream.init()
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
     |> load_changes()}
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
      events: ticket.id |> Events.for_ticket() |> Enum.reverse() |> Enum.take(10),
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
    step = step_view(ticket)

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
      steps: steps(work, artifacts, ticket, workflow),
      waits: waits(work),
      # Why the last batch sent the ticket where it is, under the commands that failed in it.
      tails: Forge.Jobs.Commands.failure_tails(ticket.id, @tail_bytes),
      artifacts: artifacts,
      diff: diff,
      commits: commits(project, ticket),
      events: ticket_events(ticket),
      queue_events: queue_events(ticket),
      activity: if(current, do: Events.for_job(current.id), else: []),
      transitions: Engine.offered_transitions(ticket, workflow),
      retry: Engine.retryable?(ticket),
      # Where the ticket stands in its project's merge queue, or nil (`ui.md` § Steps).
      queue: Forge.MergeQueue.places(project.id)[ticket.id],
      stuck_reason: Engine.why_stuck(ticket),
      drift: Tickets.drift(ticket, project),
      conflict: Forge.Merge.Watch.notice(ticket),
      human_state:
        ticket.status in Forge.Tickets.Ticket.open_statuses() and
          Workflow.State.human?(Workflow.state(workflow, ticket.state)),
      writable: writable(ticket, workflow),
      proposals: Proposals.open_for_ticket(ticket.id),
      changeset: Artifacts.latest(ticket.id, Workflow.changeset_artifact()),
      release: release(ticket),
      paused: paused?(ticket, jobs),
      now: DateTime.utc_now()
    )
    |> assign_decision()
    |> assign_docs(artifacts, jobs)
    |> load_chats()
    |> load_changes()
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
    assign(socket, docs: docs(project, ticket, art, waiting(assigns.decision), jobs))
  end

  defp waiting(%{kind: :approval, pins: pins}), do: for(p <- pins, not p.changeset, do: p.name)

  defp waiting(%{kind: :step, step: step}),
    do: for(d <- step.documents, d.version != nil, do: d.name)

  defp waiting(_none), do: []

  # What the conversation's last reply asked and nobody has answered: they stay unanswered if the
  # step is accepted now, and Accept's panel says so. Read only when there is a row to say it in.
  defp step_questions(step) do
    if ForgeWeb.Components.StepAccept.row?(step) do
      step.chat.id |> Conversations.messages() |> List.last() |> Conversations.questions()
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
  defp queue_events(ticket) do
    events = Events.for_ticket(ticket.id)

    if Enum.any?(events, &queue_event?/1),
      do: Enum.filter(events, &(queue_event?(&1) or &1.type == "ticket.merged")),
      else: []
  end

  defp queue_event?(%{type: type}), do: String.starts_with?(type, "merge_queue.")

  # The ticket's own events that say something its jobs do not — a decision and its note, a
  # transition, why it stuck — newest first, for Activity (`ui.md` § Activity).
  defp ticket_events(ticket) do
    ticket.id
    |> Events.for_ticket()
    |> Enum.filter(&(&1.type in TicketViews.said_types()))
    |> Enum.reverse()
    |> Enum.take(12)
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
    |> Events.for_ticket()
    |> Enum.filter(&(&1.type == "step.accepted"))
    |> Map.new(&{&1.job_id, &1.payload})
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

  # Every artifact the ticket has, a row each — a document's rendered when opened — its latest
  # version first and the earlier ones linked, grouped by what it asks of the person. The
  # changeset is not one: it is Changes.
  defp docs(project, ticket, artifacts, waiting, jobs) do
    for %{artifact: artifact, latest: latest} = entry <- artifacts, TicketViews.doc?(entry) do
      href = fn version ->
        ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version}"
      end

      doc =
        WorkScreen.doc(
          artifact,
          Artifacts.versions(ticket.id, artifact.name),
          href,
          entry.approvable,
          Forge.References.ticket_scope(project.name, ticket)
        )

      doc
      |> Map.put(:group, group(doc, latest, waiting))
      |> Map.put(:by, TicketViews.written_by(latest.author, jobs))
    end
  end

  # Waiting: what the decision on screen waits on. Built from: what a person approved or wrote.
  # Produced: the rest, what the ticket's jobs wrote.
  defp group(doc, latest, waiting) do
    cond do
      doc.name in waiting -> :waiting
      doc.approved or match?(%{"kind" => "user"}, latest.author) -> :built_from
      true -> :produced
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
          cost: Enum.reduce(group, 0, &(&2 + &1.usage))
        }
      end)

    if Enum.any?(visits, &(&1.name == ticket.state)) do
      visits
    else
      visits ++ [%{name: ticket.state, jobs: [], artifacts: [], cost: 0}]
    end
    |> Enum.map(&Map.put(&1, :topology, ForgeWeb.Topology.of(workflow, &1.name)))
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
  def handle_info({:job_event, id, event}, %{assigns: %{following: id}} = socket) do
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

  def handle_event("more", params, socket), do: JobStream.handle_event("more", params, socket)

  def handle_event("notices", params, socket),
    do: JobStream.handle_event("notices", params, socket)

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
    do: {:noreply, assign(socket, forward: params["way"])}

  # The dock button: the way picked, taken by the operation that takes it anywhere — a transition
  # or running the state again, each guarded in `Forge.Operator`.
  def handle_event("forward", params, socket) do
    case forward(params["way"], socket.assigns.ticket) do
      {event, params} -> handle_event(event, params, assign(socket, forward: nil))
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

  defp forward("again", ticket), do: {"retry", %{"ticket" => ticket.id}}
  defp forward("to:" <> to, ticket), do: {"transition", %{"ticket" => ticket.id, "to" => to}}
  defp forward(_nothing, _ticket), do: nil

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
        activity: WorkScreen.activity_count(assigns.activity)
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
      measure="46rem"
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
      measure={if @view == "changes", do: nil, else: "46rem"}
      fill
    >
      <:decision :if={@decision || @release || @decision_error}>
        <TicketViews.release_band :if={@release} ticket={@ticket} release={@release} />
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
