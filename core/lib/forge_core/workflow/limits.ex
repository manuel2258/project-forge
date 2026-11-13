defmodule ForgeCore.Workflow.Limits do
  @moduledoc """
  Per-ticket limits. `ticket_tokens` caps the sum of all job usage in weighted tokens.
  `legacy_ticket_cost` is the older dollar key when that is what the workflow said
  (see `ForgeCore.Workflow.Budget`).
  """

  @enforce_keys [:ticket_tokens]
  defstruct [:ticket_tokens, :legacy_ticket_cost]

  @type t :: %__MODULE__{
          ticket_tokens: non_neg_integer(),
          legacy_ticket_cost: number() | nil
        }
end
