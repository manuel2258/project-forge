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

  The harness process gets a clean environment: an allowlist of the worker's own variables
  (PATH, locale, proxies, Nix settings), a private HOME inside the job directory, what the
  driver asks for, and `:extra_env`. Nothing else from the worker leaks in. Values the driver
  marks `{:secret, value}` reach the process through the environment only, never argv.
  """

  # Temporary: a runner that exits, normally or not, is never restarted. A job that must run
  # again is re-queued as a pending row and started afresh by the platform, not restarted in
  # place; `Dir.prepare/3` clears `out/` for it, so it never inherits a dead run's outputs.
  use GenServer, restart: :temporary

  alias ForgeCore.Job.{Outcome, Spec}
  alias ForgeCore.Prompt
  alias ForgeWorker.Job.{Dir, Result}

  require Logger

  @default_wall_clock_ms :timer.hours(1)
  @default_grace_ms :timer.seconds(10)
  @eof_grace_ms :timer.seconds(5)
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

    # A session to resume is what makes this a continuation of an earlier attempt rather than
    # a fresh one, and so what decides whether `out/` is kept or cleared.
    resume? = Keyword.get(Keyword.get(opts, :harness_opts, []), :resume_session) != nil
    job_dir = Dir.prepare(Keyword.fetch!(opts, :root), spec, resume: resume?)
    File.write!(Dir.prompt_path(job_dir), Prompt.compose(spec, job_dir))
    transcript_path = Dir.new_transcript_path(job_dir)

    state = %{
      spec: spec,
      job_dir: job_dir,
      harness: harness,
      sink: Keyword.get(opts, :sink, fn _ -> :ok end),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      port: nil,
      buffer: "",
      transcript_path: transcript_path,
      transcript: File.open!(transcript_path, [:write, :binary]),
      finished_event: nil,
      started_event: nil,
      killed: nil,
      exit_status: nil,
      eof: false,
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
    {plain, secrets} = split_env(env ++ Keyword.get(opts, :extra_env, []))

    assignments =
      Enum.map(inherited_env() ++ [{"HOME", Dir.home_dir(job_dir)}] ++ plain, fn {k, v} ->
        "#{k}=#{v}"
      end)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :eof,
        {:line, @max_line},
        {:args,
         ["-c", wrapper(secrets), "forge-job", Dir.prompt_path(job_dir), Dir.stderr_path(job_dir)] ++
           assignments ++ [executable | args]},
        {:cd, Keyword.fetch!(opts, :worktree)},
        {:env, Enum.map(secrets, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
      ])

    {:noreply, %{state | port: port}}
  end

  # The shell reads the prompt into stdin, sends stderr to its file, and `exec`s `env -i`
  # with only the assignments we pass as arguments plus the secrets forwarded by name from
  # its own environment. `exec` keeps the wrapper the process group leader we signal.
  defp wrapper(secrets) do
    forwarded = Enum.map_join(secrets, " ", fn {k, _} -> ~s(${#{k}+"#{k}=$#{k}"}) end)

    ~s(prompt="$1"; stderr="$2"; shift 2; exec /usr/bin/env -i #{forwarded} "$@" <"$prompt" 2>"$stderr")
  end

  defp split_env(env) do
    Enum.reduce(env, {[], []}, fn
      {_key, false}, acc -> acc
      {key, {:secret, value}}, {plain, secrets} -> {plain, secrets ++ [{key, value}]}
      {key, value}, {plain, secrets} -> {plain ++ [{key, value}], secrets}
    end)
  end

  @inherited ~w(PATH LANG LC_ALL TERM TMPDIR SSL_CERT_FILE NIX_SSL_CERT_FILE NIX_PATH NIX_REMOTE
                NIX_CONFIG HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

  defp inherited_env do
    for key <- @inherited, value = System.get_env(key), do: {key, value}
  end

  defp maybe_nix(executable, args, %Spec{env: env}, true) when is_binary(env) do
    {"nix", ["develop", ".##{env}", "--command", executable | args]}
  end

  defp maybe_nix(executable, args, _spec, _nix), do: {executable, args}

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
    {:noreply, handle_line(state.buffer <> chunk, %{state | buffer: ""})}
  end

  # The exit status arrives before the last of the output: a final unterminated chunk is only
  # delivered when the pipe closes, which is strictly after the process has gone. `:eof` is the
  # message that says the output is complete, so concluding waits for both. Deferring a hop
  # instead would be a race — a self-sent message is queued immediately, and the trailing chunk
  # has not necessarily been delivered yet.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    maybe_conclude(%{state | exit_status: status})
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    maybe_conclude(%{state | eof: true})
  end

  def handle_info(:conclude, %{result: nil} = state) do
    state =
      if state.buffer == "", do: state, else: handle_line(state.buffer, %{state | buffer: ""})

    File.close(state.transcript)
    result = conclude(state)
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

  # Concluding needs both the exit status and `:eof`. A child that outlived the harness can hold
  # the output pipe open, in which case the status arrives and `:eof` never does; the backstop
  # bounds that wait rather than hanging the job. It is not the path a healthy run takes.
  defp maybe_conclude(%{exit_status: status, eof: eof} = state) when status != nil do
    if eof do
      handle_info(:conclude, state)
    else
      Process.send_after(self(), :conclude, @eof_grace_ms)
      {:noreply, state}
    end
  end

  defp maybe_conclude(state), do: {:noreply, state}

  defp handle_line(line, state) do
    IO.binwrite(state.transcript, [line, "\n"])
    Enum.reduce(state.harness.parse_line(line), state, &emit/2)
  end

  # A failing sink must not take the job down with it.
  defp emit(%{type: type, payload: payload} = event, state) do
    try do
      state.sink.(%{type: "job.harness." <> type, payload: payload, job_id: state.spec.job_id})
    rescue
      error -> Logger.warning("event sink failed for #{type}: #{Exception.message(error)}")
    end

    case type do
      "finished" -> %{state | finished_event: event}
      "started" -> %{state | started_event: event}
      _ -> state
    end
  end

  # -- ending -------------------------------------------------------------------------------

  defp kill(%{killed: nil, port: port} = state, reason) do
    signal(port, "TERM")
    Process.send_after(self(), :force_kill, state.grace_ms)
    # A harness that already produced its result finished on its own; the signal only
    # hurries the exit and must not relabel the outcome.
    if state.finished_event, do: state, else: %{state | killed: reason}
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
      transcript_path: state.transcript_path,
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
