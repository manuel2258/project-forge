defmodule Forge.Queue do
  @moduledoc """
  The operator's queue: everything waiting on a human decision, in one ordered list.
  Blocking questions, pending approvals, stuck tickets, tickets resting in a human state that
  has a way forward, and conversations waiting on a reply.

  And one kind in that list that is waiting on nobody: an open non-blocking question, served as
  `:assumption` — the agent said what it assumed and carried on. It is here so that it reaches
  someone who has not opened its ticket (`docs/design/job-prompt.md` § Non-blocking questions),
  and it is a kind of its own so that nothing reading the queue can count it as a question that
  halted a job. `waiting?/1` is the one place that says which is which. The list is the
  decisions, oldest first, and then the assumptions, oldest first: they are never sorted in among
  what is waiting (`docs/design/ui.md` § Not waiting on you).

  `worker_status/1` is a second list, read by the Queue page alone: the tickets whose current job
  is running on a worker or still waiting to start. It is not in `items/1` and nothing counts it —
  see its own doc.
  """

  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]

  require Logger

  alias Forge.Accounts.User
  alias Forge.{Artifacts, Conversations, Engine, Jobs, Projects, Repo, Spend, Tickets}
  alias Forge.Artifacts.Question
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow

  # A ticket that can still be waiting on someone: one that is running or stuck. The queue loads
  # only these, and one ticket's items are read only for these, from this one list.
  @open Forge.Tickets.Ticket.open_statuses()

  @typedoc """
  One thing waiting on a person.

  `ticket` is nil for a conversation about a project, which is why every reader of this has to
  take a project of its own rather than reaching through the ticket.
  """
  @type item :: %{
          kind:
            :question
            | :assumption
            | :approval
            | :stuck
            | :review
            | :chat
            | :on_worker
            | :awaiting_worker,
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
  The queue's items for one ticket, read the way the queue reads every ticket: what a ticket's
  own page counts as waiting is then what the queue would count for it, from one definition
  (`docs/design/ui.md` § Decide and Timeline). A finished ticket has none.
  """
  @spec for_ticket(Ticket.t()) :: [item()]
  def for_ticket(%Ticket{status: status} = ticket) when status in @open,
    do: questions([ticket]) ++ ticket_items(ticket)

  def for_ticket(%Ticket{}), do: []

  @doc """
  The queue's item for one conversation — the one it would list — or none: a conversation is
  in the queue only while it is live and the agent spoke last.
  """
  @spec for_chat(Job.t()) :: [item()]
  def for_chat(%Job{kind: :chat} = chat) do
    if chat.status in Conversations.live_statuses(), do: chat_item(chat), else: []
  end

  @doc """
  Whether an item is waiting on a person. Everything is, except an assumption: a question the
  agent did not stop for, which no count of what is waiting may include.
  """
  @spec waiting?(item()) :: boolean()
  def waiting?(%{kind: :assumption}), do: false

  # Named rather than left to the catch-all below. `worker_status/1`'s kinds never reach here
  # through `items/1`, but this function's contract is every kind of `item()`, and a reader that
  # asked it about one would otherwise be told a running job is waiting on a person.
  def waiting?(%{kind: kind}) when kind in [:on_worker, :awaiting_worker], do: false

  def waiting?(%{kind: _kind}), do: true

  # The wait reasons `Forge.Jobs.Scheduler` records for a pause that *time* resolves rather than
  # a machine: the node's daily spend cap, and a project whose every credential is rate-limited.
  # A ticket held by one of these is **never in the queue** (`docs/design/capacity.md` § Four
  # exhaustions, three treatments) — it is drawn `PAUSED` where it lives and nowhere else,
  # because an item in the queue the operator cannot act on is the failure that note is written
  # against.
  @paused_waits ~w(spend_paused limited)

  @doc """
  The tickets whose work is already moving, or would be if a machine were free: the current job
  of each, as `:on_worker` when it is running on an assigned worker and `:awaiting_worker` when
  it is still pending. Oldest first, as one group.

  Active tickets only, and never one the node's spend cap or a rate-limited credential pool is
  holding — see `@paused_waits` and `under_way_item/2`. A stuck ticket keeps the accent flag
  `items/1` gives it rather than a second, quieter line, which is why the status is narrowed in
  the query and not afterwards.

  Deliberately not part of `items/1`. That list is what the JSON API, the CLI and the push digest
  are built on, and each of them matches its kinds exhaustively — `Forge.CLI.queue_line/1` has no
  catch-all clause at all. Neither of these kinds is a decision, so neither belongs in a list
  whose readers are entitled to assume one (`docs/design/ui.md` § A job waiting for a machine).
  """
  @spec worker_status(User.t()) :: [item()]
  def worker_status(%User{} = user) do
    projects = Projects.list(user)
    under_way(Enum.map(projects, & &1.id), Map.new(projects, &{&1.id, &1}))
  end

  defp under_way(project_ids, projects) do
    Repo.all(
      from t in Ticket,
        # `:active`, not `@open`. A stuck ticket can legitimately hold a job that still reads
        # pending — the engine's stuck-for-placement leaves the pending job on the row — and a
        # stuck ticket keeps its accent flag rather than gaining a second, quieter line that says
        # the opposite. Excluded by the read, whose model is the ticket's own `status` column,
        # and not by an `if` over a derived flag afterwards.
        where: t.status == :active,
        where: ^visible(project_ids)
    )
    |> Enum.flat_map(&under_way_item(&1, projects))
    |> drop_paused()
    |> oldest_first()
  end

  # The ticket's *current* job, which is the last of its workflow jobs and its commands by
  # creation — `work` on the ticket's own page, built from the same two reads
  # (`ForgeWeb.TicketLive`). A command counts because a command state creates no workflow job at
  # all (`docs/design/commands.md` § A command state) and an agent that invoked one parks while
  # it runs: reading only `Jobs.for_ticket/1` left the group empty while a build was on a
  # machine. Where a batch runs several commands at once this reads the last of them to be
  # created, so a ticket is listed while that one is live rather than until the whole batch is.
  #
  # A ticket whose current job has finished, parked or stopped on a question matches neither
  # clause and contributes nothing; so does one with no job at all.
  #
  # `worker_id` is checked on the running clause and deliberately not on the pending one, because
  # the column says where the job's *last* run was and not what is holding it: `Jobs.resume/1`
  # and `Commands.put_resume/3` put a job back to `:pending` without clearing it, so a resumed
  # job is pending on a worker id that is not a reservation. It is waiting for a machine like any
  # other pending job, and matching `worker_id: nil` here would show nothing for exactly the
  # tickets a person had just unblocked.
  defp under_way_item(%Ticket{} = ticket, projects) do
    case current_job(ticket) do
      %Job{status: :running, worker_id: worker_id} = job when not is_nil(worker_id) ->
        [under_way_entry(ticket, job, :on_worker, projects)]

      %Job{status: :pending} = job ->
        [under_way_entry(ticket, job, :awaiting_worker, projects)]

      _other ->
        []
    end
  end

  defp current_job(%Ticket{id: id}) do
    (Jobs.for_ticket(id) ++ Jobs.commands_for_ticket(id))
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> List.last()
  end

  # **The pauses, dropped after the fact and not in the query**, because neither is a column on
  # anything this read loads: the daily cap is a sum over the node's runs, and a rate-limited pool
  # is a reason the scheduler wrote on the job. Both are asked of the same thing that decided
  # them — the one `Forge.Spend` the `PAUSED · SPEND` chip reads, and the wait the ticket's own
  # timeline prints — so a ticket cannot read paused in one place and merely slow here.
  #
  # Only `:awaiting_worker` is dropped. A job already running on a machine is running whatever the
  # cap says; the cap stops the *next* one from starting.
  defp drop_paused(entries) do
    pending = for %{kind: :awaiting_worker, detail: %{job_id: id}} <- entries, do: id

    # Both reads are taken once for the whole page, outside the reject: `Spend.paused?/0` sums
    # the node's runs and `current_waits/1` is one query for every pending job at once, and a
    # predicate that asked either per entry would ask N times for one answer. `pending != []`
    # is an equivalent mutant — with nothing to drop the answer is unused either way — and is
    # there only so that a page with no pending job does not sum the node's spend to find out.
    capped? = pending != [] and Spend.paused?()
    waits = Jobs.current_waits(pending)

    Enum.reject(entries, fn entry ->
      entry.kind == :awaiting_worker and
        (capped? or paused_wait?(waits[entry.detail.job_id]))
    end)
  end

  defp paused_wait?(%Event{payload: %{"reason" => reason}}), do: reason in @paused_waits
  defp paused_wait?(_no_wait_recorded), do: false

  # `since` is when the thing the line describes began, which is not the same column for the two
  # kinds. A running job has a `started_at` — `Jobs.mark_started/3` writes it in the same update
  # as the status — and that is when the run started; its `inserted_at` could be ten hours
  # earlier if it waited that long for room, and "10h" beside *Running on a worker* would be a
  # lie. A pending job has no start, and its `inserted_at` is how long the ticket has been held.
  # The fallback is for a `:running` row written without one, which only a direct changeset does;
  # a `since` of nil would take the sort and the page down with it.
  defp under_way_entry(%Ticket{} = ticket, %Job{} = job, kind, projects) do
    %{
      kind: kind,
      ticket: ticket,
      project:
        Map.get_lazy(projects, ticket.project_id, fn -> Projects.get!(ticket.project_id) end),
      since: (kind == :on_worker && job.started_at) || job.inserted_at,
      question: nil,
      detail: %{job_id: job.id}
    }
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

    {waiting, assumed} =
      (questions(tickets) ++ Enum.flat_map(tickets, &ticket_items/1) ++ chats(project_ids))
      |> Enum.split_with(&waiting?/1)

    oldest_first(waiting) ++ oldest_first(assumed)
  end

  defp oldest_first(items), do: Enum.sort_by(items, & &1.since, DateTime)

  # `true` rather than a missing clause, so that the scoped and unscoped reads run the same
  # query shape and a mistake in one cannot pass because the other took a different path.
  defp visible(nil), do: dynamic(true)
  defp visible(project_ids), do: dynamic([t], t.project_id in ^project_ids)

  # A conversation waiting on a person is literally what the queue is for: something that will
  # not move until someone acts. It is in the queue only while it is waiting — a chat mid-reply
  # is not waiting on you, it is working (`docs/design/conversations.md` § In the queue).
  defp chats(project_ids) do
    Repo.all(
      from j in Job,
        where: j.kind == :chat and j.status in ^Conversations.live_statuses(),
        where: ^visible_chat(project_ids)
    )
    |> Enum.flat_map(&chat_item/1)
  end

  defp visible_chat(nil), do: dynamic(true)
  defp visible_chat(project_ids), do: dynamic([j], j.project_id in ^project_ids)

  defp chat_item(%Job{} = chat) do
    case Conversations.messages(chat.id) do
      [] ->
        []

      messages ->
        if List.last(messages).role == :assistant, do: [waiting_chat(chat, messages)], else: []
    end
  end

  defp waiting_chat(%Job{} = chat, messages) do
    last = List.last(messages)

    %{
      kind: :chat,
      ticket: chat.ticket_id && Tickets.get!(chat.ticket_id),
      project: Projects.get!(chat.project_id),
      since: last.at,
      question: nil,
      detail: %{
        chat_id: chat.id,
        text: last.text,
        questions: Conversations.questions(last),
        reply: Conversations.reply_ref(messages)
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
          retry: retryable?(ticket)
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

  # Whether the state the stuck ticket rests in can be run again (`Engine.retry/2`). Asked through
  # the parsed workflow for the reason above: one ticket whose definition no longer parses costs
  # its own detail, not the queue.
  defp retryable?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, _workflow} -> Engine.retryable?(ticket)
      {:error, errors} -> unparseable(ticket, errors, false)
    end
  end

  # Whether a decision from here pins the changeset — that is, whether it is a merge decision, and
  # so whether the operator should be offered the diff before taking it. Held on the item rather
  # than recomputed by the page, so the API serves the same fact.
  defp reviewable?(%Ticket{} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} ->
        workflow
        |> Workflow.transitions_from(ticket.state)
        |> Enum.any?(&(Workflow.changeset_artifact() in &1.approve))

      {:error, errors} ->
        unparseable(ticket, errors, false)
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
