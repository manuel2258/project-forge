defmodule Forge.Engine do
  @moduledoc """
  Applies `ForgeCore.Engine` decisions to tickets: transitions, approvals and stuck states,
  each with its event, and the next job when the target is a job state.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Jobs, Merge, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  require Forge.Tickets.Ticket
  alias ForgeCore.Engine, as: Core
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

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
          |> put_commit_message(Merge.commit_message_version(ticket))

        {:error, _none} ->
          payload
      end
    else
      payload
    end
  end

  # No key where the ticket has no `commit-message` yet, the way a missing changeset leaves none:
  # `named/1` then reports it rather than the merge inventing something to say.
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

    with :ok <- no_live_job(ticket),
         {:ok, transition} <- Core.choose(workflow, ticket.state, to, Keyword.get(opts, :outcome)) do
      take(ticket, workflow, transition, nil, user_id, :approved, Keyword.get(opts, :comment))
    end
  end

  defp no_live_job(%Ticket{id: id, state: state}) do
    if Jobs.live?(id, state), do: {:error, {:job_live, state}}, else: :ok
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
        {:ok, ticket}

      {:error, :locked, reason, _changes} ->
        {:error, reason}

      {:error, step, reason, _changes} ->
        {:error, {step, reason}}
    end
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
      true -> with(:ok <- no_live_job(ticket), do: {:ok, :repinnable})
    end
  end

  @doc "Whether `retry/2` would run the ticket's state again, for a surface deciding to offer it."
  @spec retryable?(Ticket.t()) :: boolean()
  def retryable?(%Ticket{} = ticket), do: retryable(ticket, Tickets.workflow(ticket)) == :ok

  defp retryable(%Ticket{status: status}, _workflow) when not Ticket.open?(status),
    do: {:error, {:not_retryable, status}}

  defp retryable(%Ticket{} = ticket, workflow) do
    case Workflow.state(workflow, ticket.state) do
      %State{prompt: prompt} when is_binary(prompt) -> no_live_job(ticket)
      %State{invoke: [_ | _]} -> no_live_job(ticket)
      _human_or_missing -> {:error, {:no_job_in, ticket.state}}
    end
  end

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
  # moved it — took a transition or ran its state again: the count the loop round an integrating
  # state is bounded by (`ForgeCore.Engine.conflict/5`). `>` and `>=` against the person's event
  # are equivalent mutants: it is never itself a `ticket.merge_conflicted`.
  defp engine_rounds(ticket_id) do
    person =
      Repo.one(
        from e in Event,
          where:
            e.ticket_id == ^ticket_id and e.type in ["transition.taken", "ticket.retried"] and
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

  # The engine's own transition. Into a merging state that names an `on_conflict` it is checked
  # first, as a person's approval is; into any other state — a merging state that names none
  # included, so a workflow without the key behaves as it always did — it is simply taken.
  defp put_engine_transition(multi, ticket, workflow, %Transition{to: to} = transition, outcome) do
    # Only a merging state may name an `on_conflict` (`ForgeCore.Workflow.Validator`), so naming
    # one is the test, as in `conflict_route/2`.
    if Workflow.on_conflict(workflow, to) != nil do
      case check_merge(ticket, workflow, transition, :engine) do
        {:ok, source} ->
          put_transition(multi, ticket, workflow, transition, outcome, :system, source: source)

        {:conflict, edge, conflict} ->
          put_conflict(multi, ticket, workflow, edge, to, conflict, :system, nil)

        {:stuck, rounds, conflict} ->
          multi
          |> put_conflict_event(ticket, nil, to, conflict, :system, "check")
          |> put_stuck(
            ticket,
            "merge still conflicts after #{rounds} integrations in a row: " <>
              "the integrate-then-merge loop stops here"
          )

        # Nothing to merge, or nowhere to merge it: stuck where it is, with its edges out, rather
        # than in a terminal state that would offer none.
        {:error, {:merge_impossible, reason}} ->
          put_stuck(multi, ticket, "could not merge: #{inspect(reason)}")
      end
    else
      put_transition(multi, ticket, workflow, transition, outcome, :system)
    end
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
    |> put_conflict(ticket, workflow, edge, transition.to, conflict, {:user, user_id}, comment)
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
          put_transition(multi, ticket, workflow, transition, outcome, {:user, user_id},
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
  defp put_decisions(ticket, %Transition{} = transition, user_id, decision, comment, source) do
    transition_map = %{"from" => transition.from, "to" => transition.to}

    multi =
      Enum.reduce(transition.approve, Multi.new(), fn name, multi ->
        case checked(name, source) || Artifacts.latest(ticket.id, name) do
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
      Events.log(multi, :decision_event, "approval.#{decision}", {:user, user_id}, %{
        ticket_id: ticket.id,
        payload: Map.put(transition_map, "comment", comment)
      })
    end
  end

  defp checked(name, %{row: row}) when is_binary(name) do
    if name == Workflow.changeset_artifact(), do: row
  end

  defp checked(_name, nil), do: nil

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
    |> put_conflict(ticket, workflow, edge, merging, conflict, {:user, user_id}, nil)
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
    with :ok <- no_live_job(ticket) do
      workflow
      |> Workflow.transitions_from(ticket.state)
      |> Enum.find(&(Workflow.on_conflict(workflow, &1.to) != nil))
      |> case do
        %Transition{} = transition -> {:ok, transition}
        nil -> {:error, :no_conflict_route}
      end
    end
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
  """
  @spec enter(Ticket.t(), Workflow.t(), String.t(), String.t() | nil) :: Ticket.t()
  def enter(%Ticket{} = ticket, %Workflow{} = workflow, state_name, user_id) do
    if Workflow.merges_on_enter?(workflow, state_name) do
      merge_now(ticket, workflow, user_id)
    else
      ticket
    end
  end

  defp run_entry_actions(ticket, workflow, %Transition{to: to}, :approved, user_id),
    do: enter(ticket, workflow, to, user_id)

  defp run_entry_actions(ticket, _workflow, _transition, _decision, _user_id), do: ticket

  defp merge_now(ticket, workflow, user_id) do
    user = user_id && Repo.get(Forge.Accounts.User, user_id)

    case named(ticket) do
      {:ok, source} ->
        case Merge.perform(ticket, source.sha, source.commit_message_version, user) do
          {:ok, merged} ->
            merged(ticket, source, merged, user_id)

          {:conflict, paths, head} ->
            conflict = %{paths: paths, head: head, source: source, by: by(user_id)}

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
      # with nothing written for the commit to say. Sticking says so, rather than merging under a
      # message nobody wrote.
      %{"changeset" => _sha, "changeset_version" => _version} ->
        {:error, :no_commit_message}

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

  defp actor(nil), do: :system
  defp actor(user_id), do: {:user, user_id}
end
