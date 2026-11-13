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
  event is appended to the log the page already holds and the transcript folded again from it —
  rather than every event reading the log, the diff and the documents again, several times a
  sentence.
  """

  use ForgeWeb, :live_view

  alias Forge.{Artifacts, Conversations, Events, Git, Jobs, Merge, Operator, Projects, Tickets}
  alias Forge.Git.Url
  alias ForgeWeb.{ChatViews, Diff, Format, JobStream, TicketViews, Transcript, WorkScreen}
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
     |> JobStream.init()
     |> ForgeWeb.Capacity.project(project)
     |> load()}
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

    {:noreply, assign(socket, tab: tab)}
  end

  defp load(%{assigns: %{chat_id: id, project: project, ticket: ticket}} = socket) do
    chat = Conversations.get!(id)
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)

    socket
    |> assign(
      chat: chat,
      events: Events.for_job(id),
      docs: docs(chat, project, ticket),
      unrecorded: Conversations.unrecorded(id),
      diff: chat_diff(project, chat),
      commits: commits(project, chat),
      branch_exists: Git.branch_exists?(repo, branch),
      # What a merge of this branch would say, from the definition the merge itself reads
      # (`Forge.Merge.commit_message/1`).
      commit_message: Merge.commit_message(chat),
      # Where a reopen makes a deleted branch again, from the definition the reopen uses.
      base_branch: Conversations.base_branch(project, ticket),
      merged: Merge.merged_chat?(chat),
      waiting: Jobs.current_wait(chat),
      step: step_view(chat, ticket),
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
    |> assign_strip()
    |> fold()
    |> assign_decision()
  end

  # The one decision row a conversation has (`docs/design/ui.md` § The decision row): a step's
  # Accept, or else merging its branch, which nobody is waiting on.
  defp assign_decision(%{assigns: assigns} = socket) do
    decision =
      Decision.step(assigns.step, questions(assigns.messages)) ||
        Decision.merge(assigns, assigns.chat)

    Decision.put(socket, decision)
  end

  defp step_view(chat, %Forge.Tickets.Ticket{} = ticket),
    do: if(Jobs.Job.step?(chat), do: Forge.Steps.view(ticket, chat))

  defp step_view(_chat, nil), do: nil

  # The projection, from the log the page holds. The fold is pure; what the transcript's references
  # mean is not, and costs no query when the messages hold none (`Transcript.resolve/3`) and a
  # few — not one per message — when they do.
  defp fold(%{assigns: %{events: events}} = socket) do
    messages = Conversations.transcript(events)

    assign(socket,
      messages: messages,
      now: Conversations.now(events),
      memory: Forge.Jobs.Memory.trouble(events),
      plan: Transcript.plan(messages),
      refs:
        Transcript.resolve(messages, transcript_scope(socket.assigns), socket.assigns.chat_id),
      secrets_gone: secrets_gone(events),
      at: DateTime.utc_now()
    )
  end

  # What its latest run could not hold because it was deleted since the conversation was opened
  # (`docs/design/secrets.md` § Conversations): said on the page, rather than left for the agent
  # to find its variable missing halfway through a turn.
  defp secrets_gone(events) do
    case List.last(for %{type: "job.secrets", payload: payload} <- events, do: payload) do
      nil -> []
      run -> run["gone"]
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
      case JobStream.add(socket.assigns.events, event) do
        :seen ->
          {:noreply, socket}

        {:ok, events} ->
          {:noreply, socket |> assign(events: events) |> fold() |> JobStream.catch_up(event)}
      end
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

  @impl true
  def handle_event("draft", %{"text" => text}, socket),
    do: {:noreply, assign(socket, draft: text)}

  def handle_event("decision:" <> _ = event, params, socket),
    do: Decision.handle_event(event, params, socket, &load/1)

  # Three intentions, because guessing between them from one gesture is how a chat client loses
  # a message (`docs/design/conversations.md` § Turns). Send holds the message until the turn
  # ends; Send while the agent responds is *Interrupt and send*, which the form says in a field
  # drawn beside the button that names it (`15a`); stop ends the turn and sends nothing.
  def handle_event("send", %{"text" => text} = params, socket),
    do: say(socket, text, force: params["interrupt"] == "true")

  def handle_event("stop", _params, socket) do
    :ok = Operator.stop_chat(socket.assigns.chat, socket.assigns.current_scope.user)
    {:noreply, socket}
  end

  # The page offers End only while the conversation is live, and the context refuses one that is
  # not, so a stale page or a crafted event is told rather than crashing the view.
  def handle_event("close", _params, socket) do
    case Operator.close_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      :ok ->
        {:noreply, assign(socket, chat_error: nil)}

      {:error, :not_live} ->
        {:noreply,
         socket
         |> assign(chat_error: {:details, "This conversation has already stopped."})
         |> load()}
    end
  end

  def handle_event("reopen", _params, socket) do
    case Operator.reopen_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      {:ok, _chat} ->
        {:noreply, socket |> assign(chat_error: nil) |> load()}

      # Reopening a live one would take its worker away from under it. The page offers Reopen
      # only when it is not live; this is a stale page, or an event nobody drew a button for.
      {:error, :live} ->
        {:noreply,
         socket |> assign(chat_error: {:dock, "This conversation is still live."}) |> load()}

      # Remaking a deleted branch is a git write, and it can fail — a ticket branch that is gone
      # too. Said, rather than a crash that reads as the page breaking.
      {:error, reason} ->
        {:noreply, assign(socket, chat_error: {:dock, "Could not reopen: #{inspect(reason)}"})}
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

  def handle_event("more", params, socket), do: JobStream.handle_event("more", params, socket)

  def handle_event("notices", params, socket),
    do: JobStream.handle_event("notices", params, socket)

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

  defp say(socket, text, opts) do
    case String.trim(text || "") do
      "" ->
        {:noreply, socket}

      text ->
        deliver(socket, text, opts)
    end
  end

  # It can have ended between the render and the tap. Reloading is what swaps the send box for the
  # reopen button, so the page stops offering what it cannot do rather than only saying so. The
  # question form's Send takes the same road through `Operator.answer_chat/4` and is reloaded the
  # same way.
  defp deliver(socket, text, opts) do
    case Operator.send_chat(socket.assigns.chat, socket.assigns.current_scope.user, text, opts) do
      {:ok, _event} ->
        {:noreply, socket |> assign(draft: "", chat_error: nil) |> load()}

      {:error, :not_live} ->
        {:noreply,
         socket
         |> assign(chat_error: {:dock, "This conversation has stopped. Reopen it to say that."})
         |> load()}
    end
  end

  # The queue asks the same thing of the same reply, so the asking lives in `Conversations`. What
  # was *said* (`Conversations.said/1`), because that is the reading `Operator.answer_chat/4`
  # checks the form's reply against: a turn that only acted is not the reply being answered.
  # Reading the whole transcript's last instead is an equivalent mutant as the harness behaves:
  # a turn starts with a person's message, so a silent turn is never directly after a reply that
  # asked, and both readings find no form where they differ.
  defp questions(messages),
    do: messages |> Conversations.said() |> List.last() |> Conversations.questions()

  defp reply(messages), do: messages |> Conversations.said() |> Conversations.reply_ref()

  # Waiting on *you*: the agent finished a turn and said something — the queue's reading, from
  # the same messages (`Conversations.said/1`), so the page and the queue agree. A reply still
  # being spoken is not waiting on anyone, and neither is a turn that only acted.
  defp waiting?(%{status: status}, messages) do
    case {status, messages |> Conversations.said() |> List.last()} do
      {status, %{role: :assistant, turn: turn}} when status in [:running, :pending] -> turn != nil
      _other -> false
    end
  end

  # The agent has the ball: either it has not started this turn's reply, or it is still in it —
  # an assistant turn no `chat.turn` has closed.
  defp responding?(%{status: status}, messages) do
    status == :running and
      case List.last(messages) do
        %{role: :user} -> true
        %{role: :assistant, turn: nil} -> true
        _other -> false
      end
  end

  # One definition, in the context that enforces it: a page that thought a conversation was live
  # while `Conversations.send/3` disagreed would offer a send box that refuses.
  defp live?(chat), do: Conversations.live?(chat)

  @impl true
  def render(assigns) do
    messages = assigns.messages

    assigns =
      assign(assigns,
        questions: questions(messages),
        reply: reply(messages),
        responding: responding?(assigns.chat, messages),
        live: live?(assigns.chat),
        title: page_heading(assigns, messages),
        viewer: assigns.current_scope.user,
        fetch: fetch_command(assigns.project, assigns.chat),
        conflict: conflict(assigns.decision),
        merge: merge(assigns.decision),
        step_doc: ChatViews.step_doc(assigns.step, assigns.docs)
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
      measure="48rem"
      fill
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

      <WorkScreen.body :if={@tab == "changes"} id="changes">
        <ChatViews.changes {assigns} />
      </WorkScreen.body>

      <WorkScreen.body :if={@tab == "docs"} id="docs">
        <WorkScreen.docs docs={@docs} unrecorded={@unrecorded} />
      </WorkScreen.body>

      <WorkScreen.body :if={@tab == "activity"} id="activity">
        <WorkScreen.activity
          events={@events}
          shown={@shown}
          notices={@notices}
          heading={WorkScreen.stream_heading(@chat, @events)}
          hrefs={WorkScreen.version_hrefs(@docs)}
        />
      </WorkScreen.body>
    </Layouts.app>
    """
  end

  # A step's conversation is its ticket's work, and its page the ticket's frame: titled by the
  # ticket. Any other is called what the person opened it with (`Conversations.title/3`).
  defp page_heading(%{chat: chat, ticket: ticket, step: step}, messages) do
    first = Enum.find_value(messages, fn m -> m.role == :user && m.text end)
    Conversations.title(chat, step && ticket, first)
  end

  # Under the title: a step's ticket, its state and visit, as the ticket's own page says it; a
  # conversation's own state otherwise — responding and on which turn, waiting on you, idle,
  # waiting for a machine, or stopped and when.
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

  defp subline(%{chat: chat, live: live, responding: responding, messages: messages}) do
    "chat · " <>
      cond do
        responding -> "▸ responding · turn #{chat.turns + 1}"
        waiting?(chat, messages) -> "waiting on you"
        chat.status == :pending -> "waiting for a machine"
        live -> "idle"
        true -> stopped(chat)
      end
  end

  defp stopped(%{finished_at: %DateTime{} = at}), do: "stopped " <> Format.ago_phrase(at)
  defp stopped(_chat), do: "stopped"

  # A step's conversation carries its ticket's strip, with the ticket's counts
  # (`TicketViews.strip_of/4`, the job page's too): Talk is this page, and every other view is the
  # ticket's own (`docs/design/ui.md` § The Accept area). Built here, on load and when the ticket
  # changes, and never in the template: a step's conversation renders on every streamed block,
  # and the strip reads the ticket's jobs, its documents and a diff of its whole branch.
  defp assign_strip(%{assigns: %{step: %{}} = assigns} = socket) do
    %{project: project, ticket: ticket, chat: chat, events: events} = assigns
    current = ticket.id |> Jobs.for_ticket() |> List.last()

    strip =
      for view <- TicketViews.strip_of(project, ticket, current, {chat.id, events}) do
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
        {"activity", "Activity", WorkScreen.activity_count(assigns.events)}
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
