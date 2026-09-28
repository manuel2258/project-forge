defmodule ForgeWorker.Job.Command do
  @moduledoc """
  Runs one command job: a fixed script, an argument vector, a commit and a timeout
  (`docs/design/commands.md`). No harness, no credential, no prompt — the script's exit status is
  the result, and its combined output is the log.

  The script is the text the spec carries, read by the platform at the ticket's pinned commit, and
  written here into the job directory: the checkout supplies everything else and never the script,
  so an agent that edited `build.sh` on its branch does not change what `build` does.

  It runs the way an agent does (`ForgeWorker.Job.Runner`): inside the job's slice, with a clean
  environment, the argument vector passed to `exec` and never to a shell, in `nix develop` when
  the spec names an environment. Its stdin is `/dev/null` and its stdout and stderr go to one file.

  Options: `:spec` (required), `:root` (required, the job directory's parent), `:worktree`
  (required), `:slice`, `:slice_opts`, `:nix_env` and `:grace_ms`. Its log and the files of its
  groups staged for upload are in the worker's own directory (`ForgeWorker.Job.Dir.worker_dir/1`),
  which the script cannot reach.
  """

  use GenServer, restart: :temporary

  alias ForgeCore.Job.{Result, Spec}
  alias ForgeWorker.Job.{Dir, Exec}
  alias ForgeWorker.Log

  @default_grace_ms :timer.seconds(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Blocks until the command ends, and returns its result. The process exits after replying."
  @spec await(pid(), timeout()) :: {:ok, Result.t()}
  def await(pid, timeout \\ :infinity), do: GenServer.call(pid, :await, timeout)

  @doc "Stops the command. Its result then says it was cancelled."
  @spec cancel(pid()) :: :ok
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @doc """
  Where a command job's combined output is written: the worker's own directory, not the job's.
  The shell that opens it is the worker's, and the link uploads it, so a log in the job directory
  was a name the script could replace with a link to any file the worker can read.
  """
  @spec log_path(String.t()) :: String.t()
  def log_path(job_dir), do: Path.join(Dir.worker_dir(job_dir), "command.log")

  @impl true
  def init(opts) do
    %Spec{kind: :command, job_id: job_id, command: command} = spec = Keyword.fetch!(opts, :spec)

    Dir.check_id!(job_id)
    job_dir = Path.join(Keyword.fetch!(opts, :root), job_id)
    File.rm_rf!(job_dir)
    File.rm_rf!(Dir.worker_dir(job_dir))
    Dir.worker_dir!(job_dir)
    File.mkdir_p!(Path.join(job_dir, "home"))
    File.mkdir_p!(Path.join(job_dir, "out"))
    script = Path.join(job_dir, "command")
    File.write!(script, command["script"])
    File.chmod!(script, 0o755)

    state = %{
      spec: spec,
      job_dir: job_dir,
      worktree: Keyword.fetch!(opts, :worktree),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      started: System.monotonic_time(:millisecond),
      port: nil,
      slice: nil,
      slice_context: nil,
      killed: nil,
      waiters: [],
      result: nil
    }

    {:ok, state, {:continue, {:spawn, opts, script}}}
  end

  @impl true
  def handle_continue({:spawn, opts, script}, %{spec: spec} = state) do
    {executable, args} =
      Exec.nix(script, spec.command["args"] || [], spec.env, Keyword.get(opts, :nix_env, false))

    env =
      Exec.inherited_env() ++
        [
          {"HOME", Path.join(state.job_dir, "home")},
          {"FORGE_JOB", state.job_dir},
          # Where the script writes its groups of files, one directory each
          # (`docs/design/workflow-grammar-v1.md` § Commands).
          {"FORGE_OUT", Path.join(state.job_dir, "out")}
        ]

    slice = Keyword.get(opts, :slice) || ForgeWorker.Slice.impl()

    slice_opts =
      opts
      |> Keyword.get(:slice_opts, %{})
      |> Map.merge(%{
        job_id: spec.job_id,
        worktree: state.worktree,
        job_dir: state.job_dir,
        env: env,
        secret_names: []
      })

    case slice.prepare(slice_opts) do
      {:ok, context} ->
        {executable, args} = slice.wrap(executable, args, context)
        state = %{state | slice: slice, slice_context: context}
        Process.send_after(self(), :timeout, spec.command["timeout_ms"])
        {:noreply, %{state | port: spawn_port(state, executable, args, env)}}

      {:error, reason} ->
        # A command that cannot be confined is not run unconfined: it ends with no status.
        Log.line("slice.failed", :error, "could not make a slice: #{inspect(reason)}",
          job_id: spec.job_id
        )

        {:noreply, conclude(state, nil)}
    end
  end

  # The shell redirects and then `exec`s `env -i` with only the assignments passed as arguments,
  # which keeps it the process group leader a signal reaches everything through. The log is one
  # file for both streams, because a build's error is only legible beside what it printed first.
  defp spawn_port(state, executable, args, env) do
    assignments = Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)

    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      {:args,
       [
         "-c",
         ~s(log="$1"; shift; exec /usr/bin/env -i "$@" </dev/null >"$log" 2>&1),
         "forge-command",
         log_path(state.job_dir)
       ] ++ assignments ++ [executable | args]},
      {:cd, state.worktree}
    ])
  end

  # A script that ran to a status leaves what it wrote, whatever the status: a failing test run's
  # screenshots are what the failure is. One stopped, or whose slice could not be made, is not
  # read.
  defp stage(result, %{spec: spec} = state, :converged),
    do: ForgeWorker.Job.Blobs.stage(result, state.job_dir, Spec.group_outputs(spec))

  defp stage(result, _state, _outcome), do: result

  @impl true
  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:await, _from, %{result: result} = state),
    do: {:stop, :normal, {:ok, result}, state}

  @impl true
  def handle_cast(:cancel, state), do: {:noreply, kill(state, :operator)}

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, result: nil} = state) do
    {:noreply, conclude(state, status)}
  end

  def handle_info(:timeout, %{result: nil} = state), do: {:noreply, kill(state, :wall_clock)}

  def handle_info(:force_kill, %{port: port, result: nil} = state) when is_port(port) do
    Exec.signal(port, "KILL")
    {:noreply, state}
  end

  def handle_info(:release, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp kill(%{killed: nil, port: port} = state, reason) when is_port(port) do
    Exec.signal(port, "TERM")
    Process.send_after(self(), :force_kill, state.grace_ms)
    %{state | killed: reason}
  end

  defp kill(state, _reason), do: state

  # `docs/design/commands.md` § An invocation is a job: `converged` whenever the script ran to a
  # status, whatever the status; `cancelled` when stopped; `error`, with no status, when it
  # outlived its timeout or its slice could not be made — a script that will not start still
  # exits, 127 from `env`, and that is a status like any other. A killed command's status is the
  # signal's, and reporting it would read as the script's own answer.
  defp conclude(state, status) do
    if state.slice, do: state.slice.cleanup(state.slice_context)

    {outcome, exit_status, reason} =
      case {state.killed, status} do
        {:operator, _status} -> {:cancelled, nil, "cancelled"}
        {:wall_clock, _status} -> {:error, nil, "outlived its timeout"}
        {nil, nil} -> {:error, nil, "could not be confined"}
        {nil, status} -> {:converged, status, nil}
      end

    result =
      %Result{
        status: :finished,
        outcome: outcome,
        exit_status: exit_status,
        killed: state.killed,
        reason: reason,
        duration_ms: System.monotonic_time(:millisecond) - state.started
      }
      |> stage(state, outcome)

    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))

    # A caller that has not asked yet is about to — the link awaits straight after starting — so
    # the result is held briefly for it, as `Runner` holds one.
    if state.waiters == [], do: Process.send_after(self(), :release, :timer.seconds(5))
    if state.waiters != [], do: send(self(), :release)

    %{state | result: result, waiters: []}
  end
end
