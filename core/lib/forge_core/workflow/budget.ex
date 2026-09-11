defmodule ForgeCore.Workflow.Budget do
  @moduledoc "Per-job limits: agentic turns and cost in USD. Copied into every job spec."

  @enforce_keys [:turns, :cost]
  defstruct [:turns, :cost]

  @type t :: %__MODULE__{turns: pos_integer(), cost: number()}
end
