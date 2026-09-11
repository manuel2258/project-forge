defmodule ForgeCore.Workflow.Limits do
  @moduledoc "Per-ticket limits. `ticket_cost` caps the sum of all job costs in USD."

  @enforce_keys [:ticket_cost]
  defstruct [:ticket_cost]

  @type t :: %__MODULE__{ticket_cost: number()}
end
