defmodule ForgeCore.Harness do
  @moduledoc """
  The execution harnesses a workflow may name (`docs/design/codex.md`; `docs/decisions.md`
  § Harnesses). The platform's own registry (`Forge.Harness`) knows how to check a credential for
  each; a test holds the two lists equal, so a harness added to one cannot be forgotten by the
  other.
  """

  @names ~w(claude_code codex)

  @doc "Every harness name a state's `harness` key may take."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "The harness a job runs when neither its state nor its project names one."
  @spec default() :: String.t()
  def default, do: "claude_code"
end
