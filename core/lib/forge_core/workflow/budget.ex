defmodule ForgeCore.Workflow.Budget do
  @moduledoc """
  Per-job limits: agentic turns and weighted tokens (`ForgeCore.Usage`). Copied into every job spec.

  `legacy_cost` is the older dollar figure when the workflow said `cost:` rather than `tokens:`;
  `tokens` is then that figure converted. Admission refuses a workflow that has one
  (`ForgeCore.Workflow.legacy_keys/1`); a ticket already admitted keeps running on the conversion.
  """

  @enforce_keys [:turns, :tokens]
  defstruct [:turns, :tokens, :legacy_cost]

  @type t :: %__MODULE__{
          turns: pos_integer(),
          tokens: non_neg_integer(),
          legacy_cost: number() | nil
        }
end
