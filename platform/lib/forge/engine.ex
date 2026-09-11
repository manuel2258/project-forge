defmodule Forge.Engine do
  @moduledoc """
  Applies `ForgeCore.Engine` decisions to tickets: transitions, approvals and stuck states,
  each with its event, and the next job when the target is a job state.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Jobs, Repo, Tickets}
  alias Forge.Events.Event
  alias Forge.Jobs.Job
  alias Forge.Tickets.Ticket
  alias ForgeCore.Engine, as: Core
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  @doc "Adds what follows a finished job to `multi`: a transition, a pending approval, or stuck."
  @spec put_after_job(Multi.t(), Ticket.t(), Job.t(), String.t()) :: Multi.t()
  def put_after_job(multi, %Ticket{} = ticket, %Job{} = job, outcome) do
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

  defp put_stuck(multi, ticket, reason) do
    multi
    |> Tickets.put_progress(:ticket, ticket, %{
      state: ticket.state,
      status: :stuck,
      cost_usd: ticket.cost_usd
    })
    |> Events.log(:stuck_event, "ticket.stuck", :system, %{
      ticket_id: ticket.id,
      payload: %{"reason" => reason}
    })
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
  leaves the ticket where it is.
  """
  @spec decide(Ticket.t(), String.t(), :approved | :rejected, String.t() | nil) ::
          {:ok, Ticket.t()} | {:error, term()}
  def decide(%Ticket{pending_transition: nil}, _user_id, _decision, _comment),
    do: {:error, :nothing_pending}

  def decide(%Ticket{pending_transition: pending} = ticket, user_id, decision, comment) do
    workflow = Tickets.workflow(ticket)
    {:ok, transition} = Core.choose(workflow, pending["from"], pending["to"])
    transition_map = %{"from" => pending["from"], "to" => pending["to"]}

    multi =
      Enum.reduce(pending["approve"], Multi.new(), fn name, multi ->
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
      |> Events.log(:decision_event, "approval.#{decision}", {:user, user_id}, %{
        ticket_id: ticket.id,
        payload: Map.put(transition_map, "comment", comment)
      })

    multi =
      case decision do
        :approved ->
          put_transition(
            multi,
            ticket,
            workflow,
            transition,
            pending["outcome"],
            {:user, user_id}
          )

        :rejected ->
          multi
      end

    multi
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, Map.get(changes, :ticket, ticket)}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "A person takes any declared transition out of the current state; unsticks the ticket."
  @spec choose(Ticket.t(), String.t(), String.t()) :: {:ok, Ticket.t()} | {:error, term()}
  def choose(%Ticket{} = ticket, user_id, to) do
    workflow = Tickets.workflow(ticket)

    with {:ok, transition} <- Core.choose(workflow, ticket.state, to) do
      Multi.new()
      |> put_transition(ticket, workflow, transition, nil, {:user, user_id})
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} -> {:ok, ticket}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end
end
