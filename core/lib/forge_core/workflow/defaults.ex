defmodule ForgeCore.Workflow.Defaults do
  @moduledoc """
  Workflow-wide fallbacks for keys a state may also declare: `resources`, and `timeout` for an
  agent state's runs.

  It is a struct rather than a bare `Resources` because the YAML key is `defaults:` with `resources:`
  nested under it, and the grammar has room for more: reading `workflow.defaults.resources` stays
  true when another default arrives, where a field called `default_resources` would have to be
  joined by a sibling.
  """

  alias ForgeCore.Workflow.Resources

  @enforce_keys []
  defstruct [:resources, :timeout_ms]

  @type t :: %__MODULE__{resources: Resources.t() | nil, timeout_ms: pos_integer() | nil}
end
