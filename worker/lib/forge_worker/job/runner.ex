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
    * `:slice` - how the process is confined (`ForgeWorker.Slice`). Default: the configured
      implementation, which is `Slice.Direct` unless the image says otherwise.
    * `:slice_opts` - the ceiling and share for this job, from the assignment.
    * `:extra_env` - additional `{name, value}` pairs for the process environment.
    * `:secrets` - the job's project secrets, sealed (`ForgeWorker.Job.Secrets`): opened at each
      spawn into the process's environment, never its arguments, and held sealed otherwise.
    * `:backlog` - the project's tickets, as the platform composed them at assignment. Written
      to `tickets/` in the job directory; see `ForgeWorker.Job.Dir.prepare/3`.
    * `:command_logs` - `[{file, path}]`, the logs of the commands a parked job invoked, copied
      to `commands/` in the job directory; see `ForgeWorker.Job.Dir.prepare/3`.
    * `:head` - the commit the worktree is at. Named in the continuation a resumed run is
      handed; see `ForgeCore.Prompt.continuation/3`.
    * `:max_corrections` - prompt mode only. How many times a run whose outputs could not be
      accepted is resumed with the problems listed, before it is reported (§ Correcting the
      outputs in `docs/design/claude-code-events.md`). Default 2.
    * `:start_notice_ms` - how often a harness that has been given its prompt and not yet said it
      started is reported as `job.harness.starting`, with the tail of its stderr. Default two
      minutes.
    * `:start_timeout_ms` - how long it may take before it is stopped as one that never started.
      Default thirty minutes (§ A harness that never starts in
      `docs/design/claude-code-events.md`).
    * `:memory_sample_ms` - how often the slice's reading of the job's memory is taken while the
      process runs (§ Memory in `docs/design/claude-code-events.md`). Default five seconds.
    * `:hold_prompt` - streaming only. When true nothing is delivered at start: the composed
      prompt waits for the first `send_message/2` and goes down with it, as one message. A
      reopened conversation with nothing waiting to be answered is the case
      (`docs/design/conversations.md` § Lifetime).

  The harness process gets a clean environment: an allowlist of the worker's own variables
  (PATH, locale, proxies, Nix settings), a private HOME inside the job directory, what the
  driver asks for, and `:extra_env`. Nothing else from the worker leaks in. Values marked
  `{:secret, value}` reach the process's environment through a file it loads itself, and through
  no argv, no unit property and no other process's environment (`ForgeWorker.Job.Exec`).
  """

  # Temporary: a runner that exits, normally or not, is never restarted. A job that must run
  # again is re-queued as a pending row and started afresh by the platform, not restarted in
  # place; `Dir.prepare/3` clears `out/` for it, so it never inherits a dead run's outputs.
  use GenServer, restart: :temporary

  alias ForgeCore.Job.{Correction, Outcome, Result, Spec}
  alias ForgeCore.Prompt
  alias ForgeWorker.Job.{Dir, Exec, Memory}
  alias ForgeWorker.Log

  require Logger

  @default_max_corrections 2
  @default_start_notice_ms :timer.minutes(2)
  @default_start_timeout_ms :timer.minutes(30)
  @default_memory_sample_ms :timer.seconds(5)
  # The tail of stderr a `starting` event carries: enough for `nix develop`'s last lines.
  @stderr_tail_bytes 2048
  # How long a conversation waits on a runner still setting up before the call gives up. The
  # default five seconds is shorter than making a slice can take, and a call that times out
  # takes the conversation with it.
  @call_timeout :timer.minutes(1)
  @default_wall_clock_ms :timer.hours(1)
  @default_grace_ms :timer.seconds(10)
  @eof_grace_ms :timer.seconds(5)
  # How long a finished prompt-mode run keeps its result for a caller who has not asked yet.
  @hold_ms :timer.seconds(5)
  @max_line 4 * 1024 * 1024

  # Cannot collide with a message: every line the runner writes to a streaming harness is JSON,
  # so a line that is not JSON is not a message.
  @close_sentinel "__FORGE_CLOSE__"

  # -- API ----------------------------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Blocks until the run ends. The runner exits right after replying."
  @spec await(pid(), timeout()) :: {:ok, Result.t()}
  def await(pid, timeout \\ :infinity), do: GenServer.call(pid, :await, timeout)

  @doc "Asks the runner to stop the harness. The result then reports `killed: :operator`."
  @spec cancel(pid()) :: :ok
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @doc """
  Sends a user message to a streaming harness. The harness queues it if a turn is in flight and
  echoes it when it takes it, so `:ok` means written, not answered.

  `{:error, :closed}` when the process is already gone, which is a conversation whose machine
  was lost rather than a message worth retrying.
  """
  @spec send_message(pid(), String.t()) :: :ok | {:error, :closed | :unsupported}
  def send_message(pid, text) when is_binary(text),
    do: GenServer.call(pid, {:send_message, text}, @call_timeout)

  @doc """
  Ends the turn in flight, leaving the process running. The turn it cuts is reported as
  interrupted rather than as the error the harness calls it.
  """
  @spec interrupt(pid()) :: :ok | {:error, :closed | :unsupported}
  def interrupt(pid), do: GenServer.call(pid, :interrupt, @call_timeout)

  @doc """
  Closes the harness's stdin, which is how a conversation ends: the process sees EOF and exits
  on its own, so nothing is signalled and the last turn is not cut short.
  """
  @spec close(pid()) :: :ok | {:error, :closed | :unsupported}
  def close(pid), do: GenServer.call(pid, :close, @call_timeout)

  # -- lifecycle ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    spec = Keyword.fetch!(opts, :spec)
    harness = Keyword.get(opts, :harness, ForgeWorker.Harness.ClaudeCode)
    mode = Keyword.get(Keyword.get(opts, :harness_opts, []), :mode, :prompt)

    # Refused here rather than discovered later: a harness that cannot take streaming input
    # starts perfectly well and then ignores every message, which looks like a conversation
    # that has stopped answering. This is the first caller `capabilities/0` has ever had.
    if mode == :streaming and not Map.get(harness.capabilities(), :streaming_input, false) do
      {:stop, {:unsupported, :streaming_input}}
    else
      {state, continue} = start_state(opts, spec, harness, mode)
      {:ok, state, continue}
    end
  end

  defp start_state(opts, spec, harness, mode) do
    # A session to resume is what makes this a continuation of an earlier attempt rather than
    # a fresh one, and so what decides whether `out/` is kept or cleared — for a job resuming its
    # own session. A fork is a new attempt, told its output directory is empty, and a fork run
    # again on the machine that lost it would otherwise inherit what the lost run left. A
    # conversation's documents are collected every turn, so what one left in `out/` has been
    # recorded, and a reopen that resumes its session clears it as a cold reopen always has.
    harness_opts = Keyword.get(opts, :harness_opts, [])
    resume? = Keyword.get(harness_opts, :resume_session) != nil
    fork? = Keyword.get(harness_opts, :fork_session, false)

    job_dir =
      Dir.prepare(Keyword.fetch!(opts, :root), spec,
        resume: resume? and not fork? and spec.kind != :chat,
        backlog: Keyword.get(opts, :backlog),
        command_logs: Keyword.get(opts, :command_logs, []),
        session: Keyword.get(opts, :session)
      )

    # Held, the prompt is composed when the message it opens with arrives, and written then:
    # `prompt.md` is the prompt as the harness was given it, and until then it has been given
    # nothing.
    #
    # `mode == :streaming` is an equivalent mutant: its only caller that holds is
    # `ForgeWorker.Job.Conversation`, which always runs streaming, and a workflow job's runner is
    # never passed `:hold_prompt`. Kept because in `:prompt` mode the shell redirects stdin from
    # `prompt.md`, and a held prompt is one that file was never written for.
    hold = mode == :streaming and Keyword.get(opts, :hold_prompt, false)

    unless hold,
      do: Dir.write_new!(Dir.prompt_path(job_dir), prompt(spec, job_dir, resume?, opts))

    transcript_path = Dir.new_transcript_path(job_dir)

    state = %{
      spec: spec,
      job_dir: job_dir,
      harness: harness,
      mode: mode,
      owner: Keyword.get(opts, :owner),
      sink: Keyword.get(opts, :sink, fn _ -> :ok end),
      grace_ms: Keyword.get(opts, :grace_ms, @default_grace_ms),
      port: nil,
      buffer: "",
      transcript_path: transcript_path,
      transcript: File.open!(transcript_path, [:write, :binary]),
      # What the harness reads its stdin from in prompt mode. A correction writes its own file
      # beside the first, so the prompt the job was given is still there to read afterwards.
      prompt_path: Dir.prompt_path(job_dir),
      # The options the process was spawned with, kept for a correction to spawn the next — behind
      # a function, because they carry the git token (`{:secret, …}` in `:extra_env`), and a value
      # in this state is a value in every crash report and `:sys.get_state/1` of this process. A
      # closure prints as a function. The credential is kept the same way for the same reason
      # (`ForgeWorker.Job.Credential.put/3`).
      spawn_opts: fn -> opts end,
      corrections: 0,
      max_corrections: Keyword.get(opts, :max_corrections, @default_max_corrections),
      # What the rounds before this one spent, summed, once a correction has run: the result
      # reports the whole job, not its last process.
      prior: nil,
      start_notice_ms: setting(opts, :start_notice_ms, @default_start_notice_ms),
      start_timeout_ms: setting(opts, :start_timeout_ms, @default_start_timeout_ms),
      memory_sample_ms: setting(opts, :memory_sample_ms, @default_memory_sample_ms),
      # Who hears that this machine's slice supervisor did not answer (`ForgeWorker.Health`).
      health: Keyword.get_lazy(opts, :health, &ForgeWorker.Health.server/0),
      # What the job's memory has done so far, and what has been said about it
      # (`ForgeWorker.Job.Memory`); and what the slice said of the process that last ended.
      memory:
        Memory.new(
          opts |> Keyword.get(:slice_opts, %{}) |> Map.get(:memory_max),
          # The node's, when it set one; `Memory`'s own default otherwise.
          threshold: setting(opts, :memory_pressure_full, nil)
        ),
      ending: nil,
      # When the harness was given something to start on, and so from when its silence counts.
      waiting_since: nil,
      # Stopped because it never started, which is what the result's reason then says.
      stalled: false,
      finished_event: nil,
      started_event: nil,
      rate_limit: nil,
      # Whether the sink has failed yet this run: said once, in the machine's log, rather than
      # once for every event after it.
      sink_failed: false,
      # A conversation produces one of these per turn. `finished_event` is the latest, which is
      # what the result is built from; `turns` is how many there have been, which is what tells
      # a second turn from a first.
      turns: 0,
      hold: hold,
      # How a held prompt is composed when the first message arrives: as a resume's, if this run
      # resumes, since a reopened conversation resuming its session is told only that it was
      # reopened (`ForgeCore.Prompt.continuation/4`). Only a conversation holds, and its
      # continuation needs the head and nothing else — not the harness options, which carry the
      # credential.
      resume: resume?,
      prompt_opts: [head: Keyword.get(opts, :head)],
      interrupting: nil,
      killed: nil,
      # A cancel or the wall clock asked this run to stop — recorded even when `killed` is not,
      # which is a prompt-mode run that had already printed its result (`kill/2`). A run asked to
      # stop is never corrected: it is concluded as killed when a correction would have followed,
      # and `Correction.needed/2` corrects no killed run.
      kill_requested: nil,
      exit_status: nil,
      slice: nil,
      slice_context: nil,
      eof: false,
      waiters: [],
      result: nil
    }

    Process.send_after(
      self(),
      :wall_clock,
      Keyword.get(opts, :wall_clock_ms, @default_wall_clock_ms)
    )

    {state, {:continue, {:spawn, opts}}}
  end

  # An option, else the application's setting, else the default — so a conversation, which starts
  # its runner without naming these, is timed the way the machine is configured to time it.
  defp setting(opts, key, default),
    do: Keyword.get(opts, key, Application.get_env(:forge_worker, key, default))

  # A run that resumes its session is handed what changed while it was stopped, not the whole
  # prompt again. Chosen from `resume?`, which is `:resume_session` — the value the driver turns
  # into `--resume` — so the prompt and the flag cannot disagree. Whether the session is really
  # there is the harness's to find out: a resume it cannot honour ends before `system/init`, and
  # the platform re-queues the job with no session, which lands in the second clause
  # (`docs/design/job-prompt.md` § The continuation prompt).
  defp prompt(spec, job_dir, true = _resume?, opts) do
    fork = opts |> Keyword.get(:harness_opts, []) |> Keyword.get(:fork_session, false)
    Prompt.continuation(spec, job_dir, Keyword.get(opts, :head), fork: fork)
  end

  defp prompt(spec, job_dir, false = _resume?, _opts), do: Prompt.compose(spec, job_dir)

  @impl true
  def handle_continue({:spawn, opts}, %{spec: spec, job_dir: job_dir, harness: harness} = state) do
    {executable, args, env} = harness.command(spec, job_dir, Keyword.get(opts, :harness_opts, []))

    # The environment is composed before the slice is made, not after, because a slice that
    # starts the process somewhere else has to be told what it is.
    {plain, secrets} = split_env(env ++ Keyword.get(opts, :extra_env, []) ++ secret_env(opts))
    {executable, args, secrets_file} = load_secrets(executable, args, job_dir, secrets)
    {executable, args} = Exec.nix(executable, args, spec.env, Keyword.get(opts, :nix_env, false))

    plain =
      Exec.inherited_env() ++
        [{"HOME", Dir.home_dir(job_dir)}] ++
        Exec.memory_env(Keyword.get(opts, :slice_opts)) ++ plain

    case slice(opts, spec, job_dir, plain, secrets_file) do
      {:ok, slice, context} ->
        {executable, args} = slice.wrap(executable, args, context)
        state = %{state | slice: slice, slice_context: context}
        {:noreply, spawn_harness(state, opts, executable, args, plain)}

      {:error, reason} ->
        {:noreply, conclude_without_starting(state, reason)}
    end
  end

  # The slice is made before the process and removed after it, whatever the outcome: a Unix
  # user left behind is a Unix user left behind on every job this worker ever ran.
  defp slice(opts, %Spec{} = spec, job_dir, plain, secrets_file) do
    slice = Keyword.get(opts, :slice) || ForgeWorker.Slice.impl()

    slice_opts =
      opts
      |> Keyword.get(:slice_opts, %{})
      |> Map.merge(%{
        job_id: spec.job_id,
        worktree: Keyword.fetch!(opts, :worktree),
        job_dir: job_dir,
        env: plain,
        secrets_file: secrets_file
      })

    with {:ok, context} <- slice.prepare(slice_opts), do: {:ok, slice, context}
  end

  # A slice that cannot be made is a job that cannot run: it concludes with nothing started,
  # which `ForgeCore.Job.Outcome` already reads as an error, rather than running unconfined.
  defp conclude_without_starting(state, reason) do
    Log.line("slice.failed", :error, "could not make a slice: #{inspect(reason)}",
      job_id: state.spec.job_id
    )

    send(self(), {:conclude, state.corrections})
    state
  end

  defp spawn_harness(state, opts, executable, args, plain) do
    job_dir = state.job_dir
    assignments = Enum.map(plain, fn {k, v} -> "#{k}=#{v}" end)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :eof,
        {:line, @max_line},
        {:args,
         [
           "-c",
           wrapper(state.mode),
           "forge-job",
           state.prompt_path,
           Dir.stderr_path(job_dir)
         ] ++ assignments ++ [executable | args]},
        {:cd, Keyword.fetch!(opts, :worktree)}
      ])

    state = %{state | port: port}

    # Read while the process lives, and only then: from its spawn, and from each round's own.
    Process.send_after(self(), {:sample, state.corrections}, state.memory_sample_ms)

    # The prompt is composed the same way for both modes and written to the same file; in
    # streaming mode it goes down the pipe as the first message instead of being redirected in.
    case state.mode do
      :streaming when state.hold -> state
      :streaming -> state |> deliver(File.read!(Dir.prompt_path(job_dir))) |> watch_start()
      :prompt -> watch_start(state)
    end
  end

  # The shell reads the prompt into stdin, sends stderr to its file, and `exec`s `env -i`
  # with only the assignments we pass as arguments: none of them a secret, which the process
  # loads itself (`load_secrets/4`). `exec` keeps the wrapper the process group leader we signal.
  #
  # **In streaming mode the prompt redirect is omitted, and that is the whole point.** `<"$prompt"`
  # replaces the port's stdin pipe with a regular file already at EOF, so a harness started that
  # way can never be written to — the pipe Erlang holds is discarded before the process starts.
  # A conversation keeps the pipe and gets its first message through `Port.command/2` like every
  # message after it, which also means there is one path for the first turn and the rest.
  defp wrapper(:prompt) do
    ~s(prompt="$1"; stderr="$2"; shift 2; exec /usr/bin/env -i "$@" <"$prompt" 2>"$stderr")
  end

  # Ending a conversation is stdin reaching EOF — the harness exits cleanly on it and a turn in
  # flight is allowed to finish, which signalling would cut short. BEAM cannot do that itself:
  # `:erlang` offers `port_close/1` and no half-close, so closing stdin would close stdout with
  # it and lose the last turn's output. The relay supplies the EOF instead — it forwards every
  # line and exits on the sentinel, which the child sees as the pipe closing.
  #
  # **The relay is the shell's own `read` loop, and that is not a style choice.** It was
  # `awk '{print; fflush()}'`, which is correct only where `awk` is gawk: `fflush` unbuffers
  # awk's *output*, and mawk — Debian's and Ubuntu's default — buffers its *input*, holding the
  # first message until 4 KiB arrive or the pipe closes. A conversation then answers nothing and
  # the machine looks hung. `read` is required to consume no more than one line from a pipe, so
  # a shell loop cannot have that bug on any POSIX shell; it also spares the slice a process.
  #
  # **And when the harness side exits, the relay goes with it.** It did not: the shell waits for
  # every member of a pipeline, and the relay was blocked in `read` on the port's stdin for a line
  # that was never coming — so a harness that exited before it started (`systemd-run` giving up on
  # PID 1, say) was a run that never reported an exit, until the start timeout stopped it thirty
  # minutes later (`docs/design/claude-code-events.md` § A harness that never starts). Now the
  # harness side, once its process has exited, signals the port's process group with `USR1`: the
  # relay has the default action and dies; the wrapper ignores it and carries on, and exits with
  # the harness's status, which is the pipeline's; the harness side ignores it by then.
  #
  # **The relay says it is listening before it can be signalled.** The wrapper trapped `USR1` at
  # first and left the relay, a forked subshell, to drop the trap — and a signal that arrived
  # between the fork and the reset was caught there and lost, leaving the relay in `read`: 2 runs
  # in 3,000 under dash, 3 under bash, with a harness that exits at once. So the wrapper ignores
  # it; the relay restores the default and then writes an empty line; and the harness side reads
  # that line before anything else, so it cannot signal a relay that is not ready, and restores the
  # default for the harness it runs, which gets the signal dispositions it always had. Not `PIPE`,
  # which would read better: the BEAM ignores it, an ignored signal stays ignored across `exec`,
  # and a shell may not trap one it started ignoring — so nothing here could die of it, which is
  # also why the relay never died writing into the pipe the harness had left. The pipeline's own
  # stderr is `/dev/null`, because dash reports a member killed by a signal there, and it is the
  # worker's journal; the harness's goes to its file as before. Dropping that redirect is an
  # equivalent mutant as far as any test can see: what it removes is a line the BEAM's own stderr
  # would have carried, which nothing here reads. POSIX `sh`, and the wrapper is still
  # the process-group leader `Exec.signal/2` signals — there is simply no `exec` on the harness side
  # any more, because something has to happen after it. Whatever else is still in the group goes
  # too: on the image nothing is, the job being in its unit, and on a development machine it is
  # what the harness left behind, which a unit would have ended.
  defp wrapper(:streaming) do
    relay =
      ~s({ trap - USR1; echo; while IFS= read -r line; do ) <>
        ~s([ "$line" = "#{@close_sentinel}" ] && exit 0; ) <>
        ~s(printf '%s\\n' "$line"; done; })

    harness =
      ~s({ read -r _; trap - USR1; ) <>
        ~s(/usr/bin/env -i "$@" 2>"$stderr"; status=$?; ) <>
        ~s(trap '' USR1; kill -s USR1 0; exit "$status"; })

    ~s(stderr="$2"; shift 2; trap '' USR1; { ) <> relay <> " | " <> harness <> ~s(; } 2>/dev/null)
  end

  # The job's project secrets, opened here at spawn and only here (`ForgeWorker.Job.Secrets`): the
  # runner's state keeps the sealed form inside `spawn_opts`, and a correction opens them again.
  defp secret_env(opts), do: opts |> Keyword.get(:secrets) |> ForgeWorker.Job.Secrets.env()

  # Every secret — the credential, the git token, the project's — is written to the file the
  # process loads before it `exec`s the harness, innermost, so not even `nix develop` holds them
  # (`ForgeWorker.Job.Exec`). The file is removed when the process has ended.
  defp load_secrets(executable, args, job_dir, secrets) do
    path = Exec.write_secrets(job_dir, secrets)
    {executable, args} = Exec.load_secrets(executable, args, path)
    {executable, args, path}
  end

  defp split_env(env) do
    Enum.reduce(env, {[], []}, fn
      {_key, false}, acc -> acc
      {key, {:secret, value}}, {plain, secrets} -> {plain, secrets ++ [{key, value}]}
      {key, value}, {plain, secrets} -> {plain ++ [{key, value}], secrets}
    end)
  end

  # -- calls --------------------------------------------------------------------------------

  @impl true
  def handle_call(:await, from, %{result: nil} = state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  # The run ended before this caller asked, and the runner stayed to hand it over (`:conclude`).
  # Having done that, it has nothing left to do.
  def handle_call(:await, _from, %{result: result} = state),
    do: {:stop, :normal, {:ok, result}, state}

  def handle_call(_request, _from, %{mode: :prompt} = state),
    do: {:reply, {:error, :unsupported}, state}

  # The first message to a held prompt carries it: the context and what the person said arrive
  # as one message and are answered in one turn. Composed the way a first start would compose
  # it with this message as its opening, so what a reopened conversation is given differs from
  # a new one's only in what the spec says about the past.
  def handle_call({:send_message, text}, _from, %{hold: true} = state) do
    prompt = prompt(%{state.spec | prompt: text}, state.job_dir, state.resume, state.prompt_opts)
    Dir.write_new!(Dir.prompt_path(state.job_dir), prompt)

    case write(state, state.harness.encode_message(prompt)) do
      :ok -> {:reply, :ok, watch_start(%{state | hold: false})}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:send_message, text}, _from, state) do
    {:reply, write(state, state.harness.encode_message(text)), state}
  end

  def handle_call(:interrupt, _from, state) do
    request_id = "forge-" <> Integer.to_string(state.turns + 1)

    case write(state, state.harness.encode_interrupt(request_id)) do
      :ok -> {:reply, :ok, %{state | interrupting: request_id}}
      error -> {:reply, error, state}
    end
  end

  # Closing stdin is the whole of it: the spike measured that the harness exits cleanly on EOF,
  # so there is nothing to signal and a turn in flight is allowed to finish.
  def handle_call(:close, _from, %{port: port} = state) when is_port(port) do
    {:reply, close_stdin(port), state}
  end

  def handle_call(:close, _from, state), do: {:reply, {:error, :closed}, state}

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

  # **Tagged with the round it concludes.** A correction starts a second process in this one, and
  # the backstop `maybe_conclude/1` sets for the first is still in the mailbox: untagged, it would
  # conclude the second round the moment it arrived, before the harness had said anything.
  # **No test reaches the tag**: it needs a first round whose output pipe outlives its exit and a
  # second that is still running when the five-second backstop fires, which is a suite made slow
  # for one clause. Dropping it is a real bug, not an equivalent mutant — keep it.
  def handle_info({:conclude, round}, %{result: nil, corrections: round} = state) do
    state =
      if state.buffer == "", do: state, else: handle_line(state.buffer, %{state | buffer: ""})

    # Every process's end comes here, one that never started included
    # (`conclude_without_starting/2`), so this is the one place its secrets file goes.
    Exec.remove_secrets(state.job_dir)
    state = ended(state)
    result = conclude(state)

    # A run asked to stop whose outputs would have been corrected stopped as it was asked to: it
    # is reported killed, as a run that had not printed its result is, and not as the error its
    # outputs would otherwise have made it.
    result =
      if state.kill_requested && Correction.needed(state.spec, result) != :none,
        do: conclude(%{state | killed: state.kill_requested}),
        else: result

    case correct(state, result) do
      {:ok, state} -> {:noreply, state}
      :none -> finish(state, result)
    end
  end

  # The end is reached by more than one road — the exit status and the end of output each ask for
  # it — and a runner holding its result for a late `await/1` (`stop_or_hold/2`) is still here to
  # receive the second. The first conclusion is the one; one for an earlier round is stale.
  def handle_info({:conclude, _round}, state), do: {:noreply, state}

  # Sent only once a result is held, so there is nothing left to wait for.
  def handle_info(:release, state), do: {:stop, :normal, state}

  def handle_info(:wall_clock, %{result: nil} = state), do: {:noreply, kill(state, :wall_clock)}
  def handle_info(:wall_clock, state), do: {:noreply, state}

  # Tagged with the round, like `:conclude`: one set for a round that then ended must not reach
  # the next round's process.
  def handle_info({:force_kill, round}, %{port: port, result: nil, corrections: round} = state) do
    Exec.signal(port, "KILL")
    {:noreply, state}
  end

  def handle_info({:force_kill, _round}, state), do: {:noreply, state}

  # A harness that was given its prompt and has not said it started: say so, with what it wrote
  # to stderr, and stop it once it has had long enough (§ A harness that never starts). Tagged with
  # the round, like `:conclude`, so a correction's process is timed from its own start.
  def handle_info(
        {:start_check, round},
        %{corrections: round, started_event: nil, result: nil, stalled: false} = state
      )
      when is_port(state.port) do
    waited = System.monotonic_time(:millisecond) - state.waiting_since
    gave_up = waited >= state.start_timeout_ms

    state =
      emit(
        %{
          type: "starting",
          payload: %{
            waited_s: div(waited, 1000),
            gave_up: gave_up,
            stderr: stderr_tail(state.job_dir),
            # Whether memory is why it has not started: 2026-09-29's first chat could not exec in
            # a ceiling of two bytes, and its `starting` events said nothing but the time.
            memory: Memory.snapshot(reading(state))
          }
        },
        state
      )

    if gave_up do
      Exec.signal(state.port, "TERM")
      Process.send_after(self(), {:force_kill, round}, state.grace_ms)
      {:noreply, %{state | stalled: true}}
    else
      Process.send_after(self(), {:start_check, round}, state.start_notice_ms)
      {:noreply, state}
    end
  end

  def handle_info({:start_check, _round}, state), do: {:noreply, state}

  # Tagged with the round, like the others, and only while its process lives: an exit already
  # reported is a cgroup about to go, and the unit's own last reading says the rest.
  def handle_info(
        {:sample, round},
        %{corrections: round, result: nil, exit_status: nil, slice: slice} = state
      )
      when slice != nil do
    state = observe(state, slice.memory(state.slice_context))
    Process.send_after(self(), {:sample, round}, state.memory_sample_ms)
    {:noreply, state}
  end

  # `exit_status: nil` above is an equivalent mutant as far as the suite goes: a sample taken
  # between the exit and the conclusion reads a cgroup about to go, and what it could add the
  # unit's last reading adds anyway. Kept because a run that has ended is not one to watch.

  def handle_info({:sample, _round}, state), do: {:noreply, state}

  # What an earlier round's process said after its round was concluded — the end of its output
  # arriving after the backstop had already stood in for it. That process is gone. Like the
  # `{:conclude, round}` tag, **no test reaches this**: it needs a round whose output pipe outlives
  # the five-second backstop. Without it the message would match no clause and crash the runner.
  def handle_info({port, _message}, state) when is_port(port), do: {:noreply, state}

  defp finish(state, result) do
    File.close(state.transcript)
    if state.slice, do: state.slice.cleanup(state.slice_context)

    result =
      result
      |> accumulate(state)
      |> stalled(state)
      |> unstarted(state)
      |> killed_for_memory(state)
      |> stage(state)

    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))

    # A conversation's owner is not blocked on `await/1` — it has been handling turns all
    # along — so the result is sent to it rather than only left for a caller that will never
    # arrive. It goes before the stop, so it is in the mailbox ahead of the exit signal.
    if state.mode == :streaming, do: notify(state, {:ended, state.spec.job_id, result})

    stop_or_hold(%{state | result: result, waiters: []}, state.waiters)
  end

  # -- a harness that never starts ------------------------------------------------------------

  defp watch_start(state) do
    Process.send_after(self(), {:start_check, state.corrections}, state.start_notice_ms)
    %{state | waiting_since: System.monotonic_time(:millisecond)}
  end

  # The reason a run stopped for never starting gives, in place of "no result message": that is
  # true and names nothing, and the last line of stderr is usually the thing it was stuck on.
  defp stalled(result, %{stalled: false}), do: result

  defp stalled(result, state) do
    reason = "the harness had not started after #{duration(state.start_timeout_ms)}"
    %{result | reason: with_stderr(reason, state)}
  end

  # **A harness that exited on its own before it said it started** — `systemd-run` giving up on
  # PID 1, a `nix develop` that failed, a binary that is not there — says why the way a stopped
  # one does: with stderr's last line, and not with "no result message", which is true and names
  # nothing. Only one that exited (a status) with no result message and nothing asked it to stop:
  # a resume the harness refused has a result, and its own words are the better reason.
  defp unstarted(
         result,
         %{started_event: nil, finished_event: nil, kill_requested: nil, stalled: false} = state
       )
       when is_integer(state.exit_status) do
    reason = "the harness exited with status #{state.exit_status} before it started"
    %{result | reason: with_stderr(reason, state)}
  end

  defp unstarted(result, _state), do: result

  # **Killed at its ceiling, said in words** rather than as no result message or an exit status
  # (`docs/design/claude-code-events.md` § Memory): a run with no result message, not stopped by
  # this runner, whose unit's last reading says so (`Memory.killed/2`, the one rule a command's
  # reason uses too).
  defp killed_for_memory(
         result,
         %{finished_event: nil, kill_requested: nil, stalled: false} = state
       ) do
    case Memory.killed(state.ending, state.memory.ceiling) do
      nil -> result
      killed -> %{result | reason: "the harness was " <> killed}
    end
  end

  defp killed_for_memory(result, _state), do: result

  # The slice's own lines taken out — `systemd-run`'s summary names nothing — where the slice said
  # what they are; the raw tail where no process ended to ask about.
  defp with_stderr(reason, state) do
    last =
      case state.ending do
        %{last_line: line} -> line
        nil -> state.job_dir |> stderr_tail() |> ForgeWorker.Slice.last_line()
      end

    if last, do: "#{reason}; stderr: #{last}", else: reason
  end

  # **The machine's failure, not the job's**: the slice's supervisor never answered, so the process
  # never ran (`docs/design/worker-tier.md` § How a machine finds out). Said before the run
  # concludes, and synchronously, so the link has stopped listening for this job's ending by the
  # time it arrives.
  defp unreachable(%{unreachable: reason}, health) when is_binary(reason),
    do: ForgeWorker.Health.unreachable(reason, health)

  defp unreachable(_ending, _health), do: :ok

  # -- memory -----------------------------------------------------------------------------------

  defp reading(%{slice: nil}), do: nil
  defp reading(state), do: state.slice.memory(state.slice_context)

  # A reading's events, said in order through the sink like any the harness makes.
  defp observe(state, reading) do
    {memory, events} = Memory.observe(state.memory, reading)

    Enum.reduce(events, %{state | memory: memory}, fn payload, state ->
      emit(%{type: "memory", payload: payload}, state)
    end)
  end

  # What the slice can say of the process that just ended, once, and the unit's last reading run
  # through the watch like any other — so a kill no sample saw is still an event before the result.
  defp ended(%{slice: nil} = state), do: state

  defp ended(state) do
    ending = state.slice.ended(state.slice_context, Dir.stderr_path(state.job_dir))
    unreachable(ending, state.health)
    observe(%{state | ending: ending}, ending.memory)
  end

  defp duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp duration(ms), do: "#{div(ms, 60_000)} minutes"

  defp stderr_tail(job_dir),
    do: ForgeWorker.Slice.tail(Dir.stderr_path(job_dir), @stderr_tail_bytes)

  # -- correcting the outputs -----------------------------------------------------------------

  # A run whose harness ended cleanly but whose outputs could not be accepted is resumed — the same
  # session, the same job directory with `out/` as it was left, the same slice — and told what is
  # wrong, a bounded number of times, before anything is reported
  # (`docs/design/claude-code-events.md` § Correcting the outputs). Only in prompt mode: a
  # conversation has no outputs to accept. Only with a slice, because the next process runs in
  # the one this run was given, and a run whose slice was refused never started.
  defp correct(%{mode: :prompt, slice: slice} = state, %Result{} = result) when slice != nil do
    spent = spent(state, result.harness)

    with {:correct, problems} <- Correction.needed(state.spec, result),
         true <- state.corrections < state.max_corrections,
         session when is_binary(session) <- result.harness["session_id"],
         {:ok, budget} <- Correction.remaining(state.spec, spent) do
      round = state.corrections + 1
      text = Correction.prompt(problems, round, state.max_corrections)

      state =
        emit(
          %{
            type: "correction",
            payload: %{round: round, of: state.max_corrections, problems: problems}
          },
          state
        )

      {:ok, respawn(state, round, session, budget, text, result.harness)}
    else
      _ -> :none
    end
  end

  defp correct(_state, _result), do: :none

  defp respawn(state, round, session, budget, text, harness) do
    path = Path.join(state.job_dir, "correction-#{round}.md")
    Dir.write_new!(path, text)

    opts = state.spawn_opts.()
    harness_opts = opts |> Keyword.get(:harness_opts, []) |> Keyword.put(:resume_session, session)
    spec = %{state.spec | budget: budget}

    {executable, args, env} = state.harness.command(spec, state.job_dir, harness_opts)
    {plain, secrets} = split_env(env ++ Keyword.get(opts, :extra_env, []) ++ secret_env(opts))
    {executable, args, _path} = load_secrets(executable, args, state.job_dir, secrets)
    {executable, args} = Exec.nix(executable, args, spec.env, Keyword.get(opts, :nix_env, false))

    plain =
      Exec.inherited_env() ++
        [{"HOME", Dir.home_dir(state.job_dir)}] ++
        Exec.memory_env(Keyword.get(opts, :slice_opts)) ++ plain

    {executable, args} = state.slice.wrap(executable, args, state.slice_context)

    state = %{
      state
      | corrections: round,
        memory: Memory.new_round(state.memory),
        prior: add_up(state.prior, harness),
        prompt_path: path,
        port: nil,
        buffer: "",
        exit_status: nil,
        eof: false,
        started_event: nil,
        finished_event: nil
    }

    spawn_harness(state, opts, executable, args, plain)
  end

  # Turns and cost so far: every earlier round's, and this one's.
  defp spent(state, harness) do
    total = add_up(state.prior, harness)
    %{turns: total["turns"], cost: total["cost_usd"]}
  end

  @summed ~w(turns cost_usd duration_ms)

  defp add_up(nil, harness),
    do: add_up(%{"turns" => 0, "cost_usd" => 0, "duration_ms" => 0}, harness)

  defp add_up(prior, harness) do
    Map.new(@summed, fn key -> {key, (prior[key] || 0) + (harness[key] || 0)} end)
  end

  # The job's result is the last round's, with what every round spent. The platform adds the cost
  # and the turns to the job once, so reporting only the last process's would lose the rest.
  defp accumulate(result, %{prior: nil}), do: result

  defp accumulate(%Result{harness: harness} = result, %{prior: prior, corrections: corrections}) do
    harness =
      harness
      |> Map.merge(add_up(prior, harness))
      |> Map.put("corrections", corrections)

    %{result | harness: harness}
  end

  # **A run can end before anyone has asked for it.** A slice refused at once concludes within the
  # call that started the runner, and a runner that stopped on concluding took the result with
  # it: `await/1` then exited with `:normal` instead of returning, the job was reported as a
  # crash rather than as the error it was, and the suite failed on it one run in several. So a
  # prompt-mode run nobody is waiting on yet holds its result for a caller who is about to ask —
  # `Link` awaits straight after starting it — and not for ever: a runner nobody awaits is one
  # somebody cancelled and walked away from, and it goes after `@hold_ms`. A conversation's owner
  # is told by message instead, and stops it as before.
  defp stop_or_hold(%{mode: :prompt} = state, []) do
    Process.send_after(self(), :release, @hold_ms)
    {:noreply, state}
  end

  defp stop_or_hold(state, _waiters), do: {:stop, :normal, state}

  # Writing to a port whose process has gone raises rather than returning an error, and a
  # conversation whose machine was lost is exactly the case that reaches here — so the failure
  # is turned into a value the caller can report instead of one that takes the runner with it.
  defp write(%{port: port}, iodata) when is_port(port) do
    Port.command(port, iodata)
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  defp write(_state, _iodata), do: {:error, :closed}

  defp deliver(state, text) do
    write(state, state.harness.encode_message(text))
    state
  end

  defp close_stdin(port) do
    Port.command(port, [@close_sentinel, "\n"])
    :ok
  rescue
    ArgumentError -> {:error, :closed}
  end

  # Concluding needs both the exit status and `:eof`. A child that outlived the harness can hold
  # the output pipe open, in which case the status arrives and `:eof` never does; the backstop
  # bounds that wait rather than hanging the job. It is not the path a healthy run takes.
  defp maybe_conclude(%{exit_status: status, eof: eof} = state) when status != nil do
    if eof do
      handle_info({:conclude, state.corrections}, state)
    else
      Process.send_after(self(), {:conclude, state.corrections}, @eof_grace_ms)
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
    state =
      try do
        state.sink.(%{type: "job.harness." <> type, payload: payload, job_id: state.spec.job_id})
        state
      rescue
        error -> sink_failed(state, type, error)
      end

    case type do
      "finished" -> finished(state, event)
      "started" -> %{state | started_event: event}
      "rate_limit" -> %{state | rate_limit: payload}
      _ -> state
    end
  end

  # The first failure is a line in the machine's log; the rest only the journal's, since a sink
  # that fails once fails for every event after it and would fill the log with one fact.
  defp sink_failed(%{sink_failed: false} = state, type, error) do
    Log.line("event.dropped", :warning, "could not hand on #{type}: #{Exception.message(error)}",
      job_id: state.spec.job_id
    )

    %{state | sink_failed: true}
  end

  defp sink_failed(state, type, error) do
    Logger.warning("event sink failed for #{type}: #{Exception.message(error)}")
    state
  end

  # A turn ended. In prompt mode there is exactly one and this is the end of the run; in
  # streaming mode there is one per turn and the process carries on, so the count is kept and
  # the owner is told. `finished_event` holds the latest rather than the first — the run's
  # result is built from the last thing the harness said, not the first.
  defp finished(state, event) do
    state = %{state | finished_event: event, turns: state.turns + 1}

    if state.mode == :streaming do
      # The job's memory as it stands at the turn's end, from a reading taken now: a conversation
      # reports a summary per turn, and this is its memory's (§ Memory).
      state = observe(state, reading(state))
      event = put_in(event.payload[:memory], Memory.summary(state.memory))
      notify(state, {:turn, state.spec.job_id, state.turns, label(state, event)})
      %{state | interrupting: nil}
    else
      state
    end
  end

  # An interrupted turn reports `error_during_execution` with a null result — exactly what a
  # genuine execution error reports, which the spike measured. Only this process knows it asked
  # for the interrupt, so only this process can say so; left to the payload, an operator's own
  # Stop renders in their conversation as a failure. See `docs/design/conversations.md` § Turns.
  defp label(%{interrupting: nil}, event), do: event
  defp label(_state, event), do: put_in(event.payload[:interrupted], true)

  defp notify(%{owner: nil}, _message), do: :ok
  defp notify(%{owner: owner}, message), do: send(owner, message)

  # -- ending -------------------------------------------------------------------------------

  defp kill(%{killed: nil, port: port} = state, reason) do
    Exec.signal(port, "TERM")
    Process.send_after(self(), {:force_kill, state.corrections}, state.grace_ms)
    state = %{state | kill_requested: state.kill_requested || reason}

    # A harness that already produced its result finished on its own; the signal only
    # hurries the exit and must not relabel the outcome. That holds for a single-turn run,
    # where a result means the work is done — but a conversation produces one every turn and is
    # not finished by any of them, so after turn one a cancel would silently stop being recorded
    # as a cancel. In streaming mode the reason is always kept.
    if state.finished_event && state.mode == :prompt,
      do: state,
      else: %{state | killed: reason}
  end

  defp kill(state, _reason), do: state

  defp conclude(%{spec: spec, job_dir: job_dir} = state) do
    collected = Dir.collect(job_dir, spec)
    finished = state.finished_event && state.finished_event.payload
    started = state.started_event && state.started_event.payload

    run =
      Map.merge(collected, %{
        killed: state.killed,
        exit_status: state.exit_status,
        # `:result` is the harness's own closing message, and it is the only field that ever
        # names why a run failed — it used to be parsed and then dropped right here.
        result:
          finished &&
            %{
              subtype: finished.subtype,
              is_error: finished.is_error,
              text: Map.get(finished, :result)
            }
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
      proposals: collected.proposals,
      invalid_proposals: collected.invalid_proposals,
      harness:
        harness_summary(
          started,
          finished,
          state.exit_status,
          state.rate_limit,
          Memory.summary(state.memory)
        )
    }

    decide(state, spec, run, base)
  end

  # A finished run's groups of files, copied out for the link to upload
  # (`docs/design/job-prompt.md` § Groups of files). Only a finished one's: a run that parks or
  # stops on a question keeps `out/` for its resume, and the run that finishes is the one whose
  # files count.
  defp stage(%Result{status: :finished} = result, %{spec: spec, job_dir: job_dir}),
    do: ForgeWorker.Job.Blobs.stage(result, job_dir, Spec.group_outputs(spec))

  defp stage(result, _state), do: result

  # A conversation has no outcome, ever, and nothing asks it for one: there is no state to leave
  # and no transition to select. Running `Outcome.decide/2` over it would invent a `declared`
  # from the last turn's document and hand the engine something to act on — see
  # `docs/design/conversations.md` § Shape, where the guard against exactly that is described as
  # belonging at the one place jobs complete.
  defp decide(%{mode: :streaming}, _spec, _run, base), do: base

  # A run that asked for commands is parked, not finished: nothing it wrote is collected as
  # final and no outcome is decided, because it has not stopped working — it is waiting on a
  # build (`docs/design/commands.md` § How an agent invokes). Only a run that ended cleanly may
  # park: one the platform killed, or one the harness stopped for its budget or an error, is over
  # whatever it asked for. And only a job whose state may invoke; any other's `invoke.json` is
  # removed unread, so a stray file cannot turn a finished run into a round of refusals.
  defp decide(state, spec, run, base) do
    case invocations(state.job_dir, spec, run) do
      :none -> outcome(spec, run, base)
      {:ok, invocations} -> %{base | status: :parked, invocations: invocations}
      {:error, reason} -> %{base | status: :parked, invocation_error: reason}
    end
  end

  defp invocations(job_dir, %Spec{may_invoke: grants}, run) do
    # `run.killed == nil` is an equivalent mutant here: a run that invokes is a single-turn run,
    # and `kill/2` leaves `killed` nil on one that already has its result — so a killed run is
    # one with no result, which `run.result != nil` already refuses. Kept for what it says.
    clean? =
      run.killed == nil and run.result != nil and run.result.subtype == "success" and
        not run.result.is_error

    if clean? and map_size(grants) > 0 do
      Dir.invocations(job_dir)
    else
      File.rm_rf(Dir.invoke_path(job_dir))
      :none
    end
  end

  defp outcome(spec, run, base) do
    case Outcome.decide(spec, run) do
      {:waiting, questions} ->
        %{base | status: :waiting, questions: questions}

      {:finished, outcome, declared, reason} ->
        %{base | outcome: outcome, declared_outcome: declared, reason: reason}
    end
  end

  # `rate_limit` is the last window report of the run, which is how the platform tells a run its
  # account's limit stopped from one that failed at its work (`docs/design/credentials.md` § A
  # limit reached mid-run). In the result rather than left to the timeline: timeline events are
  # unacked, and a lost one would turn a limit back into a failure.
  #
  # `memory` is the ceiling, the peak and the OOM kills — the unit's own last reading where there is
  # one (§ Memory in `docs/design/claude-code-events.md`) — and nil where nothing was read.
  defp harness_summary(started, finished, exit_status, rate_limit, memory) do
    started = started || %{}
    finished = finished || %{}

    # String keys, because this is the provider's own summary and it crosses the channel as
    # JSON. An atom key here would arrive as a string key there, and the platform would read
    # nil for the cost of every job.
    %{
      "session_id" => Map.get(finished, :session_id) || Map.get(started, :session_id),
      "model" => Map.get(started, :model),
      "version" => Map.get(started, :version),
      "subtype" => Map.get(finished, :subtype),
      "is_error" => Map.get(finished, :is_error),
      "turns" => Map.get(finished, :num_turns),
      "cost_usd" => Map.get(finished, :total_cost_usd),
      "duration_ms" => Map.get(finished, :duration_ms),
      "usage" => Map.get(finished, :usage),
      "exit_status" => exit_status,
      "rate_limit" => rate_limit && window_report(rate_limit),
      "memory" => memory
    }
  end

  defp window_report(report) do
    %{
      "status" => Map.get(report, :status),
      "resets_at" => Map.get(report, :resets_at),
      "rate_limit_type" => Map.get(report, :rate_limit_type)
    }
  end
end
