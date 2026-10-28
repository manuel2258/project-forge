defmodule Forge.Engine do
  @moduledoc """
  Applies `ForgeCore.Engine` decisions to tickets: transitions, approvals and stuck states,
  each with its event, and the next job when the target is a job state.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Jobs, Merge, MergeQueue, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.MergeQueue.Entry
  alias Forge.Tickets.Ticket
  require Forge.Tickets.Ticket
  alias ForgeCore.Engine, as: Core
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  @taken_out_reason "taken out of the merge queue: choose how it goes on"

  @doc "Runs `put_after_job/4` in its own transaction."
  @spec after_job(Ticket.t(), Job.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def after_job(%Ticket{} = ticket, %Job{} = job, outcome) do
    Multi.new()
    |> put_after_job(ticket, job, outcome)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        moved = Map.get(changes, :ticket, ticket)
        {:ok, entered(ticket, moved)}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  # A transition the engine took by itself may land in a state with an entry action, exactly as
  # one a person approved may.
  defp entered(%Ticket{state: before}, %Ticket{state: before} = ticket), do: ticket

  defp entered(_before, %Ticket{} = ticket),
    do: enter(ticket, Tickets.workflow(ticket), ticket.state, nil)

  @doc """
  Sticks a ticket with a reason, in its own transaction.

  `cause` is `:placement` when the scheduler could not place the ticket's job — nothing to make a
  machine from, nothing to fund it with — and nil otherwise. It is recorded on the event so that
  `resume_placement/2` can find the tickets that an arrival — an assignment, a template enabled or
  edited, a machine offering more — may have unblocked.
  """
  @spec stick(Ticket.t(), String.t(), :placement | nil) :: {:ok, Ticket.t()} | {:error, term()}
  def stick(%Ticket{} = ticket, reason, cause \\ nil) do
    # Locked and re-read: the scheduler decides to stick from a ticket it read earlier, and one
    # cancelled since must stay cancelled rather than come back as stuck. Only cancelled is
    # refused — a merge that fails sticks a ticket that entered its terminal state
    # (`stick_after_merge/2`), which is how it gets a way forward.
    Multi.new()
    |> Multi.run(:open, fn repo, _changes -> lock_uncancelled(repo, ticket.id) end)
    |> Multi.merge(fn %{open: open} -> put_stuck(Multi.new(), open, reason, cause) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: ticket}} ->
        Events.notify(ticket.id)
        {:ok, ticket}

      {:error, step, reason, _} ->
        {:error, {step, reason}}
    end
  end

  @doc """
  Adds what follows a finished job to `multi`: a transition, a pending approval, or stuck.
  A job whose ticket has moved on since it started (a person took a transition meanwhile)
  is recorded as orphaned and decides nothing.
  """
  @spec put_after_job(Multi.t(), Ticket.t(), Job.t(), String.t()) :: Multi.t()
  def put_after_job(
        multi,
        %Ticket{state: state, status: :active} = ticket,
        %Job{state: state} = job,
        outcome
      ) do
    workflow = Tickets.workflow(ticket)

    if Core.within_ticket_budget?(workflow, Decimal.to_float(ticket.cost_usd)) do
      case Core.step(workflow, job.state, outcome, counts(ticket.id)) do
        {:transition, transition} ->
          put_engine_transition(multi, ticket, workflow, transition, outcome)

        {:approval, transition} ->
          put_pending_approval(multi, ticket, transition, outcome)

        {:stuck, reason} ->
          put_stuck(multi, ticket, stuck_reason(reason))

        {:error, reason} ->
          put_stuck(multi, ticket, inspect(reason))
      end
    else
      put_stuck(multi, ticket, "ticket cost cap reached")
    end
  end

  def put_after_job(multi, %Ticket{} = ticket, %Job{} = job, outcome) do
    Events.log(multi, :orphan_event, "job.orphaned", :system, %{
      ticket_id: ticket.id,
      job_id: job.id,
      payload: %{"job_state" => job.state, "ticket_state" => ticket.state, "outcome" => outcome}
    })
  end

  @doc """
  Adds taking `transition` to `multi`: ticket state, event, next job or done.

  Options:

    * `:comment` - what a person wrote as they took it, if anything. It is recorded on the event
      and handed to the job the transition creates, which is how a tester's note on sending a
      build back reaches the job that has to act on it (`docs/design/job-prompt.md` § How the job
      arrived).
    * `:source` - for a transition into the merging state, the changeset version it is taken for,
      as `Forge.Merge.changeset/1` read it when it was checked. Read now when not given. Either
      way the event names it, and the merge after the transition merges it and no later version
      (`docs/design/workflow-grammar-v1.md` § Merging). The `commit-message` version is read here
      in both cases — nothing checks it beforehand, so there is no earlier read to carry — and
      named on the same event, so what the commit says is what that version said.
    * `:commit_message_version` - the `commit-message` version to name instead of the latest, which
      is what the merge queue passes: the one that was current when the ticket was approved.
  """
  @spec put_transition(
          Multi.t(),
          Ticket.t(),
          Workflow.t(),
          Transition.t(),
          String.t() | nil,
          Events.actor(),
          keyword()
        ) :: Multi.t()
  def put_transition(
        multi,
        %Ticket{} = ticket,
        %Workflow{} = workflow,
        %Transition{} = transition,
        outcome,
        actor,
        opts \\ []
      ) do
    target = Workflow.state(workflow, transition.to)
    terminal = Workflow.terminal?(workflow, transition.to)
    comment = Keyword.get(opts, :comment)

    # The outcome a job ended with, or nil when a person chose the transition with no job's outcome
    # behind it — out of a human state, or to unstick a ticket. The event has always recorded the
    # transition's own `when` in that case; the job is told only what actually happened.
    entered = %{
      "from" => transition.from,
      "outcome" => outcome,
      "by" => if(actor == :system, do: "engine", else: "person"),
      "comment" => blank_to_nil(comment)
    }

    multi
    |> Tickets.put_progress(:ticket, ticket, %{
      state: transition.to,
      status: if(terminal, do: :done, else: :active),
      pending_transition: nil,
      cost_usd: ticket.cost_usd
    })
    |> Events.log(:transition_event, "transition.taken", actor, %{
      ticket_id: ticket.id,
      payload:
        %{
          "from" => transition.from,
          "to" => transition.to,
          "outcome" => outcome || Transition.outcome(transition)
        }
        |> put_comment(entered["comment"])
        |> put_source(ticket, workflow, transition, opts)
    })
    |> put_follow_up(ticket, workflow, transition, target, terminal, entered)
  end

  # Nil is a transition nothing checked, which reads the latest version as it is taken.
  defp or_latest({:ok, %{} = source}, _ticket), do: {:ok, source}
  defp or_latest(_unchecked, ticket), do: Merge.changeset(ticket)

  # The queue names the version that was current when the ticket was approved, which is not the
  # latest by the time its turn comes; every other caller reads the latest as it takes the edge.
  defp commit_message_version(ticket, opts) do
    case Keyword.fetch(opts, :commit_message_version) do
      {:ok, version} -> version
      :error -> Merge.commit_message_version(ticket)
    end
  end

  defp put_comment(payload, nil), do: payload
  defp put_comment(payload, comment), do: Map.put(payload, "comment", comment)

  # The commit a transition into the merging state is taken for and the message it will carry,
  # named on its event: what the merge after it merges and what it says (`merge_now/3`), so
  # neither a changeset nor a `commit-message` written later is what it uses.
  defp put_source(payload, ticket, workflow, %Transition{to: to}, opts) do
    if Workflow.merges_on_enter?(workflow, to) do
      case opts |> Keyword.fetch(:source) |> or_latest(ticket) do
        {:ok, %{sha: sha, version: version}} ->
          payload
          |> Map.merge(%{"changeset" => sha, "changeset_version" => version})
          |> put_commit_message(commit_message_version(ticket, opts))

        {:error, _none} ->
          payload
      end
    else
      payload
    end
  end

  # No key where the ticket has no `commit-message` yet, the way a missing changeset leaves none:
  # `named/1` reads it as nil and `Merge.perform/4` refuses it, unless the pin could never have
  # had one (`Merge.legacy_message?/1`).
  defp put_commit_message(payload, nil), do: payload

  defp put_commit_message(payload, version),
    do: Map.put(payload, "commit_message_version", version)

  defp blank_to_nil(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_none), do: nil

  defp put_follow_up(multi, ticket, _workflow, transition, _target, true, _entered) do
    Events.log(multi, :done_event, "ticket.done", :system, %{
      ticket_id: ticket.id,
      payload: %{"state" => transition.to}
    })
  end

  # A chat step's entry opens a conversation instead of a job: no job, no budget, no outcome from
  # the harness (`docs/design/workflow-grammar-v1.md` § Chat steps). Before the clause below
  # because a chat step has a prompt too.
  defp put_follow_up(multi, _ticket, workflow, transition, %State{chat: true}, false, entered) do
    Multi.merge(multi, fn %{ticket: ticket} ->
      put_step_chat(Multi.new(), :next_job, ticket, workflow, transition.to, entered)
    end)
  end

  defp put_follow_up(multi, _ticket, workflow, transition, %State{prompt: prompt}, false, entered)
       when is_binary(prompt) do
    Multi.merge(multi, fn %{ticket: ticket} ->
      entered = put_batch(entered, ticket)

      Jobs.put_create(Multi.new(), :next_job, ticket, workflow, transition.to, entered,
        came_back: true
      )
    end)
  end

  # A command state's entry runs its commands (`docs/design/commands.md`).
  defp put_follow_up(
         multi,
         _ticket,
         workflow,
         transition,
         %State{invoke: [_ | _]},
         false,
         _entered
       ) do
    # How the ticket came in is for an agent to read; a command has no manifest to put it in.
    Multi.merge(multi, fn %{ticket: ticket} ->
      Forge.Jobs.Commands.put_for_state(Multi.new(), :next_job, ticket, workflow, transition.to)
    end)
  end

  defp put_follow_up(multi, _ticket, _workflow, _transition, _human_state, false, _entered),
    do: multi

  # The conversation a ticket entering a chat step gets, and its branch, cut from the ticket's.
  # (`Forge.Tickets.put_admit/5` does the same for a first state with the pieces from `Jobs`,
  # because the ticket's own branch is cut after the first state is entered.)
  defp put_step_chat(multi, key, ticket, workflow, state_name, entered) do
    multi
    |> Jobs.put_create_step(key, ticket, workflow, state_name, entered)
    |> Multi.merge(fn changes ->
      Jobs.put_step_branch(Multi.new(), {key, :branch}, changes[key], ticket)
    end)
  end

  # Out of a command state, the job is handed what its commands said — whoever took the edge, so
  # a person moving a stuck ticket on sends the log with it (`docs/design/job-prompt.md` § How
  # the job arrived). Inside the merge, so a batch decided in this same transaction is seen.
  # Found by the log and not by the workflow: only a command state's entry logs the
  # `commands.started` a batch is found by, and a re-pin can change what a state is after its
  # batch ran — the batch is still what sent the ticket on.
  defp put_batch(%{"from" => from} = entered, ticket) do
    case Forge.Jobs.Commands.decided_batch(ticket.id, from) do
      batch when is_binary(batch) -> Map.put(entered, "batch", batch)
      nil -> entered
    end
  end

  defp put_pending_approval(multi, ticket, %Transition{} = transition, outcome) do
    pending = %{
      "from" => transition.from,
      "to" => transition.to,
      "outcome" => outcome,
      "approve" => transition.approve
    }

    multi
    |> Tickets.put_progress(:ticket, ticket, %{
      state: ticket.state,
      status: :active,
      cost_usd: ticket.cost_usd,
      pending_transition: pending
    })
    |> Events.log(:approval_event, "approval.requested", :system, %{
      ticket_id: ticket.id,
      payload: pending
    })
    # An integrated ticket that now needs a person's approval is no longer in the line; the
    # approval it gets is a new one and takes a new place. No row is a no-op.
    |> MergeQueue.put_leave(ticket.id, "needs_person")
  end

  # `pending_transition: nil` is part of being stuck, not an extra. A stuck ticket is one waiting
  # for a person to choose, and both surfaces that offer the choice hide it while a pending
  # transition is set — the queue shows the approve/reject card instead (`Queue.ticket_items/1`
  # matches on `pending_transition` first) and the ticket page's chooser is behind
  # `!@ticket.pending_transition`. Leaving it set is a ticket that says "waiting for you to
  # choose" and offers nothing to choose from.
  defp put_stuck(multi, ticket, reason, cause \\ nil) do
    multi
    |> Tickets.put_progress(:ticket, ticket, %{
      state: ticket.state,
      status: :stuck,
      cost_usd: ticket.cost_usd,
      pending_transition: nil
    })
    |> Events.log(:stuck_event, "ticket.stuck", :system, %{
      ticket_id: ticket.id,
      payload: stuck_payload(reason, cause)
    })
    # Every way a ticket sticks — rounds, placement, a failed merge — takes it out of the merge
    # queue, so the line never holds a ticket that needs a person (`put_leave/3` is a no-op for
    # one that was not in it).
    |> MergeQueue.put_leave(ticket.id, "stuck")
  end

  @doc """
  Why a stuck ticket is stuck: the reason on its latest `ticket.stuck`, or nil for a ticket that is
  not. What the queue, the push and the ticket page say beside the flag — "stuck" alone sends a
  person to the event log to find out whether a job failed, a `max` ran out or nothing matched.
  """
  @spec why_stuck(Ticket.t()) :: String.t() | nil
  def why_stuck(%Ticket{status: :stuck} = ticket), do: latest_stick(ticket)["reason"]
  def why_stuck(%Ticket{}), do: nil

  # The payload of the ticket's latest `ticket.stuck`: its reason, and its cause when it has one.
  defp latest_stick(%Ticket{id: id}) do
    case Events.latest_for_ticket(id, "ticket.stuck") do
      %Event{payload: payload} -> payload
      nil -> %{}
    end
  end

  defp stuck_payload(reason, nil), do: %{"reason" => reason}
  defp stuck_payload(reason, cause), do: %{"reason" => reason, "cause" => to_string(cause)}

  @doc """
  Brings back the tickets of `project_id` that are stuck only because their job could not be
  placed, now that something has arrived that may place it: a template, machine or credential
  assigned; a template enabled, edited in what it could hold, or back in service at the first
  report of a machine of its own; a permanent machine offering the gate something new
  (`docs/design/credentials.md` § How a job picks lists them, and what is left out).

  **Without this a placement stick was a dead end.** The ticket is stuck holding a pending job,
  and `choose/4` refuses a transition while a job for the current state is live, so once the
  missing template, machine or credential was assigned there was nothing a person could do from
  the product to get the job run (`docs/design/credentials.md` § How a job picks).

  Only a ticket whose latest stick was for placement, and that still holds a pending job for its
  state, comes back: a ticket stuck on its allowance, a rejected approval or a missing transition
  was stuck for a reason no arrival answers. If the arrival was not the missing piece, the next
  scheduling pass sticks it again — once, and pushed once, not a loop.
  """
  @spec resume_placement(String.t(), Forge.Events.actor()) :: non_neg_integer()
  def resume_placement(project_id, actor) do
    from(t in Ticket, where: t.project_id == ^project_id and t.status == :stuck)
    |> Repo.all()
    |> Enum.filter(&(stuck_for_placement?(&1) and pending_job?(&1)))
    |> Enum.count(&(unstick(&1, actor) == :ok))
  end

  defp stuck_for_placement?(%Ticket{} = ticket), do: latest_stick(ticket)["cause"] == "placement"

  defp pending_job?(%Ticket{id: id, state: state}) do
    Repo.exists?(
      from j in Job, where: j.ticket_id == ^id and j.state == ^state and j.status == :pending
    )
  end

  # **Locked and re-read, and only while it is still stuck**, as `stick/3` locks against a cancel:
  # the candidates were read without a lock, and a ticket cancelled in between was written back
  # `active` from the stale read — no live job, and `ticket.unstuck` after `ticket.cancelled`.
  # Every machine's first report reaches this now, not only a person's assignment. No test pins
  # it: the window is between two statements, and nothing in the suite can open it on demand.
  defp unstick(ticket, actor) do
    Multi.new()
    |> Multi.run(:stuck, fn repo, _changes -> lock_stuck(repo, ticket.id) end)
    |> Multi.merge(fn %{stuck: stuck} ->
      Multi.new()
      |> Tickets.put_progress(:ticket, stuck, %{
        state: stuck.state,
        status: :active,
        cost_usd: stuck.cost_usd,
        pending_transition: nil
      })
      |> Events.log(:event, "ticket.unstuck", actor, %{
        ticket_id: stuck.id,
        payload: %{"reason" => "something arrived that may place its job"}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} ->
        Events.notify(ticket.id)
        :ok

      {:error, _step, _reason, _changes} ->
        :error
    end
  end

  defp stuck_reason({:no_transition, outcome}), do: "no transition from #{inspect(outcome)}"

  defp stuck_reason({:max_exceeded, %Transition{to: to, max: max}}),
    do: "transition to #{to} already fired #{max} times"

  # Firing counts come from the event log, keyed like Transition.id/1.
  defp counts(ticket_id) do
    from(e in Event,
      where: e.ticket_id == ^ticket_id and e.type == "transition.taken",
      select: e.payload
    )
    |> Repo.all()
    |> Enum.frequencies_by(fn p -> {p["from"], p["to"], p["outcome"]} end)
  end

  # -- human decisions ------------------------------------------------------------------------

  @doc """
  Decides the ticket's pending transition. Approving records an approval on the latest
  version of each listed artifact and takes the transition; rejecting records rejections and
  leaves the ticket where it is, pending, for an edit or a manual transition.
  """
  @spec decide(Ticket.t(), String.t(), :approved | :rejected, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def decide(%Ticket{pending_transition: nil}, _user_id, _decision, _comment),
    do: {:error, :nothing_pending}

  def decide(%Ticket{pending_transition: pending} = ticket, user_id, decision, comment) do
    workflow = Tickets.workflow(ticket)

    with {:ok, transition} <-
           Core.choose(workflow, pending["from"], pending["to"], pending["outcome"]) do
      take(ticket, workflow, transition, pending["outcome"], user_id, decision, comment)
    end
  end

  @doc """
  The artifacts the ticket's pending transition is waiting to have approved, by name; none when
  nothing is pending.

  `decide/4` approves the latest version of each of these, so this is also the list of documents
  whose latest version must be the one the operator was shown. One definition for every reader —
  the queue, the ticket and review pages, and `Forge.Conversations`, which refuses a chat a new
  version of any of them until the decision is made (`docs/design/conversations.md` § Commits).
  """
  @spec awaiting_approval(Ticket.t()) :: [String.t()]
  def awaiting_approval(%Ticket{pending_transition: %{} = pending}),
    do: List.wrap(pending["approve"])

  def awaiting_approval(%Ticket{}), do: []

  @doc """
  Whether approving what the ticket waits on merges: whether the transition's target is a state
  whose `on_enter` is `merge`.

  **Asked of the workflow, not of what the approval pins.** It was read off the pinned names —
  "does this approval include `changeset`" — which is a workflow author's choice and not this
  fact: a merging state reached by an approval of something else would have drawn no commit
  message and offered Approve anyway, and a non-merging state reached by an approval of the
  changeset would have withheld Approve for want of a message nothing was going to commit. The
  operation guarded is the entry action, so the guard asks the same question the entry action
  does (`CLAUDE.md` § Rules, and `put_source/5` keys on the same `merges_on_enter?/2`).

  False for a ticket waiting on nothing, and for one whose pinned workflow no longer parses —
  there is no merging state to be sure of, and `enter/4` would not merge either.
  """
  @spec approval_merges?(Ticket.t()) :: boolean()
  def approval_merges?(%Ticket{pending_transition: %{}} = ticket) do
    case Tickets.parsed_workflow(ticket) do
      {:ok, workflow} -> merge_decision?(ticket, workflow)
      {:error, _errors} -> false
    end
  end

  def approval_merges?(%Ticket{}), do: false

  @doc """
  Whether the decision in front of the operator merges: the pending approval's target state, or —
  for a ticket resting with nothing pending — any of the transitions out of the state it rests in.

  **The same question as `approval_merges?/1`, for a caller that already holds the workflow**, and
  the one definition of "is this a merge decision" for every surface that asks. Four asked it as
  "does the decision pin `changeset`", which is a workflow author's choice and not this fact: a
  merging transition that approves something else was offered as a one-line summary with no link
  to the diff, so the merge was taken without the operator seeing the change — which is exactly
  what those surfaces exist to prevent.
  """
  @spec merge_decision?(Ticket.t(), Workflow.t()) :: boolean()
  def merge_decision?(%Ticket{pending_transition: %{"to" => to}}, %Workflow{} = workflow),
    do: Workflow.merges_on_enter?(workflow, to)

  def merge_decision?(%Ticket{state: state}, %Workflow{} = workflow) do
    workflow
    |> Workflow.transitions_from(state)
    |> Enum.any?(&Workflow.merges_on_enter?(workflow, &1.to))
  end

  @doc """
  A person takes a declared transition out of the current state: from a human state, or to
  unstick a ticket. Refused while a job for the current state is pending, running or
  waiting, and while a decision on another transition is pending. A transition that requires
  approval records the approvals as part of the choice.
  Options: `:outcome` picks between parallel edges, `:comment` is stored with approvals.

  **The pending check is here and not on a page.** It was the ticket page's
  `:if={!@ticket.pending_transition}` alone, which was armour while clicking was the only way in
  — and a conversation asks for a transition by writing a file, not by finding a button
  (`docs/design/conversations.md` § Taking a transition). So every caller meets it at the
  operation: the chat, the API and the page. `:pending_approval` is `repinnable/2`'s name for the
  same condition, not a second one.
  """
  @spec choose(Ticket.t(), String.t(), String.t(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def choose(ticket, user_id, to, opts \\ [])

  def choose(%Ticket{status: :cancelled}, _user_id, _to, _opts),
    do: {:error, {:not_active, :cancelled}}

  def choose(%Ticket{pending_transition: %{}}, _user_id, _to, _opts),
    do: {:error, :pending_approval}

  def choose(%Ticket{} = ticket, user_id, to, opts) do
    workflow = Tickets.workflow(ticket)

    with :ok <- not_queued(ticket),
         :ok <- no_live_job(ticket),
         {:ok, transition} <- Core.choose(workflow, ticket.state, to, Keyword.get(opts, :outcome)) do
      take(ticket, workflow, transition, nil, user_id, :approved, Keyword.get(opts, :comment))
    end
  end

  # **While a ticket is queued no other transition may be taken on it**, by the page, the API or a
  # conversation alike: the line owns its next step until a person takes it out. The same rule as
  # a pending decision's, enforced at the operation (`:queued` beside `:pending_approval`).
  defp not_queued(%Ticket{} = ticket) do
    if MergeQueue.queued?(ticket), do: {:error, :queued}, else: :ok
  end

  # **A live conversation of a chat step is a live job here**: `Jobs.live?/2` counts its row as it
  # counts a job's, so the refusal is the same one every by-hand transition, chat request and API
  # call already meets; the first branch only names it, so the person is told to Accept instead of
  # being told a job is running (`docs/design/conversations.md` § A
  # conversation that is a step). The way out of a live step is Accept.
  defp no_live_job(%Ticket{id: id, state: state}) do
    cond do
      Jobs.live_step(id, state) != nil -> {:error, {:step_live, state}}
      Jobs.live?(id, state) -> {:error, {:job_live, state}}
      true -> :ok
    end
  end

  @doc """
  The transitions a person may take out of where the ticket rests: every edge declared from the
  current state **but none whose `approve` names a document with no version**, because taking it
  would record an approval of nothing and is refused (`workflow-grammar-v1.md` § Semantics). A
  refinement that failed left its ticket offering `planning`, which failed twice when taken.

  The *edges*, not their targets, because the filter is per edge and two edges may reach one
  target with only one of them offerable. Everything that offers a transition reads this one
  walk — the ticket page and the queue through `offered_transitions/2` below, a conversation's
  manifest through `Forge.Jobs` — so none of them can disagree about which edge survived.
  """
  @spec offered_edges(Ticket.t(), Workflow.t()) :: [Transition.t()]
  def offered_edges(%Ticket{} = ticket, %Workflow{} = workflow) do
    workflow
    |> Workflow.transitions_from(ticket.state)
    |> Enum.filter(&(unversioned(ticket, &1) == []))
  end

  @doc """
  The states a person may move the ticket to from where it rests, each named once — two edges may
  share a target. `offered_edges/2`'s targets; the ticket page and the queue both ask this, so
  they cannot disagree.
  """
  @spec offered_transitions(Ticket.t(), Workflow.t()) :: [String.t()]
  def offered_transitions(%Ticket{} = ticket, %Workflow{} = workflow) do
    ticket
    |> offered_edges(workflow)
    |> Enum.map(& &1.to)
    |> Enum.uniq()
  end

  defp unversioned(%Ticket{id: id}, %Transition{approve: names}),
    do: Enum.reject(names, &Artifacts.latest(id, &1))

  # -- cancelling and restoring ---------------------------------------------------------------

  # Every status a job is not finished in. Wider than `Jobs.live?/2`, which leaves out
  # `:hibernated` because it asks whether something occupies the state now: a hibernated job
  # occupies nothing but is resumable, and a cancelled ticket's job must not be.
  @live_job_statuses [:pending, :running, :waiting, :parked, :hibernated]

  @doc """
  Cancels a ticket: `cancelled`, every live job of it finished as `cancelled`, a machine running
  one told to stop, any pending approval cleared. Not a deletion — the history, the branch and the
  documents stay, and `restore/2` undoes it (`workflow-grammar-v1.md` § Cancelling a ticket).
  Refused for a ticket that is done or already cancelled.
  """
  @spec cancel(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def cancel(%Ticket{} = ticket, user_id) do
    now = DateTime.utc_now(:second)

    # **Locked, and read inside the transaction.** The ticket row first, then its live jobs, so
    # every other writer is serialised against this one: the scheduler starting a pending job
    # (`mark_started` locks the row and requires `:pending`), a result being recorded (`record`
    # locks the row and refuses a finished job), and the scheduler sticking the ticket
    # (`stick/3` locks the ticket and refuses one no longer open). Read outside, a job that went
    # from pending to running in between was finished here and its machine never told, and a
    # result committed in between moved the cancelled ticket on to its next state. **No test
    # reaches the locks**: each race needs another writer to commit between two statements of
    # this process. What each refused writer does next is tested (`cancel_test.exs`).
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes -> lock_open(repo, ticket.id, :not_cancellable) end)
    |> Multi.run(:live, fn repo, _changes ->
      {:ok,
       repo.all(
         from j in Job,
           where:
             j.ticket_id == ^ticket.id and j.kind in [:workflow, :command] and
               j.status in @live_job_statuses,
           lock: "FOR UPDATE"
       )}
    end)
    |> Multi.merge(fn %{locked: locked, live: live} ->
      ids = Enum.map(live, & &1.id)

      Multi.new()
      |> Tickets.put_progress(:ticket, locked, %{
        state: locked.state,
        status: :cancelled,
        cost_usd: locked.cost_usd,
        pending_transition: nil
      })
      |> Multi.update_all(:ended, from(j in Job, where: j.id in ^ids),
        set: [status: :finished, outcome: :cancelled, finished_at: now, updated_at: now]
      )
      |> Jobs.Runs.close_all(ids, now)
      |> MergeQueue.put_leave(ticket.id, "cancelled")
      |> Events.log(:cancel_event, "ticket.cancelled", actor(user_id), %{
        ticket_id: ticket.id,
        payload: %{"state" => locked.state, "jobs" => ids}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: ticket, live: live}} ->
        # After the commit, never inside it: a machine told to stop a job the transaction then
        # rolled back would stop work that is still the ticket's. The machine is released when it
        # says it stopped (`Forge.Jobs.hibernate/4` and `complete/2`, which settle what the run
        # spent), not here, where its process is still running. `Workers.push/2` to a job with
        # no worker is an equivalent mutant of the filter: it finds no channel and does nothing.
        for %Job{status: :running, worker_id: worker_id} = job <- live, worker_id != nil do
          Forge.Workers.push(worker_id, {:cancel, job.id, :ticket_cancelled})
        end

        Enum.each(live, &Forge.Git.Tokens.revoke_for_job(&1.id))
        stop_step_chats(ticket, user_id)
        {:ok, ticket}

      {:error, :locked, reason, _changes} ->
        {:error, reason}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  # A cancelled ticket's step conversation is stopped and left dormant, its branch kept, so that
  # restoring the ticket leaves it reopenable (`docs/design/conversations.md` § A conversation
  # that is a step). After the commit, for the reason the jobs' pushes are.
  defp stop_step_chats(%Ticket{id: id}, user_id) do
    for chat <- Jobs.live_step_chats(id) do
      Forge.Conversations.close(chat, "cancelled", actor: actor(user_id))
    end

    :ok
  end

  defp lock_stuck(repo, ticket_id) do
    case repo.one!(from t in Ticket, where: t.id == ^ticket_id, lock: "FOR UPDATE") do
      %Ticket{status: :stuck} = ticket -> {:ok, ticket}
      %Ticket{status: status} -> {:error, {:not_stuck, status}}
    end
  end

  defp lock_uncancelled(repo, ticket_id) do
    case repo.one!(from t in Ticket, where: t.id == ^ticket_id, lock: "FOR UPDATE") do
      %Ticket{status: :cancelled} -> {:error, {:not_open, :cancelled}}
      %Ticket{} = ticket -> {:ok, ticket}
    end
  end

  # The ticket row, locked, if it is still open — active or stuck. `why` names the refusal.
  defp lock_open(repo, ticket_id, why) do
    case repo.one!(from t in Ticket, where: t.id == ^ticket_id, lock: "FOR UPDATE") do
      %Ticket{status: status} = ticket when Ticket.open?(status) -> {:ok, ticket}
      %Ticket{status: status} -> {:error, {why, status}}
    end
  end

  @doc """
  Undoes `cancel/2`: the ticket is `stuck` in the state it was in, waiting for a person to run that
  state again or take a transition out of it. Nothing is started by restoring.
  """
  @spec restore(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def restore(%Ticket{status: :cancelled} = ticket, user_id) do
    Multi.new()
    # A release is one at a time (`docs/design/ticket-types.md` § Releases): another may have been
    # started since this one was cancelled.
    |> Forge.ReleaseTickets.put_restorable(ticket)
    |> Tickets.put_progress(:ticket, ticket, %{
      state: ticket.state,
      status: :stuck,
      cost_usd: ticket.cost_usd,
      pending_transition: nil
    })
    |> Events.log(:restore_event, "ticket.restored", actor(user_id), %{
      ticket_id: ticket.id,
      payload: %{"state" => ticket.state}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: ticket}} ->
        {:ok, ticket}

      {:error, :release_lock, reason, _changes} ->
        {:error, reason}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
  end

  def restore(%Ticket{status: status}, _user_id), do: {:error, {:not_cancelled, status}}

  # -- running a state again ------------------------------------------------------------------

  @doc """
  Runs the ticket's current state again: the next attempt of its job, or its commands again, with
  the arrival the last attempt had. Clears a pending approval, whose documents are about to be
  replaced, and unsticks the ticket. Takes no transition, so no `max` counts it
  (`workflow-grammar-v1.md` § Running a state again).

  Refused, with why, on a ticket that is done, in a state no job runs in, or with a job still live
  in its state — `retryable/1` is the same check, for a surface deciding whether to offer it.
  """
  @spec retry(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def retry(%Ticket{} = ticket, user_id) do
    workflow = Tickets.workflow(ticket)

    with :ok <- retryable(ticket, workflow) do
      Multi.new()
      |> Tickets.put_progress(:ticket, ticket, %{
        state: ticket.state,
        status: :active,
        cost_usd: ticket.cost_usd,
        pending_transition: nil
      })
      |> Events.log(:retry_event, "ticket.retried", actor(user_id), %{
        ticket_id: ticket.id,
        payload: %{"state" => ticket.state}
      })
      |> put_again(workflow, Workflow.state(workflow, ticket.state))
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} ->
          Events.notify(ticket.id)
          {:ok, ticket}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  @doc """
  Re-pins the ticket's workflow to the project's default branch as it is now: its definition, its
  prompts and its command scripts are read from the new commit for every job made after this one.
  The branch, its base and everything already written stay as they were. What is read is the
  ticket's own type's file, so a ticket never changes type by being re-pinned; a type whose file
  is gone refuses (`docs/design/ticket-types.md` § Pinning and re-pinning).

  **What it is for** is a ticket that cannot pass a state because of a file no job on it may edit
  — a command script is read at the pin, never from the branch (`docs/design/commands.md` § The
  shape). The fix lands on the default branch; without this, the ticket kept failing on the old
  script for ever. Re-pinning is a person's act because it changes what "the build passed" means
  for this ticket, which is exactly what no job may do.

  Refused while a job for the state is live — it was made from the old pin, and would run on it
  — while an approval is pending, whose transition the new workflow may not have, when the new
  workflow has no state the ticket is in, and when there is nothing new to pin.
  """
  @spec repin(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def repin(%Ticket{} = ticket, user_id) do
    with {:ok, prepared} <- Tickets.prepare_repin(Forge.Projects.get!(ticket.project_id), ticket) do
      Multi.new()
      |> Multi.run(:open, fn repo, _changes -> lock_open(repo, ticket.id, :not_repinnable) end)
      |> Multi.run(:repinnable, fn _repo, %{open: open} -> repinnable(open, prepared) end)
      |> Multi.update(:ticket, fn %{open: open} ->
        Ticket.repin_changeset(open, %{
          workflow: prepared.yaml_map,
          workflow_commit: prepared.base
        })
      end)
      |> Events.log(:repin_event, "ticket.repinned", actor(user_id), %{
        ticket_id: ticket.id,
        payload: %{"from" => ticket.workflow_commit, "to" => prepared.base}
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} ->
          Events.notify(ticket.id)
          {:ok, ticket}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp repinnable(%Ticket{} = ticket, %{base: base, workflow: workflow}) do
    cond do
      ticket.workflow_commit == base -> {:error, :already_pinned}
      is_map(ticket.pending_transition) -> {:error, :pending_approval}
      Workflow.state(workflow, ticket.state) == nil -> {:error, {:no_state, ticket.state}}
      true -> with(:ok <- not_queued(ticket), :ok <- no_live_job(ticket), do: {:ok, :repinnable})
    end
  end

  @doc "Whether `retry/2` would run the ticket's state again, for a surface deciding to offer it."
  @spec retryable?(Ticket.t()) :: boolean()
  def retryable?(%Ticket{} = ticket), do: retryable(ticket, Tickets.workflow(ticket)) == :ok

  defp retryable(%Ticket{status: status}, _workflow) when not Ticket.open?(status),
    do: {:error, {:not_retryable, status}}

  defp retryable(%Ticket{} = ticket, workflow) do
    case Workflow.state(workflow, ticket.state) do
      # A chat step is never run again as a job: its conversation is reopened, and a new visit
      # comes only from the workflow's own edges.
      %State{chat: true} -> {:error, {:no_job_in, ticket.state}}
      %State{prompt: prompt} when is_binary(prompt) -> queued_or_live(ticket)
      %State{invoke: [_ | _]} -> queued_or_live(ticket)
      _human_or_missing -> {:error, {:no_job_in, ticket.state}}
    end
  end

  defp queued_or_live(ticket), do: with(:ok <- not_queued(ticket), do: no_live_job(ticket))

  defp put_again(multi, workflow, %State{prompt: prompt}) when is_binary(prompt) do
    Multi.merge(multi, fn %{ticket: ticket} ->
      Jobs.put_create(Multi.new(), :next_job, ticket, workflow, ticket.state, arrival(ticket))
    end)
  end

  defp put_again(multi, workflow, %State{invoke: [_ | _]}) do
    Multi.merge(multi, fn %{ticket: ticket} ->
      Forge.Jobs.Commands.put_for_state(Multi.new(), :next_job, ticket, workflow, ticket.state)
    end)
  end

  # How the last attempt of this state arrived, so the next is told the same: the comment a tester
  # sent a build back with is still what the job has to act on (`job-prompt.md` § How the job
  # arrived). Nil when no attempt ran here, which is how a ticket's first state arrives anyway.
  defp arrival(%Ticket{id: id, state: state}) do
    Repo.one(
      from j in Job,
        where: j.ticket_id == ^id and j.state == ^state and j.kind == :workflow,
        order_by: [desc: j.attempt],
        limit: 1,
        select: j.spec["entered"]
    )
  end

  # Records approvals (or rejections) for the transition's artifacts, then takes it if approved —
  # or, when the merge it leads to conflicts and the merging state says where a conflict goes,
  # takes that edge instead.
  defp take(ticket, workflow, transition, outcome, user_id, decision, comment) do
    if decision == :approved and queues?(workflow, transition) do
      commit_enqueue(ticket, transition, outcome, user_id, comment)
    else
      take_now(ticket, workflow, transition, outcome, user_id, decision, comment)
    end
  end

  defp take_now(ticket, workflow, transition, outcome, user_id, decision, comment) do
    case mergeable(ticket, workflow, transition, decision) do
      {:ok, source} ->
        commit_take(ticket, workflow, transition, outcome, user_id, decision, comment, source)

      {:conflict, edge, conflict} ->
        commit_conflict(ticket, workflow, transition, edge, conflict, user_id, comment)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A git side effect can live neither inside the transaction, which may roll back, nor simply
  # after it: a conflict would then leave the ticket reading `merged` while the default branch
  # never moved, and a terminal state has no edges to get out by. So the merge is checked first,
  # with no side effect, on the commit the transition will name — and a conflict either refuses
  # the approval while the ticket still has a way forward, or, when the merging state names an
  # `on_conflict`, is where the ticket goes (`docs/design/workflow-grammar-v1.md` § Merging).
  defp mergeable(ticket, workflow, %Transition{to: to} = transition, :approved) do
    if Workflow.merges_on_enter?(workflow, to) do
      check_merge(ticket, workflow, transition, :person)
    else
      {:ok, nil}
    end
  end

  defp mergeable(_ticket, _workflow, _transition, _decision), do: {:ok, nil}

  # The check before a transition into the merging state, for whoever is taking it: the commit it
  # will name, and what a conflict on it does. `{:ok, source}` takes the transition as asked.
  defp check_merge(ticket, workflow, %Transition{} = transition, by) do
    case Merge.changeset(ticket) do
      {:ok, source} ->
        case Merge.check(ticket, source.sha) do
          :ok ->
            {:ok, source}

          {:conflict, paths, head} ->
            conflict = %{paths: paths, head: head, source: source, by: by}
            on_conflict(ticket, workflow, transition, conflict)

          {:error, reason} ->
            {:error, {:merge_impossible, reason}}
        end

      {:error, reason} ->
        {:error, {:merge_impossible, reason}}
    end
  end

  defp on_conflict(ticket, workflow, %Transition{} = transition, %{by: by} = conflict) do
    # A person is never bounded (`ForgeCore.Engine.conflict/5`), so what is passed for one is an
    # equivalent mutant; nought spares counting the engine's rounds for nothing.
    rounds = if by == :engine, do: engine_rounds(ticket.id), else: 0

    case Core.conflict(workflow, transition.from, transition.to, by, rounds) do
      {:route, edge} -> {:conflict, edge, conflict}
      {:stuck, {:conflict_rounds, n}} -> {:stuck, n, conflict}
      :refuse -> {:error, {:merge_conflict, conflict.paths}}
    end
  end

  # How many times the engine has sent this ticket down `on_conflict` by itself since a person last
  # moved it — took a transition, ran its state again or put it in the merge queue: the count the
  # loop round an integrating state is bounded by (`ForgeCore.Engine.conflict/5`). `>` and `>=`
  # against the person's event are equivalent mutants: it is never itself a
  # `ticket.merge_conflicted`.
  defp engine_rounds(ticket_id) do
    person =
      Repo.one(
        from e in Event,
          where:
            e.ticket_id == ^ticket_id and
              e.type in ["transition.taken", "ticket.retried", "merge_queue.entered"] and
              fragment("?->>'kind'", e.actor) == "user",
          select: max(e.seq)
      ) || 0

    Repo.one(
      from e in Event,
        where:
          e.ticket_id == ^ticket_id and e.type == "ticket.merge_conflicted" and e.seq > ^person and
            fragment("?->>'by'", e.payload) == "engine",
        select: count()
    )
  end

  # The engine's own transition. Into a merging state it is the merge queue's when the ticket is in
  # it (back in its place after an integration) or the edge queues (a new place); a ticket a person
  # took out of the queue meanwhile is not merged, and sticks with its edges offered. Into a merging
  # state that names an `on_conflict` it is checked first, as a person's approval is; into any other
  # state — a merging state that names none included, so a workflow without the key behaves as it
  # always did — it is simply taken.
  defp put_engine_transition(multi, ticket, workflow, %Transition{to: to} = transition, outcome) do
    if Workflow.merges_on_enter?(workflow, to) do
      # **Locked, then decided.** Whether the ticket is in the line, and whether a person took it
      # out, are read after the ticket row is held: `take_out/2` holds the same lock, so the two
      # are serialised and each sees the other's result. Read while the multi was built, a
      # take-out in between left `put_return` updating a row that was gone (a raise out of the
      # transaction, and a ticket stranded), and the other order returned a row underneath it. The
      # test reaches the deferral (the multi is built before the take-out and run after); the
      # `FOR UPDATE` that serialises two writers committing at once is an equivalent mutant as far
      # as a single-process test can tell.
      multi
      |> Multi.run({:queue_lock, System.unique_integer([:positive])}, fn repo, _changes ->
        {:ok, repo.one!(from t in Ticket, where: t.id == ^ticket.id, lock: "FOR UPDATE")}
      end)
      |> Multi.merge(fn _changes ->
        decide_merging_edge(Multi.new(), ticket, workflow, transition, outcome)
      end)
    else
      multi
      |> put_transition(ticket, workflow, transition, outcome, :system)
      |> MergeQueue.put_leave(ticket.id, "needs_person")
    end
  end

  defp decide_merging_edge(multi, ticket, workflow, %Transition{to: to} = transition, outcome) do
    cond do
      entry = MergeQueue.entry(ticket) ->
        put_back_in_line(multi, ticket, entry, transition, outcome)

      taken_out_since_entered?(ticket) ->
        put_stuck(multi, ticket, @taken_out_reason)

      Transition.queues?(transition) ->
        put_engine_enqueue(multi, ticket, transition, outcome)

      Workflow.on_conflict(workflow, to) != nil ->
        put_checked_transition(multi, ticket, workflow, transition, outcome)

      true ->
        put_transition(multi, ticket, workflow, transition, outcome, :system)
    end
  end

  defp put_checked_transition(multi, ticket, workflow, %Transition{to: to} = transition, outcome) do
    case check_merge(ticket, workflow, transition, :engine) do
      {:ok, source} ->
        put_transition(multi, ticket, workflow, transition, outcome, :system, source: source)

      {:conflict, edge, conflict} ->
        put_conflict(multi, ticket, workflow, edge, to, conflict, :system, nil)

      {:stuck, rounds, conflict} ->
        multi
        |> put_conflict_event(ticket, nil, to, conflict, :system, "check")
        |> put_stuck(ticket, rounds_reason(rounds))

      # Nothing to merge, or nowhere to merge it: stuck where it is, with its edges out, rather
      # than in a terminal state that would offer none.
      {:error, {:merge_impossible, reason}} ->
        put_stuck(multi, ticket, "could not merge: #{inspect(reason)}")
    end
  end

  defp rounds_reason(rounds) do
    "merge still conflicts after #{rounds} integrations in a row: " <>
      "the integrate-then-merge loop stops here"
  end

  # The engine's edge into a merging state, declared to queue, takes no transition: the ticket
  # stays where it is, in line, and the runner takes the edge in its turn.
  defp put_engine_enqueue(multi, ticket, transition, outcome) do
    case Merge.changeset(ticket) do
      {:ok, source} ->
        MergeQueue.put_enter(multi, ticket, transition, outcome, source, :system, %{
          commit_message_version: Merge.commit_message_version(ticket)
        })

      {:error, reason} ->
        put_stuck(multi, ticket, "could not merge: #{inspect(reason)}")
    end
  end

  # An integrated ticket whose edge leads straight to the merging state keeps its place and is
  # checked again in its turn, on the changeset the integration produced.
  defp put_back_in_line(multi, ticket, entry, transition, outcome) do
    case Merge.changeset(ticket) do
      {:ok, source} ->
        MergeQueue.put_return(
          multi,
          entry,
          transition,
          outcome,
          source,
          Merge.commit_message_version(ticket)
        )

      {:error, reason} ->
        put_stuck(multi, ticket, "could not merge: #{inspect(reason)}")
    end
  end

  # Whether a person took the ticket out of the merge queue since it came into the state it is in:
  # an integration that was running at the time finishes, and the edge it would have taken into the
  # merging state is not taken (`workflow-grammar-v1.md` § The merge queue). Ordered by the event
  # sequence, which a clock cannot reorder. Running the state again starts it afresh, as entering
  # it does.
  defp taken_out_since_entered?(%Ticket{id: id, state: state}) do
    entered =
      Repo.one(
        from e in Event,
          where:
            e.ticket_id == ^id and
              ((e.type == "transition.taken" and fragment("?->>'to'", e.payload) == ^state) or
                 e.type == "ticket.retried"),
          select: max(e.seq)
      ) || 0

    Repo.exists?(
      from e in Event,
        where: e.ticket_id == ^id and e.type == "merge_queue.taken_out" and e.seq > ^entered
    )
  end

  # The edge to the merging state's `on_conflict`, taken in place of the transition into it, and
  # the conflict that sent it, in one: the timeline shows the move, and the event says why.
  defp put_conflict(multi, ticket, workflow, edge, merging, conflict, actor, comment) do
    multi
    |> put_transition(ticket, workflow, edge, Workflow.merge_conflict_outcome(), actor,
      comment: comment
    )
    |> put_conflict_event(ticket, edge, merging, conflict, actor, stage(edge, merging))
  end

  # A conflict found by the check, before anything moved, or by the merge itself after the race.
  defp stage(%Transition{from: merging}, merging), do: "merge"
  defp stage(_edge, _merging), do: "check"

  defp put_conflict_event(multi, ticket, edge, merging, conflict, actor, stage) do
    Events.log(multi, :conflict_event, "ticket.merge_conflicted", actor, %{
      ticket_id: ticket.id,
      payload: %{
        "state" => merging,
        "from" => edge && edge.from,
        "to" => edge && edge.to,
        "paths" => conflict.paths,
        "head" => conflict.head,
        "changeset" => conflict.source.sha,
        "changeset_version" => conflict.source.version,
        "by" => Atom.to_string(conflict.by),
        "stage" => stage
      }
    })
  end

  # A person's approval whose merge conflicted, sent down `on_conflict`: the approval is recorded
  # against the version it approved — that is what the person did — and the ticket moves to the
  # target rather than into the merging state. Nothing is merged, so there is no entry action.
  defp commit_conflict(ticket, workflow, transition, edge, conflict, user_id, comment) do
    ticket
    |> put_decisions(transition, user_id, :approved, comment, conflict.source)
    |> put_conflict(ticket, workflow, edge, transition.to, conflict, actor(user_id), comment)
    |> Repo.transaction()
    |> case do
      # `Forge.Operator` announces what a person's act did, as it does for every other.
      {:ok, %{ticket: moved}} -> {:ok, moved}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp commit_take(ticket, workflow, transition, outcome, user_id, decision, comment, source) do
    multi = put_decisions(ticket, transition, user_id, decision, comment, source)

    multi =
      case decision do
        :approved ->
          put_transition(multi, ticket, workflow, transition, outcome, actor(user_id),
            comment: comment,
            source: source
          )

        # `docs/design/workflow-grammar-v1.md` § Approval: "Rejection keeps the ticket in `from`
        # and the operator chooses what happens next, including editing the artifact (which
        # creates a new version) and approving that."
        #
        # Keeping it in `from` was the whole of what this did, and that left the decision itself
        # pending for ever: the card never closed, the queue kept offering the same approve or
        # reject, and the chooser the sentence promises stayed hidden behind it. `:stuck` is the
        # status that already means "waiting for you to choose", and it is what the operator
        # needs to be in to do any of the things that sentence lists.
        :rejected ->
          put_stuck(multi, ticket, "approval rejected")
      end

    multi
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        moved = Map.get(changes, :ticket, ticket)
        {:ok, run_entry_actions(moved, workflow, transition, decision, user_id)}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  # The approvals (or rejections) a transition records on the latest version of each artifact it
  # lists, and the decision's event — `changeset`'s on the version the check before the merge was
  # made on, when there was one, so the approval and the commit the transition names are one read
  # (`docs/design/workflow-grammar-v1.md` § Merging). Read again, they would differ only if a
  # version were recorded between the check and the transaction, which nothing here can open: the
  # only writer of a changeset is a job's result, and no job is live while a person takes an edge.
  # So reading it again is an equivalent mutant as far as any test can tell.
  defp put_decisions(ticket, transition, user_id, decision, comment, source, pinned \\ %{}) do
    transition_map = %{"from" => transition.from, "to" => transition.to}

    multi =
      Enum.reduce(transition.approve, Multi.new(), fn name, multi ->
        # `pinned` is Accept's versions, each checked against what the person was shown. Reading
        # the latest here instead is an equivalent mutant as far as a test can tell: a conversation's
        # turn takes the ticket lock Accept holds, so only a writer that takes none — a person
        # editing a document through the API — could commit a newer version in between, and a test
        # cannot interleave one. Passed so the approval names the version the check named when one does.
        case checked(name, source) || Map.get(pinned, name) || Artifacts.latest(ticket.id, name) do
          nil ->
            Multi.error(multi, {:approval, name}, {:no_version, name})

          version ->
            Artifacts.put_approval(
              multi,
              {:approval, name},
              version,
              user_id,
              decision,
              transition_map,
              comment
            )
        end
      end)

    if transition.approve == [] do
      multi
    else
      Events.log(multi, :decision_event, "approval.#{decision}", actor(user_id), %{
        ticket_id: ticket.id,
        payload: Map.put(transition_map, "comment", comment)
      })
    end
  end

  defp checked(name, %{row: row}) when is_binary(name) do
    if name == Workflow.changeset_artifact(), do: row
  end

  defp checked(_name, nil), do: nil

  # -- accepting a chat step -------------------------------------------------------------------

  @doc """
  The person ends a chat step: the ticket takes the edge for `outcome` as it would after a job,
  and the step's conversation is ended (`docs/design/conversations.md` § A conversation that is
  a step).

  **Accept is the approval.** When the edge asks for approval, the latest version of each
  document it names is approved by `user_id`, as `choose/4` would, with no second decision.

  **`seen` is `%{document name => version}` as the person was shown it**, and every declared
  document must still be at exactly that version — one written since, or one the page showed as
  not written, refuses with `{:stale, names}` and approves nothing unseen. In one transaction
  under the ticket's lock, which a step's turn also takes to record its documents, so the
  versions read are the versions approved. Refused, nothing changed, when the ticket is not open,
  is in the merge queue (`:queued`, as `choose/4` refuses) or is no longer in the step, `chat` is
  not the visit's latest or was already accepted (so a second
  press, or a replay after a reconnect, moves the ticket once), a turn is in flight, the outcome
  is not one the step declares or has no edge left (`max`), or a document it must produce has no
  version.
  """
  @spec accept(Ticket.t(), Job.t(), String.t(), String.t() | nil, %{String.t() => pos_integer()}) ::
          {:ok, Ticket.t()} | {:error, term()}
  def accept(%Ticket{} = ticket, %Job{} = chat, user_id, outcome, seen) do
    with {:ok, workflow} <- Tickets.parsed_workflow(ticket),
         {:ok, transition} <- accepted_edge(ticket, workflow, chat, outcome),
         {:ok, source} <- accepted_merge(ticket, workflow, transition) do
      Multi.new()
      |> Multi.run(:locked, fn repo, _changes -> lock_open(repo, ticket.id, :not_active) end)
      |> Multi.run(:step, fn repo, %{locked: locked} ->
        accepted_step(repo, locked, workflow, chat, outcome, seen)
      end)
      |> Multi.merge(fn %{locked: locked, step: %{transition: edge, versions: versions}} ->
        put_decisions(locked, edge, user_id, :approved, nil, source, versions)
        |> put_transition(locked, workflow, edge, outcome, actor(user_id), source: source)
        |> Events.log(:accepted_event, "step.accepted", actor(user_id), %{
          ticket_id: ticket.id,
          job_id: chat.id,
          payload: %{
            "state" => chat.state,
            "visit" => chat.attempt,
            "outcome" => outcome,
            "to" => edge.to,
            "approved" => edge.approve,
            "versions" => Map.new(versions, fn {name, version} -> {name, version.version} end)
          }
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, changes} ->
          moved = Map.get(changes, :ticket, ticket)
          # The conversation is over with the step: its machine released, its branch dealt with as
          # ending any conversation does. After the commit, never inside it.
          Forge.Conversations.end_step(chat, actor: actor(user_id))

          {:ok,
           run_entry_actions(moved, workflow, accepted_transition(changes), :approved, user_id)}

        {:error, step, reason, _changes} when step in [:locked, :step] ->
          {:error, reason}

        # A document the edge approves that no state has written: the refusal the page words,
        # not the step of the transaction it was found in.
        {:error, {:approval, _name}, {:no_version, _name2} = reason, _changes} ->
          {:error, reason}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  defp accepted_transition(changes) do
    %{step: %{transition: transition}} = changes
    transition
  end

  # The edge `outcome` takes, found outside the transaction so a merge into the next state can be
  # checked with no side effect, and found again inside it (`accepted_step/6`) so the answer used
  # is the one the locked ticket gives.
  def accepted_edge(ticket, workflow, chat, outcome) do
    declared = (Workflow.state(workflow, chat.state) || %State{name: chat.state}).outcomes

    # Reached only by a conversation of a state its ticket's workflow lacks, so no test is written:
    # the parser gives every state with a prompt `[done]` when it names no outcomes
    # (`ForgeCore.Workflow.Parser`), a chat step included, so `nil` is only the fallback state
    # above. Deleting the default would make `outcome in nil` raise for that, and for nothing else.
    declared = declared || [Workflow.default_outcome()]

    if outcome in declared do
      case Core.step(workflow, chat.state, outcome, counts(ticket.id)) do
        {:transition, transition} -> {:ok, transition}
        {:approval, transition} -> {:ok, transition}
        {:stuck, {:no_transition, _outcome}} -> {:error, {:no_edge, outcome}}
        {:stuck, {:max_exceeded, _transition}} -> {:error, {:max_spent, outcome}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unknown_outcome, outcome}}
    end
  end

  defp accepted_merge(ticket, workflow, transition) do
    case mergeable(ticket, workflow, transition, :approved) do
      {:ok, source} -> {:ok, source}
      {:conflict, _edge, conflict} -> {:error, {:merge_conflict, conflict}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accepted_step(repo, ticket, workflow, chat, outcome, seen) do
    row = repo.get!(Job, chat.id)

    latest =
      repo.one(
        from j in Job,
          where: j.ticket_id == ^ticket.id and j.state == ^chat.state and j.kind == :chat,
          select: max(j.attempt)
      )

    cond do
      ticket.state != chat.state ->
        {:error, {:not_in_step, chat.state}}

      # Accept takes an edge by hand, so it meets the rule `choose/4` does: a queued ticket — one
      # whose conflict route led into this step — moves only once a person takes it out. Under the
      # lock `take_out/2` holds, so the two are serialised.
      MergeQueue.queued?(ticket) ->
        {:error, :queued}

      # Before `superseded`, so that on an edge back into this state — where the press opened a newer
      # visit — a second press on the old conversation is told it was accepted, not that the
      # ticket has been round again.
      Forge.Conversations.accepted?(chat.id) ->
        {:error, :already_accepted}

      latest != row.attempt ->
        {:error, :superseded}

      Forge.Conversations.in_flight?(row) ->
        {:error, :in_flight}

      true ->
        accepted_documents(ticket, workflow, chat, outcome, seen)
    end
  end

  # **Every document Accept records or approves is pinned to the version the person was shown**:
  # the step's own `produces` and the documents the chosen edge approves, which may be an earlier
  # state's. An approved document the step does not produce used to be read as the latest and not
  # checked, so a version written meanwhile — by the step's agent, a plain chat or a person through
  # the API — was approved unseen. The page lists and sends it like any other
  # (`Forge.Steps.view/2`), so it is checked here the same way.
  defp accepted_documents(ticket, workflow, chat, outcome, seen) do
    state = Workflow.state(workflow, chat.state)

    with {:ok, transition} <- accepted_edge(ticket, workflow, chat, outcome) do
      own = for name <- state.produces, Workflow.document?(name), do: name
      approved = for name <- transition.approve, Workflow.document?(name), do: name
      names = Enum.uniq(own ++ approved)
      latest = Map.new(names, &{&1, Artifacts.latest(ticket.id, &1)})

      # An optional document the step never wrote is not missing — unless the edge approves it,
      # when there is nothing to approve.
      missing =
        for name <- names,
            latest[name] == nil,
            name not in state.optional or name in approved,
            do: name

      stale =
        for name <- names,
            Map.get(seen, name) != (latest[name] && latest[name].version),
            do: name

      with [] <- missing |> Enum.sort() |> none_or({:no_version, missing}),
           [] <- stale |> Enum.sort() |> none_or({:stale, stale}) do
        {:ok,
         %{
           transition: transition,
           versions: for({n, v} <- latest, v != nil, into: %{}, do: {n, v})
         }}
      else
        {tag, names} -> {:error, {tag, Enum.sort(names)}}
      end
    end
  end

  defp none_or([], _refusal), do: []
  defp none_or(_names, refusal), do: refusal

  # -- sending a ticket down the conflict route ------------------------------------------------

  @doc """
  Sends a ticket whose changeset no longer merges down its merging state's `on_conflict` before
  anybody approves it (`docs/design/workflow-grammar-v1.md` § Merging): the action beside the
  notice a merge leaves on the tickets it put in conflict (`Forge.Merge.Watch`).

  The check is made again, and a conflict takes the route a conflicting approval takes, by this
  person, less the approval — a pending one is cleared, since the version it would approve is
  about to be replaced. Refused on a ticket that is not open, with a job live in its state, or in
  a state with no edge into a merging state that names an `on_conflict`; and refused with
  `:merges_cleanly` when there is nothing to integrate after all.
  """
  @spec integrate(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def integrate(%Ticket{} = ticket, user_id) do
    workflow = Tickets.workflow(ticket)

    with {:ok, transition} <- conflict_route(ticket, workflow) do
      case check_merge(ticket, workflow, transition, :person) do
        {:conflict, edge, conflict} ->
          send_down(ticket, workflow, edge, transition.to, conflict, user_id)

        {:ok, _source} ->
          {:error, :merges_cleanly}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_down(ticket, workflow, edge, merging, conflict, user_id) do
    Multi.new()
    |> put_conflict(ticket, workflow, edge, merging, conflict, actor(user_id), nil)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: moved}} -> {:ok, moved}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "The state `integrate/2` would send the ticket to, or nil where it would refuse."
  @spec integrates_to(Ticket.t(), Workflow.t()) :: String.t() | nil
  def integrates_to(%Ticket{} = ticket, %Workflow{} = workflow) do
    case conflict_route(ticket, workflow) do
      {:ok, transition} -> Workflow.on_conflict(workflow, transition.to)
      {:error, _reason} -> nil
    end
  end

  # The edge out of where the ticket rests into a merging state that names an `on_conflict` — only
  # a merging state may name one (`ForgeCore.Workflow.Validator`), so naming one is the test.
  defp conflict_route(%Ticket{status: status}, _workflow) when not Ticket.open?(status),
    do: {:error, {:not_open, status}}

  defp conflict_route(%Ticket{} = ticket, workflow) do
    with :ok <- not_queued(ticket),
         :ok <- no_live_job(ticket) do
      workflow
      |> Workflow.transitions_from(ticket.state)
      |> Enum.find(&(Workflow.on_conflict(workflow, &1.to) != nil))
      |> case do
        %Transition{} = transition -> {:ok, transition}
        nil -> {:error, :no_conflict_route}
      end
    end
  end

  # -- the merge queue --------------------------------------------------------------------------

  # Approving an edge declared to queue records the approval and the ticket's place in line; it
  # takes no transition and checks no conflict — that is the queue's, in its turn.
  defp queues?(workflow, %Transition{to: to} = transition),
    do: Transition.queues?(transition) and Workflow.merges_on_enter?(workflow, to)

  defp commit_enqueue(ticket, transition, outcome, user_id, comment) do
    case Merge.changeset(ticket) do
      {:ok, source} ->
        ticket
        |> put_decisions(transition, user_id, :approved, comment, source)
        |> MergeQueue.put_enter(ticket, transition, outcome, source, user_id, %{
          comment: blank_to_nil(comment),
          commit_message_version: Merge.commit_message_version(ticket)
        })
        |> Tickets.put_progress(:ticket, ticket, %{
          state: ticket.state,
          status: :active,
          pending_transition: nil,
          cost_usd: ticket.cost_usd
        })
        |> Repo.transaction()
        |> case do
          {:ok, %{ticket: queued}} ->
            MergeQueue.kick(ticket.project_id)
            {:ok, queued}

          # A second approval racing the first meets the unique index on the ticket.
          {:error, :merge_queue_entry, _changeset, _changes} ->
            {:error, :queued}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:merge_impossible, reason}}
    end
  end

  @doc """
  Handles the front of the project's merge queue: `:idle` when nothing waits, `:busy` when a merge
  is already running there and another ticket waits behind it, and otherwise what became of the ticket at the front — `{:merged |
  :integrating | :stuck | :left, ticket_id}`. Called by `Forge.MergeQueue.Runner`, one project at a
  time; tickets of other projects do not wait for it.

  The front `waiting` row is claimed (the database refuses a second claim in the project) and its
  ticket is checked against the default branch's head. Clean: the approved version is merged under
  the commit message that was current at the approval (after an integration, the changeset it
  produced and the latest message). Conflicting: the existing conflict route is
  taken and the ticket keeps its place while it is integrated. Anything else sticks that ticket
  and leaves the line to the one behind it.
  """
  @spec advance_queue(String.t()) :: :idle | :busy | {atom(), String.t()}
  def advance_queue(project_id) do
    case MergeQueue.claim(project_id) do
      nil -> :idle
      :busy -> :busy
      %Entry{} = entry -> {run_entry(entry), entry.ticket_id}
    end
  end

  defp run_entry(%Entry{} = entry) do
    with %Ticket{status: :active, state: state} = ticket when state == entry.from_state <-
           Repo.get(Ticket, entry.ticket_id),
         workflow = Tickets.workflow(ticket),
         {:ok, transition} <-
           Core.choose(workflow, entry.from_state, entry.to_state, entry.edge_outcome) do
      check_entry(ticket, workflow, transition, entry)
    else
      _no_longer_queued -> leave_line(entry, "moved on")
    end
  end

  defp check_entry(ticket, workflow, transition, entry) do
    source = %{sha: entry.changeset_sha, version: entry.changeset_version}

    case Merge.check(ticket, entry.changeset_sha) do
      :ok ->
        merge_entry(ticket, workflow, transition, entry, source)

      {:conflict, paths, head} ->
        conflict = %{paths: paths, head: head, source: source, by: :engine}
        conflicted_entry(ticket, workflow, entry, conflict)

      {:error, reason} ->
        stick_entry(ticket, entry, "could not merge: #{inspect(reason)}")
    end
  end

  defp merge_entry(ticket, workflow, transition, entry, source) do
    Multi.new()
    |> Multi.run(:open, fn repo, _changes -> lock_entry(repo, entry) end)
    |> Multi.merge(fn %{open: open} ->
      put_transition(Multi.new(), open, workflow, transition, entry.outcome, :system,
        source: source,
        commit_message_version: entry.commit_message_version,
        comment: entry.comment
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: moved}} ->
        entered = enter(moved, workflow, entry.to_state, entry_user(entry), by: :engine)
        Events.notify(ticket.id)
        settle(entry, entered, workflow)

      {:error, :open, _gone, _changes} ->
        leave_line(entry, "moved on")

      {:error, _step, reason, _changes} ->
        stick_entry(ticket, entry, "could not merge: #{inspect(reason)}")
    end
  end

  defp conflicted_entry(ticket, workflow, entry, conflict) do
    rounds = engine_rounds(ticket.id)

    case Core.conflict(workflow, entry.from_state, entry.to_state, :engine, rounds) do
      {:route, edge} ->
        sent_down(ticket, workflow, entry, fn open ->
          put_conflict(Multi.new(), open, workflow, edge, entry.to_state, conflict, :system, nil)
        end)

      {:stuck, {:conflict_rounds, n}} ->
        sent_down(ticket, workflow, entry, fn open ->
          Multi.new()
          |> put_conflict_event(open, nil, entry.to_state, conflict, :system, "check")
          |> put_stuck(open, rounds_reason(n))
        end)

      :refuse ->
        stick_entry(ticket, entry, "merge conflict in #{Enum.join(conflict.paths, ", ")}")
    end
  end

  defp sent_down(ticket, workflow, entry, build) do
    Multi.new()
    |> Multi.run(:open, fn repo, _changes -> lock_entry(repo, entry) end)
    |> Multi.merge(fn %{open: open} -> build.(open) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: moved}} ->
        Events.notify(ticket.id)
        settle(entry, moved, workflow)

      {:error, :open, _gone, _changes} ->
        leave_line(entry, "moved on")

      {:error, _step, reason, _changes} ->
        stick_entry(ticket, entry, "could not merge: #{inspect(reason)}")
    end
  end

  # The ticket row, locked, only while it is still the one the row is for: active, where it was
  # queued, and the row not taken out meanwhile.
  #
  # Every condition here is an equivalent mutant as far as a test can tell: `run_entry/1` read the
  # status and the state a moment earlier, and the row is `merging` since `claim/1`, which
  # `take_out/2` refuses to delete. A ticket or row can only differ now by another writer
  # committing between that read and this lock, which nothing in the suite can open on demand (the
  # same window `cancel/2` documents).
  defp lock_entry(repo, %Entry{} = entry) do
    ticket = repo.one!(from t in Ticket, where: t.id == ^entry.ticket_id, lock: "FOR UPDATE")
    current = repo.get(Entry, entry.id)

    if ticket.status == :active and ticket.state == entry.from_state and current != nil,
      do: {:ok, ticket},
      else: {:error, :gone}
  end

  # What became of the ticket the merge was for, and so of its row.
  defp settle(%Entry{} = entry, %Ticket{} = ticket, workflow) do
    cond do
      ticket.status == :stuck ->
        leave_line(entry, "stuck")
        :stuck

      ticket.state == entry.to_state and ticket.status in [:active, :done] ->
        leave_line(entry, "merged")
        :merged

      integrating?(workflow, ticket) ->
        Multi.new()
        |> MergeQueue.put_status(ticket.id, :integrating)
        |> Repo.transaction()

        :integrating

      true ->
        leave_line(entry, "needs_person")
        :left
    end
  end

  # Sent to a job state, the ticket is being integrated and keeps its place. A conflict route
  # that ends in a human state needs a person's approval, and a person's approval is a new place.
  defp integrating?(workflow, %Ticket{status: :active, state: state}) do
    case Workflow.state(workflow, state) do
      %State{prompt: prompt} when is_binary(prompt) -> true
      _human_or_command -> false
    end
  end

  defp integrating?(_workflow, _ticket), do: false

  # Locked and checked against the row, as the merge is: a ticket a person took out since the
  # runner claimed it must not be stuck by a check that failed for it, which would clear the
  # pending approval the take-out just restored. **No test opens that window**: it needs a take-out
  # that read the row `waiting` just before `claim/1` committed and deletes it just after, and
  # dropping the lock is an equivalent mutant as far as the suite can tell.
  defp stick_entry(_ticket, entry, reason) do
    Multi.new()
    |> Multi.run(:open, fn repo, _changes -> lock_entry(repo, entry) end)
    |> Multi.merge(fn %{open: open} -> put_stuck(Multi.new(), open, reason) end)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} ->
        Events.notify(entry.ticket_id)
        leave_line(entry, "stuck")
        :stuck

      {:error, _step, _reason, _changes} ->
        leave_line(entry, "moved on")
    end
  end

  defp leave_line(%Entry{ticket_id: ticket_id}, reason) do
    Multi.new() |> MergeQueue.put_leave(ticket_id, reason) |> Repo.transaction()
    Events.notify(ticket_id)
    :left
  end

  defp entry_user(%Entry{entered_by: %{"kind" => "user", "id" => id}}), do: id
  defp entry_user(%Entry{}), do: nil

  @doc """
  Takes a ticket out of the merge queue: an unapproval (`docs/design/workflow-grammar-v1.md` § The
  merge queue). The approval is withdrawn and the ticket is again waiting for approval where it was
  approved from; queueing it again takes a new approval. A ticket being integrated keeps
  integrating — only the merge after it is stopped, which `put_engine_transition/5` sees as the job
  ends. Refused with `{:not_queued, how_it_left}` when the ticket is not queued (it merged, or
  someone took it out first) and with `:merging` while its merge is running.
  """
  @spec take_out(Ticket.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def take_out(%Ticket{id: id}, user_id) do
    Multi.new()
    |> Multi.run(:locked, fn repo, _changes ->
      {:ok, repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")}
    end)
    |> Multi.run(:entry, fn repo, _changes ->
      case repo.get_by(Entry, ticket_id: id) do
        nil -> {:error, {:not_queued, MergeQueue.last_left(id)}}
        %Entry{status: :merging} -> {:error, :merging}
        %Entry{} = entry -> {:ok, entry}
      end
    end)
    |> Multi.merge(fn %{locked: ticket, entry: entry} ->
      Multi.new()
      |> Multi.delete_all(:left, from(e in Entry, where: e.id == ^entry.id))
      |> Artifacts.put_withdrawal(entry.approval_ids)
      |> Events.log(:taken_out_event, "merge_queue.taken_out", actor(user_id), %{
        ticket_id: id,
        payload: %{
          "from" => entry.from_state,
          "to" => entry.to_state,
          "status" => Atom.to_string(entry.status)
        }
      })
      |> put_unapproved(ticket, entry)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} ->
        MergeQueue.kick(changes.locked.project_id)
        {:ok, Map.get(changes, :ticket, changes.locked)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # An integrating ticket is where integration put it and the job runs on. A waiting one is back
  # where its approval was asked for: the pending approval again if a job's outcome asked it, the
  # chooser if it rests in a human state, and otherwise stuck, which is what offers a person the
  # edges out.
  #
  # Picking the edge by `entry.outcome` instead of `edge_outcome` is an equivalent mutant here: the
  # pending approval is restored only when `outcome != nil`, and a job's outcome that asked for
  # an approval is the outcome of the edge it asked on, so the two are equal whenever it matters.
  defp put_unapproved(multi, _ticket, %Entry{status: :integrating}), do: multi

  defp put_unapproved(multi, ticket, %Entry{} = entry) do
    workflow = Tickets.workflow(ticket)

    case Core.choose(workflow, entry.from_state, entry.to_state, entry.edge_outcome) do
      {:ok, %Transition{approve: [_ | _]} = transition} when entry.outcome != nil ->
        put_pending_approval(multi, ticket, transition, entry.outcome)

      _no_approval_to_ask_again ->
        if human_state?(workflow, ticket.state),
          do: multi,
          else: put_stuck(multi, ticket, @taken_out_reason)
    end
  end

  defp human_state?(workflow, state_name) do
    case Workflow.state(workflow, state_name) do
      %State{} = state -> not State.job?(state) and not State.command?(state)
      nil -> false
    end
  end

  @doc """
  Finishes the merge queue's unfinished work: a row left `merging` is finished from where its
  ticket got to. In the merging state (the transition committed): the merge is finished
  (`enter/5` is idempotent). Sent down the conflict route (that commit made, the row not yet
  marked): the row becomes `integrating`, keeping its place. Where it was queued from: back to
  `waiting`. Anywhere else it moved on, and the row goes. With a project, only its rows.
  **Only by whoever holds the project's name in `Forge.MergeQueue.Registry`** (the runner's task
  does, before anything else): a live task's `merging` row is not stranded and must be left alone.
  Called without one it is for a caller who knows nothing is running, which is the tests.
  """
  @spec recover_queue(String.t() | nil) :: non_neg_integer()
  def recover_queue(project_id \\ nil) do
    entries = Enum.filter(MergeQueue.merging(), &(project_id in [nil, &1.project_id]))
    Enum.each(entries, &recover_entry/1)
    length(entries)
  end

  defp recover_entry(%Entry{} = entry) do
    ticket = Repo.get(Ticket, entry.ticket_id)
    workflow = ticket && Tickets.workflow(ticket)

    cond do
      ticket == nil or ticket.status not in [:active, :done] ->
        leave_line(entry, "moved on")

      ticket.state == entry.to_state ->
        settle(
          entry,
          enter(ticket, workflow, entry.to_state, entry_user(entry), by: :engine),
          workflow
        )

      sent_down?(ticket, workflow, entry) ->
        settle(entry, ticket, workflow)

      ticket.state == entry.from_state ->
        Multi.new() |> MergeQueue.put_status(entry.ticket_id, :waiting) |> Repo.transaction()

      true ->
        leave_line(entry, "moved on")
    end
  end

  # The conflict route was taken and the row not marked. When the route leads back to the state the
  # ticket was queued from (an integrating state looping on itself) the state alone cannot say, but
  # the job the route made can.
  defp sent_down?(ticket, workflow, entry) do
    ticket.state == Workflow.on_conflict(workflow, entry.to_state) and
      (ticket.state != entry.from_state or Jobs.live?(ticket.id, ticket.state))
  end

  # -- entry actions ---------------------------------------------------------------------------

  @doc """
  Runs what entering `state_name` does, after the transition into it has been recorded.

  `merge` is the only action in v1, and it merges the commit the transition into the state named
  (`docs/design/workflow-grammar-v1.md` § Merging). It was checked before the transition was taken,
  so a failure here is a race — something else moved the default branch in between.
  `Forge.Merge.perform/4` retries once against the moved head, and what it returns then is final:
  a conflict leaves the merging state by its `on_conflict`, when it names one, and anything else
  but success sticks the ticket with the reason rather than leaving it claiming to be merged.
  `Forge.Merge.perform/4` is idempotent, so retrying is always safe.

  `:by` is `:engine` for the merge queue's own merge (a conflict that wins the race then counts
  against the three-in-a-row bound), whichever `user_id` is the commit's author.
  """
  @spec enter(Ticket.t(), Workflow.t(), String.t(), String.t() | nil, keyword()) :: Ticket.t()
  def enter(%Ticket{} = ticket, %Workflow{} = workflow, state_name, user_id, opts \\ []) do
    if Workflow.merges_on_enter?(workflow, state_name) do
      merge_now(ticket, workflow, user_id, Keyword.get_lazy(opts, :by, fn -> by(user_id) end))
    else
      ticket
    end
  end

  defp run_entry_actions(ticket, workflow, %Transition{to: to}, :approved, user_id),
    do: enter(ticket, workflow, to, user_id)

  defp run_entry_actions(ticket, _workflow, _transition, _decision, _user_id), do: ticket

  defp merge_now(ticket, workflow, user_id, by) do
    user =
      Forge.Actor.user_id(user_id) && Repo.get(Forge.Accounts.User, Forge.Actor.user_id(user_id))

    case named(ticket) do
      {:ok, source} ->
        case Merge.perform(ticket, source.sha, source.commit_message_version, user) do
          {:ok, merged} ->
            merged(ticket, source, merged, user_id)

          {:conflict, paths, head} ->
            conflict = %{paths: paths, head: head, source: source, by: by}

            leave_merging(
              ticket,
              workflow,
              conflict,
              Workflow.on_conflict(workflow, ticket.state)
            )

          {:error, reason} ->
            stick_after_merge(ticket, "could not merge: #{inspect(reason)}")
        end

      {:error, reason} ->
        stick_after_merge(ticket, "could not merge: #{inspect(reason)}")
    end
  end

  defp merged(ticket, source, %{sha: sha, already: already}, user_id) do
    Events.append("ticket.merged", actor(user_id), %{
      ticket_id: ticket.id,
      payload: %{"sha" => sha, "already" => already, "changeset" => source.sha}
    })

    # What the merge did to the project's other open tickets (`Forge.Merge.Watch`). A merge that
    # found its commit already there moved nothing.
    unless already,
      do: Merge.Watch.after_merge(ticket.project_id, sha, %{"ticket" => ticket.number})

    ticket
  end

  defp by(nil), do: :engine
  defp by(_user_id), do: :person

  # The commit the transition into the merging state named: on its `transition.taken`, the latest
  # into the state the ticket is in. Never the latest changeset version — that is the rule this
  # exists to keep (`docs/design/workflow-grammar-v1.md` § Merging). Asking only for the latest
  # transition of any kind is an equivalent mutant: every caller of `enter/4` calls it straight
  # after the transition into the state; the filter keeps that from being something to remember.
  defp named(%Ticket{id: id, state: state}) do
    Repo.one(
      from e in Event,
        where:
          e.ticket_id == ^id and e.type == "transition.taken" and
            fragment("?->>'to'", e.payload) == ^state,
        order_by: [desc: e.seq],
        limit: 1,
        select: e.payload
    )
    |> case do
      %{"changeset" => sha, "changeset_version" => version, "commit_message_version" => message} ->
        {:ok, %{sha: sha, version: version, commit_message_version: message}}

      # A transition that named a changeset and no `commit-message`: the ticket reached its merge
      # with nothing written for the commit to say. Whether that is a ticket pinned before the
      # document existed, which merges under the message earlier releases wrote, or one that was
      # meant to have one and sticks, is `Merge.perform/4`'s to say: the decision is in one place.
      %{"changeset" => sha, "changeset_version" => version} ->
        {:ok, %{sha: sha, version: version, commit_message_version: nil}}

      _none ->
        {:error, :no_changeset}
    end
  end

  # The late race lost twice: with nowhere to go, stuck as it always was; with an `on_conflict`,
  # out of the merging state by it — locked and re-read, as `stick/3` is, so a ticket cancelled
  # meanwhile stays cancelled. A merging state with transitions out leaves the ticket `active` in
  # it, which `cancel/2` accepts. And when the move cannot be made — the target's job cannot be
  # created — stuck there saying so, rather than left reading `done` with nothing merged.
  defp leave_merging(ticket, _workflow, conflict, nil),
    do: stick_after_merge(ticket, "merge conflict in #{Enum.join(conflict.paths, ", ")}")

  defp leave_merging(ticket, workflow, conflict, target) do
    edge = Workflow.conflict_transition(workflow, ticket.state, ticket.state)

    Multi.new()
    |> Multi.run(:open, fn repo, _changes -> lock_uncancelled(repo, ticket.id) end)
    |> Multi.merge(fn %{open: open} ->
      put_conflict(Multi.new(), open, workflow, edge, ticket.state, conflict, :system, nil)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: moved}} ->
        Events.notify(moved.id)
        moved

      {:error, :open, _cancelled, _changes} ->
        ticket

      {:error, _step, reason, _changes} ->
        stick_after_merge(
          ticket,
          "merge conflict in #{Enum.join(conflict.paths, ", ")}, " <>
            "and could not move to #{target}: #{inspect(reason)}"
        )
    end
  end

  defp stick_after_merge(ticket, reason) do
    case stick(ticket, reason) do
      {:ok, stuck} -> stuck
      {:error, _reason} -> ticket
    end
  end

  defp actor(who), do: Forge.Actor.of(who)
end
