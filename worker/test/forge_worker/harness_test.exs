defmodule ForgeWorker.HarnessTest do
  @moduledoc """
  What a runner calls a driver through: the stateful callbacks, which fall back to the stateless
  ones for a driver that keeps no conversation of its own (Claude Code), and which driver an
  assignment asks for.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Harness
  alias ForgeWorker.Harness.{ClaudeCode, Codex}

  test "a stateless driver is called through its stateless callbacks, with no state and nothing to write" do
    assert Harness.init(ClaudeCode, []) == {[], nil}

    line = ~s({"type":"system","subtype":"init","session_id":"s"})
    assert {events, [], nil} = Harness.handle_line(ClaudeCode, line, nil)
    assert events == ClaudeCode.parse_line(line)

    assert {bytes, nil} = Harness.send_message(ClaudeCode, "hi", nil)
    assert bytes == ClaudeCode.encode_message("hi")

    assert {bytes, nil} = Harness.interrupt(ClaudeCode, "r1", nil)
    assert bytes == ClaudeCode.encode_interrupt("r1")
  end

  test "a stateful driver is called through its own" do
    assert {first, state} = Harness.init(Codex, [])
    assert IO.iodata_to_binary(first) =~ "initialize"

    assert {[], [_ | _] = reply, _state} =
             Harness.handle_line(Codex, ~s({"id":0,"result":{}}), state)

    assert IO.iodata_to_binary(reply) =~ "thread/start"
  end

  test "the drivers this release can run are named as the platform names them" do
    assert Harness.drivers() == %{"claude_code" => ClaudeCode, "codex" => Codex}
    assert Map.keys(Harness.drivers()) |> Enum.sort() == ForgeCore.Harness.names()
  end

  test "Claude Code's executable, model and effort are not handed to Codex" do
    opts = [
      executable: "/bin/claude",
      model: "opus",
      effort: "high",
      codex_executable: "/bin/codex"
    ]

    assert Harness.machine_opts(opts, ForgeWorker.Harness.Codex) == [
             codex_executable: "/bin/codex"
           ]

    assert Harness.machine_opts(opts, ForgeWorker.Harness.ClaudeCode) == opts
  end

  test "an assignment names its driver, or leaves it to the machine, or names one this release lacks" do
    assert Harness.for_assignment(%{"harness" => "codex"}, ClaudeCode) == Codex
    assert Harness.for_assignment(%{"harness" => "claude_code"}, Codex) == ClaudeCode
    assert Harness.for_assignment(%{"harness" => "opencode"}, ClaudeCode) == nil
    assert Harness.for_assignment(%{"harness" => nil}, ClaudeCode) == ClaudeCode
    assert Harness.for_assignment(%{}, Codex) == Codex
  end
end
