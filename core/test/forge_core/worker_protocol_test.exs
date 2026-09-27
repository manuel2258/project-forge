defmodule ForgeCore.WorkerProtocolTest do
  @moduledoc """
  The protocol number and the range the platform accepts. `docs/design/worker-channel.md`
  § Versions.

  The number itself is never written in these tests: it lives in `core/priv/worker_protocol`
  and nowhere else, and a test that said `1` would be the second place.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.WorkerProtocol

  @root Path.expand("../../..", __DIR__)
  @file_path Path.join(@root, "core/priv/worker_protocol")

  test "the number is the file's" do
    assert WorkerProtocol.current() ==
             @file_path |> File.read!() |> String.trim() |> String.to_integer()
  end

  describe "what the platform accepts" do
    test "a worker that sends none is protocol 0, which is accepted" do
      assert WorkerProtocol.minimum() == 0
      assert WorkerProtocol.compatible?(0)
    end

    test "every protocol from the minimum to the current one" do
      for protocol <- WorkerProtocol.minimum()..WorkerProtocol.current() do
        assert WorkerProtocol.compatible?(protocol), inspect(protocol)
      end
    end

    # A platform cannot know what a protocol from after it expects, so a newer worker is refused
    # as surely as an older one.
    test "nothing newer than the current one, and nothing older than the minimum" do
      refute WorkerProtocol.compatible?(WorkerProtocol.current() + 1)
      refute WorkerProtocol.compatible?(WorkerProtocol.minimum() - 1)
    end

    test "nothing that is not a number" do
      refute WorkerProtocol.compatible?(nil)
      refute WorkerProtocol.compatible?(to_string(WorkerProtocol.current()))
      refute WorkerProtocol.compatible?(WorkerProtocol.current() * 1.0)
    end

    test "what can be written down is a whole number a Postgres integer holds" do
      assert WorkerProtocol.recordable?(0)
      assert WorkerProtocol.recordable?(2_147_483_647)
      refute WorkerProtocol.recordable?(2_147_483_648)
      refute WorkerProtocol.recordable?(-1)
      refute WorkerProtocol.recordable?(1.0)
      refute WorkerProtocol.recordable?("1")
    end

    test "the range, as the product says it" do
      assert WorkerProtocol.range() == "#{WorkerProtocol.minimum()}–#{WorkerProtocol.current()}"
    end
  end

  # The drift check the note promises. Both ends read one file, so they cannot disagree — unless
  # one of them stops reading it and writes the number down instead, which is the mutation these
  # two refuse.
  describe "one source" do
    test "flake.nix reads the file rather than stating the number" do
      flake = File.read!(Path.join(@root, "flake.nix"))

      assert flake =~ ~r/builtins\.readFile \.\/core\/priv\/worker_protocol/
      refute flake =~ ~r/protocol\s*=\s*"?\d+"?\s*;/i
    end

    test "bin/hetzner-image labels a snapshot from the flake, not from a number of its own" do
      script = File.read!(Path.join(@root, "bin/hetzner-image"))

      assert script =~ "forge-worker-protocol="
      refute script =~ ~r/forge-worker-protocol=\d/
      refute script =~ ~r/protocol=["']?\d/
    end
  end
end
