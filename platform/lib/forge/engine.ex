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
  `resume_placement/2` can find the tickets that the arrival of an assignment may have unblocked.
  """
  @spec stick(Ticket.t(), String.t(), :placement | nil) :: {:ok, Ticket.t()} | {:error, term()}
  def stick(%Ticket{} = ticket, reason, cause \\ nil) do
    Multi.new()
    |> put_stuck(ticket, reason, cause)
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
          put_transition(multi, ticket, workflow, transition, outcome, :system)

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

  @doc "Adds taking `transition` to `multi`: ticket state, event, next job or done."
  @spec put_transition(
          Multi.t(),
          Ticket.t(),
          Workflow.t(),
          Transition.t(),
          String.t() | nil,
          Events.actor()
        ) :: Multi.t()
  def put_transition(
        multi,
        %Ticket{} = ticket,
        %Workflow{} = workflow,
        %Transition{} = transition,
        outcome,
        actor
      ) do
    target = Workflow.state(workflow, transition.to)
    terminal = Workflow.terminal?(workflow, transition.to)

    multi
    |> Tickets.put_progress(:ticket, ticket, %{
      state: transition.to,
      status: if(terminal, do: :done, else: :active),
      pending_transition: nil,
      cost_usd: ticket.cost_usd
    })
    |> Events.log(:transition_event, "transition.taken", actor, %{
      ticket_id: ticket.id,
      payload: %{
        "from" => transition.from,
        "to" => transition.to,
        "outcome" => outcome || Transition.outcome(transition)
      }
    })
    |> put_follow_up(ticket, workflow, transition, target, terminal)
  end

  defp put_follow_up(multi, ticket, _workflow, transition, _target, true) do
    Events.log(multi, :done_event, "ticket.done", :system, %{
      ticket_id: ticket.id,
      payload: %{"state" => transition.to}
    })
  end

  defp put_follow_up(multi, _ticket, workflow, transition, %State{prompt: prompt}, false)
       when is_binary(prompt) do
    Multi.merge(multi, fn %{ticket: ticket} ->
      Jobs.put_create(Multi.new(), :next_job, ticket, workflow, transition.to)
    end)
  end

  defp put_follow_up(multi, _ticket, _workflow, _transition, _human_state, false), do: multi

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

  defp stuck_payload(reason, nil), do: %{"reason" => reason}
  defp stuck_payload(reason, cause), do: %{"reason" => reason, "cause" => to_string(cause)}

  @doc """
  Brings back the tickets of `project_id` that are stuck only because their job could not be
  placed, now that an assignment has arrived that may place it.

  **Without this a placement stick was a dead end.** The ticket is stuck holding a pending job,
  and `choose/4` refuses a transition while a job for the current state is live, so once the
  missing template, machine or credential was assigned there was nothing a person could do from
  the product to get the job run (`docs/design/credentials.md` § How a job picks).

  Only a ticket whose latest stick was for placement, and that still holds a pending job for its
  state, comes back: a ticket stuck on its allowance, a rejected approval or a missing transition
  was stuck for a reason no assignment answers. If the assignment was not the missing piece, the
  next scheduling pass sticks it again — one event, not a loop.
  """
  @spec resume_placement(String.t(), Forge.Events.actor()) :: non_neg_integer()
  def resume_placement(project_id, actor) do
    from(t in Ticket, where: t.project_id == ^project_id and t.status == :stuck)
    |> Repo.all()
    |> Enum.filter(&(stuck_for_placement?(&1) and pending_job?(&1)))
    |> Enum.count(&(unstick(&1, actor) == :ok))
  end

  defp stuck_for_placement?(%Ticket{id: id}) do
    Repo.one(
      from e in Event,
        where: e.ticket_id == ^id and e.type == "ticket.stuck",
        order_by: [desc: e.seq],
        limit: 1,
        select: e.payload["cause"]
    ) == "placement"
  end

  defp pending_job?(%Ticket{id: id, state: state}) do
    Repo.exists?(
      from j in Job, where: j.ticket_id == ^id and j.state == ^state and j.status == :pending
    )
  end

  defp unstick(ticket, actor) do
    Multi.new()
    |> Tickets.put_progress(:ticket, ticket, %{
      state: ticket.state,
      status: :active,
      cost_usd: ticket.cost_usd,
      pending_transition: nil
    })
    |> Events.log(:event, "ticket.unstuck", actor, %{
      ticket_id: ticket.id,
      payload: %{"reason" => "an assignment arrived that may place its job"}
    })
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
  A person takes a declared transition out of the current state: from a human state, or to
  unstick a ticket. Refused while a job for the current state is pending, running or
  waiting. A transition that requires approval records the approvals as part of the choice.
  Options: `:outcome` picks between parallel edges, `:comment` is stored with approvals.
  """
  @spec choose(Ticket.t(), String.t(), String.t(), keyword()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def choose(%Ticket{} = ticket, user_id, to, opts \\ []) do
    workflow = Tickets.workflow(ticket)

    with :ok <- no_live_job(ticket),
         {:ok, transition} <- Core.choose(workflow, ticket.state, to, Keyword.get(opts, :outcome)) do
      take(ticket, workflow, transition, nil, user_id, :approved, Keyword.get(opts, :comment))
    end
  end

  defp no_live_job(%Ticket{id: id, state: state}) do
    if Jobs.live?(id, state), do: {:error, {:job_live, state}}, else: :ok
  end

  # Records approvals (or rejections) for the transition's artifacts, then takes it if approved.
  defp take(ticket, workflow, %Transition{} = transition, outcome, user_id, decision, comment) do
    with :ok <- mergeable(ticket, workflow, transition, decision) do
      commit_take(ticket, workflow, transition, outcome, user_id, decision, comment)
    end
  end

  # A git side effect can live neither inside the transaction, which may roll back, nor simply
  # after it: a conflict would then leave the ticket reading `merged` while the default branch
  # never moved, and a terminal state has no edges to get out by. So the merge is checked first,
  # with no side effect, and the approval is refused while the ticket still has a way forward.
  defp mergeable(ticket, workflow, %Transition{to: to}, :approved) do
    if Workflow.merges_on_enter?(workflow, to) do
      case Merge.check(ticket) do
        :ok -> :ok
        {:conflict, paths} -> {:error, {:merge_conflict, paths}}
        {:error, reason} -> {:error, {:merge_impossible, reason}}
      end
    else
      :ok
    end
  end

  defp mergeable(_ticket, _workflow, _transition, _decision), do: :ok

  defp commit_take(
         ticket,
         workflow,
         %Transition{} = transition,
         outcome,
         user_id,
         decision,
         comment
       ) do
    transition_map = %{"from" => transition.from, "to" => transition.to}

    multi =
      Enum.reduce(transition.approve, Multi.new(), fn name, multi ->
        case Artifacts.latest(ticket.id, name) do
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

    multi =
      if transition.approve == [] do
        multi
      else
        Events.log(multi, :decision_event, "approval.#{decision}", {:user, user_id}, %{
          ticket_id: ticket.id,
          payload: Map.put(transition_map, "comment", comment)
        })
      end

    multi =
      case decision do
        :approved ->
          put_transition(multi, ticket, workflow, transition, outcome, {:user, user_id})

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

  # -- entry actions ---------------------------------------------------------------------------

  @doc """
  Runs what entering `state_name` does, after the transition into it has been recorded.

  `merge` is the only action in v1. It was checked before the transition was taken, so a failure
  here is a race — something else moved the default branch in between — and the ticket is stuck
  with the reason rather than left claiming to be merged. `Forge.Merge.perform/2` is idempotent,
  so retrying is always safe.
  """
  @spec enter(Ticket.t(), Workflow.t(), String.t(), String.t() | nil) :: Ticket.t()
  def enter(%Ticket{} = ticket, %Workflow{} = workflow, state_name, user_id) do
    if Workflow.merges_on_enter?(workflow, state_name) do
      merge_now(ticket, user_id)
    else
      ticket
    end
  end

  defp run_entry_actions(ticket, workflow, %Transition{to: to}, :approved, user_id),
    do: enter(ticket, workflow, to, user_id)

  defp run_entry_actions(ticket, _workflow, _transition, _decision, _user_id), do: ticket

  defp merge_now(ticket, user_id) do
    user = user_id && Repo.get(Forge.Accounts.User, user_id)

    case Merge.perform(ticket, user) do
      {:ok, %{sha: sha, already: already}} ->
        Events.append("ticket.merged", actor(user_id), %{
          ticket_id: ticket.id,
          payload: %{"sha" => sha, "already" => already}
        })

        ticket

      other ->
        stick_after_merge(ticket, other)
    end
  end

  defp stick_after_merge(ticket, outcome) do
    reason =
      case outcome do
        {:conflict, paths} -> "merge conflict in #{Enum.join(paths, ", ")}"
        {:error, reason} -> "could not merge: #{inspect(reason)}"
      end

    case stick(ticket, reason) do
      {:ok, stuck} -> stuck
      {:error, _reason} -> ticket
    end
  end

  defp actor(nil), do: :system
  defp actor(user_id), do: {:user, user_id}
end
