defmodule ForgeWorker.Job.CommandTest.WrapReportingSlice do
  @moduledoc "Reports the command it was asked to confine, and runs it unchanged."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts), do: {:ok, opts}

  @impl ForgeWorker.Slice
  def wrap(executable, args, context) do
    send(context.reply_to, {:wrapped, executable, args})
    {"/bin/sh", ["-c", "exit 0"]}
  end

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.CommandTest.RefusingSlice do
  @moduledoc "A slice that cannot be made."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(_opts), do: {:error, :no_such_user}

  @impl ForgeWorker.Slice
  def wrap(executable, args, _context), do: {executable, args}

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.CommandTest.PrepareReportingSlice do
  @moduledoc "Reports what it was asked to prepare — the environment and the secrets' names — and runs it as `Direct` would."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts) do
    send(opts.reply_to, {:prepared, opts})
    ForgeWorker.Slice.Direct.prepare(opts)
  end

  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate cleanup(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.CommandTest do
  @moduledoc """
  One command job on the worker (`docs/design/commands.md`): the spec's script, the argument
  vector as a vector, the log, the status, and the three ways a command ends without one.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures, only: [sealed_secrets: 2, tmp_dir: 1, uuid: 0]

  alias ForgeCore.Job.{Result, Spec}
  alias ForgeWorker.Job.Command
  alias ForgeWorker.Job.CommandTest.{PrepareReportingSlice, RefusingSlice, WrapReportingSlice}

  setup do
    %{root: tmp_dir("command-root"), worktree: tmp_dir("command-worktree")}
  end

  defp spec(script, overrides \\ %{}) do
    %Spec{
      job_id: uuid(),
      kind: :command,
      branch: "ticket/7",
      commit: String.duplicate("a", 40),
      env: Map.get(overrides, :env),
      command: %{
        "name" => "build",
        "args" => Map.get(overrides, :args, []),
        "script" => script,
        "at" => String.duplicate("b", 40),
        "timeout_ms" => Map.get(overrides, :timeout_ms, 10_000)
      }
    }
  end

  defp run(context, spec, opts \\ []) do
    {:ok, pid} =
      Command.start_link(
        [spec: spec, root: context.root, worktree: context.worktree, grace_ms: 100] ++ opts
      )

    {:ok, result} = Command.await(pid, 10_000)
    {result, Path.join(context.root, spec.job_id)}
  end

  defp log(job_dir), do: File.read!(Command.log_path(job_dir))

  # Dead or a zombie: an orphan is reparented to whatever PID 1 is, which in a container may never
  # reap it, and `kill -0` answers for a zombie too.
  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> not (stat |> String.split(") ") |> List.last() |> String.starts_with?("Z"))
      {:error, _gone} -> false
    end
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end

  # `docs/design/workflow-grammar-v1.md` § Commands: what a script can rely on to find things.
  # The script is the pinned copy in the job directory, not the checkout's, so the checkout has
  # to be named for a script that has moved away from where it started.
  test "names the checkout, the job directory and the output directory to the script", context do
    File.write!(Path.join(context.worktree, "marker"), "in the checkout\n")

    script = """
    #!/bin/sh
    case "$0" in "$FORGE_JOB"/*) echo "script in the job directory" ;; esac
    [ "$FORGE_OUT" = "$FORGE_JOB/out" ] && echo "out under the job directory"
    cd /
    cat "$FORGE_CHECKOUT/marker"
    """

    {result, job_dir} = run(context, spec(script))

    assert %Result{outcome: :converged, exit_status: 0} = result

    assert log(job_dir) ==
             "script in the job directory\nout under the job directory\nin the checkout\n"
  end

  # A command's project secrets reach the script's environment through the file its process loads —
  # never the argument list its other variables go in, nor anything the slice is told, which a unit
  # shows every user on the machine (`docs/design/secrets.md` § Delivery).
  test "a secret reaches the script's environment and the slice learns nothing of it", context do
    spec = spec(~s(#!/bin/sh\n[ "$CARGO_REGISTRY_TOKEN" = "cio_the-value" ] && echo "holds it"\n))
    secrets = sealed_secrets(%{"CARGO_REGISTRY_TOKEN" => "cio_the-value"}, spec.job_id)

    {result, job_dir} =
      run(context, spec,
        secrets: secrets,
        slice: PrepareReportingSlice,
        slice_opts: %{reply_to: self()}
      )

    assert %Result{outcome: :converged, exit_status: 0} = result
    assert log(job_dir) == "holds it\n"

    assert_receive {:prepared, prepared}
    assert Path.dirname(prepared.secrets_file) == job_dir <> ".worker"
    refute inspect(prepared, limit: :infinity, printable_limit: :infinity) =~ "cio_the-value"
    refute File.exists?(prepared.secrets_file)
  end

  # `systemd-run` reports a script killed by a signal as 255, which says nothing; the unit's last
  # reading says it was SIGKILL and counted an OOM kill, and the reason says so in words. It ran to a
  # status, so it stays `converged` (`docs/design/commands.md` § What the row holds).
  test "a script killed at its ceiling says so, and still ran to a status", context do
    {:ok, readings} = Agent.start_link(fn -> [nil] end)

    ending = %{
      exit: %{code: "killed", status: "KILL", result: "signal"},
      memory: %{peak: 1_073_741_824, oom_kills: 1}
    }

    opts = [
      slice: ForgeWorker.ScriptedSlice,
      slice_opts: %{memory_max: 1_073_741_824, readings: readings, ending: ending}
    ]

    {result, _job_dir} = run(context, spec("#!/bin/sh\nexit 255\n"), opts)

    assert %Result{outcome: :converged, exit_status: 255} = result
    assert result.reason == "the script was killed at its 1 GiB memory ceiling"

    # And a status of its own is only a status: with no kill counted, or with a kill of some other
    # process in its tree while the script itself exited.
    for ending <- [
          %{ending | memory: %{peak: 1, oom_kills: 0}},
          %{ending | exit: %{code: "exited", status: "255", result: "exit-code"}}
        ] do
      opts = put_in(opts, [:slice_opts, :ending], ending)
      {result, _job_dir} = run(context, spec("#!/bin/sh\nexit 255\n"), opts)
      assert result.reason == nil, inspect(ending)
    end
  end

  # A command whose `systemd-run` could not reach PID 1 never ran: the machine's health hears of it
  # before the result, which the link then withholds.
  test "a command whose slice supervisor did not answer makes the machine unhealthy", context do
    name = :"health-#{System.unique_integer([:positive])}"
    {:ok, _pid} = ForgeWorker.Health.start_link(name: name, link: self(), probe_ms: nil)
    {:ok, readings} = Agent.start_link(fn -> [nil] end)
    reason = "systemd-run could not reach PID 1: Failed to connect to bus: Connection timed out"

    opts = [
      slice: ForgeWorker.ScriptedSlice,
      slice_opts: %{readings: readings, ending: %{unreachable: reason}},
      health: name
    ]

    {_result, _job_dir} = run(context, spec("#!/bin/sh\nexit 1\n"), opts)

    assert_received {:unhealthy, ^reason}
    assert ForgeWorker.Health.unhealthy(name) == reason
  end

  # A build that sizes its own parallelism by what it may use needs to be told it.
  test "tells the script its memory ceiling", context do
    script = "#!/bin/sh\necho \"ceiling ${FORGE_MEMORY_MAX-none}\"\n"

    {_result, job_dir} = run(context, spec(script), slice_opts: %{memory_max: 1_073_741_824})
    assert log(job_dir) == "ceiling 1073741824\n"

    {_result, job_dir} = run(context, spec(script))
    assert log(job_dir) == "ceiling none\n"
  end

  test "runs the spec's script in the worktree, with each argument as one argument", context do
    File.write!(Path.join(context.worktree, "marker"), "in the worktree\n")

    script = """
    #!/bin/sh
    for arg in "$@"; do printf '[%s]\\n' "$arg"; done
    cat marker
    echo to stderr >&2
    exit 3
    """

    {result, job_dir} = run(context, spec(script, %{args: ["--filter", "foo bar", "$HOME;id"]}))

    assert %Result{status: :finished, outcome: :converged, exit_status: 3, killed: nil} = result
    assert is_integer(result.duration_ms)

    # No word splitting and no expansion: `foo bar` is one argument and `$HOME;id` is text.
    assert log(job_dir) ==
             "[--filter]\n[foo bar]\n[$HOME;id]\nin the worktree\nto stderr\n"
  end

  # The link uploads the log by its path, as the worker: a log in the job directory was a name the
  # script's user owns, and could swap for a link to a file only the worker may read.
  test "writes its log where the script cannot reach, and uploads what it printed", context do
    secret = Path.join(tmp_dir("secret"), "worker.env")
    File.write!(secret, "NOT-THE-LOG")

    script = """
    #!/bin/sh
    echo printed
    rm -f "$FORGE_JOB/command.log"
    ln -s #{secret} "$FORGE_JOB/command.log"
    """

    {result, job_dir} = run(context, spec(script))

    assert %Result{outcome: :converged, exit_status: 0} = result
    assert log(job_dir) == "printed\n"
    refute String.starts_with?(Command.log_path(job_dir), job_dir <> "/")
    assert %File.Stat{mode: mode} = File.stat!(Path.dirname(Command.log_path(job_dir)))
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  # "Read at the pinned base commit": the checkout is the invocation's commit, and an agent that
  # edited the script there has not changed what the command does.
  test "runs the script it was given, never the one on the branch", context do
    File.mkdir_p!(Path.join([context.worktree, ".forge", "commands"]))
    File.write!(Path.join([context.worktree, ".forge", "commands", "build.sh"]), "echo branch\n")

    {result, job_dir} = run(context, spec("#!/bin/sh\necho pinned\n"))

    assert result.exit_status == 0
    assert log(job_dir) == "pinned\n"
  end

  test "sees a clean environment, not the worker's", context do
    System.put_env("FORGE_TEST_WORKER_SECRET", "hunter2")
    on_exit(fn -> System.delete_env("FORGE_TEST_WORKER_SECRET") end)

    {_result, job_dir} =
      run(context, spec("#!/bin/sh\necho \"secret=$FORGE_TEST_WORKER_SECRET home=$HOME\"\n"))

    assert log(job_dir) == "secret= home=#{Path.join(job_dir, "home")}\n"
  end

  test "a command that outlives its timeout ends with no status", context do
    {result, _job_dir} = run(context, spec("#!/bin/sh\nexec sleep 30\n", %{timeout_ms: 200}))

    assert %Result{outcome: :error, exit_status: nil, killed: :wall_clock} = result
    assert result.reason == "outlived its timeout"
  end

  # The signal goes to the process group: what the script started in the background is stopped
  # with it, not left running on the machine.
  test "a timeout stops what the script started, not only the script", context do
    script = """
    #!/bin/sh
    sleep 30 &
    echo $! > bg.pid
    wait
    """

    {result, _job_dir} = run(context, spec(script, %{timeout_ms: 300}))
    assert %Result{outcome: :error, reason: "outlived its timeout"} = result

    pid = context.worktree |> Path.join("bg.pid") |> File.read!() |> String.trim()
    assert eventually(fn -> not alive?(pid) end)
  end

  # And a script that ignores the polite signal is killed after the grace.
  test "a script that ignores TERM is killed once the grace is up", context do
    script = "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 0.05; done\n"

    {result, _job_dir} = run(context, spec(script, %{timeout_ms: 300}))
    assert %Result{outcome: :error, exit_status: nil, reason: "outlived its timeout"} = result
  end

  test "cancel stops it, and it says it was cancelled", context do
    {:ok, pid} =
      Command.start_link(
        spec: spec("#!/bin/sh\nexec sleep 30\n"),
        root: context.root,
        worktree: context.worktree,
        grace_ms: 100
      )

    Command.cancel(pid)

    assert {:ok, %Result{outcome: :cancelled, exit_status: nil, killed: :operator}} =
             Command.await(pid, 5_000)
  end

  test "a command that cannot be confined is not run", context do
    {result, job_dir} = run(context, spec("#!/bin/sh\necho ran\n"), slice: RefusingSlice)

    assert %Result{outcome: :error, exit_status: nil, reason: "could not be confined"} = result
    refute File.exists?(Command.log_path(job_dir))
  end

  test "runs inside the project's environment when the spec names one", context do
    {_result, job_dir} =
      run(context, spec("#!/bin/sh\n", %{env: "build", args: ["--all"]}),
        nix_env: true,
        slice: WrapReportingSlice,
        slice_opts: %{reply_to: self()}
      )

    script = Path.join(job_dir, "command")
    assert_receive {:wrapped, "nix", ["develop", ".#build", "--command", ^script, "--all"]}
  end

  # `produces: [build.log, pkg/*]`: the script writes into `$FORGE_OUT/pkg/`.
  test "stages the groups of files its script wrote, whatever its status", context do
    script =
      "#!/bin/sh\nmkdir -p \"$FORGE_OUT/pkg\"\nprintf built > \"$FORGE_OUT/pkg/app.bin\"\nexit 1\n"

    spec = spec(script)
    spec = %{spec | command: Map.put(spec.command, "outputs", ["pkg/*"])}

    {result, job_dir} = run(context, spec)

    assert %Result{exit_status: 1, blobs: %{"pkg/app.bin" => %{"path" => path}}} = result
    assert File.read!(path) == "built"
    assert Path.dirname(path) == ForgeWorker.Job.Dir.blobs_dir(job_dir)
  end

  test "stages nothing for a command that outlived its timeout", context do
    spec =
      spec(
        ~s(#!/bin/sh\nmkdir -p "$FORGE_OUT/pkg"\ntouch "$FORGE_OUT/pkg/x"\nexec sleep 30\n),
        %{timeout_ms: 300}
      )

    spec = %{spec | command: Map.put(spec.command, "outputs", ["pkg/*"])}

    {result, _job_dir} = run(context, spec)
    assert %Result{outcome: :error, blobs: blobs} = result
    assert blobs == %{}
  end

  test "refuses a job id that is not a UUID", context do
    Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{}, _stack}} =
             Command.start_link(
               spec: %{spec("#!/bin/sh\n") | job_id: "../x"},
               root: context.root,
               worktree: context.worktree
             )
  end
end
