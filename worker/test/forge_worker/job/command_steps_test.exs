defmodule ForgeWorker.Job.CommandStepsTest do
  @moduledoc """
  How a command tells its devshell from its script (`ForgeWorker.Job.Command`,
  `docs/design/worker-tier.md` § Looking into a copy): a one-line wrapper innermost in `nix develop`
  writes the time the script began, and a stand-in `nix` on the path takes a measurable time to
  start it.

  Not async: the stand-in is found through `PATH`, which is the node's.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures, only: [tmp_dir: 1, uuid: 0]

  alias ForgeCore.Job.Spec
  alias ForgeWorker.Job.{Command, Steps}

  # Starts a devshell the way `nix develop .#env --command …` does: slowly, then runs the command.
  @slow_nix "#!/bin/sh\nsleep 0.5\nshift 3\nexec \"$@\"\n"

  setup do
    bin = tmp_dir("fake-nix")
    File.write!(Path.join(bin, "nix"), @slow_nix)
    File.chmod!(Path.join(bin, "nix"), 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    %{root: tmp_dir("steps-root"), worktree: tmp_dir("steps-worktree")}
  end

  defp spec(script, env) do
    %Spec{
      job_id: uuid(),
      kind: :command,
      branch: "ticket/7",
      commit: String.duplicate("a", 40),
      env: env,
      command: %{
        "name" => "build",
        "args" => [],
        "script" => script,
        "at" => String.duplicate("b", 40),
        "timeout_ms" => 10_000
      }
    }
  end

  defp run(context, spec, opts) do
    {:ok, steps} = Steps.start_link()

    {:ok, pid} =
      Command.start_link(
        [spec: spec, root: context.root, worktree: context.worktree, steps: steps] ++ opts
      )

    {:ok, _result} = Command.await(pid, 10_000)
    {listed, _total} = Steps.finish(steps)
    Map.new(listed, &{&1["name"], &1})
  end

  test "the devshell is the time before the script began, and the script the time after",
       context do
    steps = run(context, spec("#!/bin/sh\nsleep 0.2\n", "build"), nix_env: true)

    assert %{"devshell" => %{"ms" => devshell}, "script" => %{"ms" => script}} = steps
    assert devshell >= 400, "the stand-in nix takes half a second to start the script"
    assert script >= 150
    assert script < devshell
    refute Map.has_key?(steps["devshell"], "skipped")
  end

  test "a script that rewrites its own marker is not believed, and the devshell is unmeasured",
       context do
    forged = "#!/bin/sh\necho 1 > \"$FORGE_JOB/.forge-script-started\"\n"
    steps = run(context, spec(forged, "build"), nix_env: true)

    assert %{"devshell" => %{"skipped" => "unmeasured"}, "script" => script} = steps
    refute Map.has_key?(steps["devshell"], "ms")
    # From the spawn to the exit: the half second of devshell is in it.
    assert script["ms"] >= 400
  end

  # The job's user owns the marker and the worker reads it as root: a FIFO that nobody writes to must
  # read as unmeasured, not hang the worker.
  test "a marker that is a FIFO is unmeasured and does not stop the command", context do
    script = "#!/bin/sh\nm=\"$FORGE_JOB/.forge-script-started\"\nrm -f \"$m\"\nmkfifo \"$m\"\n"
    steps = run(context, spec(script, "build"), nix_env: true)

    assert %{"devshell" => %{"skipped" => "unmeasured"}, "script" => %{"ms" => _ms}} = steps
  end

  # A link to a file that holds the very time the wrapper wrote would read fine if a link were
  # followed; what is refused is the link (and so also a link to `/dev/zero`, which never ends).
  test "a marker that is a link is unmeasured, even to a file that holds a good time", context do
    script = """
    #!/bin/sh
    m="$FORGE_JOB/.forge-script-started"
    cp "$m" "$m.real"
    rm -f "$m"
    ln -s "$m.real" "$m"
    """

    steps = run(context, spec(script, "build"), nix_env: true)
    assert %{"devshell" => %{"skipped" => "unmeasured"}} = steps
  end

  # Padded with blanks after a good time, so that only the size of the file refuses it: the first
  # bytes read would parse.
  test "a marker bigger than a clock reading is unmeasured, even with a good time first",
       context do
    script = """
    #!/bin/sh
    m="$FORGE_JOB/.forge-script-started"
    cp "$m" "$m.real"
    head -c 4096 /dev/zero | tr '\\0' ' ' >> "$m.real"
    mv "$m.real" "$m"
    """

    steps = run(context, spec(script, "build"), nix_env: true)
    assert %{"devshell" => %{"skipped" => "unmeasured"}} = steps
  end

  test "without an environment there is no devshell, and the script is the whole run", context do
    steps = run(context, spec("#!/bin/sh\nsleep 0.1\n", nil), nix_env: true)

    assert %{"devshell" => %{"skipped" => "no_env"}, "script" => %{"ms" => ms}} = steps
    assert ms >= 80
    assert ms < 400
  end

  test "a command that is not timed runs as before", context do
    {:ok, pid} =
      Command.start_link(
        spec: spec("#!/bin/sh\necho fine\n", "build"),
        root: context.root,
        worktree: context.worktree,
        nix_env: true
      )

    assert {:ok, %{exit_status: 0}} = Command.await(pid, 10_000)
  end
end
