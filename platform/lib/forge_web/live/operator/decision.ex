defmodule ForgeWeb.Operator.Decision do
  @moduledoc """
  The decision row and the panel it drops (`docs/design/ui.md` § The decision row): **every
  approve, accept and merge in the product**, and nowhere else — a ticket's approval of its
  changeset or a document, a chat step's Accept, a chat's merge.

  A page builds the decision it has with `approval/3`, `step/2` or `merge/2`, draws it with
  `row/1` in the frame's `decision` slot, and hands every `decision:` event here. What the panel
  holds — open or folded, the note, the outcome picked — is the page's, in the assigns `init/1`
  makes; the panel's form carries all of it with a `phx-change`, so a rejoin gives it back
  (`docs/design/ui.md` § A reconnect is not a reload). A refusal is drawn inside the panel, never
  as a flash (§ Errors stay where you acted), and what succeeded is a toast.

  **A reject needs a note**, and that rule is `Forge.Engine.decide/4`'s: Reject is disabled here
  while the note is blank, and a press that arrives anyway is refused by the operation and said
  inside the panel.

  **What the panel holds belongs to the decision it was opened on.** A page assigns its decision
  with `put/2` on every load, and when the decision is no longer the same one — another person
  decided it, the ticket moved on and came back to a new version, a later visit of the step, new
  commits on the chat's branch — the panel folds and forgets its note and its pick. Without that, a
  new approval arrived already open, under a finger, holding a note written about the version
  before it.

  **A press names what it was pressed on.** Approve and Reject send the approval the panel drew
  (`shown`), and a press on one that is no longer what waits does nothing and says so where the
  person acted: in the panel of what waits now, or, when nothing does, in place of the row.
  """

  use ForgeWeb, :html

  alias Forge.{Artifacts, Engine, Merge, Operator, Steps, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.Components.StepAccept
  alias ForgeWeb.{Format, Toast, WorkScreen}
  alias ForgeWeb.Operator.Actions
  alias Phoenix.Component

  # -- the page's state ----------------------------------------------------------------------

  @doc "The assigns a page starts with: folded, no note, nothing picked, nothing refused."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    socket
    |> Component.assign(decision: nil, decision_key: nil)
    |> decided()
  end

  @doc """
  Assigns the page's decision, `approval/3`, `step/3`, `merge/2` or nil. When it is not the
  decision the panel was opened on, the panel is folded and its note, pick and refusal dropped.
  """
  @spec put(Phoenix.LiveView.Socket.t(), map() | nil) :: Phoenix.LiveView.Socket.t()
  def put(socket, decision) do
    key = key(decision)

    if key == socket.assigns.decision_key,
      do: Component.assign(socket, decision: decision),
      else: socket |> Component.assign(decision: decision, decision_key: key) |> decided()
  end

  # Which decision it is: an approval by the edge and the versions it pins, a step by its
  # conversation — each visit of a chat step is a conversation of its own — and a merge by the
  # commits it would merge.
  defp key(nil), do: nil
  defp key(%{kind: :approval, shown: shown}), do: {:approval, shown}
  defp key(%{kind: :step, step: step}), do: {:step, step.chat.id}
  defp key(%{kind: :merge, chat: chat, head: head}), do: {:merge, chat.id, head}

  # -- what the decision is ------------------------------------------------------------------

  @doc """
  The approval `ticket` waits on, or nil: the versions it pins, where it goes, and — when the
  approval merges — the commit message, the documents the change was built from, the questions
  answered and what it cost (`docs/design/decisions.md`). `diff` is the page's diff of the
  branch, for the row's size, or nil.
  """
  @spec approval(map(), map(), map() | nil) :: map() | nil
  def approval(_project, %{pending_transition: nil}, _diff), do: nil

  def approval(project, ticket, diff) do
    pending = ticket.pending_transition
    commit = commit(ticket)
    merges = commit != nil

    pins =
      for name <- Engine.awaiting_approval(ticket),
          version = Artifacts.latest(ticket.id, name),
          do: pin(project, ticket, name, version)

    %{
      kind: :approval,
      shown: shown(pending, Enum.map(pins, &{&1.name, &1.version})),
      project: project,
      ticket: ticket,
      from: pending["from"],
      to: pending["to"],
      pins: pins,
      diff: size(diff),
      merges: merges,
      commit: commit,
      commit_message: commit && commit.version,
      legacy: merges and commit.legacy,
      built_from: if(merges, do: built_from(project, ticket), else: []),
      answered: if(merges, do: length(Artifacts.answered(ticket.id)), else: 0),
      # Left out when nothing was spent: `spent 0 windows` is a figure about nothing.
      spent: Format.spent(ticket.usage)
    }
  end

  @doc """
  What a merge of `ticket` will say, read the one way every place that decides it draws it — the
  approval's panel and the queue's approval item (`docs/design/ui.md` § Changes): nil when its
  approval does not merge; else the `commit-message` version, or nil and `legacy` when the ticket
  was pinned before merges carried a written message. `commit/1` draws it.
  """
  @spec commit(map()) :: %{ticket: map(), version: map() | nil, legacy: boolean()} | nil
  def commit(ticket) do
    if Engine.approval_merges?(ticket) do
      version = Merge.commit_message(ticket)

      %{
        ticket: ticket,
        version: version,
        legacy: is_nil(version) and Merge.legacy_message?(ticket)
      }
    end
  end

  @doc """
  What `commit/1` read, drawn: the message read-only through `WorkScreen.commit_message/1`, or for
  a legacy pin the sentence that says what the merge will write instead.
  """
  attr :commit, :map, required: true
  attr :id, :string, required: true

  def commit_block(%{commit: %{legacy: true}} = assigns) do
    ~H"""
    <section id={@id}>
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-ink-3">
        The commit it will make
      </h2>
      <p class="mt-2 text-sm/[1.55] text-ink-2">
        This ticket was pinned before merges carried a written message, so its merge says
        what earlier releases wrote.
      </p>
      <p class="mt-1 min-w-0 break-words font-mono text-[12.5px]/[1.55]">
        Merge {@commit.ticket.branch}: {@commit.ticket.title}
      </p>
    </section>
    """
  end

  def commit_block(assigns) do
    ~H"""
    <WorkScreen.commit_message version={@commit.version} id={@id} />
    """
  end

  # The approval as a press names it: its edge and the versions it pins. What the panel drew is
  # sent with Approve and Reject, and what waits when they arrive is read the same way.
  defp shown(pending, pins) do
    "#{pending["from"]}>#{pending["to"]}:" <>
      Enum.map_join(pins, ",", fn {name, version} -> "#{name}@#{version}" end)
  end

  # What waits now, as `shown` names it, with the versions that name was made from: one read,
  # so that the versions a press is checked against are the ones it then decides.
  defp waiting_now(%{pending_transition: nil}), do: nil

  defp waiting_now(ticket) do
    pins = pins_now(ticket)
    {shown(ticket.pending_transition, pins), Map.new(pins)}
  end

  defp pins_now(ticket) do
    for name <- Engine.awaiting_approval(ticket),
        version = Artifacts.latest(ticket.id, name),
        do: {name, version.version}
  end

  # A diff that could not be built has no size to draw.
  defp size(%{added: added, removed: removed}), do: %{added: added, removed: removed}
  defp size(_none), do: nil

  defp pin(project, ticket, name, version) do
    changeset? = name == Workflow.changeset_artifact()

    %{
      name: name,
      version: version.version,
      changeset: changeset?,
      at: version.inserted_at,
      href:
        if(not changeset?,
          do: ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{name}/#{version.version}"
        )
    }
  end

  # What the change was built from: every document on the ticket, at its latest version, but the
  # message the merge itself will carry, which is drawn whole below.
  defp built_from(project, ticket) do
    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :document,
        artifact.name != Workflow.commit_message_artifact(),
        version = Artifacts.latest(ticket.id, artifact.name),
        do: %{
          name: artifact.name,
          version: version.version,
          href:
            ~p"/tickets/#{project.name}/#{ticket.number}/artifacts/#{artifact.name}/#{version.version}"
        }
  end

  @doc """
  A chat step's Accept, or nil while it has nothing to accept (`ui.md` § The Accept area).
  `questions` are the ones the conversation's last reply left open; `answer` is where *Answer
  first* goes — nil on the conversation's own page, where folding the panel shows the question
  card.
  """
  @spec step(map() | nil, list(), String.t() | nil) :: map() | nil
  def step(step, questions, answer \\ nil) do
    if StepAccept.row?(step),
      do: %{kind: :step, step: step, questions: questions, answer: answer}
  end

  @doc """
  A chat's merge, or nil when there is nothing on its branch to merge: what the branch holds, its
  commits, the message the merge would carry, and whether it merges cleanly
  (`Forge.Merge.check_chat/1`, asked as the page loads).
  """
  @spec merge(map(), map()) :: map() | nil
  def merge(%{merged: true}, _chat), do: nil
  def merge(%{diff: %{files: [_ | _]}} = page, chat), do: merge_of(page, chat)
  def merge(_page, _chat), do: nil

  defp merge_of(page, chat) do
    conflict =
      case Merge.check_chat(chat) do
        {:conflict, paths} -> paths
        _clean_or_unknown -> nil
      end

    %{
      kind: :merge,
      chat: chat,
      project: page.project,
      diff: page.diff,
      commits: length(page.commits),
      head: Enum.map(page.commits, & &1.sha),
      commit_message: page.commit_message,
      conflict: conflict
    }
  end

  # -- events --------------------------------------------------------------------------------

  @doc """
  Handles a `decision:` event and returns `{:noreply, socket}` for the page to return. `reload`
  is the page's own, called after a decision and after every refusal of one, so the page draws
  what is true now.
  """
  @spec handle_event(
          String.t(),
          map(),
          Phoenix.LiveView.Socket.t(),
          (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket, reload),
    do: {:noreply, dispatch(event, params, socket, reload)}

  defp dispatch("decision:open", _params, socket, _reload),
    do: Component.assign(socket, decision_open: true, decision_error: nil)

  defp dispatch("decision:close", _params, socket, _reload),
    do: Component.assign(socket, decision_open: false, decision_error: nil)

  # The panel's form, on every change and on a rejoin: it exists only while the panel is open, so
  # a change is the panel open, with what it holds.
  defp dispatch("decision:change", params, socket, _reload) do
    Component.assign(socket,
      decision_open: true,
      decision_note: to_text(params["note"]),
      decision_pick: blank_to_nil(params["outcome"])
    )
  end

  # Approve or Reject. The ticket is read again rather than taken from the page, and what waits on
  # it now must be what the panel drew (`shown`): a press that arrives after someone else decided,
  # or after a newer version replaced what was read, decides nothing. Without the check, such a
  # press approved whatever was pending by then.
  @changed "What waits changed before your press arrived: it is now what is drawn here. " <>
             "Nothing was done."

  defp dispatch("decision:decide", params, socket, reload) do
    ticket = Tickets.get!(socket.assigns.ticket.id)
    pressed = params["shown"]

    case waiting_now(ticket) do
      # The versions the press was checked against go with it, from the same read, so the
      # operation decides those and only those: a version recorded after that read is refused
      # there, as stale. Passing nil instead is an equivalent mutant as far as a page test can
      # tell — it cannot record a version between the read and the decision — so the refusal is
      # tested on `Forge.Engine.decide/5` itself. Reading the pins a second time for `seen` is
      # the same kind of mutant, which no test can tell apart: what rules it out is that
      # `waiting_now/1` returns both from one read.
      {^pressed, seen} when pressed != nil ->
        decide(ticket, seen, params, socket, reload)

      nil ->
        socket
        |> reload.()
        |> refuse("Someone decided this before your press arrived. Nothing was done.")

      _other ->
        socket |> reload.() |> refuse(@changed)
    end
  end

  # No step on the page: the ticket left it before this press arrived, or the page is a plain
  # conversation's and the event was sent by hand. The page redraws; nothing is accepted.
  defp dispatch("decision:accept", _params, %{assigns: %{step: nil}} = socket, reload),
    do: socket |> decided() |> reload.()

  defp dispatch("decision:accept", params, socket, reload) do
    chat = socket.assigns.step.chat
    user = socket.assigns.current_scope.user
    # `|| decision_pick` is an equivalent mutant: the panel's form always carries `outcome`, as
    # a checked radio or the hidden input holding the pick (`ForgeWeb.Components.StepAccept`),
    # and a radio group with none checked leaves `decision_pick` nil too, since
    # `decision:change` read it from the same form. Dropping it changes nothing a form sends.
    outcome = blank_to_nil(params["outcome"]) || socket.assigns.decision_pick

    case Operator.accept_step(chat, user, outcome, seen(params["seen"])) do
      {:ok, ticket} ->
        socket
        |> decided()
        |> Toast.put("Accepted step #{chat.state}", Toast.started(ticket))
        |> reload.()

      {:error, reason} ->
        socket |> reload.() |> refuse(Steps.refusal(reason))
    end
  end

  # The second route into the default branch (`Forge.Operator.merge_chat/2`): a person pressing
  # Merge on a diff they can see.
  defp dispatch("decision:merge", _params, socket, reload) do
    %{chat: chat, project: project, current_scope: %{user: user}} = socket.assigns

    case Operator.merge_chat(chat, user) do
      {:ok, _result} ->
        socket
        |> decided()
        |> Toast.put("Merged #{branch(chat)}", "into #{project.default_branch}")
        |> reload.()

      {:conflict, paths} ->
        socket
        |> reload.()
        |> refuse("It does not merge cleanly: #{Enum.join(paths, ", ")}.")

      {:error, reason} ->
        socket |> reload.() |> refuse("Could not merge: #{Actions.describe(reason)}.")
    end
  end

  defp decide(ticket, seen, params, socket, reload) do
    decision = if params["decision"] == "rejected", do: :rejected, else: :approved
    user = socket.assigns.current_scope.user
    pinned = pinned_words(ticket)

    case Operator.decide(ticket, user, decision, params["note"], seen) do
      {:ok, moved} ->
        socket
        |> decided()
        |> Toast.put(decided_title(decision, pinned), decided_detail(decision, moved))
        |> reload.()

      {:error, {:stale, _names}} ->
        socket
        |> Component.assign(decision_note: to_text(params["note"]))
        |> reload.()
        |> refuse(@changed)

      {:error, reason} ->
        socket
        |> Component.assign(decision_note: to_text(params["note"]))
        |> reload.()
        |> refuse(Actions.describe(reason))
    end
  end

  # The commit message's first line, which a wide row carries inline (`18f`); the panel draws it
  # whole. Nothing for an approval that does not merge, or one with no message to carry.
  defp subject(%{merges: true, commit_message: %{content: content}}) do
    content |> ForgeCore.Document.body() |> String.trim() |> String.split("\n", parts: 2) |> hd()
  end

  defp subject(_decision), do: nil

  defp decided(socket) do
    Component.assign(socket,
      decision_open: false,
      decision_note: "",
      decision_pick: nil,
      decision_error: nil
    )
  end

  # A refusal, drawn after the page has reloaded — a reload that finds another decision drops what
  # the panel held (`put/2`), and the refusal must outlive it. In the panel of what waits now, or,
  # when nothing does, in place of the row (`gone/1`).
  defp refuse(%{assigns: %{decision: nil}} = socket, words),
    do: Component.assign(socket, decision_open: false, decision_error: words)

  defp refuse(socket, words),
    do: Component.assign(socket, decision_open: true, decision_error: words)

  defp pinned_words(ticket) do
    for name <- Engine.awaiting_approval(ticket),
        version = Artifacts.latest(ticket.id, name),
        do: "#{name} v#{version.version}"
  end

  defp decided_title(:approved, [one]), do: "Approved #{one}"
  defp decided_title(:approved, pins), do: "Approved #{length(pins)} versions"
  defp decided_title(:rejected, [one]), do: "Rejected #{one}"
  defp decided_title(:rejected, pins), do: "Rejected #{length(pins)} versions"

  defp decided_detail(:approved, ticket), do: Toast.started(ticket)
  defp decided_detail(:rejected, _ticket), do: "the note goes to the next job"

  # `%{"refinement.md" => "3"}` off the wire; a document the page drew as not written sends "".
  defp seen(%{} = fields) do
    for {name, value} <- fields, {version, ""} <- [Integer.parse(to_string(value))], into: %{} do
      {name, version}
    end
  end

  defp seen(_none), do: %{}

  defp to_text(text) when is_binary(text), do: text
  defp to_text(_none), do: ""

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp branch(chat), do: "chat/" <> String.slice(chat.id, 0, 8)

  # -- drawing -------------------------------------------------------------------------------

  attr :decision, :map, required: true, doc: "`approval/3`, `step/3` or `merge/2`"
  attr :open, :boolean, default: false
  attr :note, :string, default: ""
  attr :pick, :string, default: nil
  attr :error, :string, default: nil

  attr :tab, :string,
    default: nil,
    doc:
      "the view the page is on: a conflicting merge's Resolve is not drawn on Changes, its target"

  @doc """
  The row, pinned under the top bar on every view of the object, and while `open` the panel it
  drops: what happens and where the ticket goes, what it pins or commits, any warning, then the
  secondary act and the primary.
  """
  def row(%{decision: %{kind: :approval}} = assigns) do
    d = assigns.decision

    assigns =
      assign(assigns,
        label: Enum.map_join(d.pins, " · ", &"#{&1.name} v#{&1.version}"),
        changeset: Enum.find(d.pins, & &1.changeset),
        blank: String.trim(assigns.note) == "",
        approvable: not (d.merges and is_nil(d.commit_message) and not d.legacy),
        subject: subject(d)
      )

    ~H"""
    <.frame_row open={@open} kind={if @changeset, do: "changeset", else: "doc"} action="Approve">
      <:title>
        {@label}
        <.diff_stat
          :if={@changeset && @decision.diff}
          added={@decision.diff.added}
          removed={@decision.diff.removed}
        />
      </:title>
      <:meta>
        {@decision.from} → {@decision.to}{written(@decision.pins)}<span
          :if={@subject}
          id="decision-will-commit"
          class="decision-commit"
        ><span class="decision-commit-label">will commit</span> {@subject}</span>
      </:meta>
      <.drop_panel
        id="decision-panel"
        title={"Approve #{@label}"}
        body={approval_body(@decision)}
        on_close="decision:close"
      >
        <form id="decision-form" phx-change="decision:change" phx-submit="decision:decide">
          <div class="flex flex-col gap-3">
            <ul :if={Enum.any?(@decision.pins, & &1.href)} id="decision-pins" class="flex flex-col">
              <li :for={pin <- @decision.pins} :if={pin.href}>
                <.link
                  href={pin.href}
                  class="flex min-h-[46px] items-center gap-2 font-mono text-[12.5px] text-link"
                >
                  Read {pin.name} v{pin.version} ›
                </.link>
              </li>
            </ul>

            <%!-- What the merge is built from, beside it (`decisions.md`): the documents, the
                  questions a person answered and what the ticket cost. --%>
            <%!-- Built from is the one fact here a reviewer reads closely: each version on a
                  line of its own and linked to it, never cut by an ellipsis (UX pass, B12). --%>
            <.fact_list :if={@decision.merges} id="decision-built-from">
              <:fact :if={@decision.built_from != []} label="built from">
                <.link
                  :for={doc <- @decision.built_from}
                  href={doc.href}
                  class="decision-built-from-doc"
                >
                  {doc.name} v{doc.version}
                </.link>
              </:fact>
              <:fact label="answered">{answered(@decision.answered)}</:fact>
              <:fact :if={@decision.spent} label="spent">{@decision.spent}</:fact>
            </.fact_list>

            <%!-- What the merge will commit, read-only, above the control that approves it. --%>
            <.commit_block
              :if={@decision.commit}
              commit={@decision.commit}
              id={ForgeWeb.Operator.Components.commit_message_id(@decision.ticket)}
            />

            <%!-- *Note*, not *Note, optional*: beside "required to reject" the label contradicted
                  its own hint (UX pass, A18). --%>
            <.input
              id="decision-note"
              name="note"
              value={@note}
              multiline
              label="Note"
              hint="Needed to reject. Kept with the decision either way."
            />

            <.refusal error={@error} />

            <%!-- Which approval this press is on (`dispatch/4`'s "decision:decide"). --%>
            <input type="hidden" name="shown" value={@decision.shown} />

            <div class="ui-drop-actions">
              <.button
                type="submit"
                name="decision"
                value="rejected"
                variant="danger"
                disabled={@blank}
                phx-disable-with="Rejecting…"
              >
                Reject
              </.button>
              <.button
                :if={@approvable}
                type="submit"
                name="decision"
                value="approved"
                variant="decision"
                diamond={false}
                fill
                phx-disable-with="Approving…"
              >
                {approve_label(@decision.pins)}
              </.button>
            </div>
          </div>
        </form>
        <.fold />
      </.drop_panel>
    </.frame_row>
    """
  end

  def row(%{decision: %{kind: :step}} = assigns) do
    %{step: step, questions: questions} = assigns.decision
    picked = StepAccept.effective_pick(step, assigns.pick)

    assigns =
      assign(assigns,
        step: step,
        picked: picked,
        to: StepAccept.target(step, picked),
        title: step_title(step),
        asked: length(questions)
      )

    ~H"""
    <.frame_row open={@open} kind="doc" action="Accept" disabled={@step.in_flight}>
      <:title>{@title}</:title>
      <:meta>{step_meta(@step)}</:meta>
      <.drop_panel
        id="decision-panel"
        title={"Accept step #{@step.state}"}
        body={StepAccept.summary(@step, @picked)}
        on_close="decision:close"
      >
        <:warning :if={@asked > 0} title={unanswered(@asked)}>
          <span :for={question <- @decision.questions} class="block">“{question.text}”</span>
          <span class="mt-1 block">
            {@to || "The next state"} starts from the documents as written. Answer first if they
            should change.
          </span>
        </:warning>
        <form id="decision-form" phx-change="decision:change" phx-submit="decision:accept">
          <div class="flex flex-col gap-3">
            <StepAccept.panel step={@step} pick={@pick} />

            <.refusal error={@error} />

            <div class="ui-drop-actions">
              <.button
                :if={@asked > 0 and @decision.answer}
                navigate={@decision.answer}
                variant="secondary"
              >
                Answer first
              </.button>
              <.button
                :if={@asked > 0 and is_nil(@decision.answer)}
                type="button"
                variant="secondary"
                phx-click="decision:close"
              >
                Answer first
              </.button>
              <.button :if={@asked == 0} type="button" variant="quiet" phx-click="decision:close">
                Cancel
              </.button>
              <.button
                :if={@step.ready}
                type="submit"
                variant="decision"
                diamond={false}
                fill
                disabled={is_nil(@picked)}
                phx-disable-with="Accepting…"
              >
                {accept_label(@picked, @asked)}
              </.button>
            </div>
          </div>
        </form>
        <.fold />
      </.drop_panel>
    </.frame_row>
    """
  end

  def row(%{decision: %{kind: :merge}} = assigns) do
    ~H"""
    <%!-- With no message written there is nothing to merge yet, and the row says so with no
          button to press: the merge would be refused (`conversations.md` § Commits). --%>
    <%!-- A conflict turns the button into Resolve, which goes straight to the two ways out on
          Changes (`15c`): a panel with a disabled Merge and a link to them was two taps more,
          named after an act that would be refused (UX pass, B7). --%>
    <%!-- On Changes itself it would lead where it stands, above the ways out it points at: there
          the row states the conflict and draws no button (UX re-check #11). --%>
    <.frame_row
      open={@open and is_nil(@decision.conflict)}
      kind="branch"
      action={merge_action(@decision.conflict, @tab)}
      tone="neutral"
      disabled={is_nil(@decision.commit_message)}
      patch={@decision.conflict && ~p"/chats/#{@decision.chat.id}?tab=changes"}
    >
      <:title>
        {branch(@decision.chat)}
        <.diff_stat added={@decision.diff.added} removed={@decision.diff.removed} />
      </:title>
      <:meta>
        {commits(@decision.commits)} ·
        <span :if={is_nil(@decision.commit_message)} id="decision-unwritten">
          nothing to merge yet: no commit message is written
        </span>
        <span :if={@decision.conflict} id="decision-conflict" class="text-danger">
          conflicts with {@decision.project.default_branch} in {Enum.join(
            @decision.conflict,
            ", "
          )}
        </span>
        <span :if={@decision.commit_message && !@decision.conflict}>
          merges cleanly into {@decision.project.default_branch}
        </span>
      </:meta>
      <.drop_panel
        id="decision-panel"
        title={"Merge #{branch(@decision.chat)} into #{@decision.project.default_branch}"}
        body="Commits what the branch holds to the default branch, under the message below. Nobody is waiting on this."
        on_close="decision:close"
      >
        <form id="decision-form" phx-change="decision:change" phx-submit="decision:merge">
          <div class="flex flex-col gap-3">
            <%!-- Read-only, above the control that merges (`conversations.md` § Commits). --%>
            <WorkScreen.commit_message
              version={@decision.commit_message}
              id="chat-commit-message"
            />

            <.refusal error={@error} />

            <div class="ui-drop-actions">
              <.button type="button" variant="quiet" phx-click="decision:close">Cancel</.button>
              <.button
                :if={@decision.commit_message}
                type="submit"
                variant="neutral"
                fill
                phx-disable-with="Merging…"
              >
                Merge
              </.button>
            </div>
          </div>
        </form>
        <.fold />
      </.drop_panel>
    </.frame_row>
    """
  end

  attr :error, :string, required: true

  @doc """
  A refusal with no decision left to draw it in: a press that arrived after the decision went.
  Drawn where the row was, until it is dismissed or another decision takes its place
  (`docs/design/ui.md` § Errors stay where you acted).
  """
  def gone(assigns) do
    ~H"""
    <div id="decision-gone" class="flex items-center gap-3 px-4 py-2">
      <.error_note class="flex-1">{@error}</.error_note>
      <.button type="button" variant="quiet" phx-click="decision:close">Dismiss</.button>
    </div>
    """
  end

  defp merge_action(nil, _tab), do: "Merge"
  defp merge_action(_conflict, "changes"), do: nil
  defp merge_action(_conflict, _tab), do: "Resolve"

  attr :open, :boolean, required: true
  attr :kind, :string, required: true
  attr :action, :string, required: true, doc: "the button's word, or nil for no button"
  attr :tone, :string, default: "accent"
  attr :disabled, :boolean, default: false
  attr :patch, :string, default: nil
  attr :rest, :global
  slot :title, required: true
  slot :meta
  slot :inner_block

  # The row, with Escape folding its panel while it is open.
  defp frame_row(assigns) do
    ~H"""
    <.decision_row
      id="decision-row"
      kind={@kind}
      action={@action}
      tone={@tone}
      open={@open}
      patch={@patch}
      disabled={@disabled}
      on_toggle={if @open, do: "decision:close", else: "decision:open"}
      phx-window-keydown={@open && "decision:close"}
      phx-key={@open && "Escape"}
    >
      <:title>{render_slot(@title)}</:title>
      <:meta>{render_slot(@meta)}</:meta>
      {render_slot(@inner_block)}
    </.decision_row>
    """
  end

  attr :error, :string, default: nil

  # A refusal, where the person acted (`ui.md` § Errors stay where you acted).
  defp refusal(assigns) do
    ~H"""
    <.error_note :if={@error} id="decision-error">
      {@error}
    </.error_note>
    """
  end

  defp fold(assigns) do
    ~H"""
    <button type="button" class="frame-handle" phx-click="decision:close" aria-label="Fold">
      <span aria-hidden="true" />
    </button>
    """
  end

  defp approval_body(decision) do
    "Moves ##{decision.ticket.number} from #{decision.from} to #{decision.to}." <>
      if decision.merges,
        do: " Entering #{decision.to} merges it into #{decision.project.default_branch}.",
        else: ""
  end

  # The age alone: `written just …` cut the one word that mattered (UX re-check #19).
  defp written([%{changeset: false, at: at}]), do: " · #{Format.ago_phrase(at)}"
  defp written(_pins), do: ""

  # Until an outcome is picked the button says why it does nothing, rather than naming an act it
  # cannot take (UX pass, B20).
  defp accept_label(nil, _asked), do: "Pick an outcome"
  defp accept_label(_picked, 0), do: "Accept"
  defp accept_label(_picked, _asked), do: "Accept anyway"

  defp approve_label([%{version: version}]), do: "Approve v#{version}"
  defp approve_label(pins), do: "Approve #{length(pins)} versions"

  defp answered(0), do: "no questions"
  defp answered(1), do: "1 question"
  defp answered(n), do: "#{n} questions"

  defp commits(1), do: "1 commit"
  defp commits(n), do: "#{n} commits"

  @doc "The panel's warning when a step is accepted with its questions open."
  @spec unanswered(pos_integer()) :: String.t()
  def unanswered(1), do: "1 open question will stay unanswered"
  def unanswered(n), do: "#{n} open questions will stay unanswered"

  # The step's own document with the newest version, as the row names it, and how many more.
  defp step_title(%{documents: documents, state: state}) do
    case Enum.filter(documents, &(&1.own and &1.version)) do
      [] -> "step #{state}"
      [doc] -> "#{doc.name} v#{doc.version}"
      [doc | rest] -> "#{doc.name} v#{doc.version} +#{length(rest)}"
    end
  end

  defp step_meta(%{in_flight: true}), do: "waiting for the reply to finish"

  defp step_meta(%{dormant: true, state: state}),
    do: "step #{state} · the conversation has stopped"

  defp step_meta(%{state: state, visit: visit}), do: "step #{state} · visit #{visit}"
end
