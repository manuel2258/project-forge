defmodule ForgeCore.Workflow.Schedule do
  @moduledoc """
  One entry of a workflow's `schedules:` — a ticket of the file's type that the platform admits on
  a clock once a project admin has switched it on (`docs/design/workflow-grammar-v1.md` §
  Schedules, `docs/design/schedules.md`).

  `cron` is kept as the text the file wrote, and parsed by `ForgeCore.Cron.parse/1` where it is used: the
  struct is what a ticket pins, and a pin must read back from JSON.
  """

  @enforce_keys [:name]
  defstruct [:name, :cron, :title, :body]

  @type t :: %__MODULE__{
          name: String.t(),
          cron: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil
        }

  @doc "The keys an entry may hold, and must."
  @spec keys() :: [String.t()]
  def keys, do: ~w(name cron title body)
end
