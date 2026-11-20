defmodule Forge.Queue do
  @moduledoc """
  The operator's queue: everything waiting on a human decision, in one ordered list.
  Blocking questions, pending approvals, stuck tickets, tickets resting in a human state that
  has a way forward, conversations waiting on a reply, and schedules that failed or switched
  themselves off (`docs/design/schedules.md` § Alerts).

  And one kind in that list that is waiting on nobody: an open non-blocking question, served as
  `:assumption` — the agent said what it assumed and carried on. It is here so that it reaches
  someone who has not opened its ticket (`docs/design/job-prompt.md` § Non-blocking questions),
  and it is a kind of its own so that nothing reading the queue can count it as a question that
  halted a job. `waiting?/1` is the one place that says which is which. The list is the
  decisions, oldest first, and then the assumptions, oldest first: they are never sorted in among
  what is waiting (`docs/design/ui.md` § Not waiting on you).

  `open_tickets/2` and `held/1` are two more reads, for the Queue page alone: the open tickets that
  wait on nobody, and the held tickets that have a decision waiting. Neither is in `items/1` and
  nothing counts them — see their own docs. **A ticket on hold has no decision as an item**: its
  decisions are `held/1`'s, listed quietly, never counted and never pushed (`docs/design/ui.md` § What the queue
  counts).
  """

  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]

  require Logger

  alias Forge.Accounts.User
  alias Forge.{Artifacts, Conversations, Engine, MergeQueue, Projects, Repo, Tickets}
  alias Forge.Artifacts.Question
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  # A ticket that can still be waiting on someone: one that is running or stuck. The queue loads
  # only these, and one ticket's items are read only for these, from this one list.
  @open Forge.Tickets.Ticket.open_statuses()

  @typedoc """
  One thing waiting on a person.

  `ticket` is nil for a conversation about a project and for a schedule that failed or switched
  itself off, which is why every reader of this has to take a project of its own rather than
  reaching through the ticket.
  """
  @type item :: %{
          kind: :question | :assumption | :approval | :stuck | :review | :chat | :schedule,
          ticket: Ticket.t() | nil,
          project: Projects.Project.t(),
          since: DateTime.t(),
          question: Question.t() | nil,
          detail: map()
        }

  @doc """
  Everything on the node waiting on a person. Node-wide, so no operator surface calls it:
  the queue a person is shown is `items/1`.
  """
  @spec items() :: [item()]
  def items, do: build(nil)

  @doc """
  The queue as one user sees it: the union over the projects they are a member of.

  This is the read that leaks most easily — refusing a mutation is easy to get right, and a
  list that quietly includes one extra project looks exactly like a working queue. See
  `docs/design/identity.md` § Read scoping is the half that leaks.
  """
  @spec items(User.t()) :: [item()]
  def items(%User{} = user), do: build(Enum.map(Projects.list(user), & &1.id))

  @doc """
  The queue button's count (`docs/design/ui.md` § What the queue counts): the number of items the
  queue page draws for this user — a document version's blocking questions are one item however
  many they are, and an assumption is none — and, for a node admin, the accounts waiting for
  approval, because an account waiting on an admin is a decision too.

  Scoped by membership like `items/1`, which it reads.
  """
  @spec count(User.t()) :: non_neg_integer()
  def count(%User{} = user), do: count(items(user), waiting_accounts(user))

  @doc """
  `count/1` over a queue already read: `items/1`'s items and `waiting_accounts/1`'s figure. The
  queue page reads both to draw them and counts with this, so its subline and the queue button
  are one computation over the same reads, not two that agree.
  """
  @spec count([item()], non_neg_integer()) :: non_neg_integer()
  def count(items, accounts) when is_list(items), do: tally(items) + accounts

  @doc """
  How many of `items` the queue page draws: the waiting ones, a document version's blocking
  questions counted once. `count/1` is this over a user's queue, and the projects page is this
  over each project's share of it (`docs/design/ui.md` § The projects page), so the two never
  disagree about what one item is.
  """
  @spec tally([item()]) :: non_neg_integer()
  def tally(items) do
    {questions, rest} =
      items |> Enum.filter(&waiting?/1) |> Enum.split_with(&(&1.kind == :question))

    versions = questions |> Enum.uniq_by(& &1.question.artifact_version_id) |> length()

    versions + length(rest)
  end

  @doc """
  The accounts waiting on `user`'s approval: for a node admin the pending accounts, for anybody
  else none. Part of `count/1`, and the queue page adds it to the items it draws, so its subline
  and the queue button say one number (`docs/design/ui.md` § What the queue counts).
  """
  @spec waiting_accounts(User.t()) :: non_neg_integer()
  def waiting_accounts(%User{node_admin: true}), do: Forge.Accounts.count_pending_users()
  def waiting_accounts(%User{}), do: 0

  @doc """
  What waits on one ticket, read the way the queue reads every ticket, **held or not**: what a
  ticket's own page counts as waiting is then what the queue would count for it, from one
  definition (`docs/design/ui.md` § Decide and Timeline). A finished ticket has none.

  A held ticket's decisions are here and not in `items/1`: `held/1` lists them and the push watch
  reads them to take them as seen, which is why this one does not take the hold into account. Its
  step conversation is the exception — `unheld_chat/1`, because `for_chat/1` leaves it out while
  the ticket is held and the watch reads the ticket and not the conversation.
  """
  @spec for_ticket(Ticket.t()) :: [item()]
  def for_ticket(%Ticket{status: status} = ticket) when status in @open do
    case askable([ticket]) do
      [] -> []
      [ticket] -> questions([ticket]) ++ decisions([ticket]) ++ step_items(ticket)
    end
  end

  def for_ticket(%Ticket{}), do: []

  # A chat step's conversation waiting for the person's reply is the ticket waiting on a person:
  # it is in the queue as the conversation already, and a ticket page counts what the queue would
  # (`docs/design/ui.md` § Decide and Timeline) — whether or not it holds a machine, so this reads
  # the step's conversation and not only a live one.
  defp step_items(%Ticket{} = ticket) do
    case Forge.Steps.chat_for(ticket) do
      nil -> []
      chat -> unheld_chat(chat)
    end
  end

  @doc """
  The queue's item for one conversation — the one it would list — or none: a conversation is
  in the queue once the agent's turn has ended and the person has not spoken since
  (`Conversations.waiting?/1`) — a reply still being written is the conversation working. **A
  step's conversation needs no machine**: nothing reads as stopped, so one whose machine was
  released is waiting on its reader just the same, for as long as its step is the ticket's
  (`Conversations.sendable/2`); and one the person spoke to last, or whose reply was cut off, that
  holds no machine is the lost reply, an item of its own kind that says so. An ordinary
  conversation whose machine has gone is in no queue (`docs/design/conversations.md` § In the
  queue). **A step's conversation of a ticket on hold is in none either**: it is the ticket's
  decision, and a held ticket's are `held/1`'s.
  """
  @spec for_chat(Job.t()) :: [item()]
  def for_chat(%Job{kind: :chat, state: state, ticket_id: ticket_id} = chat)
      when state != nil and ticket_id != nil do
    if held_ticket?(ticket_id), do: [], else: unheld_chat(chat)
  end

  def for_chat(%Job{kind: :chat} = chat), do: unheld_chat(chat)

  defp held_ticket?(ticket_id),
    do: Repo.exists?(from t in Ticket, where: t.id == ^ticket_id and not is_nil(t.held_at))

  defp unheld_chat(%Job{} = chat) do
    cond do
      chat.status in Conversations.live_statuses() -> chat_item(chat)
      Job.step?(chat) and Conversations.sendable(Repo, chat) == :ok -> chat_item(chat)
      true -> []
    end
  end

  @doc """
  Whether an item is waiting on a person. Everything is, except an assumption: a question the
  agent did not stop for, which no count of what is waiting may include.
  """
  @spec waiting?(item()) :: boolean()
  def waiting?(%{kind: :assumption}), do: false

  def waiting?(%{kind: _kind}), do: true

  @doc """
  The tickets the queue page draws in **Open tickets** (`docs/design/ui.md` § A job waiting for a
  machine): every open ticket of the viewer's projects that is `:active`, not on hold, and not the
  ticket of any of `items` that is waiting on a person. Newest change first, as the project's
  Tickets list orders its rows: the query says so and `ForgeWeb.ProjectTickets.rows/2`, which draws
  them, keeps it.

  `items` is the `items/1` the page already read, so the group and the decisions are one read of
  the queue and a ticket is never in both. Its rows' facts — live job, last line, merge queue
  place, spend pause — are `Forge.Tickets.Doing.facts/2`'s, the project page's own.

  **Active, not open.** A stuck ticket is an item and keeps the accent flag `items/1` gives it
  rather than a second, quieter line that says the opposite; the read excludes it by the ticket's
  own `status` column. **Not on hold**: nothing is moving on it and nothing is about to
  (`docs/design/ui.md` § What the queue counts), and one with a decision waiting is `held/1`'s.
  One whose only item is an ordinary conversation about it is neither: that conversation is an item
  and the ticket is not drawn twice. **A paused ticket is in**, drawn `paused · spend` — never an item, never counted, never
  pushed (`docs/design/capacity.md` § Four exhaustions).

  Deliberately not part of `items/1`. That list is what the JSON API, the CLI and the push digest
  are built on, and each of them matches its kinds exhaustively — `Forge.CLI.queue_line/1` has no
  catch-all clause at all. An open ticket is not a decision, so it is not in a list whose readers
  are entitled to assume one.
  """
  @spec open_tickets(User.t(), [item()]) :: [Ticket.t()]
  def open_tickets(%User{} = user, items) do
    project_ids = Enum.map(Projects.list(user), & &1.id)

    waiting =
      for %{ticket: %Ticket{id: id}} = item <- items, waiting?(item), uniq: true, do: id

    Repo.all(
      from t in Ticket,
        where: t.status == :active,
        where: t.project_id in ^project_ids,
        where: is_nil(t.held_at),
        where: t.id not in ^waiting,
        order_by: [desc: t.updated_at, desc: t.id]
    )
  end

  @doc """
  The tickets the queue page draws in **On hold** (`docs/design/ui.md` § The end of the pass, and
  *All*): every open ticket of the viewer's projects that is on hold and has a decision waiting,
  each with what waits on it. Newest change first, as `open_tickets/2` orders them. A held ticket
  with nothing waiting — a parked idea — is in no group of the queue and not here.

  **Not in `items/1`, and nothing counts it**: a held ticket's decisions are neither counted nor
  pushed, and the page that draws them leads to the ticket's own page, where they are made. Scoped
  by membership like `items/1`; an ordinary conversation about the ticket is its own item there
  and is not in these, and a non-blocking question is not waiting (`waiting?/1`).
  """
  @spec held(User.t()) :: [{Ticket.t(), [item()]}]
  def held(%User{} = user) do
    project_ids = Enum.map(Projects.list(user), & &1.id)

    tickets =
      Repo.all(
        from t in Ticket,
          where: t.status in @open,
          where: t.project_id in ^project_ids,
          # Equivalent mutant: `held_items/1` drops a ticket that is not on hold, so this only
          # narrows the rows it reads — the same rule, twice, so that neither is the one thing
          # standing between an unheld ticket and the page.
          where: not is_nil(t.held_at),
          order_by: [desc: t.updated_at, desc: t.id]
      )

    held = held_items(tickets)
    for ticket <- tickets, items = Map.get(held, ticket.id), do: {ticket, items}
  end

  @doc """
  What waits on each of `tickets` that is on hold, by ticket id, for the tickets that have
  something: `held/1`'s read over tickets a caller has already scoped, which is how the project
  page names what a held ticket waits on. A ticket that is not held has no entry — its items are
  `items/1`'s.
  """
  @spec held_items([Ticket.t()]) :: %{String.t() => [item()]}
  def held_items(tickets) do
    for ticket <- tickets,
        Ticket.held?(ticket),
        items = Enum.filter(for_ticket(ticket), &waiting?/1),
        items != [],
        into: %{},
        do: {ticket.id, items}
  end

  defp build(project_ids) do
    tickets =
      Repo.all(
        from t in Ticket,
          # Equivalent mutant, but not for the reason first written here. The original comment
          # said `ticket_items/1` reaches `review_item/2` for any other status; it does not —
          # the `pending_transition` clause matches first and checks neither status nor
          # terminality, so a `:done` ticket carrying one would appear as an approval.
          #
          # What actually makes this redundant is an invariant in the engine:
          # `put_pending_approval/4` always writes `status: :active`, `put_transition/6` always
          # clears `pending_transition`, and `Engine.cancel/2` clears it as it writes `:cancelled`
          # — so the pair that would distinguish them cannot be produced. This stays as a narrowing of the
          # rows loaded, and a fourth `ticket_items/1` clause would need this read again.
          #
          # The rule a test can fail on is "a finished ticket is not in the queue", in
          # `scoping_test.exs`.
          where: t.status in @open,
          where: ^visible(project_ids),
          order_by: t.inserted_at
      )

    {held, unheld} = Enum.split_with(tickets, &Ticket.held?/1)

    # **A held ticket's decisions are not items** (`held/1`): its approval, stuck flag and rest in a
    # human state are not read at all, and of its questions only the assumptions stay, because
    # those wait on nobody and are the queue's quiet group, held or not. A held ticket that never
    # started has no question to carry (`askable/1`), so none is left out by dropping it here.
    held_assumptions = Enum.reject(questions(held), &(&1.kind == :question))

    {waiting, assumed} =
      (questions(unheld) ++
         held_assumptions ++
         decisions(unheld) ++
         chats(project_ids) ++
         Forge.Schedules.items(project_ids))
      |> Enum.split_with(&waiting?/1)

    oldest_first(waiting) ++ oldest_first(assumed)
  end

  # **A ticket on hold that has never started asks nothing**: the hold itself is never a queue item
  # (`docs/design/ui.md` § What the queue counts), and a ticket nothing has run for has no question
  # or approval of its own — what could be there is a by-hand move into a human state, a review of
  # nothing. A held ticket that has started keeps its decisions, which `held/1` lists; this keeps
  # that one out of it, and is read by `for_ticket/1` alone: `build/1` sets every held ticket apart
  # before it would matter.
  defp askable(tickets) do
    held = for t <- tickets, Ticket.held?(t), do: t.id

    case held do
      [] ->
        tickets

      ids ->
        started = MapSet.new(Tickets.started_ids(ids))
        Enum.reject(tickets, &(&1.id in ids and &1.id not in started))
    end
  end

  # A queued ticket waits on the merge queue and not on a person: its approval is given, so nothing
  # of it is offered here — and the queue is never drawn under the merge queue's name
  # (`docs/design/ui.md` § Decide and Timeline).
  defp decisions(tickets) do
    queued = MergeQueue.queued_ids(Enum.map(tickets, & &1.id))
    tickets |> Enum.reject(&(&1.id in queued)) |> Enum.flat_map(&ticket_items/1)
  end

  defp oldest_first(items), do: Enum.sort_by(items, & &1.since, DateTime)

  # `true` rather than a missing clause, so that the scoped and unscoped reads run the same
  # query shape and a mistake in one cannot pass because the other took a different path.
  defp visible(nil), do: dynamic(true)
  defp visible(project_ids), do: dynamic([t], t.project_id in ^project_ids)

  # A conversation waiting on a person is literally what the queue is for: something that will
  # not move until someone acts. It is in the queue only while it is waiting — a chat mid-reply
  # is not waiting on you, it is working (`docs/design/conversations.md` § In the queue).
  # A step's conversation is read whether or not it holds a machine.
  defp chats(project_ids) do
    live =
      Repo.all(
        from j in Job,
          left_join: t in Ticket,
          on: t.id == j.ticket_id,
          where: j.kind == :chat and j.status in ^Conversations.live_statuses(),
          where: ^visible_chat(project_ids),
          # A step's conversation of a ticket on hold is the ticket's decision, not an item
          # (`for_chat/1`); an ordinary conversation about one is.
          where: is_nil(j.state) or is_nil(t.held_at)
      )

    (live ++ released_steps(project_ids))
    |> Enum.flat_map(&chat_item/1)
  end

  # The step conversations that hold no machine, for the tickets that are in that step at that
  # visit — the only ones a message can still carry on (`Conversations.sendable/2`, asked of each
  # candidate, which is a handful: one per ticket resting in a chat step).
  defp released_steps(project_ids) do
    candidates =
      Repo.all(
        from j in Job,
          join: t in Ticket,
          on: t.id == j.ticket_id and t.state == j.state,
          where: j.kind == :chat and not is_nil(j.state),
          where: j.status not in ^Conversations.live_statuses(),
          where: t.status in @open and is_nil(t.held_at),
          where: ^visible_chat(project_ids),
          order_by: [desc: j.attempt]
      )

    # Only the latest visit's: an earlier one is over (`sendable/2` says so too, and this keeps
    # the check to one candidate per ticket). One conversation per ticket and visit is the
    # engine's rule, so `uniq_by` on the ticket keeps the newest.
    candidates
    |> Enum.uniq_by(& &1.ticket_id)
    |> Enum.filter(&(Conversations.sendable(Repo, &1) == :ok))
  end

  defp visible_chat(nil), do: dynamic(true)
  defp visible_chat(project_ids), do: dynamic([j], j.project_id in ^project_ids)

  defp chat_item(%Job{} = chat) do
    messages = Conversations.messages(chat.id)

    cond do
      Conversations.waiting?(messages) -> [waiting_chat(chat, messages)]
      # Only a step's conversation reaches here with no machine (`for_chat/1`, `chats/1`): the
      # person's message was the last word, or the reply was cut off before its turn ended.
      Conversations.lost?(chat, messages) -> [lost_chat(chat, messages)]
      true -> []
    end
  end

  @lost "The reply was lost with its machine; send again to carry on."

  defp lost_chat(%Job{} = chat, messages) do
    %{
      kind: :chat,
      ticket: chat.ticket_id && Tickets.get!(chat.ticket_id),
      project: Projects.get!(chat.project_id),
      since: chat.updated_at,
      question: nil,
      detail: %{
        chat_id: chat.id,
        text: @lost,
        questions: [],
        reply: Conversations.reply_ref(messages),
        lost: true
      }
    }
  end

  defp waiting_chat(%Job{} = chat, messages) do
    last = List.last(messages)

    %{
      kind: :chat,
      ticket: chat.ticket_id && Tickets.get!(chat.ticket_id),
      project: Projects.get!(chat.project_id),
      # When it started waiting: the turn's end, not the first words of the reply.
      since: last.recorded.at,
      question: nil,
      detail: %{
        chat_id: chat.id,
        text: last.text,
        questions: Conversations.questions(last),
        reply: Conversations.reply_ref(messages),
        lost: false
      }
    }
  end

  # Every open question, blocking or not. The kind is what keeps them apart: a blocking one halted
  # a job and is a decision; a non-blocking one is an assumption the job carried on from.
  defp questions(tickets) do
    by_id = Map.new(tickets, &{&1.id, &1})

    Enum.flat_map(tickets, fn ticket ->
      ticket.id
      |> Artifacts.open_questions()
      |> Enum.map(fn question ->
        %{
          kind: if(question.blocking, do: :question, else: :assumption),
          ticket: by_id[ticket.id],
          project: Projects.get!(ticket.project_id),
          since: question.inserted_at,
          question: question,
          detail: %{key: question.key, text: question.text, assumption: question.assumption}
        }
      end)
    end)
  end

  defp ticket_items(%Ticket{status: :stuck} = ticket) do
    [
      %{
        kind: :stuck,
        ticket: ticket,
        project: Projects.get!(ticket.project_id),
        since: ticket.updated_at,
        question: nil,
        detail: %{
          state: ticket.state,
          reason: Engine.why_stuck(ticket),
          transitions: transitions_from(ticket),
          reviewable: reviewable?(ticket),
          retry: retryable?(ticket),
          # What a job that ran out may be given (`Forge.Jobs.Extensions.offer/1`), nil when the
          # ticket's job did not, and the figures the form and *Run again* are judged against.
          extend: Forge.Jobs.Extensions.offer(ticket),
          room: room(ticket)
        }
      }
    ]
  end

  defp ticket_items(%Ticket{pending_transition: pending} = ticket) when is_map(pending) do
    [
      %{
        kind: :approval,
        ticket: ticket,
        project: Projects.get!(ticket.project_id),
        since: ticket.updated_at,
        question: nil,
        detail: pending
      }
    ]
  end

  defp ticket_items(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> review_item(ticket, workflow)
      {:error, errors} -> unparseable(ticket, errors, [])
    end
  end

  defp review_item(%Ticket{} = ticket, workflow) do
    state = Workflow.state(workflow, ticket.state)

    if state && ForgeCore.Workflow.State.human?(state) &&
         not Workflow.terminal?(workflow, ticket.state) do
      [
        %{
          kind: :review,
          ticket: ticket,
          project: Projects.get!(ticket.project_id),
          since: ticket.updated_at,
          question: nil,
          detail: %{
            state: ticket.state,
            transitions: transitions_from(ticket),
            reviewable: reviewable?(ticket)
          }
        }
      ]
    else
      []
    end
  end

  # The states an operator may move the ticket to from where it rests. Both stuck and review
  # items carry these, so the choices are in the queue and not only in the workflow file.
  # Two edges may share a target - the grammar only requires distinct `when` values per
  # `from` - and this names states, so each is named once.
  defp transitions_from(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Engine.offered_transitions(ticket, workflow)
      {:error, errors} -> unparseable(ticket, errors, [])
    end
  end

  defp room(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Forge.Jobs.Extensions.cap_facts(ticket, workflow)
      {:error, _errors} -> nil
    end
  end

  # Whether the state the stuck ticket rests in can be run again (`Engine.retry/2`). Asked through
  # the parsed workflow for the reason above: one ticket whose definition no longer parses costs
  # its own detail, not the queue.
  defp retryable?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, _workflow} -> Engine.retryable?(ticket)
      {:error, errors} -> unparseable(ticket, errors, false)
    end
  end

  # Whether the decision in front of the operator merges, and so whether they should be offered
  # the diff before taking it — asked of the workflow by `Engine.merge_decision?/2` rather than of
  # what the decision pins, which is not the same question (one definition for the four surfaces
  # that ask). Held on the item rather than recomputed by the page, so the API serves the same
  # fact.
  defp reviewable?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> Engine.merge_decision?(ticket, workflow)
      {:error, errors} -> unparseable(ticket, errors, false)
    end
  end

  # The queue serves every ticket at once, so a definition that no longer validates costs the
  # operator that ticket's detail, not the whole queue.
  defp unparseable(%Ticket{} = ticket, errors, fallback) do
    Logger.warning(
      "ticket #{ticket.id} pinned a workflow that no longer parses: #{inspect(errors)}"
    )

    fallback
  end
end
