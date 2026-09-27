defmodule ForgeCore.Engine do
  @moduledoc """
  The statechart step: pure decisions about what happens to a ticket next.

  Nothing here touches a database or a process. The platform reads the ticket's pinned
  workflow, its current state, the finished job's outcome and how often each transition has
  already fired, calls `step/4`, and persists the answer together with an event.
  """

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  @typedoc "How many times each transition has fired for this ticket, keyed by `Transition.id/1`."
  @type counts :: %{Transition.id() => non_neg_integer()}

  @type decision ::
          {:transition, Transition.t()}
          | {:approval, Transition.t()}
          | {:stuck, {:no_transition, Workflow.outcome()} | {:max_exceeded, Transition.t()}}

  @doc """
  Decides what follows a job in `state` ending with `outcome`.

    * `{:transition, t}` - take `t` now.
    * `{:approval, t}` - `t` matches but needs human approval of the listed artifacts.
    * `{:stuck, reason}` - no transition applies; the operator chooses one with `choose/3`.

  `outcome` is the job's engine outcome, or its declared outcome when it converged; for a command
  state, what its batch's exit statuses map to (`ForgeCore.Workflow.exit_outcome/2`).
  """
  @spec step(Workflow.t(), Workflow.state_name(), Workflow.outcome(), counts()) ::
          decision() | {:error, {:unknown_state, String.t()} | {:human_state, String.t()}}
  def step(%Workflow{} = workflow, state_name, outcome, counts) when is_map(counts) do
    case Workflow.state(workflow, state_name) do
      nil ->
        {:error, {:unknown_state, state_name}}

      %State{} = state ->
        if State.human?(state),
          do: {:error, {:human_state, state_name}},
          else: decide(workflow, state_name, outcome, counts)
    end
  end

  defp decide(workflow, state_name, outcome, counts) do
    match =
      Enum.find(
        Workflow.transitions_from(workflow, state_name),
        &(Transition.outcome(&1) == outcome)
      )

    cond do
      match == nil -> {:stuck, {:no_transition, outcome}}
      exhausted?(match, counts) -> {:stuck, {:max_exceeded, match}}
      Transition.requires_approval?(match) -> {:approval, match}
      true -> {:transition, match}
    end
  end

  @doc """
  A transition picked by a person: from a human state, or to unstick a ticket. Any declared
  transition out of `state` may be chosen; `max` does not bind a human decision. When more
  than one transition leads to `to`, `outcome` picks between them.
  """
  @spec choose(
          Workflow.t(),
          Workflow.state_name(),
          Workflow.state_name(),
          Workflow.outcome() | nil
        ) ::
          {:ok, Transition.t()}
          | {:error, :no_such_transition | {:ambiguous, [Workflow.outcome()]}}
  def choose(%Workflow{} = workflow, state_name, to, outcome \\ nil) do
    candidates =
      workflow
      |> Workflow.transitions_from(state_name)
      |> Enum.filter(&(&1.to == to and (outcome == nil or Transition.outcome(&1) == outcome)))

    case candidates do
      [] -> {:error, :no_such_transition}
      [transition] -> {:ok, transition}
      many -> {:error, {:ambiguous, Enum.map(many, &Transition.outcome/1)}}
    end
  end

  @doc "Whether a ticket that has spent `cost_usd` may still run jobs."
  @spec within_ticket_budget?(Workflow.t(), number()) :: boolean()
  def within_ticket_budget?(%Workflow{limits: %{ticket_cost: cap}}, cost_usd), do: cost_usd < cap

  @doc "Counts after `transition` fires once more."
  @spec record(counts(), Transition.t()) :: counts()
  def record(counts, %Transition{} = transition) do
    Map.update(counts, Transition.id(transition), 1, &(&1 + 1))
  end

  defp exhausted?(%Transition{max: nil}, _counts), do: false

  defp exhausted?(%Transition{max: max} = transition, counts) do
    Map.get(counts, Transition.id(transition), 0) >= max
  end
end
