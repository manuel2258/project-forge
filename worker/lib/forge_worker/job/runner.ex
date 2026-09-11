defmodule ForgeWorker.Job.Runner do
  @moduledoc """
  Runs one job: lays out the job directory, composes the prompt, starts the harness process
  in the worktree, streams its output as events to a sink, and on exit collects the outputs
  and decides the outcome. One process per running job; it exits when the job does.

  Options:

    * `:spec` (required) - the `ForgeCore.Job.Spec`.
    * `:root` (required) - directory under which the job directory is created.
    * `:worktree` (required) - the checkout the harness runs in.
    * `:sink` - `fn event -> any` called for every harness event, in order. Default: ignore.
    * `:harness` - driver module. Default `ForgeWorker.Harness.ClaudeCode`.
    * `:harness_opts` - passed to the driver's `command/3`.
    * `:wall_clock_ms` - kill after this long. Default one hour.
    * `:grace_ms` - time between SIGTERM and SIGKILL. Default 10 seconds.
    * `:nix_env` - when true and the spec has an `env`, wrap in `nix develop .#env`.
    * `:extra_env` - additional `{name, value}` pairs for the process environment.
  """

  use GenServer

  alias ForgeCore.Job.{Outcome, Spec}
  alias ForgeCore.Prompt
  alias ForgeWorker.Job.{Dir, Result}

  require Logger

  @default_wall_clock_ms :timer.hours(1)
  @default_grace_ms :timer.seconds(10)
  @max_line 4 * 1024 * 1024

  # -- API ----------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Blocks until the run ends. The runner exits right after replying."
  @spec await(pid(), timeout()) :: {:ok, Result.t()}
  def await(pid, timeout \\ :infinity), do: GenServer.call(pid, :await, timeout)

  @doc "Asks the runner to stop the harness. The result then reports `killed: :operator`."
  @spec cancel(pid()) :: :ok
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  # -- lifecycle ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    spec = Keyword.fetch!(opts, :spec)
    harness = Keyword.get(opts, :harness, ForgeWorker.Harness.ClaudeCode)
    job_dir = Dir.prepare(Keyword.fetch!(opts, :root), spec)
    File.write!(Dir.prompt_path(job_dir), Prompt.compose(spec, job_dir))

    state = %{
      spec: spec,
      job_dir: job_dir,
      harness: harness,
      sink: Keyword.get(opts, :sink, fn _ -> :ok end),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      port: nil,
      buffer: "",
      transcript: File.open!(Dir.transcript_path(job_dir), [:write, :binary]),
      finished_event: nil,
      started_event: nil,
      killed: nil,
      exit_status: nil,
      waiters: [],
      result: nil
    }

    Process.send_after(
      self(),
      :wall_clock,
      Keyword.get(opts, :wall_clock_ms, @default_wall_clock_ms)
    )

    {:ok, state, {:continue, {:spawn, opts}}}
  end

  @impl true
  def handle_continue({:spawn, opts}, %{spec: spec, job_dir: job_dir, harness: harness} = state) do
    {executable, args, env} = harness.command(spec, job_dir, Keyword.get(opts, :harness_opts, []))
    {executable, args} = maybe_nix(executable, args, spec, Keyword.get(opts, :nix_env, false))

    # sh gives us stdin from the prompt file and a separate stderr file; `exec` makes the
    # harness the process we can signal directly.
    wrapper = ~s(exec "$0" "$@" <"$FORGE_JOB_PROMPT" 2>"$FORGE_JOB_STDERR")

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, @max_line},
        {:args, ["-c", wrapper, executable | args]},
        {:cd, Keyword.fetch!(opts, :worktree)},
        {:env, port_env(env ++ Keyword.get(opts, :extra_env, []), job_dir)}
      ])

    {:noreply, %{state | port: port}}
  end

  defp maybe_nix(executable, args, %Spec{env: env}, true) when is_binary(env) do
    {"nix", ["develop", ".##{env}", "--command", executable | args]}
  end

  defp maybe_nix(executable, args, _spec, _nix), do: {executable, args}

  defp port_env(env, job_dir) do
    extra = [
      {"FORGE_JOB_PROMPT", Dir.prompt_path(job_dir)},
      {"FORGE_JOB_STDERR", Dir.stderr_path(job_dir)}
    ]

    Enum.map(env ++ extra, fn
      {key, false} -> {String.to_charlist(key), false}
      {key, value} -> {String.to_charlist(key), String.to_charlist(value)}
    end)
  end

  # -- calls --------------------------------------------------------------------------------

  @impl true
  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call(:await, _from, %{result: result} = state), do: {:reply, {:ok, result}, state}

  @impl true
  def handle_cast(:cancel, state), do: {:noreply, kill(state, :operator)}

  # -- port output --------------------------------------------------------------------------

  @impl true
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = state.buffer <> chunk
    IO.binwrite(state.transcript, [line, "\n"])
    {:noreply, Enum.reduce(state.harness.parse_line(line), %{state | buffer: ""}, &emit/2)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    File.close(state.transcript)
    result = conclude(%{state | exit_status: status})
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))
    {:stop, :normal, %{state | result: result, waiters: []}}
  end

  def handle_info(:wall_clock, %{result: nil} = state), do: {:noreply, kill(state, :wall_clock)}
  def handle_info(:wall_clock, state), do: {:noreply, state}

  def handle_info(:force_kill, %{port: port, result: nil} = state) do
    signal(port, "KILL")
    {:noreply, state}
  end

  def handle_info(:force_kill, state), do: {:noreply, state}

  defp emit(%{type: type, payload: payload} = event, state) do
    state.sink.(%{type: "job.harness." <> type, payload: payload, job_id: state.spec.job_id})

    cond do
      type == state.harness.finished_type() -> %{state | finished_event: event}
      type == "started" -> %{state | started_event: event}
      true -> state
    end
  end

  # -- ending -------------------------------------------------------------------------------

  defp kill(%{killed: nil, port: port} = state, reason) do
    signal(port, "TERM")
    Process.send_after(self(), :force_kill, state.grace_ms)
    %{state | killed: reason}
  end

  defp kill(state, _reason), do: state

  # The wrapper shell is a process group leader, so signalling the negative pid reaches the
  # harness and everything it spawned. Killing only the leader would leave children holding
  # the output pipe open and the port would never report an exit.
  defp signal(port, name) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-#{name}", "--", "-#{os_pid}"], stderr_to_stdout: true)

      nil ->
        :ok
    end
  end

  defp conclude(%{spec: spec, job_dir: job_dir} = state) do
    collected = Dir.collect(job_dir, spec)
    finished = state.finished_event && state.finished_event.payload
    started = state.started_event && state.started_event.payload

    run =
      Map.merge(collected, %{
        killed: state.killed,
        exit_status: state.exit_status,
        result: finished && %{subtype: finished.subtype, is_error: finished.is_error}
      })

    base = %Result{
      status: :finished,
      killed: state.killed,
      exit_status: state.exit_status,
      transcript_path: Dir.transcript_path(job_dir),
      stderr_path: Dir.stderr_path(job_dir),
      documents: collected.documents,
      invalid: collected.invalid,
      missing: collected.missing,
      undeclared: collected.undeclared,
      harness: harness_summary(started, finished, state.exit_status)
    }

    case Outcome.decide(spec, run) do
      {:waiting, questions} ->
        %{base | status: :waiting, questions: questions}

      {:finished, outcome, declared, reason} ->
        %{base | outcome: outcome, declared_outcome: declared, reason: reason}
    end
  end

  defp harness_summary(started, finished, exit_status) do
    started = started || %{}
    finished = finished || %{}

    %{
      session_id: Map.get(finished, :session_id) || Map.get(started, :session_id),
      model: Map.get(started, :model),
      subtype: Map.get(finished, :subtype),
      is_error: Map.get(finished, :is_error),
      turns: Map.get(finished, :num_turns),
      cost_usd: Map.get(finished, :total_cost_usd),
      duration_ms: Map.get(finished, :duration_ms),
      usage: Map.get(finished, :usage),
      exit_status: exit_status
    }
  end
end
