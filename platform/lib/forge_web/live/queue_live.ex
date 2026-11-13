defmodule ForgeWeb.QueueLive do
  @moduledoc """
  The home screen: everything waiting on you, **one item per screen, oldest first**, in a pass
  that ends somewhere definite (`docs/design/ui.md` § The queue).

  An item is **one interruption, not one question**: a job that stops inside a document
  typically stops with several questions, and one item per question would turn three decisions
  into twenty with identical timestamps. `Forge.Queue` keeps its per-question shape, because the
  JSON API and the CLI are built on it; the grouping is this page's presentation.

  Each item is drawn in the same order: an eyebrow naming its kind with its age, the sentence
  saying what is asked, the ticket's context — its track, its facts and what happened since this
  person last opened it — what is particular to its kind, and at the foot **Later** and its way
  on. Questions put what the agent said before the context, since it is what they are about. **The queue never decides in place**: an approval leads to the ticket's decision row, beside
  what it approves; a document's questions are answered in the question card; a stuck ticket's
  ways forward are choice rows and a dock button that takes the one picked. Deciding moves the
  pass on in place, without a navigation (`ForgeWeb.QueuePass` holds the pass's rules).

  The whole queue is the **All** sheet on a phone and the list column from 768px — every item in
  the pass's order, decided ones dimmed with `✓` — and beneath the items, two groups that wait
  on nobody and count towards nothing: **Not waiting on you**, the questions agents did not stop
  for (`docs/design/ui.md` § Not waiting on you), and **Under way**, the tickets whose work is on
  a machine or waiting for one, read from `Queue.worker_status/1` rather than `Queue.items/1`
  (§ A job waiting for a machine). A ticket the spend cap or a rate-limited pool holds is in
  neither: `worker_status/1` drops it, as `docs/design/capacity.md` keeps a paused ticket out of
  the queue entirely. An assumption asked in the same document as a blocking question is in that
  document's card instead, optional (§ The question card).
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1, split_pane: 1]

  alias Forge.{Artifacts, Engine, Events, Jobs, Projects, Queue, Tickets}
  alias Forge.Tickets.Views
  alias ForgeCore.Workflow
  alias ForgeWeb.{Diff, Format, PushEvents, QueuePass, Topology}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Drafts
  alias ForgeWeb.Operator.QuestionForm

  # How much of what happened since the last look the context draws: the newest, so a ticket not
  # opened in a month is not read whole.
  @since 8

  @impl true
  # No subscription of its own: every ticket change is announced to the frame's queue topic too
  # (`Forge.Events.notify/1`), which the frame filters by the viewer's projects and throttles,
  # and the frame reloads this page on it (`ForgeWeb.Frame.follow/3`) — one read of the queue
  # per change, not one for the frame and another per ticket change.
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> PushEvents.init()
     |> assign(
       page_title: "Queue",
       forms: QuestionForm.init(),
       refusal: nil,
       drafts: Drafts.init(),
       ways: %{},
       pass: nil
     )
     # The queue button's signals reload this page too, so its count moves with the button's —
     # and is the button's, read once (`ForgeWeb.Frame.follow/3`).
     |> ForgeWeb.Frame.follow(&load/1, & &1.assigns.decisions)
     |> load()}
  end

  # `?item=` is where *All*, the list column and *Back to it* lead: the pass shows that item, or
  # with `end` the end. A patch, so the sheet closes as on any other link and nothing remounts.
  @impl true
  def handle_params(%{"item" => key}, _uri, socket) when is_binary(key),
    do: {:noreply, socket |> update(:pass, &QueuePass.jump(&1, key)) |> detail()}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # The decisions are grouped and counted; the assumptions are the digest, in the order
  # `Forge.Queue` gives them, and count towards nothing — see docs/design/ui.md § Not waiting on
  # you. An assumption asked in the same document as a blocking question joins that question's
  # card instead, optional, because it was asked in the same breath (§ The question card).
  defp load(socket) do
    user = socket.assigns.current_scope.user

    queue = Queue.items(user)
    accounts = Queue.waiting_accounts(user)
    {waiting, assumed} = queue |> named_projects() |> Enum.split_with(&Queue.waiting?/1)

    {joined, digest} =
      waiting
      |> Enum.filter(&(&1.kind == :question))
      |> QuestionForm.join_assumed(assumed, & &1.question.artifact_version_id)

    items = (waiting ++ joined ++ accounts_item(accounts)) |> group() |> Enum.map(&decorate/1)

    pass =
      case socket.assigns.pass do
        nil -> QueuePass.new(items, & &1.key)
        pass -> QueuePass.merge(pass, items, & &1.key)
      end

    socket
    |> assign(
      pass: pass,
      digest: digest,
      under_way: user |> Queue.worker_status() |> named_projects(),
      # The queue button's count, computed by the same function over the same reads
      # (`Forge.Queue.count/2`): an item decided in this pass is no longer waiting once it is read
      # again, so it is not counted, and one decided elsewhere is not either.
      decisions: Queue.count(queue, accounts),
      now: DateTime.utc_now()
    )
    |> detail()
  end

  # The accounts waiting on a node admin, as one item (UX pass, A23): they are counted as decisions
  # on the queue button, so the queue lists them where the count says they are, and its way on is
  # the Accounts page, where each is decided. Waiting since the oldest of them signed up.
  defp accounts_item(0), do: []

  defp accounts_item(count) do
    oldest = List.first(Forge.Accounts.list_pending_users())

    [
      %{
        kind: :accounts,
        ticket: nil,
        project: nil,
        count: count,
        since: (oldest && oldest.inserted_at) || DateTime.utc_now(:second),
        detail: %{}
      }
    ]
  end

  # Every list this page draws takes the project as its name; the item on screen reads the
  # project's struct again where it needs one.
  defp named_projects(items), do: Enum.map(items, &Map.put(&1, :project, &1.project.name))

  # One job, stopped, against one artifact version, carrying N questions. Everything else is
  # already one interruption on its own. `load/1` only passes an assumption here when a blocking
  # question shares its version, so every group holds at least one of those.
  defp group(items) do
    {questions, rest} = Enum.split_with(items, &(&1.kind in [:question, :assumption]))

    questions
    |> Enum.group_by(& &1.question.artifact_version_id)
    |> Enum.map(fn {_version_id, group} ->
      first = hd(group)

      %{
        kind: :questions,
        ticket: first.ticket,
        project: first.project,
        # When it started waiting, which the blocking questions say. Taking the assumptions too is
        # an equivalent mutant as documents are recorded: a version's questions share one insert.
        since:
          group
          |> Enum.filter(&(&1.kind == :question))
          |> Enum.map(& &1.since)
          |> Enum.min(DateTime),
        questions: Enum.map(group, & &1.question),
        version: first.question.artifact_version,
        detail: %{}
      }
    end)
    |> Enum.concat(rest)
    |> Enum.sort_by(& &1.since, DateTime)
  end

  @changeset Workflow.changeset_artifact()

  defp decorate(item) do
    item = item |> Map.put_new(:questions, []) |> Map.put_new(:version, nil)

    item
    |> Map.put(:key, key(item))
    |> Map.put(:track, track(item.ticket))
    |> put_approve()
  end

  # What keeps an item one item across reads of the queue: the version its questions are on, the
  # conversation, or the ticket and the kind it waits as.
  defp key(%{kind: :questions, version: version}), do: "questions-#{version.id}"
  defp key(%{kind: :chat, detail: detail}), do: "chat-#{detail.chat_id}"
  defp key(%{kind: :accounts}), do: "accounts"
  defp key(%{kind: kind, ticket: ticket}), do: "#{kind}-#{ticket.id}"

  # The ticket's workflow as a track — its states in the order it reaches them, the current one
  # amber, the one a pending approval leads to next — or nil: a conversation about a project has
  # no workflow, and a pin that no longer parses has none to read.
  defp track(nil), do: nil

  defp track(ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} ->
        steps = Topology.order(workflow)

        %{
          steps: steps,
          current: Enum.find_index(steps, &(&1 == ticket.state)) || 0,
          to: pending_to(ticket, steps)
        }

      {:error, _errors} ->
        nil
    end
  end

  defp pending_to(%{pending_transition: %{"to" => to}}, steps),
    do: Enum.find_index(steps, &(&1 == to))

  defp pending_to(_ticket, _steps), do: nil

  # What an approval pins, by name and version, for its link: the decision is on the ticket.
  defp put_approve(%{kind: :approval, ticket: ticket} = item) do
    approve =
      for name <- Engine.awaiting_approval(ticket),
          version = Artifacts.latest(ticket.id, name),
          do: {name, version.version}

    Map.put(item, :approve, approve)
  end

  defp put_approve(item), do: Map.put(item, :approve, [])

  # -- the item on screen ------------------------------------------------------------------------

  # What only the item on screen draws, read for it alone: the ticket's facts, what happened since
  # this person last opened it, its documents, and what its kind needs — a changeset's size and
  # the message the merge will write, what the agent said when it stopped, a stuck ticket's last
  # attempt. Read again on every load, so it is current, and never for the other items.
  defp detail(socket) do
    item = QueuePass.current(socket.assigns.pass)
    assign(socket, item: item, detail: item && read_detail(item, socket))
  end

  defp read_detail(%{ticket: nil}, _socket), do: %{}

  defp read_detail(%{ticket: stale} = item, socket) do
    user = socket.assigns.current_scope.user
    ticket = Tickets.get!(stale.id)
    project = Projects.get!(ticket.project_id)
    jobs = Jobs.for_ticket(ticket.id)
    looked = user |> Views.since([ticket.id]) |> Map.get(ticket.id)

    %{
      ticket: ticket,
      facts: facts(ticket, jobs),
      looked: looked,
      since: Views.events_since(ticket.id, looked, @since),
      documents: documents(ticket)
    }
    |> Map.merge(kind_detail(item, project, ticket, jobs))
  end

  # Nothing spent is left out rather than drawn as `0 windows`: a fact that says nothing is a
  # token every card carries for no reason (UX pass, A11).
  defp facts(ticket, jobs) do
    spent = Format.spent(ticket.usage)
    jobs = Format.counted(length(jobs), "job")

    [
      "#{ticket.state} · visit #{Tickets.visit(ticket)}",
      if(spent, do: "#{jobs} · #{spent}", else: jobs),
      "admitted " <> Format.ago_phrase(ticket.inserted_at)
    ]
  end

  defp said_ago(at, now), do: Format.ago_phrase(at, now)

  defp documents(ticket) do
    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :document,
        not Workflow.proposal?(artifact.name),
        latest = Artifacts.latest(ticket.id, artifact.name),
        do: %{name: artifact.name, version: latest.version}
  end

  defp kind_detail(%{kind: :approval}, project, ticket, _jobs),
    do: %{diff: changeset(project, ticket), commit: ForgeWeb.Operator.Decision.commit(ticket)}

  defp kind_detail(%{kind: :questions, version: version}, _project, _ticket, _jobs) do
    case version.author do
      %{"kind" => "job", "id" => job_id} ->
        %{agent: Jobs.last_words(%Forge.Jobs.Job{id: job_id}), job_id: job_id}

      _other ->
        %{agent: nil, job_id: nil}
    end
  end

  defp kind_detail(%{kind: :stuck}, _project, ticket, jobs) do
    here = Enum.filter(jobs, &(&1.state == ticket.state))
    last = List.last(here)

    %{
      attempts: length(here),
      last: last,
      excerpt: last && excerpt(last),
      closing: last && Jobs.last_words(last),
      budget: budget(ticket)
    }
  end

  defp kind_detail(_item, _project, _ticket, _jobs), do: %{}

  # The change the merge would make, as files and lines, or nil when the branch is not there.
  defp changeset(project, ticket) do
    repo = Projects.repo_path(project)

    with {:ok, head} <- Forge.Git.resolve(repo, "refs/heads/" <> ticket.branch),
         %{files: files, added: added, removed: removed} <-
           Diff.build(repo, ticket.base_commit, head) do
      %{added: added, removed: removed, files: files}
    else
      _none -> nil
    end
  end

  # Why the last attempt ended, as the engine recorded it: its words, cut to what a glance reads.
  defp excerpt(job) do
    case Events.latest_for_job(job.id, "job.finished") do
      %{payload: %{"reason" => reason}} when is_binary(reason) and reason != "" ->
        String.slice(reason, 0, 400)

      _none ->
        nil
    end
  end

  defp budget(ticket) do
    with {:ok, workflow} <- Tickets.parsed_workflow(ticket),
         %{budget: %{} = budget} <- Workflow.state(workflow, ticket.state) do
      budget
    else
      _none -> nil
    end
  end

  # -- events ------------------------------------------------------------------------------------

  @impl true
  # This browser's push subscription: one head each, so the inventory can read them
  # (`authorization_inventory_test.exs`), all handled by `ForgeWeb.PushEvents`.
  def handle_event("push:subscribe" = event, params, socket), do: push(event, params, socket)
  def handle_event("push:unsubscribe" = event, params, socket), do: push(event, params, socket)
  def handle_event("push:error" = event, params, socket), do: push(event, params, socket)

  def handle_event(event, params, socket), do: dispatch(event, params, socket)

  # Later: to the end of the pass, nothing recorded.
  defp dispatch("queue:later", _params, socket),
    do: {:noreply, socket |> update(:pass, &QueuePass.later/1) |> detail()}

  # The way forward picked, kept by the page so a re-render or a rejoin does not lose it.
  defp dispatch("queue:pick", %{"ticket" => id, "way" => way}, socket)
       when is_binary(id) and is_binary(way),
       do: {:noreply, update(socket, :ways, &Map.put(&1, id, way))}

  # A way forward taken: the same operation the ticket's page takes, through `Actions`, which
  # resolves the ticket off the wire and refuses a non-member (`Forge.Operator`).
  defp dispatch("queue:way", %{"ticket" => id, "way" => "retry"}, socket),
    do: deciding("retry", %{"ticket" => id}, socket)

  defp dispatch("queue:way", %{"ticket" => id, "way" => "to:" <> to}, socket),
    do: deciding("transition", %{"ticket" => id, "to" => to}, socket)

  defp dispatch(event, params, socket) when event in ["questions:send", "chat:questions:send"],
    do: deciding(event, params, socket)

  # A chat's questions are answered here with the card its page draws, sent as one message by
  # `Operator.answer_chat/4` — which resolves the chat off the wire and refuses a non-member, the
  # hole a review once found in this page's answer buttons. Nothing is written to `answers`: the
  # transcript is already the record.
  defp dispatch(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  # An event that decides the item on screen. Taken, the item is decided and the pass moves on in
  # place; refused, the item stays with the refusal in words, drawn where it was sent from.
  # `Actions` leaves `:refusal` for a refusal and only for one, clearing it first.
  defp deciding(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} ->
        socket =
          if socket.assigns.refusal,
            do: socket,
            else: update(socket, :pass, &QueuePass.decide/1)

        {:noreply, load(socket)}

      {:state, socket} ->
        {:noreply, socket}

      :unknown ->
        {:noreply, socket}
    end
  end

  # -- drawing -----------------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    pass = assigns.pass
    left = QueuePass.left(pass)

    assigns =
      assign(assigns,
        rows: Enum.map(pass.order, &Map.fetch!(pass.items, &1)),
        left: left
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Queue"
      subline={subline(@pass, @decisions)}
      top_level={:queue}
      context={@rows != [] && {"All #{length(@rows)}", open_sheet("queue-all")}}
      measure="38rem"
    >
      <:list>
        <div id="queue-list" class="queue-list">
          <%!-- The header's switch, its Queue link and the title row already say Queue: the
                column names what it lists, with no fourth "Queue" (UX pass, A6). --%>
          <div class="queue-list-head">
            <span class="queue-list-count">{@decisions} {noun(@decisions, "decision")}</span>
            <button
              :if={@push_key}
              id="push-toggle"
              type="button"
              class="queue-notify"
              phx-hook="PushSubscribe"
              data-vapid-key={@push_key}
            >
              <span data-label>Notify me</span>
            </button>
          </div>
          <.error_note :if={@push_error} id="push-error">{@push_error}</.error_note>
          <div id="queue-decisions" class="queue-rows">
            <.row :for={item <- @rows} id={"item-#{item.key}"} item={item} pass={@pass} now={@now} />
          </div>
          <.digest digest={@digest} now={@now} />
          <.under_way under_way={@under_way} now={@now} />
        </div>
      </:list>

      <:aside :if={@item && @item.ticket}>
        <div id="queue-aside" class="queue-aside">
          <.context item={@item} detail={@detail} me={@current_scope.user.id} wide />
        </div>
      </:aside>

      <:composer :if={@item}>
        <.dock item={@item} forms={@forms} ways={@ways} refusal={@refusal} />
      </:composer>

      <div class="queue-page">
        <.item
          :if={@item}
          item={@item}
          detail={@detail}
          ways={@ways}
          now={@now}
          me={@current_scope.user.id}
        />
        <%!-- A way taken from an item that has gone since: said where the item stood. --%>
        <Actions.refused
          :if={!@item}
          id="queue-refusal"
          refusal={@refusal}
          at={~w(retry transition)}
        />
        <.ending :if={!@item} pass={@pass} left={@left} now={@now} />
      </div>

      <.sheet id="queue-all" label="Every item in the queue" title={sheet_title(@rows, @decisions)}>
        <div class="queue-sheet">
          <.row
            :for={item <- @rows}
            id={"all-item-#{item.key}"}
            item={item}
            pass={@pass}
            now={@now}
          />
          <.link :if={@under_way != []} patch={~p"/?item=end"} class="queue-sheet-quiet">
            Under way · {length(@under_way)}
          </.link>
          <.link :if={@digest != []} patch={~p"/?item=end"} class="queue-sheet-quiet">
            Not waiting on you · {length(@digest)}
          </.link>
        </div>
      </.sheet>
    </Layouts.app>
    """
  end

  # An empty pass is nothing waiting: accounts waiting on a node admin are an item of their own.
  defp subline(%QueuePass{order: []}, _decisions), do: "nothing waiting"

  defp subline(%QueuePass{current: nil}, decisions),
    do: "done · #{decisions} #{noun(decisions, "decision")} left"

  defp subline(pass, decisions),
    do:
      "#{QueuePass.position(pass)} of #{length(pass.order)} · " <>
        "#{decisions} #{noun(decisions, "decision")}"

  defp sheet_title(rows, decisions),
    do:
      "#{length(rows)} #{noun(length(rows), "item")} · #{decisions} #{noun(decisions, "decision")}"

  attr :id, :string, required: true
  attr :item, :map, required: true
  attr :pass, :map, required: true
  attr :now, :any, required: true

  # One item as a row of the whole queue — the list column and the *All* sheet draw the same —
  # leading to it in the pass. Decided ones stay, dimmed, with `✓`; the one on screen is marked.
  defp row(assigns) do
    assigns =
      assign(assigns,
        decided: QueuePass.decided?(assigns.pass, assigns.item.key),
        on: assigns.pass.current == assigns.item.key
      )

    ~H"""
    <.list_row
      id={@id}
      patch={~p"/?item=#{@item.key}"}
      title={row_title(@item)}
      kicker={kind(@item)}
      age={Format.ago(@item.since, @now)}
      latest={row_latest(@item)}
      latest_tone={if @item.kind == :stuck, do: "accent"}
      edge={if !@decided, do: "accent"}
      selected={@on}
      data-decided={@decided}
    >
      <:meta>{row_meta(@item)}</:meta>
      <:trailing :if={@decided}>
        <span class="queue-row-tick" aria-label="decided">✓</span>
      </:trailing>
    </.list_row>
    """
  end

  defp row_title(%{kind: kind} = item) when kind in [:chat, :accounts], do: sentence(item)
  defp row_title(item), do: item.ticket.title

  defp row_meta(%{kind: :accounts}), do: "this node"
  defp row_meta(%{ticket: nil, project: project}), do: "#{project} · chat"

  defp row_meta(%{ticket: ticket, project: project}),
    do: "#{project}##{ticket.number} · #{ticket.state}"

  defp row_latest(%{kind: :stuck, detail: %{reason: reason}}) when is_binary(reason), do: reason
  defp row_latest(%{kind: :approval} = item), do: "→ #{item.detail["to"]}"

  defp row_latest(%{kind: :questions, version: version}),
    do: "#{version.artifact.name} v#{version.version}"

  defp row_latest(_item), do: nil

  attr :item, :map, required: true
  attr :detail, :map, required: true
  attr :ways, :map, required: true
  attr :now, :any, required: true
  attr :me, :string, required: true

  defp item(assigns) do
    ~H"""
    <article id="queue-item" data-key={@item.key} class="queue-item">
      <div class="queue-eyebrow">
        <.eyebrow tone="accent">{kind_label(@item)}</.eyebrow>
        <span class="queue-age">waiting {Format.lasted(@item.since, @now)}</span>
      </div>

      <p class="queue-sentence">{sentence(@item)}</p>

      <%!-- Answered on another device or decided from the ticket while on screen: it stays drawn
            until the person moves on, and what it offers is refused in words if sent
            (`docs/design/ui.md` § The queue). --%>
      <.notice :if={@item[:gone]} id="queue-gone" tone="neutral" title="No longer waiting on you">
        It was answered or decided somewhere else. Later moves on.
      </.notice>

      <%!-- What the agent said comes before the ticket's card: it is the passage the questions are
            about, and on a phone the card under it would push it beneath the question card's
            split pane (UX pass, A1). --%>
      <.agent :if={@item.kind == :questions} item={@item} detail={@detail} now={@now} />

      <div :if={@item.ticket} class="queue-band">
        <.context item={@item} detail={@detail} me={@me} />
      </div>

      <.approval :if={@item.kind == :approval} detail={@detail} />
      <.stuck :if={@item.kind == :stuck} item={@item} detail={@detail} />
      <.ways :if={@item.kind in [:stuck, :review]} item={@item} ways={@ways} />
      <.chat_reply :if={@item.kind == :chat} item={@item} />
    </article>
    """
  end

  attr :item, :map, required: true
  attr :detail, :map, required: true
  attr :me, :string, required: true, doc: "the viewer's id: their own words are `you`"
  attr :wide, :boolean, default: false

  # The ticket the item is about (`data/ContextCard`): its number and title, its type, its track
  # with the step the decision leads to, and its facts — then, from 768px, what happened since this
  # person last looked and the documents in play. Drawn in the item below 1440px and in the
  # context column from there; only the item's copy carries ids.
  defp context(assigns) do
    ~H"""
    <.context_card
      ref={"#{@item.project}##{@item.ticket.number}"}
      title={@item.ticket.title}
      type={@item.ticket.ticket_type}
      steps={@item.track && @item.track.steps}
      current={(@item.track && @item.track.current) || 0}
      next={@item.track && @item.track.to}
      facts={@detail[:facts] || []}
      navigate={~p"/tickets/#{@item.project}/#{@item.ticket.number}"}
      waiting
    />

    <section id={!@wide && "queue-since"} class="queue-since">
      <div class="queue-since-head">
        <.eyebrow>Since you last looked</.eyebrow>
        <span :if={@detail[:looked]} class="queue-since-at">{Format.ago(@detail.looked)}</span>
      </div>
      <p :if={@detail[:since] == []} class="queue-quiet">Nothing has happened since.</p>
      <ol class="queue-since-list">
        <li :for={event <- @detail[:since] || []} class="queue-since-line">
          <span class="queue-since-age">{Format.ago(event.inserted_at)}</span>
          <span>{since_line(event, @me)}</span>
        </li>
      </ol>
    </section>

    <section :if={(@detail[:documents] || []) != []} class="queue-docs">
      <.eyebrow>Documents</.eyebrow>
      <.link
        :for={doc <- @detail.documents}
        navigate={
          ~p"/tickets/#{@item.project}/#{@item.ticket.number}/artifacts/#{doc.name}/#{doc.version}"
        }
        class="queue-doc"
      >
        <span class="queue-doc-name">{doc.name}</span>
        <span class="queue-doc-version">v{doc.version}</span>
        <span class="queue-doc-read">Read ›</span>
      </.link>
    </section>
    """
  end

  # One line of what happened, in the product's words: who said what in a conversation, where the
  # ticket went, how a job ended, the summary `Forge.Events` writes for a decision or a stick —
  # and for anything else its name alone, never a payload dumped as keys and values.
  defp since_line(%{type: "chat.message", actor: actor} = event, me),
    do: "#{who(actor, me)}: “#{excerpt_text(Events.summary(event))}”"

  defp since_line(%{type: "transition.taken", payload: %{"from" => from, "to" => to}}, _me),
    do: "#{from} → #{to}"

  defp since_line(%{type: "job.finished", payload: payload}, _me),
    do: "a job ended #{payload["outcome"] || "without an outcome"}"

  defp since_line(%{type: "artifact.version_written", actor: actor, payload: payload}, me),
    do: "#{who(actor, me)} wrote #{payload["artifact"]} v#{payload["version"]}"

  defp since_line(%{type: "ticket.admitted", payload: payload}, _me),
    do: "admitted into #{payload["state"]}"

  defp since_line(%{type: type} = event, _me)
       when type in ~w(ticket.stuck approval.approved approval.rejected ticket.merged
                       merge_queue.entered merge_queue.left ticket.renamed),
       do: "#{humane(type)}: #{excerpt_text(Events.summary(event))}"

  defp since_line(%{type: type}, _me), do: humane(type)

  # Who it was, as the viewer reads it: their own words are theirs.
  defp who(%{"kind" => "user", "id" => me}, me), do: "you"
  defp who(%{"kind" => "user"}, _me), do: "someone"
  defp who(%{"kind" => "job"}, _me), do: "agent"
  defp who(_actor, _me), do: "forge"

  @humane %{
    "merge_queue.entered" => "entered the merge queue",
    "merge_queue.left" => "left the merge queue",
    "ticket.retried" => "run again",
    "ticket.merge_conflicted" => "conflicts with the default branch",
    "approval.requested" => "waits for approval",
    "step.accepted" => "step accepted"
  }

  # What happened, in a word or two: the event's own name where that reads, *stuck*, *merged*.
  defp humane(type),
    do: @humane[type] || type |> String.split(".") |> List.last() |> String.replace("_", " ")

  defp excerpt_text(text),
    do: text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 140)

  attr :detail, :map, required: true

  # 18a: enough to know what you are walking into — the changeset's size and files, and the
  # message the merge will write. Never the decision itself: that is the row on the ticket.
  defp approval(assigns) do
    ~H"""
    <section :if={@detail[:diff]} id="queue-changeset" class="queue-block">
      <div class="queue-block-head">
        <span class="queue-block-name">changeset</span>
        <.diff_stat
          added={@detail.diff.added}
          removed={@detail.diff.removed}
          files={length(@detail.diff.files)}
        />
      </div>
      <ul class="queue-files">
        <li :for={{path, added, removed} <- Enum.take(@detail.diff.files, 8)} class="queue-file">
          <span class="queue-file-path">{path}</span>
          <.diff_stat added={lines(added)} removed={lines(removed)} />
        </li>
      </ul>
    </section>

    <%!-- The merge's message as the approval's panel draws it, read the same way (`ui.md`
          § Changes): nothing for an approval that does not merge. --%>
    <div :if={@detail[:commit]} class="queue-block">
      <ForgeWeb.Operator.Decision.commit_block commit={@detail.commit} id="queue-commit-message" />
    </div>
    """
  end

  defp lines(:binary), do: 0
  defp lines(n), do: n

  attr :item, :map, required: true
  attr :detail, :map, required: true
  attr :now, :any, required: true

  # 13b: what the agent said when it stopped, before the card that answers it. Below 768px a long
  # passage is clamped to four lines with *more* at its end, which unclamps it in the browser —
  # sticky across patches, as a JS class is (UX pass, A1).
  defp agent(assigns) do
    assigns = assign(assigns, long: long?(assigns.detail[:agent]))

    ~H"""
    <section :if={@detail[:agent]} id="queue-agent" class="queue-block">
      <.eyebrow>The agent, {said_ago(@item.version.inserted_at, @now)}</.eyebrow>
      <p id="queue-said" class={["queue-said", @long && "queue-said--clamped"]}>{@detail.agent}</p>
      <button
        :if={@long}
        id="queue-said-more"
        type="button"
        class="queue-said-more"
        phx-click={
          JS.remove_class("queue-said--clamped", to: "#queue-said") |> JS.hide(to: "#queue-said-more")
        }
      >
        more
      </button>
      <.link
        navigate={~p"/tickets/#{@item.project}/#{@item.ticket.number}/jobs/#{@detail.job_id}"}
        class="queue-link"
      >
        The whole job ›
      </.link>
    </section>
    """
  end

  # Whether a passage would run past four lines at a phone's measure — about 45 characters a line
  # at 14px in 372px — or holds more than four lines of its own. Only then is *more* drawn: a short
  # one is never clamped, so it never offers to show what it already shows.
  @clamp_chars 180
  @clamp_lines 4

  defp long?(text) when is_binary(text),
    do:
      String.length(text) > @clamp_chars or
        length(String.split(text, "\n")) > @clamp_lines

  defp long?(_none), do: false

  attr :item, :map, required: true
  attr :detail, :map, required: true

  # 13c: why, in words; the last attempt, its error and the agent's closing words; how much of the
  # budget is gone.
  defp stuck(assigns) do
    ~H"""
    <section id="queue-attempt" class="queue-block">
      <.eyebrow>Last attempt</.eyebrow>
      <p :if={!@detail[:last]} class="queue-quiet">No job ran in {@item.ticket.state}.</p>
      <div :if={@detail[:last]} class="queue-attempt">
        <span class="queue-attempt-head">
          #{@detail.last.attempt}
          <span class="queue-attempt-outcome">{@detail.last.outcome || @detail.last.status}</span>
          · {@detail.last.turns} turns · {Format.duration(@detail.last)}
        </span>
        <pre :if={@detail.excerpt} class="queue-excerpt">{@detail.excerpt}</pre>
        <p :if={@detail.closing} class="queue-said">agent: “{@detail.closing}”</p>
      </div>
      <p class="queue-budget">
        {@detail.attempts} {noun(@detail.attempts, "attempt")} in {@item.ticket.state}<span :if={
          @detail.budget
        }> · budget {@detail.budget.turns} turns</span>
      </p>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :ways, :map, required: true

  # The ways forward as choice rows: run the state again where it can be, and each transition the
  # person may take from here, each saying what it does. The dock's button takes the one picked.
  defp ways(assigns) do
    assigns =
      assign(assigns, offered: ways_of(assigns.item), picked: picked(assigns.item, assigns.ways))

    ~H"""
    <section class="queue-block">
      <.eyebrow>Ways forward</.eyebrow>
      <p :if={@offered == []} class="queue-quiet">
        No way forward is offered from {@item.ticket.state}. Open the ticket to decide.
      </p>
      <form
        :if={@offered != []}
        id={"ways-#{@item.ticket.id}"}
        class="queue-ways"
        phx-change="queue:pick"
        phx-submit="queue:way"
      >
        <input type="hidden" name="ticket" value={@item.ticket.id} />
        <.choice_row
          :for={way <- @offered}
          id={"way-#{@item.ticket.id}-#{way.value}"}
          name="way"
          value={way.value}
          label={way.label}
          detail={way.detail}
          selected={@picked == way.value}
        />
      </form>
    </section>
    """
  end

  defp ways_of(%{kind: kind, ticket: ticket, detail: detail}) when kind in [:stuck, :review] do
    retry =
      if detail[:retry],
        do: [
          %{
            value: "retry",
            label: "Retry #{ticket.state}",
            detail: "A fresh attempt with the same budget."
          }
        ],
        else: []

    moves =
      for to <- detail[:transitions] || [],
          do: %{value: "to:#{to}", label: "Move to #{to}", detail: "The ticket goes to #{to}."}

    retry ++ moves
  end

  defp ways_of(_item), do: []

  # The way forward picked, or nil: nothing is preselected (plan § 6, as Accept and the ticket's
  # Ways forward), so the dock's button names no way and is disabled until one is picked. An item
  # with no ticket — the accounts waiting — has no way to pick.
  defp picked(%{ticket: nil}, _ways), do: nil

  defp picked(item, ways) do
    way = Map.get(ways, item.ticket.id)
    if way in Enum.map(ways_of(item), & &1.value), do: way
  end

  attr :item, :map, required: true

  defp chat_reply(assigns) do
    ~H"""
    <section id="queue-reply" class="queue-block">
      <%!-- With questions, what it asked is the sentence and the card; the reply's first line
            would be the first question's fence. --%>
      <.eyebrow :if={@item.detail.questions == []}>The agent said</.eyebrow>
      <p :if={@item.detail.questions == []} class="queue-said">{first_line(@item.detail.text)}</p>
      <.link navigate={~p"/chats/#{@item.detail.chat_id}"} class="queue-link">
        Open the chat ›
      </.link>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :forms, :map, required: true
  attr :ways, :map, required: true
  attr :refusal, :map, default: nil

  # The foot of the item: Later, and its way on. Questions are the card in its split pane, with
  # Later in the card's own foot beside Send.
  defp dock(%{item: %{kind: :questions}} = assigns) do
    ~H"""
    <.split_pane id="queue-pane">
      <.question_form
        id={@item.version.id}
        questions={@item.questions}
        forms={@forms}
        refusal={@refusal}
        submit="questions:send"
        hidden={[{"ticket", @item.ticket.id}, {"version", @item.version.id}]}
      >
        <:dock><.later /></:dock>
      </.question_form>
    </.split_pane>
    """
  end

  defp dock(%{item: %{kind: :chat, detail: %{questions: [_ | _]}}} = assigns) do
    ~H"""
    <.split_pane id="queue-pane">
      <.question_form
        id={"chat-#{@item.detail.chat_id}-#{@item.detail.reply}"}
        questions={@item.detail.questions}
        forms={@forms}
        refusal={@refusal}
        submit="chat:questions:send"
        hidden={[{"chat", @item.detail.chat_id}, {"reply", @item.detail.reply}]}
      >
        <:dock><.later /></:dock>
      </.question_form>
    </.split_pane>
    """
  end

  defp dock(assigns) do
    assigns =
      assign(assigns, offered: ways_of(assigns.item), picked: picked(assigns.item, assigns.ways))

    ~H"""
    <Actions.refused id="queue-refusal" refusal={@refusal} at={~w(retry transition)} />
    <div id="queue-dock" class="queue-dock">
      <.later />
      <%!-- Never decided here: an approval is the decision row on its ticket, beside what it
            approves (`docs/design/ui.md` § The decision row). --%>
      <.button
        :if={@item.kind == :approval}
        id={"review-#{@item.ticket.id}"}
        variant="outline"
        fill
        chevron
        navigate={review_href(@item)}
      >
        {review_label(@item)}
      </.button>
      <.button
        :if={@offered != []}
        id="queue-take"
        type="submit"
        form={"ways-#{@item.ticket.id}"}
        variant="primary"
        fill
        disabled={is_nil(@picked)}
        phx-disable-with="Sending…"
      >
        {way_label(@item, @picked)}
      </.button>
      <.button
        :if={@item.kind == :chat}
        variant="outline"
        fill
        chevron
        navigate={~p"/chats/#{@item.detail.chat_id}"}
      >
        Open the chat
      </.button>
      <.button
        :if={@item.kind == :accounts}
        id="queue-accounts"
        variant="outline"
        fill
        chevron
        navigate={~p"/accounts"}
      >
        Review the accounts
      </.button>
    </div>
    """
  end

  defp later(assigns) do
    ~H"""
    <.button id="queue-later" type="button" variant="secondary" phx-click="queue:later">
      Later
    </.button>
    """
  end

  defp way_label(_item, nil), do: "Pick a way forward"

  defp way_label(item, picked),
    do: Enum.find_value(ways_of(item), &(&1.value == picked && &1.label))

  # **A merge decision leads to the change**, whatever it pins: what makes it one is the state it
  # enters (`Forge.Engine.approval_merges?/1`), and a merge taken without the diff in front of
  # the person is what the link exists to prevent. Anything else leads to what it pins — a
  # document on Docs. The row is on every view, so the person decides from where they land.
  defp review_href(%{project: project, ticket: ticket} = item) do
    tab = if change?(item), do: "changes", else: "docs"
    ~p"/tickets/#{project}/#{ticket.number}?tab=#{tab}"
  end

  defp review_label(item) do
    case {change?(item), item.approve} do
      {true, _pins} -> "Review the changeset"
      {false, [{name, version}]} -> "Review #{name} v#{version}"
      {false, pins} -> "Review #{length(pins)} versions"
    end
  end

  defp change?(%{ticket: ticket, approve: approve}),
    do: List.keymember?(approve, @changeset, 0) or Engine.approval_merges?(ticket)

  attr :pass, :map, required: true
  attr :left, :list, required: true
  attr :now, :any, required: true

  # 13d: the pass ends somewhere definite — what was decided, what is left with a way back to it —
  # and then the two quiet groups, which are the list column's and follow this on a phone. **Green
  # and *End of queue* only when nothing is left**: over items left for later they said done when
  # nothing was (UX pass, A9). What is left is drawn as the *All* sheet draws it, each row the way
  # back to its item.
  defp ending(assigns) do
    assigns =
      assign(assigns, decided: MapSet.size(assigns.pass.decided), done: assigns.left == [])

    ~H"""
    <section id="queue-end" class="queue-end">
      <.eyebrow :if={@done} tone="success">End of queue</.eyebrow>
      <.eyebrow :if={!@done}>End of the pass</.eyebrow>
      <p class="queue-sentence">{closing(@left)}</p>
      <p :if={@decided > 0} class="queue-tally">{@decided} decided</p>
      <div :if={@left != []} id="queue-left" class="queue-left">
        <.row :for={item <- @left} id={"back-#{item.key}"} item={item} pass={@pass} now={@now} />
      </div>
    </section>
    """
  end

  attr :digest, :list, required: true
  attr :now, :any, required: true

  # Prose, not items: no mark, no answer rows, no accent, because nothing here is waiting on
  # anyone. Each line leads to its ticket, where the question is answered — see docs/design/ui.md
  # § Not waiting on you.
  defp digest(assigns) do
    ~H"""
    <section :if={@digest != []} id="queue-digest" class="queue-quiet-group">
      <.eyebrow>Not waiting on you</.eyebrow>
      <p class="queue-quiet">{digest_sentence(@digest)}</p>
      <ul>
        <li :for={item <- @digest} id={"assumption-#{item.question.id}"}>
          <.link navigate={destination(item)} class="queue-quiet-line">
            <span class="queue-quiet-head">
              <span>{item.question.text}</span>
              <span class="queue-quiet-age">{Format.ago(item.since, @now)}</span>
            </span>
            <span>Assumed: {item.question.assumption}</span>
            <span class="queue-quiet-ref">{item.project}#{item.ticket.number}</span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :under_way, :list, required: true
  attr :now, :any, required: true

  # The digest's register, for the digest's reason — see the moduledoc. Grouped by the half of the
  # axis each is on, the group saying it once over its titles, where every line used to repeat
  # *Not yet on a worker.* (UX pass, A9).
  defp under_way(assigns) do
    assigns = assign(assigns, groups: under_way_groups(assigns.under_way))

    ~H"""
    <section :if={@under_way != []} id="queue-under-way" class="queue-quiet-group">
      <.eyebrow>Under way</.eyebrow>
      <div :for={{group, items} <- @groups} id={"under-way-#{group}"} class="queue-quiet-sub">
        <p class="queue-quiet">{under_way_sentence(group, items)}</p>
        <ul>
          <li :for={item <- items} id={"under-way-#{item.ticket.id}"}>
            <.link navigate={destination(item)} class="queue-quiet-line">
              <span class="queue-quiet-head">
                <span>{item.ticket.title}</span>
                <span class="queue-quiet-age">{Format.ago(item.since, @now)}</span>
              </span>
              <span class="queue-quiet-ref">{item.project}#{item.ticket.number}</span>
            </.link>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp destination(%{kind: :chat} = item), do: ~p"/chats/#{item.detail.chat_id}"
  defp destination(item), do: ~p"/tickets/#{item.project}/#{item.ticket.number}"

  # The item's kind alone, which a row's kicker carries: where it is — the document and its
  # version, the transition — is the row's latest line, said once (UX pass, A24). Counted as
  # blocking: an assumption in the same card is optional and waits on nobody.
  defp kind(%{kind: :questions, questions: questions}) do
    blocking = Enum.count(questions, & &1.blocking)
    "#{blocking} blocking #{noun(blocking, "question")}"
  end

  defp kind(%{kind: :chat}), do: "conversation"
  defp kind(%{kind: :approval}), do: "approval"
  defp kind(%{kind: :stuck}), do: "stuck"
  defp kind(%{kind: :review}), do: "review ready"
  defp kind(%{kind: :accounts}), do: "accounts"

  # The item's eyebrow: its kind and where it is. An assumption in the same card is named apart
  # rather than added to what is waiting.
  defp kind_label(%{kind: :questions, questions: questions, version: version} = item) do
    optional = Enum.count(questions, &(not &1.blocking))
    label = if optional == 0, do: kind(item), else: "#{kind(item)} · #{optional} optional"
    "#{label} · #{version.artifact.name} v#{version.version}"
  end

  defp kind_label(%{kind: :approval} = item),
    do: "approval · #{item.ticket.state} → #{item.detail["to"]}"

  defp kind_label(item), do: kind(item)

  defp sentence(%{kind: :questions, questions: [question]}), do: question.text

  defp sentence(%{kind: :questions} = item),
    do:
      "#{length(item.questions)} questions about #{item.version.artifact.name} v#{item.version.version}."

  # What it said, not what it is: a conversation waiting on you is waiting with its last reply
  # on screen, and that reply is the thing you are deciding about.
  defp sentence(%{kind: :chat} = item) do
    case item.detail.questions do
      [] -> first_line(item.detail.text)
      [question] -> question.text
      questions -> "#{length(questions)} questions: #{hd(questions).text}"
    end
  end

  defp sentence(%{kind: :approval} = item),
    do: "#{item.ticket.title} is ready to move to #{item.detail["to"]}."

  defp sentence(%{kind: :stuck, detail: %{reason: reason}} = item) when is_binary(reason),
    do: "#{item.ticket.title} is stuck: #{reason}."

  defp sentence(%{kind: :stuck} = item),
    do: "#{item.ticket.title} is stuck and needs a way forward."

  defp sentence(%{kind: :review} = item), do: "#{item.ticket.title} is waiting for your review."

  defp sentence(%{kind: :accounts, count: 1}), do: "1 account waits to be approved."
  defp sentence(%{kind: :accounts, count: count}), do: "#{count} accounts wait to be approved."

  defp first_line(nil), do: "It is waiting for you."

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  # The two halves of one axis — on a machine, or not yet — which is the distinction the ticket
  # asked for, each counted apart: telling the two apart at a glance is what this group is for, and
  # one total would hide it. Running first, and a half with nothing in it is left out.
  # **Neither names a cause.** "Waiting for a worker" did, and got it wrong: of the reasons the
  # scheduler records for a pending job most are about getting it a machine, but waiting a turn
  # behind a sibling command is not, and a template the platform refused needs a person rather
  # than room. *Why* it is waiting is the sentence on the ticket's own timeline
  # (`docs/design/ui.md` § A job waiting for a machine), which is the one place that knows.
  defp under_way_groups(items) do
    {running, waiting} = Enum.split_with(items, &(&1.kind == :on_worker))
    Enum.reject([{"running", running}, {"waiting", waiting}], &match?({_group, []}, &1))
  end

  defp under_way_sentence("running", items), do: tickets(items, "running on a worker")
  defp under_way_sentence("waiting", items), do: tickets(items, "not yet on a worker")

  defp tickets(items, what), do: "#{length(items)} #{noun(length(items), "ticket")} #{what}."

  defp digest_sentence([_one]), do: "1 assumption was stated and work continued."

  defp digest_sentence(digest),
    do: "#{length(digest)} assumptions were stated and work continued."

  defp closing([]), do: "Nothing needs you. Work continues without you."
  defp closing(left), do: "#{length(left)} left for later."

  defp noun(1, word), do: word
  defp noun(_count, word), do: word <> "s"

  defp push(event, params, socket), do: {:noreply, PushEvents.handle(event, params, socket)}
end
