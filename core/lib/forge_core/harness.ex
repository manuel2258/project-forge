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

  @doc """
  Whether a run on `harness` has a turn ceiling. Claude Code does (`--max-turns`); a Codex run is
  not bounded by `budget.turns` (`docs/design/codex.md`), so a form that offered to extend turns
  there would promise something that does nothing. Nil — a command, which runs no harness — has
  none.
  """
  @spec bounds_turns?(String.t() | nil) :: boolean()
  def bounds_turns?(harness), do: harness == "claude_code"

  @doc "The harness a job runs when neither its state nor its project names one."
  @spec default() :: String.t()
  def default, do: "claude_code"
end
