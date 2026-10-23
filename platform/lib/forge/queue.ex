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
  alias Forge.Jobs.{Job, Runs}
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
  # exhaustions, three treatments), because an item in the queue the operator cannot act on is the
  # failure that note is written against. The cap is drawn `PAUSED · SPEND` on the board, the
  # project page and the ticket; the rate limit is drawn nowhere yet (`capacity.md` § Engine
  # support says the `PAUSED` surface for it is not built), so a ticket held by one is in no
  # operator surface but the wait sentence on its own timeline. That gap is the note's to close,
  # not this group's to paper over.
  @paused_waits ~w(spend_paused limited)

  # The job statuses that can produce a line at all: one is on a machine, the other is not yet.
  # Named here because `live_jobs/1` narrows the read to them and `live_job/1` partitions what it
  # loaded between them, and the two must mean the same thing.
  @live_statuses [:running, :pending]

  @doc """
  The tickets whose work is already moving, or would be if a machine were free: the live job of
  each, as `:on_worker` when it is running on an assigned worker and `:awaiting_worker` when it is
  pending. Oldest first, as one group.

  Active tickets only, and never one the node's spend cap or a rate-limited credential pool is
  holding — see `@paused_waits` and `drop_paused/1`. A stuck ticket keeps the accent flag
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
    tickets =
      Repo.all(
        from t in Ticket,
          # `:active`, not `@open`. A stuck ticket can legitimately hold a job that still reads
          # pending — the engine's stuck-for-placement leaves the pending job on the row — and a
          # stuck ticket keeps its accent flag rather than gaining a second, quieter line that
          # says the opposite. Excluded by the read, whose model is the ticket's own `status`
          # column, and not by an `if` over a derived flag afterwards.
          where: t.status == :active,
          where: ^visible(project_ids)
      )

    live = live_jobs(Enum.map(tickets, & &1.id))

    runs =
      Runs.started(for {_ticket_id, jobs} <- live, %{status: :running, id: id} <- jobs, do: id)

    tickets
    |> Enum.flat_map(&under_way_item(&1, live, runs, projects))
    |> drop_paused()
    |> oldest_first()
  end

  # Every ticket's live work in one query, grouped in memory, rather than two reads per ticket.
  # Narrowed twice on purpose:
  #
  # - **To the columns this decides on.** A command's `spec` embeds the whole script source
  #   (`docs/design/commands.md` § An invocation is a job — "spec is the script, the argv, the
  #   env, the commit, the resources and the timeout"), so reading rows whole shipped a body per
  #   command on every render of the page — forty on a ticket with forty builds.
  # - **To the two statuses that can produce a line**, named once in `@live_statuses` and read
  #   here. A finished, parked or waiting job is not loaded at all, so none of them can be
  #   mistaken for the ticket's current state, which is criterion 5 of `refinement.md` held by
  #   construction rather than by a check.
  defp live_jobs(ticket_ids) do
    Repo.all(
      from j in Job,
        where: j.ticket_id in ^ticket_ids,
        # A conversation is not the ticket's work. It is already in the queue above as a `:chat`
        # decision while it waits on a person (`docs/design/conversations.md` § In the queue),
        # and drawing the ticket again down here would say the same ticket was both waiting on
        # you and on a machine.
        where: j.kind in [:workflow, :command],
        where: j.status in @live_statuses,
        select: %{
          id: j.id,
          ticket_id: j.ticket_id,
          kind: j.kind,
          status: j.status,
          worker_id: j.worker_id,
          started_at: j.started_at,
          inserted_at: j.inserted_at
        }
    )
    |> Enum.group_by(& &1.ticket_id)
  end

  defp under_way_item(%Ticket{} = ticket, live, runs, projects) do
    case live_job(Map.get(live, ticket.id, [])) do
      {kind, job} -> [under_way_entry(ticket, job, kind, runs, projects)]
      :none -> []
    end
  end

  # **The ticket's live work, not its newest row.** A running job with a worker if it has one,
  # else a pending job, newest within whichever class wins. Sorting the ticket's jobs and its
  # commands by creation — the `work` its own page lists — was wrong here twice over:
  #
  # - A command is created after the agent that invoked it, so once the command finished and the
  #   agent resumed, the newest row was the *finished* command and the ticket left the group for
  #   the rest of its state. `implementing` in this repository may invoke ten.
  # - A batch is inserted in declared order, so the newest row of `invoke: [lint, test, build]` is
  #   `build` — whose five-second run ends while `lint` is still going. That read the ticket as
  #   nothing while two commands were on machines, or, if `build` had not been placed yet, drew
  #   *not yet on a worker* for a ticket that was running on one.
  #
  # **Running beats pending** because the ticket is on a machine the moment any of its work is,
  # and a line saying otherwise is worse than no line. Newest within the class because that is the
  # most recent thing the line could be describing.
  #
  # `worker_id` is required on the running side and deliberately not on the pending one: the
  # column says where the job's *last* run was and not what is holding it, and `Jobs.resume/1`
  # and `Commands.put_resume/3` return a job to `:pending` without clearing it. Matching
  # `worker_id: nil` there would show nothing for exactly the tickets a person had just unblocked.
  # **Widening a status here is an equivalent mutant; narrowing one is not.** Admitting
  # `:finished` to the running clause changes nothing observable, because `live_jobs/1`'s `where`
  # never loaded such a row — and admitting it to `@live_statuses` alone changes nothing either,
  # because this clause rejects it. Criterion 5 rests on the pair, and the test that fails when
  # *both* move is "a job that has finished is never the ticket's work, however it ended", whose
  # fixture carries a job in each of the four statuses that are not live — `:finished`,
  # `:hibernated`, `:waiting` and `:parked` — every one of them holding the `worker_id` it ran
  # on, because a row without one is rejected here whatever the status filter says.
  #
  # Dropping a status is a different matter and is caught on both sides: take `:pending` out of
  # `@live_statuses` and the whole pending half of this group disappears, failing tests in both
  # queue test files; drop this clause's `== :pending` and a job running on no worker is drawn as
  # waiting for one. `@live_statuses` is named above so that a widening has one place to be made
  # rather than two that must agree.
  defp live_job(jobs) do
    running = for job <- jobs, job.status == :running, not is_nil(job.worker_id), do: job
    pending = for job <- jobs, job.status == :pending, do: job

    cond do
      running != [] -> {:on_worker, newest(running)}
      pending != [] -> {:awaiting_worker, newest(pending)}
      true -> :none
    end
  end

  defp newest(jobs), do: Enum.max_by(jobs, & &1.inserted_at, DateTime)

  # **The pauses, dropped after the fact and not in the query**, because neither is a column on
  # anything this read loads: the daily cap is a sum over the node's runs, and a rate-limited pool
  # is a reason the scheduler wrote on the job. Each is asked of the thing that decided it — the
  # one `Forge.Spend` the `PAUSED · SPEND` chip reads, and the wait the ticket's own timeline
  # prints — so a ticket cannot read paused in one place and merely slow here.
  #
  # Only `:awaiting_worker` is dropped. A job already running on a machine is running whatever the
  # cap says; the cap stops the *next* one from starting.
  defp drop_paused(entries) do
    pending = for %{kind: :awaiting_worker, detail: %{job_id: id}} <- entries, do: id
    waits = Jobs.current_waits(pending)

    # One spend read for the page: `Spend.paused?/0` sums the node's runs, and a predicate that
    # asked it per entry would ask N times for one answer.
    capped? = Spend.paused?()

    # **The cap gates a workflow job and not a command.** `Jobs.assign_command/2` takes no spend
    # gate — it says so in as many words, and never calls `spend_gate/2` — so the scheduler places
    # a pending command at the next pass whatever the cap says, and dropping one would hide a
    # ticket that is in fact only waiting for room.
    Enum.reject(entries, fn entry ->
      entry.kind == :awaiting_worker and
        ((capped? and entry.detail.job_kind == :workflow) or
           paused_wait?(waits[entry.detail.job_id]))
    end)
  end

  defp paused_wait?(%Event{payload: %{"reason" => reason}}), do: reason in @paused_waits
  defp paused_wait?(_no_wait_recorded), do: false

  defp under_way_entry(%Ticket{} = ticket, job, kind, runs, projects) do
    %{
      kind: kind,
      ticket: ticket,
      # An equivalent mutant — `Projects.get!/1` here fetches the identical struct and every
      # test stays green — and `fetch!` all the same: `projects` is built from the same ids the
      # ticket query filters on, so a missing key would mean this read had changed under itself,
      # and the map is a cache rather than a lookup that can legitimately miss.
      project: Map.fetch!(projects, ticket.project_id),
      since: since(kind, job, runs),
      question: nil,
      detail: %{job_id: job.id, job_kind: job.kind}
    }
  end

  # `since` is when the thing the line describes began, which is a different column per kind.
  #
  # For work on a machine it is **the current run's start**, which only the run ledger holds.
  # `jobs.started_at` is written `job.started_at || now` by `Jobs.mark_started/3` and never
  # rewritten, so on every run after the first it is the *first* run's start: a job that stopped
  # on a question at 09:10 and was answered at 19:00 drew "Running on a worker · 10h" a minute
  # into its second run. `Forge.Jobs.Runs` opens a row per start and a job has at most one open.
  #
  # Two fallbacks, each narrower than the last: `jobs.started_at` for a running row whose run the
  # ledger does not have, and `inserted_at` for one with neither, which is what a changeset
  # written by hand leaves. A `since` of nil would take the sort and the page down with it rather
  # than lose one line.
  #
  # A pending job has no run to be aged from, and its `inserted_at` is how long the ticket has
  # been held. A resumed one carries a `started_at` from a run that is over, which is why the kind
  # decides and not the column.
  defp since(:on_worker, job, runs), do: runs[job.id] || job.started_at || job.inserted_at
  defp since(:awaiting_worker, job, _runs), do: job.inserted_at

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
