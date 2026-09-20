defmodule ForgeCore.Workflow.Defaults do
  @moduledoc """
  Workflow-wide fallbacks for keys a state may also declare.

  One field so far. It is a struct rather than the bare `Resources` it holds because the YAML
  key is `defaults:` with `resources:` nested under it, and the grammar has room for more:
  reading `workflow.defaults.resources` stays true when a second default arrives, where a
  field called `default_resources` would have to be joined by a sibling.
  """

  alias ForgeCore.Workflow.Resources

  @enforce_keys []
  defstruct [:resources]

  @type t :: %__MODULE__{resources: Resources.t() | nil}
end
