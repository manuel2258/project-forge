defmodule ForgeCore.Engine do
  @moduledoc """
  The statechart step: pure decisions about what happens to a ticket next.

  Nothing here touches a database or a process. The platform reads the ticket's pinned
  workflow, its current state, the finished job's outcome and how often each transition has
  already fired, calls `step/4`, and persists the answer together with an event.
  """

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{State, Transition}

  # How many times in a row the engine sends a ticket down `on_conflict` by itself
  # (`docs/design/workflow-grammar-v1.md` § Merging).
  @conflict_rounds 3

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
        if State.runs?(state),
          do: decide(workflow, state_name, outcome, counts),
          else: {:error, {:human_state, state_name}}
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

  **With no outcome given and several edges to `to`, the one for the default outcome is taken.**
  A person names a state and not an edge — the operator surface offers each target once
  (`Forge.Engine.offered_transitions/2`) — so without this a target reached by two edges could
  not be moved to at all. The default edge is the right one to mean: it is the state's ordinary
  way out, and a human move records no outcome against the job anyway (`Forge.Engine`'s
  `put_transition/7`), so what the choice settles is the label on the event and which counter is
  bumped. `reviewing → review_ready` is the case that made it necessary: it has a bare edge and a
  `when: budget_exhausted` one, and a stuck review is exactly where a person needs that button.

  **Several edges to `to` and none of them the default is still ambiguous**, because nothing here
  can tell which a person meant: `refining → refining` carries `budget_exhausted` and
  `did_not_converge` and no bare edge. The page, the API and a chat name only a target and ask
  `route/4`, which calls that case a jump. This is for a caller that names an outcome, replays an
  edge it already chose, or wants the declared edge to a target or nothing — the queue's
  `decision_edge/3`, which offers no jump and so reads an ambiguous target as no edge.
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
      many -> default_among(many)
    end
  end

  @doc """
  Where a request to move the ticket from `state_name` to `to` goes, given the edges the ticket
  is *offered* (`Forge.Engine.offered_edges/2` — the caller passes them, so the filter is the one
  the page and a chat's manifest already read).

    * `{:edge, t}` - one offered edge leads to `to`, or several do and one is the bare edge: the
      declared transition, taken exactly as before.
    * `:jump` - no offered edge leads there, or several do and none is the bare edge. The move is a
      jump (`docs/design/workflow-grammar-v1.md` § Jumping): a deliberate move to any state of the
      workflow, taking no transition.
    * `{:error, {:unknown_state, to}}` - `to` is not a state of the workflow at all, which no jump
      can reach either.
  """
  @spec route(Workflow.t(), Workflow.state_name(), Workflow.state_name(), [Transition.t()]) ::
          {:edge, Transition.t()} | :jump | {:error, {:unknown_state, String.t()}}
  def route(%Workflow{} = workflow, state_name, to, offered) when is_list(offered) do
    if Workflow.state(workflow, to) == nil do
      {:error, {:unknown_state, to}}
    else
      candidates = Enum.filter(offered, &(&1.from == state_name and &1.to == to))

      case candidates do
        [] -> :jump
        [transition] -> {:edge, transition}
        many -> many |> default_among() |> routed()
      end
    end
  end

  defp routed({:ok, transition}), do: {:edge, transition}
  defp routed({:error, {:ambiguous, _outcomes}}), do: :jump

  # At most one, always: the validator refuses two transitions from one state on the same outcome,
  # and a bare edge is the one for `default_outcome/0`.
  defp default_among(many) do
    case Enum.find(many, &(&1.when == nil)) do
      %Transition{} = default -> {:ok, default}
      nil -> {:error, {:ambiguous, Enum.map(many, &Transition.outcome/1)}}
    end
  end

  @doc """
  What follows an update step (`docs/design/workflow-grammar-v1.md` § Bringing the branch up to
  date) once the branch is current (`:done`) or the merge conflicted (`:conflict`).

    * `{:transition, t}` - take the step's one edge out. `max` binds it: an edge the engine takes
      on its own has to stop somewhere, as a job's does.
    * `{:conflict, edge}` - take the edge to the step's `on_conflict`, outcome `merge_conflict`.
      No count binds it: the loop it makes is bounded by the `max` on the edges it runs through, by
      a person, or by the ticket's token cap (the validator requires none of them).
    * `{:stuck, reason}` - the edge's `max` is used up, or a conflict has nowhere to go.
  """
  @spec after_update(Workflow.t(), Workflow.state_name(), :done | :conflict, counts()) ::
          {:transition, Transition.t()}
          | {:conflict, Transition.t()}
          | {:stuck, {:max_exceeded, Transition.t()} | :no_conflict_state | :no_edge}
  def after_update(%Workflow{} = workflow, state_name, :done, counts) do
    case Workflow.transitions_from(workflow, state_name) do
      [%Transition{} = edge | _] ->
        if exhausted?(edge, counts),
          do: {:stuck, {:max_exceeded, edge}},
          else: {:transition, edge}

      # Unreachable for a validated workflow, which refuses an update step with no transition out
      # (`ForgeCore.Workflow.Validator`), and a stored pin is not validated again: this is what a
      # pin that dropped the edge would meet (`UpdateStepTest` builds one by hand). It sticks the
      # ticket in words rather than raising inside the record transaction.
      [] ->
        {:stuck, :no_edge}
    end
  end

  def after_update(%Workflow{} = workflow, state_name, :conflict, _counts) do
    case Workflow.conflict_transition(workflow, state_name, state_name) do
      %Transition{} = edge -> {:conflict, edge}
      nil -> {:stuck, :no_conflict_state}
    end
  end

  @doc """
  What a conflict found by the check before a transition from `from` into the merging state
  `merging` does, taken by `by`.

    * `{:route, t}` - take `t`, the edge to `merging`'s `on_conflict`, instead.
    * `:refuse` - `merging` names no `on_conflict`, and the conflict does what it did before the
      key existed.
    * `{:stuck, {:conflict_rounds, n}}` - the engine has already gone round `n` times in a row.

  `rounds` is how many times the engine has taken `on_conflict` by itself since a person last
  moved the ticket. A person is never bounded by it: a person in the loop is what the bound is for.
  """
  @spec conflict(
          Workflow.t(),
          Workflow.state_name(),
          Workflow.state_name(),
          :engine | :person,
          non_neg_integer()
        ) ::
          {:route, Transition.t()} | :refuse | {:stuck, {:conflict_rounds, pos_integer()}}
  def conflict(%Workflow{} = workflow, from, merging, by, rounds) do
    case Workflow.conflict_transition(workflow, from, merging) do
      nil -> :refuse
      %Transition{} = edge when by == :person -> {:route, edge}
      %Transition{} = edge when rounds < @conflict_rounds -> {:route, edge}
      %Transition{} -> {:stuck, {:conflict_rounds, @conflict_rounds}}
    end
  end

  @doc """
  Whether a ticket that has used `usage` weighted tokens may still run jobs **under the workflow's
  own `limits.ticket_tokens`**. The platform does not ask this: a ticket's allowance is the workflow's
  plus what people have raised it by (`Forge.Spend.ticket_cap/2`), which the workflow cannot know.
  What still asks is core's own tests — the one that holds the shipped workflows' loops against
  their caps (`project_workflows_test.exs`) and this function's (`engine_test.exs`) — which are about
  the workflow alone.
  """
  @spec within_ticket_budget?(Workflow.t(), non_neg_integer()) :: boolean()
  def within_ticket_budget?(%Workflow{limits: %{ticket_tokens: cap}}, usage), do: usage < cap

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
