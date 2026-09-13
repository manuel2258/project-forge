defmodule ForgeCore.Workflow do
  @moduledoc """
  A parsed and validated workflow definition, grammar v1.

  See `docs/design/workflow-grammar-v1.md`. Build one with `ForgeCore.Workflow.Parser`;
  this module only holds the data and answers questions about it.
  """

  alias ForgeCore.Workflow.{Limits, State, Transition}

  @engine_outcomes ~w(did_not_converge budget_exhausted error cancelled)
  @default_outcome "done"
  @ticket "ticket"
  @changeset "changeset"
  @answers "answers.md"

  @enforce_keys [:initial, :states, :transitions, :limits]
  defstruct version: 1, initial: nil, states: %{}, transitions: [], limits: nil

  @type state_name :: String.t()
  @type artifact_name :: String.t()
  @type outcome :: String.t()

  @type t :: %__MODULE__{
          version: 1,
          initial: state_name(),
          states: %{state_name() => State.t()},
          transitions: [Transition.t()],
          limits: Limits.t()
        }

  @doc "Outcomes every job may end with, whatever its state declares."
  @spec engine_outcomes() :: [outcome()]
  def engine_outcomes, do: @engine_outcomes

  @doc "The outcome a transition matches when it names none."
  @spec default_outcome() :: outcome()
  def default_outcome, do: @default_outcome

  @doc "Reserved input name for the ticket body."
  def ticket_artifact, do: @ticket

  @doc "Reserved artifact name for the diff of the job's branch."
  def changeset_artifact, do: @changeset

  @doc "Platform-managed document holding answers; never declared in a workflow."
  def answers_artifact, do: @answers

  @doc "Whether an artifact name denotes a document rather than the changeset."
  @spec document?(artifact_name()) :: boolean()
  def document?(name), do: name != @changeset

  @spec state(t(), state_name()) :: State.t() | nil
  def state(%__MODULE__{states: states}, name), do: Map.get(states, name)

  @spec transitions_from(t(), state_name()) :: [Transition.t()]
  def transitions_from(%__MODULE__{transitions: transitions}, name) do
    Enum.filter(transitions, &(&1.from == name))
  end

  @spec terminal?(t(), state_name()) :: boolean()
  def terminal?(workflow, name), do: transitions_from(workflow, name) == []

  @doc "Whether entering `name` merges the ticket's approved changeset. See `State`."
  @spec merges_on_enter?(t(), state_name()) :: boolean()
  def merges_on_enter?(workflow, name) do
    case state(workflow, name) do
      nil -> false
      state -> State.merges?(state)
    end
  end

  @doc "Names of the states that produce `artifact`, sorted."
  @spec producers(t(), artifact_name()) :: [state_name()]
  def producers(%__MODULE__{states: states}, artifact) do
    names = for {name, %State{produces: produces}} <- states, artifact in produces, do: name
    Enum.sort(names)
  end

  @doc "Outcomes a job in `state_name` may end with: engine outcomes plus declared ones."
  @spec outcomes(t(), state_name()) :: [outcome()]
  def outcomes(%__MODULE__{} = workflow, state_name) do
    case state(workflow, state_name) do
      %State{prompt: nil} -> @engine_outcomes
      %State{outcomes: nil} -> @engine_outcomes ++ [@default_outcome]
      %State{outcomes: declared} -> @engine_outcomes ++ declared
      nil -> @engine_outcomes
    end
  end
end
