defmodule ForgeCore.Workflow.State do
  @moduledoc """
  One state of a workflow. A job state has a `prompt` and runs one job per entry; a human
  state has none and waits for a transition taken by a person or the engine.
  """

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.Budget

  @enforce_keys [:name]
  defstruct [:name, :prompt, :env, :budget, :outcomes, inputs: [], produces: []]

  @type t :: %__MODULE__{
          name: String.t(),
          prompt: String.t() | nil,
          env: String.t() | nil,
          budget: Budget.t() | nil,
          inputs: [String.t()],
          produces: [String.t()],
          outcomes: [String.t()] | nil
        }

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
