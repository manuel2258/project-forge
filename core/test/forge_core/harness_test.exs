defmodule ForgeCore.HarnessTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Harness

  test "the harnesses a workflow may name, and the one a job runs when nothing says" do
    assert Harness.names() == ["claude_code", "codex"]
    assert Harness.default() == "claude_code"
    assert Harness.default() in Harness.names()
  end

  test "only Claude Code's runs have a turn ceiling" do
    assert Harness.bounds_turns?("claude_code")
    refute Harness.bounds_turns?("codex")
    refute Harness.bounds_turns?(nil)
  end
end
