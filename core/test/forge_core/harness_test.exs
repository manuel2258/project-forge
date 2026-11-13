defmodule ForgeCore.HarnessTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Harness

  test "the harnesses a workflow may name, and the one a job runs when nothing says" do
    assert Harness.names() == ["claude_code", "codex"]
    assert Harness.default() == "claude_code"
    assert Harness.default() in Harness.names()
  end
end
