defmodule ForgeCore.Workflow.State do
  @moduledoc """
  One state of a workflow. A job state has a `prompt` and runs one job per entry; a human
  state has none and waits for a transition taken by a person or the engine.

  `on_enter` names actions the platform takes when a ticket arrives in the state. `merge` is
  the only one in v1: entering the state merges the ticket's approved changeset into the
  project's default branch.
  """

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.Budget

  @actions [:merge]

  @enforce_keys [:name]
  defstruct [:name, :prompt, :env, :budget, :outcomes, inputs: [], produces: [], on_enter: []]

  @type action :: :merge

  @type t :: %__MODULE__{
          name: String.t(),
          prompt: String.t() | nil,
          env: String.t() | nil,
          budget: Budget.t() | nil,
          inputs: [String.t()],
          produces: [String.t()],
          outcomes: [String.t()] | nil,
          on_enter: [action()]
        }

  @doc "The entry actions v1 knows."
  @spec actions() :: [action()]
  def actions, do: @actions

  @spec merges?(t()) :: boolean()
  def merges?(%__MODULE__{on_enter: on_enter}), do: :merge in on_enter

  @spec job?(t()) :: boolean()
  def job?(%__MODULE__{prompt: prompt}), do: prompt != nil

  @spec human?(t()) :: boolean()
  def human?(state), do: not job?(state)

  @doc "The document whose front matter carries the job's outcome, or nil if none."
  @spec outcome_document(t()) :: String.t() | nil
  def outcome_document(%__MODULE__{produces: produces}) do
    Enum.find(produces, &Workflow.document?/1)
  end
end
