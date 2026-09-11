defmodule ForgeCore.Workflow.Transition do
  @moduledoc "An edge between two states, taken on an outcome, possibly requiring approval."

  alias ForgeCore.Workflow

  @enforce_keys [:from, :to]
  defstruct [:from, :to, :when, :max, approve: []]

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          when: String.t() | nil,
          max: pos_integer() | nil,
          approve: [String.t()]
        }

  @doc "The outcome this transition matches: `when`, or the default when absent."
  @spec outcome(t()) :: String.t()
  def outcome(%__MODULE__{when: nil}), do: Workflow.default_outcome()
  def outcome(%__MODULE__{when: outcome}), do: outcome

  @spec requires_approval?(t()) :: boolean()
  def requires_approval?(%__MODULE__{approve: approve}), do: approve != []
end
