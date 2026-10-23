defmodule MixCacheTest do
  @moduledoc """
  `bin/lib/mix-cache.sh`: where every script in this repository that runs `mix` keeps Mix's
  caches, and what each of its two halves does when they are warm and when they are cold.

  The saving the whole thing exists for is a *skip* — a job that finds a warm cache does not
  reinstall Hex or refetch the registry — so that is what these assert, and they assert it by
  what `mix` was asked rather than by how long it took. `mix` here is a stub on `PATH` that
  records every invocation and answers `hex.info` out of whatever `MIX_HOME` points at, so a run
  touches no network, no real Hex and never an operator's `~/.mix`.

  Not under `ForgeCore.`: the subject is not core's code but the repository's own shell, and
  `core`'s suite is where the other test of a repository script already lives
  (`ForgeCore.WorkerProtocolTest` § one source).
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @lib Path.join(@root, "bin/lib/mix-cache.sh")

  # The two things the library asks `mix`, and nothing else. `hex.info` answers from the archive
  # in MIX_HOME, which is what makes "warm" and "cold" a property of the directory under test;
  # `/nowhere` stands in when nothing points it anywhere, so an unexported MIX_HOME reads as cold.
  @stub """
  #!/usr/bin/env bash
  printf '%s\\n' "$*" >> "$STUB_LOG"
  case "$1" in
    hex.info) test -e "${MIX_HOME:-/nowhere}/archives/hex.ez" ;;
    local.hex) mkdir -p "$MIX_HOME/archives" && : > "$MIX_HOME/archives/hex.ez" ;;
    *) : ;;
  esac
  """

  # `"$PWD"` and not a path the test knows, because that is how both scripts call it: they `cd` to
  # the repository root first and the root is what the caches hang off.
  @ensure """
  . "$LIB"
  forge_mix_cache_ensure "$PWD"
  printf 'MIX_HOME=%s\\nHEX_HOME=%s\\n' "${MIX_HOME-unset}" "${HEX_HOME-unset}"
  """

  # The borrowing half ends with the question its caller will ask of whatever it exported: can
  # `mix` find Hex? That is the thing `bin/e2e-chat` dies of when the answer is no.
  @borrow """
  . "$LIB"
  forge_mix_cache_borrow "$PWD"
  printf 'MIX_HOME=%s\\nHEX_HOME=%s\\n' "${MIX_HOME-unset}" "${HEX_HOME-unset}"
  if mix hex.info > /dev/null 2>&1; then echo ready=yes; else echo ready=no; fi
  """

  setup do
    base = Path.join(System.tmp_dir!(), "mix-cache-#{System.unique_integer([:positive])}")
    checkout = Path.join(base, "checkout")
    bin = Path.join(base, "bin")
    File.mkdir_p!(checkout)
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "mix"), @stub)
    File.chmod!(Path.join(bin, "mix"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    %{base: base, checkout: checkout, bin: bin, log: Path.join(base, "asked")}
  end

  describe "the gate's half, which owns the caches" do
    test "cold, it points Mix into the checkout and installs Hex there", context do
      run = run(context, @ensure)

      assert run.status == 0, run.out
      assert run.out =~ "MIX_HOME=#{context.checkout}/.mix-home"
      assert run.out =~ "HEX_HOME=#{context.checkout}/.hex-home"
      assert run.out =~ "==> hex"
      assert run.asked == ["hex.info", "local.hex --force", "local.rebar --force"]
      assert File.exists?(Path.join(context.checkout, ".mix-home/archives/hex.ez"))
    end

    # The saving itself, and the one assertion in this file that fails if the caches stop being
    # pointed into the checkout at all: the stub answers `hex.info` out of MIX_HOME, so a run that
    # does not export it reads the warm checkout as cold and installs again.
    test "warm, it installs nothing: asking is all a second job pays", context do
      warm(context)

      run = run(context, @ensure)

      assert run.status == 0, run.out
      assert run.out =~ "MIX_HOME=#{context.checkout}/.mix-home"
      assert run.out =~ "HEX_HOME=#{context.checkout}/.hex-home"
      assert run.asked == ["hex.info"]
      refute run.out =~ "==> hex"
    end
  end

  describe "the borrowing half, which creates nothing" do
    test "it takes the checkout's caches when Hex answers out of them", context do
      warm(context)

      run = run(context, @borrow)

      assert run.status == 0, run.out
      assert run.out =~ "MIX_HOME=#{context.checkout}/.mix-home"
      assert run.out =~ "HEX_HOME=#{context.checkout}/.hex-home"
      assert run.out =~ "ready=yes"
      assert run.asked == ["hex.info", "hex.info"]
    end

    # The guard asks Hex, not the filesystem. A `.mix-home/` that exists and holds no archive is a
    # bare `mkdir` away, or a gate run interrupted after Mix made the directory: a guard that
    # tested for the directory would export it here and take this operator from a warm `~/.mix`
    # to no Hex at all, which is the failure the conditional exists to prevent.
    test "an empty cache in the checkout leaves the operator's own Hex alone", context do
      File.mkdir_p!(Path.join(context.checkout, ".mix-home"))
      operator = Path.join(context.base, "operator-mix")
      File.mkdir_p!(Path.join(operator, "archives"))
      File.write!(Path.join(operator, "archives/hex.ez"), "")

      run = run(context, @borrow, %{"MIX_HOME" => operator})

      assert run.status == 0, run.out
      assert run.out =~ "MIX_HOME=#{operator}"
      assert run.out =~ "ready=yes"
      refute run.out =~ context.checkout <> "/.mix-home"
    end

    test "it never installs Hex, and makes no cache the gate has not made", context do
      run = run(context, @borrow)

      assert run.status == 0, run.out
      assert run.out =~ "ready=no"
      assert run.asked == ["hex.info", "hex.info"]
      refute File.exists?(Path.join(context.checkout, ".mix-home"))
      refute File.exists?(Path.join(context.checkout, ".hex-home"))
    end
  end

  # The library is the only place either path is written, which is what keeps the two scripts from
  # disagreeing — and what makes the tests above cover them rather than a file nothing calls.
  # Same shape as `ForgeCore.WorkerProtocolTest` § one source, and the same mutation: a script
  # that stops sourcing this and exports a path of its own.
  describe "one source" do
    test "the gate installs through the library and writes no path of its own" do
      script = File.read!(Path.join(@root, "bin/check"))

      assert script =~ ". bin/lib/mix-cache.sh"
      assert script =~ ~s(forge_mix_cache_ensure "$PWD")
      refute script =~ "MIX_HOME="
      refute script =~ "local.hex"
    end

    test "the end-to-end check borrows through it, and so cannot create a cache" do
      script = File.read!(Path.join(@root, "bin/e2e-chat"))

      assert script =~ ". bin/lib/mix-cache.sh"
      assert script =~ ~s(forge_mix_cache_borrow "$PWD")
      refute script =~ "MIX_HOME="
      refute script =~ "forge_mix_cache_ensure"
    end
  end

  # What a job on a machine the gate has already run on finds: Hex installed in the checkout's
  # own MIX_HOME, carried there by the ticket's volume
  # (`ForgeWorker.Job.WorkspaceTest` § ticket volumes).
  defp warm(context) do
    File.mkdir_p!(Path.join(context.checkout, ".mix-home/archives"))
    File.write!(Path.join(context.checkout, ".mix-home/archives/hex.ez"), "")
    File.mkdir_p!(Path.join(context.checkout, ".hex-home"))
  end

  defp run(context, script, env \\ %{}) do
    base = %{
      "PATH" => context.bin <> ":" <> System.get_env("PATH"),
      "LIB" => @lib,
      "STUB_LOG" => context.log,
      "MIX_HOME" => nil,
      "HEX_HOME" => nil
    }

    {out, status} =
      System.cmd("bash", ["-euo", "pipefail", "-c", script],
        cd: context.checkout,
        env: Map.to_list(Map.merge(base, env)),
        stderr_to_stdout: true
      )

    %{out: out, status: status, asked: asked(context)}
  end

  defp asked(context) do
    case File.read(context.log) do
      {:ok, log} -> log |> String.split("\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
