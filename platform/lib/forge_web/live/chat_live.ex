defmodule ForgeWeb.ChatLive do
  @moduledoc """
  One conversation, as a work screen (`docs/design/ui.md` § The work screen): Talk, Changes, Docs
  and Activity, a composer that never leaves the viewport, and its facts as the rail — or the
  details sheet below `lg`.

  **The reply streams, and so does what the agent does.** This is the case `ui.md` § Motion and
  structure allows: the operator is looking at this one piece of work. It is subscribed per job,
  so a page open on one conversation is not woken by every event on the node, and a harness
  event is appended to the log the page already holds and the transcript folded again from it —
  rather than every event reading the log, the diff and the documents again, several times a
  sentence.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components
  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1]

  alias Forge.{Artifacts, Conversations, Events, Git, Jobs, Merge, Operator, Projects, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Actions, Diff, Format, JobStream, Transcript, WorkScreen}

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
       tab: "talk",
       page_title: title(project, ticket),
       forms: ForgeWeb.Operator.QuestionForm.init()
     )
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
      # What a merge of this branch would say: the conversation's own latest, in the scope this
      # one document is written in whether or not the chat has a ticket, and the same version the
      # merge itself reads (`Forge.Conversations.document_scope/2`).
      commit_message:
        chat
        |> Conversations.document_scope(Workflow.commit_message_artifact())
        |> Artifacts.versions(Workflow.commit_message_artifact())
        |> List.last(),
      # Where a reopen makes a deleted branch again, from the definition the reopen uses.
      base_branch: Conversations.base_branch(project, ticket),
      merged: Merge.merged_chat?(chat),
      waiting: Jobs.current_wait(chat),
      conflict: nil
    )
    |> fold()
  end

  # The projection, from the log the page holds. Pure, so an appended event costs a fold and no
  # query.
  defp fold(%{assigns: %{events: events}} = socket) do
    messages = Conversations.transcript(events)

    assign(socket,
      messages: messages,
      now: Conversations.now(events),
      memory: Forge.Jobs.Memory.trouble(events),
      plan: Transcript.plan(messages),
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

  # Every version it wrote, whichever scope it is in — a ticket chat's documents are the
  # ticket's — grouped by document, the latest rendered and the rest linked
  # (`docs/design/ui.md` § Docs). Approval is possible only for a ticket's document that the
  # ticket's workflow approves, so only those carry a mark.
  defp docs(chat, project, ticket) do
    approvable =
      if ticket, do: ticket |> Tickets.workflow() |> Artifacts.approvable(), else: MapSet.new()

    chat.id
    |> Artifacts.written_by()
    |> Enum.chunk_by(fn {artifact, _version} -> artifact.id end)
    |> Enum.map(fn [{artifact, _} | _] = written ->
      WorkScreen.doc(
        artifact,
        Enum.map(written, &elem(&1, 1)),
        &version_href(chat, project, ticket, artifact, &1),
        is_nil(artifact.job_id) and artifact.kind != :presentation and
          MapSet.member?(approvable, artifact.name)
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

  # Three controls, because they are three intentions and guessing between them from one gesture
  # is how a chat client loses a message (`docs/design/conversations.md` § Turns). Send holds the
  # message until the turn ends; force interrupts and sends now; stop ends the turn and sends
  # nothing.
  def handle_event("send", %{"text" => text}, socket), do: say(socket, text, force: false)

  def handle_event("force", %{"text" => text}, socket), do: say(socket, text, force: true)

  def handle_event("stop", _params, socket) do
    :ok = Operator.stop_chat(socket.assigns.chat, socket.assigns.current_scope.user)
    {:noreply, socket}
  end

  # The page offers End only while the conversation is live, and the context refuses one that is
  # not, so a stale page or a crafted event is told rather than crashing the view.
  def handle_event("close", _params, socket) do
    case Operator.close_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      :ok ->
        {:noreply, socket}

      {:error, :not_live} ->
        {:noreply,
         socket |> put_flash(:error, "This conversation has already stopped.") |> load()}
    end
  end

  # The second route into the default branch. Both routes are the platform's own merge and both
  # are guarded by the same `pre-receive` with FORGE_INTERNAL; what differs is what authorised
  # it — an approved changeset version, or an operator pressing merge on a diff they can see.
  # An operator's own default-branch token is a third route and not one of these two: it is a
  # push, guarded by the same hook's fast-forward rule (`docs/design/git-hosting.md`).
  def handle_event("merge", _params, socket) do
    case Operator.merge_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      {:ok, _result} ->
        {:noreply, socket |> put_flash(:info, "Merged.") |> load()}

      {:conflict, paths} ->
        {:noreply, socket |> load() |> assign(conflict: paths)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not merge: #{inspect(reason)}")}
    end
  end

  def handle_event("reopen", _params, socket) do
    case Operator.reopen_chat(socket.assigns.chat, socket.assigns.current_scope.user) do
      {:ok, _chat} ->
        {:noreply, load(socket)}

      # Reopening a live one would take its worker away from under it. The page offers Reopen
      # only when it is not live; this is a stale page, or an event nobody drew a button for.
      {:error, :live} ->
        {:noreply, socket |> put_flash(:error, "This conversation is still live.") |> load()}

      # Remaking a deleted branch is a git write, and it can fail — a ticket branch that is gone
      # too. Said, rather than a crash that reads as the page breaking.
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not reopen: #{inspect(reason)}")}
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
        {:noreply, socket |> assign(draft: "") |> load()}

      {:error, :not_live} ->
        {:noreply,
         socket
         |> put_flash(:error, "This conversation has stopped. Reopen it to say that.")
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

  defp tabs(assigns) do
    [
      {"talk", "Talk", nil},
      {"changes", "Changes", Diff.file_count(assigns.diff)},
      {"docs", "Docs", length(assigns.docs)},
      {"activity", "Activity", WorkScreen.activity_count(assigns.events)}
    ]
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        questions: questions(assigns.messages),
        reply: reply(assigns.messages),
        responding: responding?(assigns.chat, assigns.messages),
        live: live?(assigns.chat)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:chats}
      measure="74rem"
      frame={:work}
    >
      <WorkScreen.frame
        tabs={tabs(assigns)}
        tab={@tab}
        path={~p"/chats/#{@chat.id}"}
        capacity={@capacity}
      >
        <%!-- On a phone the back affordance and the status share one line, and the title is
              for assistive technology only: every line of header is a line the transcript
              does not have. --%>
        <:header>
          <div class="flex items-center gap-3">
            <.link
              navigate={back(@project, @ticket)}
              class="flex min-h-[46px] min-w-0 items-center font-mono text-[12.5px] opacity-60 hover:opacity-100 sm:min-h-0"
            >
              <span class="truncate">‹ {where(@project, @ticket)}</span>
            </.link>
            <span class="ml-auto shrink-0 sm:hidden"><.job_status status={@chat.status} /></span>
          </div>
          <div class="flex flex-wrap items-baseline gap-3">
            <h1 class="sr-only text-2xl font-semibold -tracking-[.025em] sm:not-sr-only">
              Conversation
            </h1>
            <span class="hidden sm:inline"><.job_status status={@chat.status} /></span>
          </div>
        </:header>

        <:strip>
          <span>chat/{String.slice(@chat.id, 0, 8)}</span>
          <Diff.stat diff={@diff} />
          <span>{@chat.turns} {if @chat.turns == 1, do: "turn", else: "turns"}</span>
          <span>{Format.windows(@chat.cost_usd) || "—"}</span>
          <%!-- Only when memory was the trouble (`docs/design/capacity.md` § Memory, which a job
                holds rather than spends). --%>
          <span :if={@memory} id="chat-memory" class="text-warning">
            ⚠ {Forge.Jobs.Memory.words(@memory)}
          </span>
          <%!-- What it was opened with, less what has gone since: the names, never a value. --%>
          <span :if={@chat.secret_names -- @secrets_gone != []} id="chat-secrets">
            holds {Enum.join(@chat.secret_names -- @secrets_gone, ", ")}
          </span>
          <span :for={name <- @secrets_gone} class="chat-secret-gone text-warning">
            ⚠ {name} was deleted and this conversation no longer holds it
          </span>
        </:strip>

        <.talk :if={@tab == "talk"} {assigns} />

        <WorkScreen.body :if={@tab == "changes"} id="changes">
          <.changes {assigns} />
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
          />
        </WorkScreen.body>

        <:footer :if={@tab == "talk"}>
          <.footer {assigns} />
        </:footer>

        <:rail>
          <.rail {assigns} />
        </:rail>
      </WorkScreen.frame>
    </Layouts.app>
    """
  end

  defp talk(assigns) do
    ~H"""
    <.scroll_pane id="messages-pane" height={nil} class="py-4">
      <ol class="flex flex-col gap-4" id="messages" data-scroll-items>
        <Transcript.transcript messages={@messages} live={@live} now={@at} />
      </ol>

      <p :if={@messages == []} class="text-sm opacity-60">Nothing said yet.</p>

      <%!-- A conversation that has not started yet says why, where the reply will appear: the
            scheduler's sentence, the latest since it last started (docs/design/ui.md § A job
            waiting for a machine). A chat sticks nothing, so this is the only surface that says
            a template is missing. --%>
      <p :if={@waiting} id="chat-waiting" class="mt-4 text-sm/[1.55] opacity-70">
        {Events.summary(@waiting)}
      </p>
    </.scroll_pane>
    """
  end

  # From the bottom up: the composer, the now line with the plan above it, and the last reply's
  # question form — under the thumb (`docs/design/ui.md` § Talk).
  defp footer(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 border-t border-base-300 pt-2 pb-2">
      <%!-- Gone when the conversation is, for the same reason the box is: the form's Send is a
            send button, and one offered on a dead conversation takes a tap and loses it. What it
            asked stays legible in the transcript. --%>
      <section
        :if={@questions != [] && @live}
        id="answer-rows"
        class="flex max-h-[45dvh] flex-col gap-2 overflow-y-auto"
      >
        <.question_form
          id={"chat-#{@chat_id}-#{@reply}"}
          questions={@questions}
          forms={@forms}
          submit="chat:questions:send"
          hidden={[{"chat", @chat_id}, {"reply", @reply}]}
        />
      </section>

      <details
        :if={@responding && @plan != []}
        id="plan"
        class="font-mono text-[12.5px]"
        phx-mounted={Actions.keep_open()}
      >
        <summary class="flex min-h-[46px] cursor-pointer items-center gap-2 text-info">
          <span class="shrink-0 opacity-60">
            {Enum.count(@plan, &(&1["status"] == "completed"))}/{length(@plan)}
          </span>
          <span class="min-w-0 truncate font-sans text-sm">
            {(Actions.current_todo(@plan) && Actions.todo_text(Actions.current_todo(@plan))) ||
              "done"}
          </span>
        </summary>
        <div class="pb-2"><Actions.checklist todos={@plan} /></div>
      </details>

      <%!-- Static text: ui.md § Motion and structure says nothing pulses, and a conversation you
            are waiting on is exactly where a decorative animation would be most tempting and
            least honest. --%>
      <div :if={@responding} id="now-line" class="flex flex-wrap items-center gap-2">
        <span class="min-w-0 basis-full break-words font-mono text-[12.5px] text-info sm:basis-0 sm:flex-1">
          {Actions.now_words(@now) || "…"}
        </span>
        <button
          type="button"
          phx-click="stop"
          class="min-h-[46px] rounded-field border border-base-300 px-3 text-sm"
        >
          Stop
        </button>
        <%!-- Deliberate, and named for what it costs: the tokens already spent on the
              interrupted turn are spent. --%>
        <button
          type="button"
          phx-click="force"
          phx-value-text={@draft}
          class="min-h-[46px] rounded-field border border-base-300 px-3 text-sm"
        >
          Interrupt and send
        </button>
      </div>

      <p :if={waiting?(@chat, @messages)} class="text-sm opacity-60">It is waiting on you.</p>

      <form :if={@live} id="say" phx-change="draft" phx-submit="send">
        <ForgeWeb.Conversations.message_box id="draft" name="text" value={@draft} send />
      </form>

      <section :if={not @live}>
        <p id="reopen-copy" class="text-sm/[1.55] opacity-70">
          This conversation has stopped. Reopening starts a new process on a new machine: it is
          given everything said here to read, and answers the next thing you say.
          <%= if @branch_exists do %>
            It works on its branch as it stands.
          <% else %>
            Its branch is gone — a merge deletes it, and so does ending — so it starts one again
            from <span class="font-mono text-[12.5px]">{@base_branch}</span> as it stands now.
          <% end %>
        </p>
        <button
          type="button"
          phx-click="reopen"
          class="mt-2 min-h-[46px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
        >
          Reopen
        </button>
      </section>
    </div>
    """
  end

  defp changes(assigns) do
    ~H"""
    <section>
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">What it changed</h2>
      <div class="mt-3">
        <Diff.file_table :if={@diff} diff={@diff} ask="ask" />
        <p :if={!@diff} class="text-sm/[1.55] opacity-70">
          There is no branch to compare: a merge deletes it, and so does ending.
        </p>
      </div>
    </section>

    <WorkScreen.commits commits={@commits} now={@at} />

    <section :if={@diff} class="mt-8">
      <p :if={@conflict} class="text-sm/[1.55] text-error">
        It does not merge cleanly: {Enum.join(@conflict, ", ")}. Ask it to rebase, or take the
        change by hand.
      </p>

      <p :if={@merged} class="text-sm/[1.55] opacity-70">
        Already on {@project.default_branch}.
      </p>

      <%!-- Above the merge control and read-only, as on a ticket's review page. The button is
            drawn only where there is one: pressing merge without it is refused, and a page that
            offered it would be offering something that fails (`conversations.md` § Commits). --%>
      <div :if={not @merged and @diff[:files] not in [nil, []]} class="mt-4">
        <WorkScreen.commit_message version={@commit_message} id="chat-commit-message" />
      </div>

      <button
        :if={(not @merged and @commit_message) && @diff[:files] not in [nil, []]}
        type="button"
        phx-click="merge"
        data-confirm="Merge this into the default branch?"
        class="mt-4 min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
      >
        Merge into {@project.default_branch}
      </button>
    </section>
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
    <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">This chat</h2>
    <p class="mt-2 text-sm/[1.55] opacity-60">{context_line(@ticket)}</p>

    <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
      <.fact label="project" value={@project.name} />
      <.fact :if={@ticket} label="ticket" value={"##{@ticket.number} #{@ticket.title}"} />
      <.fact label="model" value={Jobs.model_for(@chat) || "the platform's"} />
      <.fact label="turns" value={to_string(@chat.turns)} />
      <.fact label="spent" value={Format.windows(@chat.cost_usd) || "—"} />
      <.fact label="branch" value={"chat/" <> @chat.id} />
    </dl>

    <section :if={@live} class="mt-8">
      <button
        type="button"
        phx-click="close"
        data-confirm={ForgeWeb.Conversations.ending_confirm()}
        class="min-h-[46px] text-sm text-primary hover:underline"
      >
        End it
      </button>
      <p id="ending-copy" class="mt-1 text-sm/[1.55] opacity-60">
        It holds a worker until it ends or goes idle. If you end it, {ForgeWeb.Conversations.ending_rule()}; going idle does not.
      </p>
    </section>
    """
  end

  defp back(project, nil), do: ~p"/projects/#{project.name}"
  defp back(project, ticket), do: ~p"/tickets/#{project.name}/#{ticket.number}"

  defp where(project, nil), do: project.name
  defp where(project, ticket), do: "#{project.name}##{ticket.number} · #{ticket.title}"

  # The address of a version is its scope's (ui.md § Addressable artifact versions): the
  # conversation's own for what is scoped to it, the ticket's for a ticket chat's documents.
  defp version_href(chat, _project, _ticket, %{job_id: job_id} = artifact, version)
       when is_binary(job_id),
       do: ~p"/chats/#{chat.id}/artifacts/#{artifact.name}/#{version}"

  defp version_href(_chat, project, ticket, artifact, version),
    do: ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version}"

  defp context_line(nil), do: "About the repository as a whole."
  defp context_line(_ticket), do: "About this ticket, from its branch as it stood."
end
