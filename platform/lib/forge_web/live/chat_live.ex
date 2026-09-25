defmodule ForgeWeb.ChatLive do
  @moduledoc """
  One conversation: what was said, what is being said now, and what it has written.

  The frame is the ticket's and the job's — a column and a 21rem rail divided by a rule — because
  a conversation is the same kind of thing: work with a branch, a cost and a record
  (`docs/design/ui.md` § Space, measure and targets).

  **The reply streams.** This is the case `ui.md` § Motion and structure was rewritten to allow:
  the operator asked the question and is waiting for the answer, so the text appears as it
  arrives. It is subscribed per job, so a page open on one conversation is not woken by every
  event on the node, and it appends rather than reloading — a reload would be a page that flickers
  four times a sentence.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Conversations, Events, Git, Jobs, Merge, Operator, Projects}
  alias ForgeWeb.{Diff, Format, Markdown}

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
       page_title: title(project, ticket)
     )
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  defp title(project, nil), do: "Chat · #{project.name}"
  defp title(project, ticket), do: "Chat · #{project.name}##{ticket.number}"

  defp load(%{assigns: %{chat_id: id, project: project}} = socket) do
    chat = Conversations.get!(id)

    assign(socket,
      chat: chat,
      messages: Conversations.messages(id),
      written: Artifacts.written_by(id),
      unrecorded: Conversations.unrecorded(id),
      diff: chat_diff(project, chat),
      branch_exists: Git.branch_exists?(Projects.repo_path(project), Jobs.chat_branch(chat)),
      # Where a reopen makes a deleted branch again, from the definition the reopen uses.
      base_branch: Conversations.base_branch(project, socket.assigns.ticket),
      merged: Merge.merged_chat?(chat),
      waiting: Jobs.current_wait(chat),
      conflict: nil
    )
  end

  # Against the default branch, which is where a merge would put it — the same question the
  # review page asks about a ticket, so it is the same diff and the same drawing of it.
  defp chat_diff(project, chat) do
    repo = Projects.repo_path(project)

    with {:ok, head} <- Git.resolve(repo, "refs/heads/" <> project.default_branch),
         {:ok, source} <- Git.resolve(repo, "refs/heads/" <> Jobs.chat_branch(chat)) do
      Diff.build(repo, head, source)
    else
      _gone -> nil
    end
  end

  # Per job, so the filtering is the subscription rather than a check — CLAUDE.md's rule about a
  # handler on a global topic. A reload per event would flicker several times a sentence, so the
  # projection is recomputed from the log, which is cheap and is the only copy there is.
  @impl true
  def handle_info({:job_event, id, _event}, %{assigns: %{chat_id: id}} = socket),
    do: {:noreply, load(socket)}

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

  # Answering a question is sending what you chose as the next message, so the agent sees it
  # exactly where it expects to. Nothing is written to `answers`: the transcript is already the
  # record, and a second one would be a second truth (§ Asking a question).
  def handle_event("answer", %{"choice" => choice}, socket), do: say(socket, choice, force: false)

  defp say(socket, text, opts) do
    case String.trim(text || "") do
      "" ->
        {:noreply, socket}

      text ->
        deliver(socket, text, opts)
    end
  end

  # It can have ended between the render and the tap, and the answer rows are the case that
  # matters: they are what a person taps from a phone without reading the page again. Reloading
  # is what swaps the send box for the reopen button, so the page stops offering what it cannot
  # do rather than only saying so.
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

  # The queue asks the same thing of the same reply, so the asking lives in `Conversations`.
  defp question(messages), do: messages |> List.last() |> Conversations.question()

  # Waiting on *you*: the agent finished a turn and said something. A reply still being spoken
  # is not waiting on anyone.
  defp waiting?(%{status: status}, messages) do
    case {status, List.last(messages)} do
      {status, %{role: :assistant, turn: turn}} when status in [:running, :pending] -> turn != nil
      _other -> false
    end
  end

  # The agent has the ball: either it has not started this turn's reply, or it is still speaking
  # it — an assistant message with no turn number on it is one no `chat.turn` has closed.
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
    assigns = assign(assigns, question: question(assigns.messages))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:board}
      measure="74rem"
    >
      <.link
        navigate={back(@project, @ticket)}
        class="font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {where(@project, @ticket)}
      </.link>

      <div class="mt-4 flex flex-col gap-8 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <header class="flex flex-wrap items-baseline gap-3">
            <h1 class="text-2xl font-semibold -tracking-[.025em]">Conversation</h1>
            <.job_status status={@chat.status} />
          </header>

          <p class="mt-2 text-sm/[1.55] opacity-60">
            {context_line(@ticket)} Its work is on <span class="font-mono text-[12.5px]">chat/{@chat.id}</span>.
          </p>

          <.scroll_pane id="messages-pane" height="62vh" class="mt-8">
            <ol class="flex flex-col gap-6" id="messages" data-scroll-items>
              <li :for={message <- @messages} class="flex flex-col gap-1">
                <div class="flex items-baseline gap-2 font-mono text-[11px] tracking-[.14em] uppercase opacity-50">
                  <span>{if message.role == :user, do: "you", else: "agent"}</span>
                  <span :if={message.role == :user and not message.delivered} class="opacity-80">
                    · queued
                  </span>
                  <span :if={message[:turn]}>· turn {message.turn}</span>
                  <span>· {Format.ago(message.at, DateTime.utc_now())}</span>
                </div>

                <div class={[
                  "rounded-box border border-base-300 px-4 py-3",
                  message.role == :user && "bg-base-200"
                ]}>
                  <div class="doc text-sm/[1.6] break-words">{Markdown.to_html(message.text)}</div>
                </div>
              </li>
            </ol>
          </.scroll_pane>

          <p :if={@messages == []} class="mt-8 text-sm opacity-60">
            Nothing said yet.
          </p>

          <%!-- Where the reply will appear, so the wait has a place rather than a spinner
                somewhere else. Static: ui.md § Motion and structure says nothing pulses, and a
                conversation you are waiting on is exactly where a decorative animation would be
                most tempting and least honest. --%>
          <p :if={responding?(@chat, @messages)} class="mt-6 flex items-center gap-2">
            <span class="font-mono text-[11px] tracking-[.14em] uppercase opacity-50">agent</span>
            <span class="font-mono text-[17px] leading-none opacity-40">…</span>
          </p>

          <%!-- A conversation that has not started yet says why, in the same place: the
                scheduler's sentence, the latest since it last started (docs/design/ui.md § A job
                waiting for a machine). A chat sticks nothing, so this is the only surface that
                says a template is missing. --%>
          <p :if={@waiting} id="chat-waiting" class="mt-6 text-sm/[1.55] opacity-70">
            {Events.summary(@waiting)}
          </p>

          <%!-- A reply that asked something gets one-tap answers, which is the difference
                between answering from a phone and not. Free text stays valid and is the box
                below, not an escape hatch behind a link.

                Gone when the conversation is, for the same reason the box below is: an answer
                row *is* a send button, and one offered on a dead conversation takes a tap and
                loses it. What it asked stays legible — the reply is in the transcript above. --%>
          <section
            :if={@question && live?(@chat)}
            class="mt-8 rounded-box border border-base-300 p-4"
          >
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              It asked you
            </h2>
            <p class="mt-2 text-sm/[1.55]">{@question.text}</p>
            <div class="mt-3 flex flex-col gap-2">
              <.answer_row
                :for={option <- @question.options}
                phx-click="answer"
                phx-value-choice={option}
              >
                {option}
              </.answer_row>
            </div>
          </section>

          <section :if={live?(@chat)} class="mt-8">
            <form id="say" phx-change="draft" phx-submit="send" class="flex flex-col gap-3">
              <ForgeWeb.Conversations.message_box id="draft" name="text" value={@draft} />

              <div class="flex flex-wrap gap-3">
                <button
                  type="submit"
                  class="min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
                >
                  Send
                </button>
                <%!-- Deliberate, and named for what it costs: the tokens already spent on the
                      interrupted turn are spent. --%>
                <button
                  type="button"
                  phx-click="force"
                  phx-value-text={@draft}
                  class="min-h-[52px] rounded-field border border-base-300 px-4 text-sm"
                >
                  Interrupt and send
                </button>
                <button
                  type="button"
                  phx-click="stop"
                  class="min-h-[52px] rounded-field border border-base-300 px-4 text-sm"
                >
                  Stop
                </button>
              </div>
            </form>

            <p :if={waiting?(@chat, @messages)} class="mt-3 text-sm opacity-60">
              It is waiting on you.
            </p>
          </section>

          <section :if={@diff} class="mt-10 border-t border-base-300 pt-8">
            <Diff.section diff={@diff} id="chat-diff" title="What it changed" />

            <p :if={@conflict} class="mt-4 text-sm/[1.55] text-error">
              It does not merge cleanly: {Enum.join(@conflict, ", ")}. Ask it to rebase, or take
              the change by hand.
            </p>

            <p :if={@merged} class="mt-4 text-sm/[1.55] opacity-70">
              Already on {@project.default_branch}.
            </p>

            <button
              :if={not @merged and @diff[:files] not in [nil, []]}
              type="button"
              phx-click="merge"
              data-confirm="Merge this into the default branch?"
              class="mt-4 min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
            >
              Merge into {@project.default_branch}
            </button>
          </section>

          <section :if={not live?(@chat)} class="mt-8">
            <p id="reopen-copy" class="text-sm/[1.55] opacity-70">
              This conversation has stopped. Reopening starts a new process on a new machine: it
              is given everything said here to read, and answers the next thing you say.
              <%= if @branch_exists do %>
                It works on its branch as it stands.
              <% else %>
                Its branch is gone — a merge deletes it, and so does ending — so it starts one
                again from <span class="font-mono text-[12.5px]">{@base_branch}</span>
                as it stands now.
              <% end %>
            </p>
            <button
              type="button"
              phx-click="reopen"
              class="mt-3 min-h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
            >
              Reopen
            </button>
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">This chat</h2>

          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <.fact label="project" value={@project.name} />
            <.fact :if={@ticket} label="ticket" value={"##{@ticket.number} #{@ticket.title}"} />
            <.fact label="model" value={Jobs.model_for(@chat) || "the platform's"} />
            <.fact label="turns" value={to_string(@chat.turns)} />
            <.fact label="spent" value={Format.windows(@chat.cost_usd) || "—"} />
            <.fact label="branch" value={"chat/" <> @chat.id} />
          </dl>

          <%!-- Every version it wrote, whichever scope it is in — a ticket chat's documents are
                the ticket's — and each is a link to itself: ui.md § Addressable artifact
                versions. The row is the link, as on a job page's produced list. --%>
          <section class="mt-8">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Written</h2>
            <p :if={@written == [] and @unrecorded == %{}} class="mt-3 text-sm opacity-60">
              Nothing yet.
            </p>
            <ul id="written" class="mt-3 flex flex-col">
              <li :for={{artifact, version} <- @written}>
                <.link
                  href={version_href(@chat, @project, @ticket, artifact, version)}
                  class="flex min-h-[46px] items-center gap-2 border-b border-base-300/60 font-mono text-[12.5px] hover:bg-base-200"
                >
                  <span class="min-w-0 flex-1 truncate">{artifact.name}</span>
                  <span class="shrink-0 opacity-60">v{version.version}</span>
                  <span class="shrink-0 opacity-40" aria-hidden="true">›</span>
                </.link>
              </li>
            </ul>
            <%!-- What the last turn left in out/ that was not recorded, and why. Without this a
                  document that did not arrive is only absent, which reads the same as one
                  that was never written. --%>
            <ul :if={@unrecorded != %{}} id="unrecorded" class="mt-3 flex flex-col gap-2">
              <li :for={{name, why} <- Enum.sort(@unrecorded)} class="text-[12.5px]">
                <span class="font-mono break-all">{name}</span>
                <span class="text-error">not recorded:</span>
                <span class="opacity-70">{why}</span>
              </li>
            </ul>
          </section>

          <section :if={live?(@chat)} class="mt-8">
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
        </aside>
      </div>
    </Layouts.app>
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
       do: ~p"/chats/#{chat.id}/artifacts/#{artifact.name}/#{version.version}"

  defp version_href(_chat, project, ticket, artifact, version),
    do:
      ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version.version}"

  defp context_line(nil), do: "About the repository as a whole."
  defp context_line(_ticket), do: "About this ticket, from its branch as it stood."
end
