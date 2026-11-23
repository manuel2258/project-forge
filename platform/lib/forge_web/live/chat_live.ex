defmodule ForgeWeb.ChatLive do
  @moduledoc """
  One conversation (`docs/design/ui.md` § A chat, § Talk): Talk, Changes, Docs and Activity, a
  dock that never leaves the viewport, and its details dropped from the title. On a wide screen
  the branch and its merge are the right column (`15f`). **A workflow step's conversation draws
  its ticket's frame** (§ The Accept area): the ticket's title, the step's Accept as its decision
  row, and the ticket's strip, with Talk this conversation and the other views the ticket's.
  The drawing is `ForgeWeb.ChatViews`.

  **The reply streams, and so does what the agent does.** This is the case `ui.md` § Motion and
  structure allows: the operator is looking at this one piece of work. It is subscribed per job,
  so a page open on one conversation is not woken by every event on the node, and a harness
  event is appended to the events the page already holds and the transcript folded again from
  them — rather than every event reading the log, the diff and the documents again, several times a
  sentence. **What the page holds is ten turns** and the one in progress, and older turns are read
  when the reader reaches the top (`Forge.Conversations.talk/3`); what the page draws about the
  whole conversation — its plan, the open question's card, the now line, the heading — comes from
  queries of their own and not from the turns held (`docs/design/ui.md` § Talk).
  """

  use ForgeWeb, :live_view

  alias Forge.{
    Artifacts,
    Attachments,
    Conversations,
    Events,
    Git,
    Jobs,
    Merge,
    Operator,
    Projects,
    Tickets
  }

  alias Forge.Git.Url
  alias ForgeWeb.{ChatViews, Diff, JobStream, TicketViews, Transcript, WorkScreen}
  alias ForgeWeb.Components.StepAccept
  alias ForgeWeb.Operator.Decision

  @tabs ~w(talk changes docs activity)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    chat = Conversations.get!(id)
    %{project: project, ticket: ticket} = Conversations.context(chat)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    if connected?(socket) do
      Events.subscribe_job(chat.id)
      Events.subscribe()
    end

    {:ok,
     socket
     |> assign(
       chat_id: chat.id,
       project: project,
       ticket: ticket,
       draft: "",
       chat_error: nil,
       refusal: nil,
       tab: "talk",
       page_title: title(project, ticket),
       forms: ForgeWeb.Operator.QuestionForm.init()
     )
     |> Decision.init()
     |> assign(activity: JobStream.new(chat.id), reach: reach(socket))
     |> ForgeWeb.Capacity.project(project)
     |> open_talk()
     |> load()
     |> load_activity()}
  end

  defp title(project, nil), do: "Chat · #{project.name}"
  defp title(project, ticket), do: "Chat · #{project.name}##{ticket.number}"

  # `ask` is a reference sent from a ticket's Changes tab, which has no composer of its own: it
  # lands in the draft, and nothing is sent until the person sends it (`ui.md` § Changes).
  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "talk"

    socket =
      case params["ask"] do
        ref when is_binary(ref) and ref != "" -> assign(socket, draft: with_ref(socket, ref))
        _none -> socket
      end

    # Moving to another view folds the decision's panel: its *two ways out* link leads to
    # Changes, where they are drawn, and the panel would otherwise stay open over them.
    socket =
      if tab != socket.assigns.tab, do: assign(socket, decision_open: false), else: socket

    {:noreply, socket |> assign(tab: tab) |> load_activity()}
  end

  # Talk is read on mount: its newest ten turns and the open one, or — for a socket rejoining —
  # back as far as it had been read, in one query bounded by it (`docs/design/ui.md` § A reconnect
  # is not a reload). A position is the page's own conversation's or nothing.
  defp open_talk(%{assigns: %{chat_id: id}} = socket) do
    request =
      case JobStream.reach(socket.assigns.reach["talk"], id) do
        nil -> :latest
        position -> {:since, position}
      end

    assign(socket, talk: Conversations.talk(id, request))
  end

  defp reach(socket) do
    with true <- connected?(socket),
         %{"reach" => %{} = reach} <- get_connect_params(socket) do
      reach
    else
      _none -> %{}
    end
  end

  # What Activity shows is read only while it is the view on screen, as Changes is: the stream is
  # counted on every load (the tab says how many) and opened — or read back as far as a rejoining
  # socket had it — when the tab is first shown.
  defp load_activity(%{assigns: %{activity: stream, tab: "activity"}} = socket) do
    if JobStream.open?(stream) do
      socket
    else
      case JobStream.reach(socket.assigns.reach["activity"], stream.job_id) do
        nil -> assign(socket, activity: JobStream.open(stream))
        position -> assign(socket, activity: JobStream.rejoin(stream, position))
      end
    end
  end

  defp load_activity(socket), do: socket

  defp load(%{assigns: %{chat_id: id, project: project, ticket: ticket}} = socket) do
    chat = Conversations.get!(id)
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)
    step = step_view(chat, ticket)

    socket
    |> assign(
      chat: chat,
      docs: docs(chat, project, ticket) ++ attached_docs(socket, chat, project, ticket),
      # What the box is drawn with (the pool's room), and what came with each message, read again
      # whenever the page loads: a file withdrawn since is *withdrawn* where its link was.
      attach_room: Attachments.room(Conversations.pool(chat)),
      attach_path: attach_path(chat, project, ticket),
      attached_ids: nil,
      unrecorded: Conversations.unrecorded(id),
      diff: chat_diff(project, chat),
      commits: commits(project, chat),
      branch_exists: Git.branch_exists?(repo, branch),
      # What a merge of this branch would say, from the definition the merge itself reads
      # (`Forge.Merge.commit_message/1`).
      commit_message: Merge.commit_message(chat),
      # Whether a message may be sent now — the one check `Conversations.send/3` asks, so the
      # composer is drawn exactly when a send would be taken — and whether a person ended it for
      # good, with how. Read once a load: each is a query, and `render/1` runs on every block
      # (`lost` in `render/1` is in memory: `Conversations.lost?/2` asks nothing).
      sendable: Conversations.sendable?(chat),
      ending: Conversations.ending(chat),
      merged: Merge.merged_chat?(chat),
      waiting: Jobs.current_wait(chat),
      step: step,
      # The column beside a step: the ticket's own latest version, as its page draws it, so the
      # two pages agree (`StepAccept.aside_doc_name/1`). Built here, not in `render/1`, which runs
      # on every streamed block.
      step_doc: step_doc(project, ticket, step),
      # The mark of the state the step's ticket is in, for the subline the ticket's own page
      # draws: read once a load, since it parses the pinned workflow.
      step_mark: if(Jobs.Job.step?(chat) and ticket, do: mark(ticket)),
      # The machine it holds, for its details: every member sees its shape, its owner a link.
      machine: Conversations.machine(chat),
      # Its model and effort, for its details: read here, since each is a query when the
      # conversation names none and the details are drawn on every render.
      model: Jobs.model_for(chat),
      effort: Jobs.effort_for(chat)
    )
    |> reload_streams()
    |> assign_strip()
    |> fold()
    |> assign_decision()
  end

  # A reload reads what arrived above what each stream holds, rather than the stream again: the
  # turns' events above the newest held, the turn in progress, and the figures counted. A sweep of
  # the conversation's rows heard in what arrived reads the newest turns afresh, the rows held
  # being gone.
  defp reload_streams(%{assigns: %{chat_id: id, talk: talk}} = socket) do
    newest = talk.events |> List.last() |> then(&((&1 && &1.seq) || talk.from))
    fresh = Conversations.talk_after(id, newest)

    talk =
      if Enum.any?(fresh, &(&1.type == "job.swept")),
        do: Conversations.talk(id, :latest),
        else: %{talk | events: talk.events ++ fresh}

    assign(socket,
      talk: talk,
      open_turn: Conversations.open_turn(id),
      activity: JobStream.reload(socket.assigns.activity),
      plan: plan(id),
      memory: Forge.Jobs.Memory.trouble(id),
      last_said: Conversations.last_said(id),
      released_by_update: released_by_update?(id),
      secrets_gone: secrets_gone(id),
      # What the page is titled by, from the conversation's first message wherever it is: the turns
      # held may not reach it.
      first_said: first_said(id),
      transcripts: WorkScreen.transcript_links(socket.assigns.chat, socket.assigns.project, nil)
    )
  end

  # What the conversation was opened with, from its first message wherever it is — its words, or
  # the first file's name when it came with files alone (`Conversations.opening_words/1`).
  defp first_said(id), do: Conversations.opening_words([id])[id]

  # The agent's plan band: its latest top-level `TodoWrite` in the whole conversation, read by a
  # query of its own and not taken from the turns held.
  defp plan(id) do
    case Forge.Events.Stream.latest_todo(id, true) do
      nil ->
        []

      event ->
        event.payload |> Conversations.action(event.inserted_at) |> ForgeWeb.Actions.todos()
    end
  end

  # The one decision row a conversation has (`docs/design/ui.md` § The decision row): a step's
  # Accept, or else merging its branch, which nobody is waiting on.
  defp assign_decision(%{assigns: assigns} = socket) do
    decision =
      Decision.step(assigns.step, Conversations.questions(assigns.last_said)) ||
        Decision.merge(assigns, assigns.chat)

    Decision.put(socket, decision)
  end

  defp step_view(chat, %Forge.Tickets.Ticket{} = ticket),
    do: if(Jobs.Job.step?(chat), do: Forge.Steps.view(ticket, chat))

  defp step_view(_chat, nil), do: nil

  defp step_doc(project, ticket, step) do
    with true <- StepAccept.row?(step),
         name when is_binary(name) <- StepAccept.aside_doc_name(step),
         %{} = artifact <- Artifacts.find(ticket.id, name) do
      doc =
        WorkScreen.doc(
          artifact,
          Artifacts.versions(ticket.id, name),
          &~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{name}/#{&1}",
          false,
          Forge.References.ticket_scope(project.name, ticket)
        )

      if doc.latest.body, do: doc
    else
      _none -> nil
    end
  end

  # The projection, from the turns the page holds. The fold is pure; what the transcript's references
  # mean is not, and costs no query when the messages hold none (`Transcript.resolve/3`) and a
  # few — not one per message — when they do.
  defp fold(%{assigns: %{talk: %{events: events}, open_turn: open_turn}} = socket) do
    messages = Conversations.transcript(events)
    {attached, attached_ids} = attached(socket, messages)

    assign(socket,
      messages: messages,
      attached: attached,
      attached_ids: attached_ids,
      now: Conversations.now(open_turn),
      refs:
        Transcript.resolve(messages, transcript_scope(socket.assigns), socket.assigns.chat_id),
      at: DateTime.utc_now()
    )
  end

  # What came with each of the person's messages, by the message's id. Read when the person's
  # messages are not the ones last read — a streamed block adds none — and forced by `load/1`.
  defp attached(socket, messages) do
    ids = for %{role: :user, id: id} <- messages, do: String.to_integer(id)

    if ids == socket.assigns.attached_ids do
      {socket.assigns.attached, ids}
    else
      {Attachments.entries_for_events(ids), ids}
    end
  end

  # Where a file's version is served: the ticket's address for a ticket's pool, the conversation's
  # own for a project chat's.
  defp attach_path(_chat, project, %Tickets.Ticket{} = ticket),
    do: &~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{&1.name}/#{&1.version}"

  defp attach_path(chat, _project, nil),
    do: &~p"/chats/#{chat.id}/artifacts/#{&1.name}/#{&1.version}"

  # What its latest run could not hold because it was deleted since the conversation was opened
  # (`docs/design/secrets.md` § Conversations): said on the page, rather than left for the agent
  # to find its variable missing halfway through a turn. The newest `job.secrets` is asked for by
  # itself: it may be on a turn the page does not hold.
  defp secrets_gone(id) do
    case Events.latest_for_job(id, "job.secrets") do
      nil -> []
      %{payload: run} -> run["gone"]
    end
  end

  # Against the default branch, which is where a merge would put it — the question the review
  # page asks about a ticket, read the same way (`ForgeWeb.Diff`).
  defp chat_diff(project, chat) do
    repo = Projects.repo_path(project)

    with {:ok, head} <- Git.resolve(repo, "refs/heads/" <> project.default_branch),
         {:ok, source} <- Git.resolve(repo, "refs/heads/" <> Jobs.chat_branch(chat)) do
      Diff.build(repo, head, source)
    else
      _gone -> nil
    end
  end

  defp commits(project, chat),
    do:
      Diff.commits(
        Projects.repo_path(project),
        "refs/heads/" <> project.default_branch,
        "refs/heads/" <> Jobs.chat_branch(chat)
      )

  defp mark(ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> ForgeWeb.Topology.mark(ForgeWeb.Topology.of(workflow, ticket.state))
      {:error, _errors} -> ForgeWeb.Topology.mark(:unknown)
    end
  end

  defp approvable(nil), do: MapSet.new()

  # A pin the grammar can no longer build approves nothing: the chat still opens, and its
  # documents carry no mark.
  defp approvable(ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Artifacts.approvable(workflow)
      {:error, _errors} -> MapSet.new()
    end
  end

  # Every version it wrote, whichever scope it is in — a ticket chat's documents are the
  # ticket's — grouped by document, the latest rendered and the rest linked
  # (`docs/design/ui.md` § Docs). Approval is possible only for a ticket's document that the
  # ticket's workflow approves, so only those carry a mark.
  # A project chat's files are its own, and the chat's Docs is where they are listed, with who
  # attached them and a way to withdraw them (`docs/design/ui.md` § Attaching files). A ticket
  # chat's are the ticket's, on its page.
  defp attached_docs(socket, chat, project, nil) do
    scope = Forge.Accounts.Scope.for_project(socket.assigns.current_scope, project)
    user = socket.assigns.current_scope.user

    for {artifact, versions} <- Attachments.artifacts({:job, chat.id}) do
      artifact
      |> WorkScreen.doc(
        versions,
        &version_href(chat, project, nil, artifact, &1),
        false,
        doc_scope(chat, project, nil, artifact)
      )
      |> WorkScreen.mark_attached(versions, scope, user)
    end
  end

  defp attached_docs(_socket, _chat, _project, _ticket), do: []

  defp docs(chat, project, ticket) do
    approvable = approvable(ticket)

    chat.id
    |> Artifacts.written_by()
    |> Enum.chunk_by(fn {artifact, _version} -> artifact.id end)
    |> Enum.map(fn [{artifact, _} | _] = written ->
      WorkScreen.doc(
        artifact,
        Enum.map(written, &elem(&1, 1)),
        &version_href(chat, project, ticket, artifact, &1),
        is_nil(artifact.job_id) and artifact.kind != :presentation and
          MapSet.member?(approvable, artifact.name),
        doc_scope(chat, project, ticket, artifact)
      )
    end)
  end

  # Per job, so the filtering is the subscription rather than a check — CLAUDE.md's rule about a
  # handler on a global topic. What the harness streams is added to the log the page holds and
  # folded again (`ForgeWeb.JobStream`), and after a call's result the branch is read again
  # shortly, since that is how a commit arrives; anything else on this job's topic — a turn
  # ending, a wait, a message — changes more than the transcript, and reloads.
  @impl true
  def handle_info({:job_event, id, event}, %{assigns: %{chat_id: id}} = socket) do
    if JobStream.streamed?(event) do
      {:noreply, socket |> add(event) |> fold() |> JobStream.catch_up(event)}
    else
      {:noreply, load(socket)}
    end
  end

  def handle_info({:job_event, _id, _event}, socket), do: {:noreply, socket}

  # The global topic, filtered before any work, as `CLAUDE.md` § Rules asks of a handler on one:
  # every ticket change on the node arrives here, and each reload is a handful of queries. What
  # this page needs from it is its own conversation's changes of status — started, stopped,
  # reopened — which `Forge.Jobs` and `Forge.Conversations` announce under the job's ticket and
  # not on the job's own topic. So only that ticket: a ticket chat's, or `nil` for a project chat,
  # which is also what every other project chat's changes are announced under. That residue is
  # the cost of the status paths not notifying per job.
  def handle_info({:ticket_changed, id}, %{assigns: %{chat: %{ticket_id: id}}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  # What the branch holds, read again after a call that may have committed to it — without the
  # rest of a reload, which would also take away a merge's conflict sentence mid-turn.
  def handle_info(:catch_up, %{assigns: %{project: project, chat: chat}} = socket) do
    {:noreply,
     assign(socket,
       diff: chat_diff(project, chat),
       commits: commits(project, chat),
       catching_up: false
     )}
  end

  # What a streamed event is added to: the turns held (by its place, an event held already skipped),
  # the turn in progress, and the Activity stream and its figures — and what it changes beyond them,
  # which is read by the query that reads it.
  defp add(socket, event) do
    socket
    |> add_to(:talk, event, Conversations.fold_types())
    |> add_to(:open_turn, event, Conversations.open_types())
    |> add_to_activity(event)
    |> touch(event)
  end

  defp add_to(socket, :talk, %{type: type} = event, types) do
    talk = socket.assigns.talk
    held? = Enum.any?(talk.events, &(&1.seq == event.seq))

    if type in types and not held?,
      do: assign(socket, talk: %{talk | events: sorted([event | talk.events])}),
      else: socket
  end

  defp add_to(socket, :open_turn, %{type: type} = event, types) do
    held = socket.assigns.open_turn

    if type in types and not Enum.any?(held, &(&1.seq == event.seq)),
      do: assign(socket, open_turn: sorted([event | held])),
      else: socket
  end

  defp add_to_activity(socket, event) do
    case JobStream.add(socket.assigns.activity, event) do
      :seen -> socket
      {:ok, stream} -> assign(socket, activity: stream)
    end
  end

  # The oldest event the turns held start at: a rejoin reads back from the turn that holds it.
  defp talk_reach(%{events: [oldest | _rest]}, id), do: "#{id}:#{oldest.seq}"
  defp talk_reach(_talk, _id), do: nil

  defp sorted(events), do: Enum.sort_by(events, & &1.seq)

  defp touch(socket, %{type: "job.harness.memory"}),
    do: assign(socket, memory: Forge.Jobs.Memory.trouble(socket.assigns.chat_id))

  defp touch(socket, %{type: "job.harness.tool_use", payload: %{"name" => "TodoWrite"} = payload}) do
    if is_nil(payload["parent_tool_use_id"]),
      do: assign(socket, plan: plan(socket.assigns.chat_id)),
      else: socket
  end

  defp touch(socket, _event), do: socket

  @impl true
  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("decision:" <> _ = event, params, socket),
    do: Decision.handle_event(event, params, socket, &load/1)

  # Three intentions, because guessing between them from one gesture is how a chat client loses
  # a message (`docs/design/conversations.md` § Turns). Send holds the message until the turn
  # ends, whatever it carries and whatever the agent is doing; the queued message's own button
  # interrupts so that it is taken now; stop ends the turn and sends nothing.
  def handle_event("send", %{"text" => text} = params, socket),
    do: say(socket, text, ForgeWeb.Attaching.opts(params))

  # The button on the oldest queued message. The message id is the wire's and is parsed by the
  # context, which acts only on a message of this conversation that is still queued; a refusal
  # means the agent took it first (or another device did), so the page is read again and the
  # button is gone with the *queued*.
  def handle_event("interrupt", %{"id" => id}, socket) when is_binary(id) do
    case Operator.interrupt_chat(socket.assigns.chat, socket.assigns.current_scope.user, id) do
      :ok -> {:noreply, socket}
      {:error, _not_queued} -> {:noreply, load(socket)}
    end
  end

  # An id that is not text is a crafted event, and no button's: ignored rather than crashing the view.
  def handle_event("interrupt", _params, socket), do: {:noreply, socket}

  def handle_event("attachments:withdraw", params, socket),
    do:
      {:noreply,
       socket
       |> ForgeWeb.Attaching.withdraw(Conversations.pool(socket.assigns.chat), params)
       |> load()}

  def handle_event("stop", _params, socket) do
    :ok = Operator.stop_chat(socket.assigns.chat, socket.assigns.current_scope.user)
    {:noreply, socket}
  end

  # The page offers End only on an ordinary conversation that has not been ended, and the context
  # refuses a step's and an ended one, so a page drawn before that rule or a crafted event is told
  # rather than crashing the view.
  def handle_event("close", _params, socket) do
    case Operator.close_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      :ok ->
        {:noreply, assign(socket, chat_error: nil)}

      {:error, :step} ->
        {:noreply, socket |> assign(chat_error: {:details, refusal(:step)}) |> load()}

      {:error, :ended} ->
        {:noreply, socket |> assign(chat_error: {:details, refusal(:close_ended)}) |> load()}
    end
  end

  # Answering the reply's questions is sending every answer as one message, so the agent sees them
  # exactly where it expects to. Nothing is written to `answers`: the transcript is already the
  # record, and a second one would be a second truth (§ Asking a question). Until Send, what is
  # locked in is the page's draft (`ForgeWeb.Operator.QuestionForm`).
  def handle_event("form:change", params, socket),
    do: question_form("form:change", params, socket)

  def handle_event("form:open", params, socket), do: question_form("form:open", params, socket)

  def handle_event("chat:questions:send", params, socket),
    do: question_form("chat:questions:send", params, socket)

  # *Ask about this* on the Changes tab: the reference goes into the draft, beside anything
  # already typed, and the page moves to where the draft is. Nothing is sent.
  def handle_event("ask", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> assign(draft: with_ref(socket, ref))
     |> push_patch(to: ~p"/chats/#{socket.assigns.chat_id}?tab=talk")}
  end

  # *Ask it to rebase*, the first of a conflict's two ways out (`15c`): the request goes into the
  # draft, where it can still be edited, and nothing is sent. The paths are read again here
  # rather than taken off the wire: what is asked is what the branch conflicts in now.
  def handle_event("rebase:ask", _params, socket) do
    case socket.assigns.decision do
      %{kind: :merge, conflict: [_ | _] = paths} ->
        request = ChatViews.rebase_request(socket.assigns.project.default_branch, paths)
        {:noreply, assign(socket, draft: request)}

      _clean ->
        {:noreply, socket}
    end
  end

  # Activity's next older page, and the notices behind their count.
  def handle_event("more", _params, socket),
    do: {:noreply, assign(socket, activity: JobStream.older(socket.assigns.activity))}

  def handle_event("notices", _params, %{assigns: %{activity: stream}} = socket) do
    drawn = stream |> JobStream.held() |> WorkScreen.entries(stream.notices) |> length()
    {:noreply, assign(socket, activity: JobStream.toggle_notices(stream, drawn))}
  end

  # Talk's next ten older turns, read from the turn the page starts after (never a position the
  # request names), joined to what is held, and the transcript folded again.
  def handle_event("talk:more", _params, %{assigns: %{talk: %{more: false}}} = socket),
    do: {:noreply, socket}

  def handle_event("talk:more", _params, %{assigns: %{talk: talk, chat_id: id}} = socket) do
    older = Conversations.talk(id, {:older, talk.from})
    talk = %{talk | events: older.events ++ talk.events, from: older.from, more: older.more}
    {:noreply, socket |> assign(talk: talk) |> fold()}
  end

  defp question_form(event, params, socket) do
    case ForgeWeb.Operator.QuestionForm.handle(event, params, socket) do
      {:state, socket} -> {:noreply, socket}
      {:handled, socket} -> {:noreply, load(socket)}
      :unknown -> {:noreply, socket}
    end
  end

  defp with_ref(socket, ref) do
    case String.trim_trailing(socket.assigns.draft) do
      "" -> ref <> " "
      typed -> typed <> "\n" <> ref <> " "
    end
  end

  # Words or files: the context refuses a message of neither (`Conversations.send/3`).
  defp say(socket, text, opts), do: deliver(socket, String.trim(text || ""), opts)

  # It can have ended, or its step can be over, between the render and the tap. Reloading is what
  # takes the send box away, so the page stops offering what it cannot do rather than only saying
  # so. The question form's Send takes the same road through `Operator.answer_chat/4` and is
  # reloaded the same way. A conversation that holds no machine is started again by the send
  # itself, which is the page's concern only in what it then says: it waits for a machine.
  defp deliver(socket, text, opts) do
    case Operator.send_chat(socket.assigns.chat, socket.assigns.current_scope.user, text, opts) do
      {:ok, _event} ->
        {:noreply,
         socket |> assign(draft: "", chat_error: nil) |> ForgeWeb.Attaching.sent() |> load()}

      {:error, reason} when reason in [:ended, :step_over] ->
        {:noreply, socket |> assign(chat_error: {:dock, refusal(reason)}) |> load()}

      # Nothing typed and nothing that finished: nothing was sent, the agent is not woken. Files
      # that all failed are named as *not sent* under the box, which is the box's to say, so it is
      # told the act is over; with nothing attached it ignores it.
      {:error, :empty} ->
        {:noreply, ForgeWeb.Attaching.sent(socket)}

      # Remaking a deleted branch is a git write, and it can fail — a ticket branch that is gone
      # too. Said, rather than a crash that reads as the page breaking.
      {:error, reason} ->
        {:noreply, assign(socket, chat_error: {:dock, "Could not send: #{inspect(reason)}"})}
    end
  end

  # Refusals in words, for the page and for an event nobody drew a button for.
  defp refusal(:ended), do: "This conversation was ended. Start a new one to say that."
  defp refusal(:step_over), do: "This step is over, so nothing more can be said in it."
  defp refusal(:step), do: "A step's conversation cannot be ended: it ends with its step."
  defp refusal(:close_ended), do: "This conversation was already ended."

  # The queue asks the same thing of the same reply, so the asking lives in `Conversations`. What
  # was *said* (`Conversations.said/1`), because that is the reading `Operator.answer_chat/4`
  # checks the form's reply against: a turn that only acted is not the reply being answered.
  # **From `Conversations.last_said/1`, read on a load** (a message sent and a turn's end both
  # reload the page) and not from the turns held, which may hold nothing said at all. A streamed
  # block does not read it, so a reply still being spoken draws its card when the page loads, and its
  # turn's end reloads the page — which is when the queue offers it.
  defp questions(last_said), do: Conversations.questions(last_said)

  defp reply(last_said), do: Conversations.reply_ref(List.wrap(last_said))

  # Waiting on *you*: the agent finished a turn and said something — the queue's reading, from
  # the same messages and the same rule (`Conversations.waiting?/1`). A reply still being spoken
  # is not waiting on anyone, and neither is a turn that only acted.
  # Whether it holds a machine does not matter: one released by the idle timeout is waiting on you
  # the same (`subline/1` leaves out one a person ended).
  defp waiting?(last_said), do: last_said |> List.wrap() |> Conversations.waiting?()

  # The agent has the ball: either it has not started this turn's reply, or it is still in it —
  # an assistant turn no `chat.turn` has closed.
  #
  # **Taken, not sent**: a message still queued is not the agent having the ball
  # (`Conversations.turn_open?/1`).
  defp responding?(%{status: status}, messages),
    do: status == :running and Conversations.turn_open?(messages)

  # One definition, in the context that enforces it: a page that thought a conversation was live
  # while `Conversations.send/3` disagreed would offer a send box that refuses.
  defp live?(chat), do: Conversations.live?(chat)

  @impl true
  def render(assigns) do
    messages = assigns.messages

    last_said = assigns.last_said

    assigns =
      assign(assigns,
        questions: questions(last_said),
        reply: reply(last_said),
        responding: responding?(assigns.chat, messages),
        live: live?(assigns.chat),
        can_end: not Jobs.Job.step?(assigns.chat) and is_nil(assigns.ending),
        lost: assigns.sendable and Conversations.lost?(assigns.chat, List.wrap(last_said)),
        title: page_heading(assigns),
        viewer: assigns.current_scope.user,
        fetch: fetch_command(assigns.project, assigns.chat),
        conflict: conflict(assigns.decision),
        merge: merge(assigns.decision)
      )

    assigns =
      assign(assigns,
        subline: subline(assigns),
        tab: if(assigns.step, do: "talk", else: assigns.tab)
      )

    ~H"""
    <Layouts.app
      section="Chats"
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@title}
      subline={@subline}
      context={context(@project, @ticket, @step)}
      views={views(assigns)}
      view={@tab}
      measure={nil}
      fill
      resizable
    >
      <:decision :if={@decision || @decision_error}>
        <Decision.gone :if={is_nil(@decision)} error={@decision_error} />
        <Decision.row
          :if={@decision}
          decision={@decision}
          open={@decision_open}
          note={@decision_note}
          pick={@decision_pick}
          error={@decision_error}
          tab={@tab}
        />
      </:decision>
      <:details>
        <ChatViews.details {assigns} now={@at} />
      </:details>

      <:composer :if={@tab in ["talk", "changes"]}>
        <ChatViews.dock {assigns} />
      </:composer>

      <:aside :if={is_nil(@step)}>
        <ChatViews.aside {assigns} error={@decision_error} />
      </:aside>
      <:aside :if={@step_doc}>
        <ChatViews.step_aside doc={@step_doc} />
      </:aside>

      <ChatViews.talk :if={@tab == "talk"} {assigns} />
      <span
        id="stream-reach"
        hidden
        data-talk={talk_reach(@talk, @chat_id)}
        data-activity={JobStream.reach_of(@activity)}
      ></span>

      <WorkScreen.body :if={@tab == "changes"} id="changes">
        <ChatViews.changes {assigns} />
      </WorkScreen.body>

      <WorkScreen.body :if={@tab == "docs"} id="docs">
        <WorkScreen.docs docs={@docs} unrecorded={@unrecorded} refusal={@refusal} />
      </WorkScreen.body>

      <WorkScreen.body :if={@tab == "activity"} id="activity">
        <WorkScreen.activity
          stream={@activity}
          heading={WorkScreen.stream_heading(@chat, @activity.count)}
          hrefs={WorkScreen.version_hrefs(@docs)}
          transcripts={@transcripts}
        />
      </WorkScreen.body>
    </Layouts.app>
    """
  end

  # A step's conversation is its ticket's work, and its page the ticket's frame: titled by the
  # ticket. Any other is called what the person opened it with (`Conversations.title/3`).
  defp page_heading(%{chat: chat, ticket: ticket, step: step, first_said: first}),
    do: Conversations.title(chat, step && ticket, first)

  # Under the title: a step's ticket, its state and visit, as the ticket's own page says it; a
  # conversation's own state otherwise — responding and on which turn, waiting on you, idle,
  # waiting for a machine, or ended.
  # The ticket's own subline — its number, the state's mark and name, and its status when it is
  # not active — and the step's visit after it: built from less, it dropped the mark the ticket's
  # page draws for the same ticket (UX pass, B28).
  defp subline(%{step: %{} = step, ticket: ticket} = assigns) do
    [
      "##{ticket.number} · #{assigns.step_mark} #{ticket.state}",
      ticket.status != :active && to_string(ticket.status),
      "visit #{step.visit}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  # Nothing says a conversation stopped: one whose machine was released is idle, and the only
  # ending a person sees is the one they chose. One an update released says why, though, beside
  # whatever it otherwise is.
  defp subline(%{chat: chat, responding: responding, last_said: last_said} = assigns) do
    released = after_update(assigns.live, assigns.released_by_update)

    "chat · " <>
      cond do
        responding -> "▸ responding · turn #{chat.turns + 1}"
        assigns.ending -> "ended"
        waiting?(last_said) -> "waiting on you" <> released
        chat.status == :pending -> "waiting for a machine"
        true -> "idle" <> released
      end
  end

  # **Released by an update says so, and that a message carries it on** — and not whose machine
  # it was: that is its owner's (`docs/design/worker-tier.md` § Updating a permanent machine).
  # Only while the update is the last thing that happened to it: a conversation holding a machine
  # has been started again, a person's message since has started it, and a machine lost since
  # (`job.interrupted`) is a different reason, which the update's old `chat.ended` must not speak
  # for. So the newest `chat.ended` and what followed it decide (`released_by_update?/1`).
  defp after_update(true, _released), do: ""
  defp after_update(false, false), do: ""
  defp after_update(false, true), do: " — its machine stopped to update; a message carries it on"

  # Read by queries of their own on a load, not from the turns held, which may not reach back to
  # the update: the newest `chat.ended`, and whether a message or a lost machine came after it.
  defp released_by_update?(id) do
    case Events.latest_for_job(id, "chat.ended") do
      %{payload: %{"reason" => "update"}, seq: seq} ->
        Events.for_job_types(id, ["chat.message", "job.interrupted"], seq) == []

      _other ->
        false
    end
  end

  # A step's conversation carries its ticket's strip, with the ticket's counts
  # (`TicketViews.strip_of/4`, the job page's too): Talk is this page, and every other view is the
  # ticket's own (`docs/design/ui.md` § The Accept area). Built here, on load and when the ticket
  # changes, and never in the template: a step's conversation renders on every streamed block,
  # and the strip reads the ticket's jobs, its documents and a diff of its whole branch.
  defp assign_strip(%{assigns: %{step: %{}} = assigns} = socket) do
    %{project: project, ticket: ticket, chat: chat, activity: activity} = assigns
    current = ticket.id |> Jobs.for_ticket() |> List.last()

    strip =
      for view <- TicketViews.strip_of(project, ticket, current, {chat.id, activity.count}) do
        # Talk is this page: patched, so its drafts and its scroll stay.
        if view.key == "talk",
          do: view |> Map.delete(:navigate) |> Map.put(:patch, ~p"/chats/#{chat.id}"),
          else: view
      end

    assign(socket, strip: strip)
  end

  defp assign_strip(socket), do: assign(socket, strip: nil)

  # The views a strip draws: a step's, as loaded; any other conversation's its own.
  defp views(%{strip: [_ | _] = strip}), do: strip

  defp views(assigns) do
    WorkScreen.views(
      [
        {"talk", "Talk", nil},
        {"changes", "Changes", Diff.file_count(assigns.diff)},
        {"docs", "Docs", length(assigns.docs)},
        {"activity", "Activity", assigns.activity.count}
      ],
      ~p"/chats/#{assigns.chat_id}"
    )
  end

  # The parent, at the top bar's right end: a step's and a project chat's project, a ticket
  # chat's ticket.
  defp context(project, _ticket, %{}), do: {project.name, ~p"/projects/#{project.name}"}
  defp context(project, ticket, nil), do: {context_label(project, ticket), back(project, ticket)}

  defp conflict(%{kind: :merge, conflict: [_ | _] = paths}), do: paths
  defp conflict(_decision), do: nil

  defp merge(%{kind: :merge} = decision), do: decision
  defp merge(_decision), do: nil

  # The second of a conflict's ways out: what a person types to take the branch by hand, against
  # the project's clone URL (`docs/design/git-hosting.md`).
  defp fetch_command(project, chat),
    do: "git fetch #{Url.for(project)} #{Jobs.chat_branch(chat)}"

  defp back(project, nil), do: ~p"/projects/#{project.name}"
  defp back(project, ticket), do: ~p"/tickets/#{project.name}/#{ticket.number}"

  # The parent object, short enough for the top bar's right end.
  defp context_label(project, nil), do: project.name
  defp context_label(project, ticket), do: "#{project.name}##{ticket.number}"

  # The address of a version is its scope's (ui.md § Addressable artifact versions): the
  # conversation's own for what is scoped to it, the ticket's for a ticket chat's documents.
  defp version_href(chat, _project, _ticket, %{job_id: job_id} = artifact, version)
       when is_binary(job_id),
       do: ~p"/chats/#{chat.id}/artifacts/#{artifact.name}/#{version}"

  defp version_href(_chat, project, ticket, artifact, version),
    do: ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version}"

  # A document is searched where it lives: the conversation's own artifacts for what is scoped to
  # it, the ticket's for a ticket chat's documents (`ui.md` § Documents → References).
  defp doc_scope(chat, project, _ticket, %{job_id: job_id}) when is_binary(job_id),
    do: Forge.References.chat_scope(project, chat.id)

  defp doc_scope(_chat, project, ticket, _artifact),
    do: Forge.References.ticket_scope(project.name, ticket)

  # A ticket conversation's messages are searched against the ticket and a project chat's against
  # its own documents (`conversations.md` § References in messages).
  defp transcript_scope(%{project: project, ticket: nil, chat_id: id}),
    do: Forge.References.chat_scope(project, id)

  defp transcript_scope(%{project: project, ticket: ticket}),
    do: Forge.References.ticket_scope(project.name, ticket)
end
