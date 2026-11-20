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
  on. Questions put what the agent said before the context, since it is what they are about.
  **Every item about a ticket shows the ticket's past** after the context — a line per step, one of
  which opens in place, and the loops that have fired (`ForgeWeb.QueuePast`, `Forge.Tickets.Past`).

  **The queue never approves and never merges**: an approval leads to the ticket's decision row,
  beside what it approves, and so does a way forward that approves or merges
  (`Forge.Engine.decision_edge?/2`), which a stuck ticket or one resting in a human state shows as a
  link instead of a choice row and which the queue refuses in words if it is sent anyway. What it
  does in place: a document's questions are answered in the question card, and a stuck ticket's
  other ways forward are choice rows with a dock button that takes the one picked. Deciding moves
  the pass on in place, without a navigation (`ForgeWeb.QueuePass` holds the pass's rules).

  The whole queue is the **All** sheet on a phone and the list column from 768px — every item in
  the pass's order, decided ones dimmed with `✓` — and beneath the items, three groups that wait
  on nobody and count towards nothing: **Not waiting on you**, the questions agents did not stop
  for (`docs/design/ui.md` § Not waiting on you), **Open tickets**, every open ticket that is
  not on hold and has nothing waiting on a person, each drawn as the project's Tickets list draws
  it (`ForgeWeb.ProjectTickets`, § A job waiting for a machine), read from `Queue.open_tickets/2`
  rather than `Queue.items/1`, and **On hold**, last, the tickets on hold that have a decision
  waiting, drawn the same way with the latest line naming what waits and read from `Queue.held/1`
  (a held ticket's decisions are not items: they are decided on its own page). A ticket the spend
  cap holds is in *Open tickets*, `paused · spend`: never an item, never counted, never pushed
  (`docs/design/capacity.md`). **Where they are drawn depends on
  the width**: from 1440px in the list column under the decisions, below it once, after the end of
  the pass, and only when no item is on screen (`queue.css`). An assumption asked in the same document as a blocking question is in that
  document's card instead, optional (§ The question card).
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Operator.QuestionForm, only: [question_form: 1, split_pane: 1]
  import ForgeWeb.QueueItems, only: [noun: 2]

  alias Forge.{Artifacts, Engine, Events, Jobs, Projects, Queue, Tickets}
  alias Forge.Tickets.{Doing, Past, Views}
  alias ForgeCore.Workflow

  alias ForgeWeb.Components.MoreRoom

  alias ForgeWeb.{
    Diff,
    Format,
    ProjectTickets,
    PushEvents,
    QueueItems,
    QueuePass,
    QueuePast,
    TicketViews,
    Topology,
    WorkflowMap
  }

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
       opened: nil,
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
    named = user |> Projects.list() |> Map.new(&{&1.id, &1.name})
    {waiting, assumed} = queue |> named_projects() |> Enum.split_with(&Queue.waiting?/1)

    {joined, digest} =
      waiting
      |> Enum.filter(&(&1.kind == :question))
      |> QuestionForm.join_assumed(assumed, & &1.question.artifact_version_id)

    items =
      (waiting ++ joined ++ accounts_item(accounts))
      |> QueueItems.group()
      |> Enum.map(&decorate/1)

    pass =
      case socket.assigns.pass do
        nil -> QueuePass.new(items, & &1.key)
        pass -> QueuePass.merge(pass, items, & &1.key)
      end

    {open, held} = quiet_rows(user, queue)

    socket
    |> assign(
      pass: pass,
      digest: digest,
      open: open,
      held: held,
      projects: named,
      # The queue button's count, computed by the same function over the same reads
      # (`Forge.Queue.count/2`): an item decided in this pass is no longer waiting once it is read
      # again, so it is not counted, and one decided elsewhere is not either.
      decisions: Queue.count(queue, accounts),
      now: DateTime.utc_now()
    )
    |> detail()
  end

  # Open tickets and On hold, drawn as the project's Tickets list draws them: the same rows, from the
  # same reads (`Forge.Tickets.Doing.facts/2`, once over both lists), over every project the viewer
  # is in. `items` is the queue just read, so a ticket is never both an item and a row; a held
  # ticket is never one at all, and its row's latest line names what waits on it.
  defp quiet_rows(user, items) do
    tickets = Queue.open_tickets(user, items)
    held = Queue.held(user)
    held_tickets = Enum.map(held, &elem(&1, 0))
    facts = Doing.facts(tickets ++ held_tickets)
    now = DateTime.utc_now()

    open = ProjectTickets.rows(tickets, Map.merge(facts, %{items: items, now: now}))

    held_rows =
      ProjectTickets.rows(
        held_tickets,
        Map.merge(facts, %{
          items: [],
          held: Map.new(held, fn {t, held} -> {t.id, held} end),
          now: now
        })
      )

    {open, held_rows}
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
  defp key(%{kind: :schedule, detail: detail}), do: "schedule-#{detail.id}"
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
  #
  # **A step's line opened is the item's**: `opened` is `{item key, step}`, and moving to another
  # item drops it, so a line is never open on an item it was not opened on.
  defp detail(socket) do
    item = QueuePass.current(socket.assigns.pass)

    socket =
      case {item, socket.assigns.opened} do
        {%{key: key}, {key, _step}} -> socket
        _moved -> assign(socket, opened: nil)
      end

    assign(socket, item: item, detail: item && read_detail(item, socket))
  end

  defp read_detail(%{ticket: nil}, _socket), do: %{}

  defp read_detail(%{ticket: stale} = item, socket) do
    user = socket.assigns.current_scope.user
    ticket = Tickets.get!(stale.id)
    project = Projects.get!(ticket.project_id)
    jobs = Jobs.for_ticket(ticket.id)
    looked = user |> Views.since([ticket.id]) |> Map.get(ticket.id)

    workflow =
      case Tickets.parsed_workflow(ticket) do
        {:ok, workflow} -> workflow
        {:error, _errors} -> nil
      end

    artifacts = Artifacts.list(ticket.id)
    past = Past.steps(ticket, workflow, jobs)

    %{
      ticket: ticket,
      workflow: workflow,
      facts: facts(ticket, jobs),
      looked: looked,
      since: Views.events_since(ticket.id, looked, @since),
      documents: documents(ticket, artifacts),
      presented: presented?(ticket, artifacts),
      past: past,
      loops: Past.loops(ticket, workflow)
    }
    |> Map.merge(opened(item, ticket, past, socket.assigns.opened))
    |> Map.merge(
      kind_detail(item, %{project: project, ticket: ticket, past: past, workflow: workflow})
    )
  end

  # The line that is open, and what its latest run said — read for that one line alone.
  defp opened(item, ticket, past, {key, name}) when key == item.key do
    step = Enum.find(past, &(&1.name == name and QueuePast.openable?(&1, item)))
    run = step && Past.latest_run(ticket, step)
    %{opened: run && name, run: run}
  end

  defp opened(_item, _ticket, _past, _opened), do: %{opened: nil, run: nil}

  # Whether the ticket has a presentation with a version: the approval's way on leads to it.
  defp presented?(ticket, artifacts) do
    Enum.any?(artifacts, fn artifact ->
      artifact.kind == :presentation and Artifacts.latest(ticket.id, artifact.name) != nil
    end)
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

  defp documents(ticket, artifacts) do
    for artifact <- artifacts,
        artifact.kind == :document,
        not Workflow.proposal?(artifact.name),
        latest = Artifacts.latest(ticket.id, artifact.name),
        do: %{name: artifact.name, version: latest.version}
  end

  defp kind_detail(%{kind: :approval} = item, %{project: project, ticket: ticket}) do
    %{
      diff: changeset(project, ticket),
      commit: ForgeWeb.Operator.Decision.commit(ticket),
      pinned: pinned(project, ticket, item.approve)
    }
  end

  # A ticket ready to merge shows what an approval of a change shows, because what it would do is
  # the same: its way forward merges (`Forge.Engine.merge_decision?/2`, which asks the workflow
  # because a resting ticket has no pending approval to ask).
  defp kind_detail(%{kind: :review}, %{workflow: %Workflow{} = workflow} = ctx) do
    if Engine.merge_decision?(ctx.ticket, workflow) do
      %{
        diff: changeset(ctx.project, ctx.ticket),
        commit: ForgeWeb.Operator.Decision.commit_of(ctx.ticket)
      }
    else
      %{}
    end
  end

  defp kind_detail(%{kind: :questions, version: version}, _ctx) do
    case version.author do
      %{"kind" => "job", "id" => job_id} ->
        %{agent: Jobs.last_words(%Forge.Jobs.Job{id: job_id}), job_id: job_id}

      _other ->
        %{agent: nil, job_id: nil}
    end
  end

  defp kind_detail(%{kind: :stuck}, ctx) do
    %{
      attempt: attempt(Enum.find(ctx.past, & &1.current), ctx.ticket),
      budget: budget(ctx.workflow, ctx.ticket)
    }
  end

  # The documents the step's conversation produces that have a version, at their latest.
  defp kind_detail(%{kind: :chat, detail: %{chat_id: chat_id}}, ctx) do
    chat = Jobs.get!(chat_id)

    with %Workflow{} = workflow <- ctx.workflow,
         %Workflow.State{produces: produces} <- chat.state && Workflow.state(workflow, chat.state) do
      %{produced: produced(ctx.ticket, produces)}
    else
      _none -> %{produced: []}
    end
  end

  defp kind_detail(_item, _ctx), do: %{}

  defp produced(ticket, produces) do
    for name <- produces,
        Workflow.document?(name) and not Workflow.presentation?(name),
        version = Artifacts.latest(ticket.id, name),
        do: %{name: name, version: version.version}
  end

  # Every document the approval pins, rendered exactly as the ticket's Docs view renders it.
  defp pinned(project, ticket, approve) do
    scope = Forge.References.ticket_scope(project.name, ticket)

    for {name, _version} <- approve,
        name != @changeset,
        version = Artifacts.latest(ticket.id, name),
        do: %{
          name: name,
          version: version.version,
          body: ForgeWeb.FileType.render_document(name, version, scope)
        }
  end

  # The last attempt of the step the ticket stuck in, by the step's kind: an agent's job, a
  # command step's batch, a conversation's reply. Nothing for a human step, which has no run.
  defp attempt(%{kind: :agent, job: nil}, _ticket), do: %{kind: :agent, job: nil}

  defp attempt(%{kind: :agent, job: job}, _ticket),
    do: %{kind: :agent, job: job, excerpt: excerpt(job), closing: Jobs.last_words(job)}

  defp attempt(%{kind: :command, runs: 0}, _ticket), do: %{kind: :command, batch: nil}

  defp attempt(%{kind: :command, name: name}, ticket),
    do: %{
      kind: :command,
      batch: Forge.Jobs.Commands.latest_batch(ticket.id, name, Past.tail_bytes())
    }

  defp attempt(%{kind: :conversation, job: chat}, _ticket),
    do: %{kind: :conversation, job: chat, reply: chat && Past.last_reply(chat)}

  defp attempt(_human_or_none, _ticket), do: nil

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

  # The step's allowance in turns and tokens, as the workflow map says it.
  defp budget(%Workflow{} = workflow, ticket) do
    case Workflow.state(workflow, ticket.state) do
      %Workflow.State{} = state -> WorkflowMap.budget(state)
      nil -> nil
    end
  end

  defp budget(nil, _ticket), do: nil

  # -- events ------------------------------------------------------------------------------------

  @impl true
  # This browser's push subscription: one head each, so the inventory can read them
  # (`authorization_inventory_test.exs`), all handled by `ForgeWeb.PushEvents`.
  def handle_event("push:subscribe" = event, params, socket), do: push(event, params, socket)
  def handle_event("push:unsubscribe" = event, params, socket), do: push(event, params, socket)
  def handle_event("push:error" = event, params, socket), do: push(event, params, socket)

  # A schedule's alert dismissed, by any member: the schedule is resolved from its id, and
  # `Operator.dismiss_schedule/4` asks `:use` of its project and refuses a non-member, so an id off
  # the wire reaches nothing it should not. What is refused is not drawn: the item is simply read
  # again, and is gone or is not.
  def handle_event("schedule:dismiss", %{"id" => id}, socket) when is_binary(id) do
    with %Forge.Schedules.Schedule{} = row <- Forge.Schedules.find(id) do
      project = Projects.get!(row.project_id)

      Forge.Operator.dismiss_schedule(
        project,
        socket.assigns.current_scope.user,
        row.ticket_type,
        row.name
      )
    end

    {:noreply, socket |> update(:pass, &QueuePass.decide/1) |> load()}
  end

  def handle_event(event, params, socket), do: dispatch(event, params, socket)

  # Later: to the end of the pass, nothing recorded.
  defp dispatch("queue:later", _params, socket),
    do: {:noreply, socket |> update(:pass, &QueuePass.later/1) |> detail()}

  # The way forward picked, kept by the page so a re-render or a rejoin does not lose it.
  # What is typed under it (the Extend and Run again fields) is held with the pick, in the page's
  # drafts under the form's own id, so that a rejoin gives it back and the raise box follows it
  # (`ForgeWeb.Components.MoreRoom`). The raise is the shortfall until typed in: picking another
  # way or changing the tokens drops what an earlier shortfall filled in.
  defp dispatch("queue:pick", %{"ticket" => id, "way" => way} = params, socket)
       when is_binary(id) and is_binary(way) do
    typed =
      if params["_target"] in [["tokens"], ["way"]], do: Map.delete(params, "raise"), else: params

    socket =
      case Drafts.handle("draft:change", Map.put(typed, "draft", "ways-#{id}"), socket) do
        {:state, socket} -> socket
        :unknown -> socket
      end

    {:noreply, update(socket, :ways, &Map.put(&1, id, way))}
  end

  # A way forward taken: the same operation the ticket's page takes, through `Actions`, which
  # resolves the ticket off the wire and refuses a non-member (`Forge.Operator`).
  defp dispatch("queue:way", %{"ticket" => id, "way" => "retry"} = params, socket),
    do:
      deciding(
        "retry",
        params |> Map.take(~w(note raise draft)) |> Map.put("ticket", id),
        socket
      )

  defp dispatch("queue:way", %{"ticket" => id, "way" => "extend"} = params, socket),
    do:
      deciding(
        "extend",
        params |> Map.take(~w(tokens turns note raise job draft)) |> Map.put("ticket", id),
        socket
      )

  defp dispatch("queue:way", %{"ticket" => id, "way" => "to:" <> to}, socket),
    do: deciding("transition", %{"ticket" => id, "to" => to}, socket)

  # **The queue never approves or merges**, whichever way the event arrives — a row of this page,
  # one drawn before this rule, a crafted one: a transition that records an approval or enters a
  # merging state is refused at the operation (`Forge.Engine.choose/4`, `approving: false`), in
  # words, and nothing is written. A page that is not the queue takes it with no such option.
  defp dispatch("transition", params, socket), do: deciding("transition", params, socket)

  # A step's line opened or closed (`ForgeWeb.QueuePast`). The form carries every box that is
  # checked, so the one just opened is the value that is not already open; none checked closes it.
  # A form that is not about the item on screen opens nothing there: `detail/1` drops a line opened
  # on any other item, and `opened/4` opens only a step the item can show.
  defp dispatch("queue:step", %{"item" => key} = params, socket) do
    opened = step_opened(socket.assigns.opened, key, params)
    {:noreply, socket |> assign(opened: opened) |> detail()}
  end

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
    case Actions.handle(event, params, socket, approving: false, jump: false) do
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

  defp step_opened(opened, key, params) do
    was =
      case opened,
        do: (
          {^key, step} -> step
          _other -> nil
        )

    case Enum.reject(List.wrap(params["open"]), &(&1 == was)) do
      [step | _] when is_binary(step) -> {key, step}
      # A crafted `open` that is not a list of names opens nothing rather than crashing the page.
      [_other | _] -> nil
      [] -> if was in List.wrap(params["open"]), do: opened, else: nil
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
          <.digest id="queue-digest" prefix="" digest={@digest} now={@now} />
          <.open_tickets id="queue-open" open={@open} projects={@projects} now={@now} />
          <.held_tickets id="queue-held" held={@held} projects={@projects} now={@now} />
        </div>
      </:list>

      <:aside :if={@item && @item.ticket}>
        <div id="queue-aside" class="queue-aside">
          <.context item={@item} detail={@detail} me={@current_scope.user.id} wide />
        </div>
      </:aside>

      <:composer :if={@item}>
        <.dock item={@item} detail={@detail} forms={@forms} ways={@ways} refusal={@refusal} />
      </:composer>

      <div class="queue-page">
        <.item
          :if={@item}
          item={@item}
          detail={@detail}
          ways={@ways}
          drafts={@drafts}
          now={@now}
          me={@current_scope.user.id}
        />
        <%!-- A way taken from an item that has gone since: said where the item stood. --%>
        <Actions.refused
          :if={!@item}
          id="queue-refusal"
          refusal={@refusal}
          at={~w(retry extend transition)}
        />
        <.ending :if={!@item} pass={@pass} left={@left} now={@now} />
        <%!-- Below 1440px the three quiet groups are drawn here, after the end of the pass, and not in
              the list column; from 1440px the column's are drawn and these are not (`queue.css`).
              Never while an item is on screen. --%>
        <.digest :if={!@item} id="queue-end-digest" prefix="end-" digest={@digest} now={@now} />
        <.open_tickets
          :if={!@item}
          id="queue-end-open"
          open={@open}
          projects={@projects}
          now={@now}
        />
        <.held_tickets
          :if={!@item}
          id="queue-end-held"
          held={@held}
          projects={@projects}
          now={@now}
        />
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
          <.link :if={@open != []} patch={~p"/?item=end"} class="queue-sheet-quiet">
            Open tickets · {length(@open)}
          </.link>
          <.link :if={@digest != []} patch={~p"/?item=end"} class="queue-sheet-quiet">
            Not waiting on you · {length(@digest)}
          </.link>
          <.link :if={@held != []} patch={~p"/?item=end"} class="queue-sheet-quiet">
            On hold · {length(@held)}
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
      kicker={QueueItems.kind(@item)}
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

  defp row_title(%{kind: kind} = item) when kind in [:chat, :accounts, :schedule],
    do: sentence(item)

  defp row_title(item), do: item.ticket.title

  defp row_meta(%{kind: :accounts}), do: "this node"

  defp row_meta(%{kind: :schedule, project: project, detail: detail}),
    do: "#{project} · #{detail.ticket_type || "workflow"}"

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
  attr :drafts, :map, required: true
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

      <%!-- The ticket's past is the item's own, at every width: the context column beside it
            carries the card and what happened since, never this. --%>
      <QueuePast.past :if={@item.ticket} item={@item} detail={@detail} />

      <.approval :if={@item.kind in [:approval, :review]} item={@item} detail={@detail} />
      <.stuck :if={@item.kind == :stuck} item={@item} detail={@detail} />
      <.ways
        :if={@item.kind in [:stuck, :review]}
        item={@item}
        detail={@detail}
        ways={@ways}
        drafts={@drafts}
      />
      <.chat_reply :if={@item.kind == :chat} item={@item} detail={@detail} />
      <.schedule_alert :if={@item.kind == :schedule} item={@item} />
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

  defp since_line(%{type: "transition.taken", payload: %{"from" => from, "to" => to} = p}, _me),
    do: if(p["jump"], do: "jumped #{from} → #{to}", else: "#{from} → #{to}")

  defp since_line(%{type: "job.finished", payload: payload}, _me),
    do: "a job ended #{payload["outcome"] || "without an outcome"}"

  defp since_line(%{type: "artifact.version_written", actor: actor, payload: payload}, me),
    do: "#{who(actor, me)} wrote #{payload["artifact"]} v#{payload["version"]}"

  # An update step's visit says what it did, in its own sentence: the event's name alone would read
  # *branch updated* over a conflict that sent the ticket to a job.
  defp since_line(%{type: "ticket.branch_updated"} = event, _me),
    do: excerpt_text(Events.summary(event))

  defp since_line(
         %{type: "ticket.admitted", payload: %{"schedule" => %{"name" => name}} = payload},
         _me
       ),
       do: "admitted by the schedule #{name} into #{payload["state"]}"

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

  attr :item, :map, required: true
  attr :detail, :map, required: true

  # 18a: enough to know what you are walking into — the changeset's size and files, and the
  # message the merge will write, or every document the approval pins. Never the decision itself:
  # that is the row on the ticket.
  defp approval(assigns) do
    ~H"""
    <%!-- Each pinned document under its name and version, in a box that scrolls inside itself, so
          one long plan does not push the rest below the fold (`ui.md` § What each kind shows). --%>
    <section
      :for={doc <- @detail[:pinned] || []}
      id={"queue-pinned-#{doc.name}"}
      class="queue-block"
    >
      <div class="queue-block-head">
        <span class="queue-block-name">{doc.name}</span>
        <span class="queue-doc-version">v{doc.version}</span>
      </div>
      <div class="queue-pinned">
        <ForgeWeb.FileType.document_body body={doc.body} />
      </div>
    </section>

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
  # sticky across patches, as a JS class is (UX pass, A1). The links are drawn at every width:
  # the whole job it said it in, and the document version the questions are about, which no job
  # need have written.
  defp agent(assigns) do
    ~H"""
    <section id="queue-agent" class="queue-block">
      <div :if={@detail[:agent]}>
        <.eyebrow>The agent, {said_ago(@item.version.inserted_at, @now)}</.eyebrow>
        <QueuePast.clamped id="queue-said" text={@detail.agent} />
      </div>
      <div class="queue-links">
        <.link
          :if={@detail[:job_id]}
          navigate={~p"/tickets/#{@item.project}/#{@item.ticket.number}/jobs/#{@detail.job_id}"}
          class="queue-link"
        >
          The whole job ›
        </.link>
        <.link
          id="queue-read-version"
          navigate={
            ~p"/tickets/#{@item.project}/#{@item.ticket.number}/artifacts/#{@item.version.artifact.name}/#{@item.version.version}"
          }
          class="queue-link"
        >
          Read {@item.version.artifact.name} v{@item.version.version} ›
        </.link>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :detail, :map, required: true

  # 13c: why, in words; the last attempt by the kind of step it stuck in — an agent's job with its
  # error and closing words, a command step's batch, a conversation's reply — and how much of the
  # step's allowance it had. A human step has no attempt to show.
  defp stuck(assigns) do
    ~H"""
    <section :if={@detail[:attempt] || @detail[:budget]} id="queue-attempt" class="queue-block">
      <.eyebrow :if={@detail[:attempt]}>Last attempt</.eyebrow>
      <.attempt :if={@detail[:attempt]} item={@item} attempt={@detail.attempt} />
      <p :if={@detail[:budget]} class="queue-budget">budget {@detail.budget} per run</p>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :attempt, :map, required: true

  defp attempt(%{attempt: %{kind: :agent, job: nil}} = assigns) do
    ~H"""
    <p class="queue-quiet">{@item.ticket.state} has not run yet.</p>
    """
  end

  defp attempt(%{attempt: %{kind: :agent}} = assigns) do
    ~H"""
    <div class="queue-attempt">
      <span class="queue-attempt-head">
        #{@attempt.job.attempt}
        <span class="queue-attempt-outcome">{@attempt.job.outcome || @attempt.job.status}</span>
        · {Format.counted(@attempt.job.turns, "turn")} · {Format.duration(@attempt.job)}
      </span>
      <pre :if={@attempt.excerpt} class="queue-excerpt">{@attempt.excerpt}</pre>
      <p :if={@attempt.closing} class="queue-said">agent: “{@attempt.closing}”</p>
    </div>
    """
  end

  defp attempt(%{attempt: %{kind: :command, batch: nil}} = assigns) do
    ~H"""
    <p class="queue-quiet">{@item.ticket.state} has not run yet.</p>
    """
  end

  defp attempt(%{attempt: %{kind: :command}} = assigns) do
    ~H"""
    <div id="queue-attempt-batch" class="queue-attempt">
      <QueuePast.batch item={@item} batch={@attempt.batch} />
    </div>
    """
  end

  defp attempt(%{attempt: %{kind: :conversation}} = assigns) do
    ~H"""
    <div class="queue-attempt">
      <QueuePast.clamped :if={@attempt.reply} id="queue-attempt-said" text={@attempt.reply} />
      <p :if={!@attempt.reply} class="queue-quiet">{@item.ticket.state} has not run yet.</p>
    </div>
    """
  end

  attr :item, :map, required: true
  attr :detail, :map, required: true
  attr :ways, :map, required: true
  attr :drafts, :map, required: true

  # The ways forward as choice rows: run the state again where it can be, and each transition the
  # person may take from here that decides nothing, each saying what it starts. A way that approves
  # or merges is not a row but the dock's link to the ticket, said here in one line when it is all
  # there is (`Forge.Engine.decision_edge?/2`).
  defp ways(assigns) do
    {rows, links} = ways_of(assigns.item, assigns.detail)

    assigns =
      assign(assigns,
        rows: rows,
        links: links,
        picked: picked(assigns.item, assigns.detail, assigns.ways)
      )

    ~H"""
    <section class="queue-block">
      <.eyebrow>Ways forward</.eyebrow>
      <p :if={@rows == [] and @links == []} class="queue-quiet">
        No way forward is offered from {@item.ticket.state}. Open the ticket to decide.
      </p>
      <p :if={@rows == [] and @links != []} id="queue-ways-on-ticket" class="queue-quiet">
        Moving on from {@item.ticket.state} approves or merges, so it is taken on the ticket, where
        what it approves is on screen.
      </p>
      <form
        :if={@rows != []}
        id={"ways-#{@item.ticket.id}"}
        class="queue-ways"
        phx-change="queue:pick"
        phx-submit="queue:way"
      >
        <input type="hidden" name="ticket" value={@item.ticket.id} />
        <%= for way <- @rows do %>
          <.choice_row
            id={"way-#{@item.ticket.id}-#{way.value}"}
            name="way"
            value={way.value}
            label={way.label}
            detail={way.detail}
            selected={@picked == way.value}
          />
          <%!-- The same fields the ticket page draws under the same two rows, so the queue never
                offers Retry without Extend where the page offers both. --%>
          <MoreRoom.fields
            :if={@picked == way.value and @item.detail[:room] != nil and way_fields(way.value)}
            way={way_fields(way.value)}
            offer={@item.detail[:extend]}
            room={@item.detail.room}
            drafts={@drafts}
            draft={"ways-#{@item.ticket.id}"}
            prefix={"queue-#{@item.ticket.id}"}
            project={@item.project}
          />
        <% end %>
      </form>
    </section>
    """
  end

  # `{rows, links}`: the ways taken here, and where the ones that are not are taken. Whether a way
  # decides is asked of the edge `ForgeCore.Engine.choose/4` resolves for it — the one
  # `Forge.Engine.choose/4` takes and refuses — so the row not drawn is the one the operation
  # would not take. A target that resolves to nothing, or ambiguously (an open proposal's), stays a
  # row as it was, and so does every way when the pin cannot be read.
  defp ways_of(%{kind: kind, ticket: ticket} = item, detail) when kind in [:stuck, :review] do
    workflow = detail[:workflow]
    past = detail[:past] || []

    extend =
      if item.detail[:retry] && item.detail[:extend],
        do: [
          %{
            value: "extend",
            label: "Extend #{ticket.state}",
            detail: "the same job carries on with its session, on the room you give it"
          }
        ],
        else: []

    retry =
      if item.detail[:retry],
        do: [
          %{value: "retry", label: "Retry #{ticket.state}", detail: retry_detail(ticket, past)}
        ],
        else: []

    {moves, edges} =
      for to <- item.detail[:transitions] || [], reduce: {[], []} do
        {moves, edges} ->
          case decision_edge(workflow, ticket, to) do
            nil ->
              {[
                 %{
                   value: "to:#{to}",
                   label: "Move to #{to}",
                   detail: move_detail(workflow, past, to)
                 }
                 | moves
               ], edges}

            edge ->
              {moves, [edge | edges]}
          end
      end

    links =
      edges
      |> Enum.reverse()
      |> Enum.map(&edge_link(item, detail, &1))
      |> Enum.uniq_by(& &1.href)

    {extend ++ retry ++ Enum.reverse(moves), links}
  end

  defp ways_of(_item, _detail), do: {[], []}

  # The rows that open fields under them, and what `MoreRoom` calls each.
  defp way_fields("extend"), do: "extend"
  defp way_fields("retry"), do: "again"
  defp way_fields(_other), do: nil

  defp decision_edge(nil, _ticket, _to), do: nil

  defp decision_edge(workflow, ticket, to) do
    with {:ok, edge} <- ForgeCore.Engine.choose(workflow, ticket.state, to),
         true <- Engine.decision_edge?(workflow, edge) do
      edge
    else
      _plain -> nil
    end
  end

  # What it starts, then how often that step has already run: *starts a job in implementing · has
  # run 4 times*.
  defp move_detail(nil, _past, to), do: "The ticket goes to #{to}."

  defp move_detail(workflow, past, to) do
    step = Enum.find(past, &(&1.name == to))
    kind = (step && step.kind) || Past.declared_kind(workflow, to)
    "#{TicketViews.leads(workflow, to)} · #{ran_phrase(kind, (step && step.runs) || 0)}"
  end

  defp ran_phrase(kind, 0) when kind in [:human, :update], do: "has not been visited yet"

  defp ran_phrase(kind, n) when kind in [:human, :update],
    do: "visited #{Format.counted(n, "time")}"

  defp ran_phrase(_kind, 0), do: "has not run yet"
  defp ran_phrase(_kind, n), do: "has run #{Format.counted(n, "time")}"

  defp retry_detail(ticket, past) do
    runs = Enum.find_value(past, 0, &(&1.name == ticket.state && &1.runs))
    "starts run #{runs + 1} of #{ticket.state}, with the same budget"
  end

  # Where a way that decides is taken: the ticket's Changes for a merge or a changeset, its Docs
  # for documents only.
  defp edge_link(%{project: project, ticket: ticket}, detail, edge) do
    change? = Workflow.merges_on_enter?(detail.workflow, edge.to) or @changeset in edge.approve

    pins =
      for name <- edge.approve,
          version = Artifacts.latest(ticket.id, name),
          do: {name, version.version}

    review_link(project, ticket, change?, pins, detail[:presented])
  end

  # **A merge decision leads to the change**, whatever it pins: what makes it one is the state it
  # enters, and a merge taken without the diff in front of the person is what the link exists to
  # prevent. Opened on the presentation when there is one, since that is what is read to decide.
  # Anything else leads to what it pins — documents, on Docs. The decision row is on every view, so
  # the person decides from where they land.
  defp review_link(project, ticket, true, _pins, presented) do
    sub = if presented, do: "presentation", else: "files"

    %{
      label: if(presented, do: "Read the presentation", else: "Review the changeset"),
      href: ~p"/tickets/#{project}/#{ticket.number}?tab=changes&sub=#{sub}"
    }
  end

  defp review_link(project, ticket, false, pins, _presented) do
    label =
      case pins do
        [{doc, version}] -> "Review #{doc} v#{version}"
        pins -> "Review #{length(pins)} versions"
      end

    %{label: label, href: ~p"/tickets/#{project}/#{ticket.number}?tab=docs"}
  end

  # The way forward picked, or nil: nothing is preselected (plan § 6, as Accept and the ticket's
  # Ways forward), so the dock's button names no way and is disabled until one is picked. An item
  # with no ticket — the accounts waiting — has no way to pick.
  defp picked(%{ticket: nil}, _detail, _ways), do: nil

  defp picked(item, detail, ways) do
    way = Map.get(ways, item.ticket.id)
    {rows, _links} = ways_of(item, detail)
    if way in Enum.map(rows, & &1.value), do: way
  end

  attr :item, :map, required: true
  attr :detail, :map, required: true

  defp chat_reply(assigns) do
    ~H"""
    <section id="queue-reply" class="queue-block">
      <%!-- With questions, what it asked is the sentence and the card; the reply drawn whole
            would repeat them. Without, the whole reply is what is being decided about. --%>
      <.eyebrow :if={@item.detail.questions == []}>The agent said</.eyebrow>
      <QueuePast.clamped
        :if={@item.detail.questions == [] and @item.detail.text}
        id="queue-reply-said"
        text={ForgeWeb.Transcript.asked(@item.detail.text)}
      />
      <div class="queue-links">
        <.link
          :for={doc <- @detail[:produced] || []}
          id={"queue-produced-#{doc.name}"}
          navigate={
            ~p"/tickets/#{@item.project}/#{@item.ticket.number}/artifacts/#{doc.name}/#{doc.version}"
          }
          class="queue-link"
        >
          Read {doc.name} v{doc.version} ›
        </.link>
        <.link navigate={~p"/chats/#{@item.detail.chat_id}"} class="queue-link">
          Open the chat ›
        </.link>
      </div>
    </section>
    """
  end

  defp schedule_path(%{project: project, detail: detail}),
    do: ForgeWeb.SchedulesView.path(%{name: project}, detail)

  attr :item, :map, required: true

  # A schedule that failed or switched itself off: which one, where it is declared, and the way to
  # it. What it says is in the sentence above; the reason is also the schedule's own on the Workflow
  # view, where it stays after this item is dismissed.
  defp schedule_alert(assigns) do
    ~H"""
    <section id="queue-schedule" class="queue-block">
      <p class="queue-quiet">
        Declared in {if @item.detail.ticket_type,
          do: "the #{@item.detail.ticket_type} type's workflow file",
          else: "the project's workflow file"}.
        Dismissing it only clears this item: the schedule's own page keeps what went wrong.
      </p>
      <div class="queue-links">
        <.link
          navigate={schedule_path(@item)}
          class="queue-link"
        >
          Open the schedule ›
        </.link>
      </div>
    </section>
    """
  end

  attr :item, :map, required: true
  attr :detail, :map, required: true
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
        project={@item.project}
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
        project={@item.project}
        hidden={[{"chat", @item.detail.chat_id}, {"reply", @item.detail.reply}]}
      >
        <:dock><.later /></:dock>
      </.question_form>
    </.split_pane>
    """
  end

  defp dock(assigns) do
    {rows, links} = ways_of(assigns.item, assigns.detail)

    assigns =
      assign(assigns,
        offered: rows,
        links: links,
        picked: picked(assigns.item, assigns.detail, assigns.ways)
      )

    ~H"""
    <Actions.refused id="queue-refusal" refusal={@refusal} at={~w(retry extend transition)} />
    <div id="queue-dock" class="queue-dock">
      <.later />
      <%!-- Never decided here: an approval is the decision row on its ticket, beside what it
            approves (`docs/design/ui.md` § The decision row) — and so is a way forward that
            approves or merges. --%>
      <.button
        :if={@item.kind == :approval}
        id={"review-#{@item.ticket.id}"}
        variant="outline"
        fill
        chevron
        navigate={review_href(@item, @detail)}
      >
        {review_label(@item, @detail)}
      </.button>
      <.button
        :for={{link, index} <- Enum.with_index(@links)}
        id={"review-#{@item.ticket.id}-#{index}"}
        variant="outline"
        fill
        chevron
        navigate={link.href}
      >
        {link.label}
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
        {way_label(@offered, @picked)}
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
        :if={@item.kind == :schedule}
        id="queue-schedule-dismiss"
        type="button"
        variant="primary"
        fill
        phx-click="schedule:dismiss"
        phx-value-id={@item.detail.id}
        phx-disable-with="Dismissing…"
      >
        Dismiss
      </.button>
      <.button
        :if={@item.kind == :schedule}
        id="queue-schedule-open"
        variant="outline"
        fill
        chevron
        navigate={schedule_path(@item)}
      >
        Open the schedule
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

  defp way_label(_rows, nil), do: "Pick a way forward"
  defp way_label(rows, picked), do: Enum.find_value(rows, &(&1.value == picked && &1.label))

  # The approval's way on, by the same rule as a way forward's (`review_link/5`): what it pins
  # decides where it leads.
  defp review_href(item, detail), do: approval_link(item, detail).href
  defp review_label(item, detail), do: approval_link(item, detail).label

  defp approval_link(%{project: project, ticket: ticket} = item, detail),
    do: review_link(project, ticket, change?(item), item.approve, detail[:presented])

  defp change?(%{ticket: ticket, approve: approve}),
    do: List.keymember?(approve, @changeset, 0) or Engine.approval_merges?(ticket)

  attr :pass, :map, required: true
  attr :left, :list, required: true
  attr :now, :any, required: true

  # 13d: the pass ends somewhere definite — what was decided, what is left with a way back to it —
  # and then the three quiet groups, which are the list column's and follow this on a phone. **Green
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

  attr :id, :string, required: true
  attr :prefix, :string, required: true, doc: "for the ids of the lines: the group is drawn twice"
  attr :digest, :list, required: true
  attr :now, :any, required: true

  # Prose, not items: no mark, no answer rows, no accent, because nothing here is waiting on
  # anyone. Each line leads to its ticket, where the question is answered — see docs/design/ui.md
  # § Not waiting on you.
  defp digest(assigns) do
    ~H"""
    <section :if={@digest != []} id={@id} class="queue-quiet-group">
      <.eyebrow>Not waiting on you</.eyebrow>
      <p class="queue-quiet">{digest_sentence(@digest)}</p>
      <ul>
        <li :for={item <- @digest} id={"#{@prefix}assumption-#{item.question.id}"}>
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

  attr :id, :string, required: true
  attr :open, :list, required: true
  attr :projects, :map, required: true
  attr :now, :any, required: true

  # The Tickets list's own rows (`ForgeWeb.ProjectTickets.list/1`), each naming its project and
  # linking into it, usage whenever there is one. One list, newest change first, with no cap: the
  # rows come ordered from `ProjectTickets.rows/2`, and nothing here decides which are shown.
  defp open_tickets(assigns) do
    ~H"""
    <section :if={@open != []} id={@id} class="queue-quiet-group">
      <.eyebrow>Open tickets</.eyebrow>
      <ProjectTickets.list
        id={"#{@id}-rows"}
        rows={@open}
        named={@projects}
        usage_always
        now={@now}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :held, :list, required: true
  attr :projects, :map, required: true
  attr :now, :any, required: true

  # The tickets on hold with a decision waiting, as the Tickets list draws a held ticket: quiet,
  # never amber, its latest line naming what waits (`ProjectTickets.rows/2`, `held:`). The decision
  # is made on the ticket's page, which each row leads to; nothing here is an item or is counted.
  defp held_tickets(assigns) do
    ~H"""
    <section :if={@held != []} id={@id} class="queue-quiet-group">
      <.eyebrow>On hold</.eyebrow>
      <ProjectTickets.list
        id={"#{@id}-rows"}
        rows={@held}
        named={@projects}
        usage_always
        now={@now}
      />
    </section>
    """
  end

  defp destination(%{kind: :chat} = item), do: ~p"/chats/#{item.detail.chat_id}"
  defp destination(item), do: ~p"/tickets/#{item.project}/#{item.ticket.number}"

  # The item's eyebrow: its kind and where it is. An assumption in the same card is named apart
  # rather than added to what is waiting.
  defp kind_label(%{kind: :questions, questions: questions, version: version} = item) do
    optional = Enum.count(questions, &(not &1.blocking))

    label =
      if optional == 0,
        do: QueueItems.kind(item),
        else: "#{QueueItems.kind(item)} · #{optional} optional"

    "#{label} · #{version.artifact.name} v#{version.version}"
  end

  defp kind_label(%{kind: :approval} = item),
    do: "approval · #{item.ticket.state} → #{item.detail["to"]}"

  defp kind_label(item), do: QueueItems.kind(item)

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

  # A schedule's alert says which schedule, what happened and why, as the Workflow view does. The
  # words come from a repository, so they are text and nothing else.
  defp sentence(%{kind: :schedule, detail: %{problem_kind: :switched_off} = d}),
    do: "Schedule #{d.name} switched itself off: #{d.reason}."

  defp sentence(%{kind: :schedule, detail: d}),
    do: "Schedule #{d.name} could not admit its ticket: #{d.reason}."

  defp sentence(%{kind: :accounts, count: 1}), do: "1 account waits to be approved."
  defp sentence(%{kind: :accounts, count: count}), do: "#{count} accounts wait to be approved."

  defp first_line(nil), do: "It is waiting for you."

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 160)
  end

  defp digest_sentence([_one]), do: "1 assumption was stated and work continued."

  defp digest_sentence(digest),
    do: "#{length(digest)} assumptions were stated and work continued."

  defp closing([]), do: "Nothing needs you. Work continues without you."
  defp closing(left), do: "#{length(left)} left for later."

  defp push(event, params, socket), do: {:noreply, PushEvents.handle(event, params, socket)}
end
