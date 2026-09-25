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
    * `:backlog` - the project's tickets, as the platform composed them at assignment. Written
      to `tickets/` in the job directory; see `ForgeWorker.Job.Dir.prepare/3`.
    * `:head` - the commit the worktree is at. Named in the continuation a resumed run is
      handed; see `ForgeCore.Prompt.continuation/3`.
    * `:hold_prompt` - streaming only. When true nothing is delivered at start: the composed
      prompt waits for the first `send_message/2` and goes down with it, as one message. A
      reopened conversation with nothing waiting to be answered is the case
      (`docs/design/conversations.md` § Lifetime).

  The harness process gets a clean environment: an allowlist of the worker's own variables
  (PATH, locale, proxies, Nix settings), a private HOME inside the job directory, what the
  driver asks for, and `:extra_env`. Nothing else from the worker leaks in. Values the driver
  marks `{:secret, value}` reach the process through the environment only, never argv.
  """

  # Temporary: a runner that exits, normally or not, is never restarted. A job that must run
  # again is re-queued as a pending row and started afresh by the platform, not restarted in
  # place; `Dir.prepare/3` clears `out/` for it, so it never inherits a dead run's outputs.
  use GenServer, restart: :temporary

  alias ForgeCore.Job.{Outcome, Result, Spec}
  alias ForgeCore.Prompt
  alias ForgeWorker.Job.Dir

  require Logger

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
    do: GenServer.call(pid, {:send_message, text})

  @doc """
  Ends the turn in flight, leaving the process running. The turn it cuts is reported as
  interrupted rather than as the error the harness calls it.
  """
  @spec interrupt(pid()) :: :ok | {:error, :closed | :unsupported}
  def interrupt(pid), do: GenServer.call(pid, :interrupt)

  @doc """
  Closes the harness's stdin, which is how a conversation ends: the process sees EOF and exits
  on its own, so nothing is signalled and the last turn is not cut short.
  """
  @spec close(pid()) :: :ok | {:error, :closed | :unsupported}
  def close(pid), do: GenServer.call(pid, :close)

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
    # a fresh one, and so what decides whether `out/` is kept or cleared.
    resume? = Keyword.get(Keyword.get(opts, :harness_opts, []), :resume_session) != nil

    job_dir =
      Dir.prepare(Keyword.fetch!(opts, :root), spec,
        resume: resume?,
        backlog: Keyword.get(opts, :backlog)
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
      do: File.write!(Dir.prompt_path(job_dir), prompt(spec, job_dir, resume?, opts))

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
      finished_event: nil,
      started_event: nil,
      rate_limit: nil,
      # A conversation produces one of these per turn. `finished_event` is the latest, which is
      # what the result is built from; `turns` is how many there have been, which is what tells
      # a second turn from a first.
      turns: 0,
      hold: hold,
      interrupting: nil,
      killed: nil,
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

  # A run that resumes its session is handed what changed while it was stopped, not the whole
  # prompt again. Chosen from `resume?`, which is `:resume_session` — the value the driver turns
  # into `--resume` — so the prompt and the flag cannot disagree. Whether the session is really
  # there is the harness's to find out: a resume it cannot honour ends before `system/init`, and
  # the platform re-queues the job with no session, which lands in the second clause
  # (`docs/design/job-prompt.md` § The continuation prompt).
  defp prompt(spec, job_dir, true = _resume?, opts),
    do: Prompt.continuation(spec, job_dir, Keyword.get(opts, :head))

  defp prompt(spec, job_dir, false = _resume?, _opts), do: Prompt.compose(spec, job_dir)

  @impl true
  def handle_continue({:spawn, opts}, %{spec: spec, job_dir: job_dir, harness: harness} = state) do
    {executable, args, env} = harness.command(spec, job_dir, Keyword.get(opts, :harness_opts, []))
    {executable, args} = maybe_nix(executable, args, spec, Keyword.get(opts, :nix_env, false))

    # The environment is composed before the slice is made, not after, because a slice that
    # starts the process somewhere else has to be told what it is.
    {plain, secrets} = split_env(env ++ Keyword.get(opts, :extra_env, []))
    plain = inherited_env() ++ [{"HOME", Dir.home_dir(job_dir)}] ++ plain

    case slice(opts, spec, job_dir, plain, secrets) do
      {:ok, slice, context} ->
        {executable, args} = slice.wrap(executable, args, context)
        state = %{state | slice: slice, slice_context: context}
        {:noreply, spawn_harness(state, opts, executable, args, plain, secrets)}

      {:error, reason} ->
        {:noreply, conclude_without_starting(state, reason)}
    end
  end

  # The slice is made before the process and removed after it, whatever the outcome: a Unix
  # user left behind is a Unix user left behind on every job this worker ever ran.
  defp slice(opts, %Spec{} = spec, job_dir, plain, secrets) do
    slice = Keyword.get(opts, :slice) || ForgeWorker.Slice.impl()

    slice_opts =
      opts
      |> Keyword.get(:slice_opts, %{})
      |> Map.merge(%{
        job_id: spec.job_id,
        worktree: Keyword.fetch!(opts, :worktree),
        job_dir: job_dir,
        env: plain,
        secret_names: Enum.map(secrets, fn {name, _value} -> name end)
      })

    with {:ok, context} <- slice.prepare(slice_opts), do: {:ok, slice, context}
  end

  # A slice that cannot be made is a job that cannot run: it concludes with nothing started,
  # which `ForgeCore.Job.Outcome` already reads as an error, rather than running unconfined.
  defp conclude_without_starting(state, reason) do
    Logger.error("could not make a slice for job #{state.spec.job_id}: #{inspect(reason)}")
    send(self(), :conclude)
    state
  end

  defp spawn_harness(state, opts, executable, args, plain, secrets) do
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
           wrapper(secrets, state.mode),
           "forge-job",
           Dir.prompt_path(job_dir),
           Dir.stderr_path(job_dir)
         ] ++ assignments ++ [executable | args]},
        {:cd, Keyword.fetch!(opts, :worktree)},
        {:env, Enum.map(secrets, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)}
      ])

    state = %{state | port: port}

    # The prompt is composed the same way for both modes and written to the same file; in
    # streaming mode it goes down the pipe as the first message instead of being redirected in.
    case state.mode do
      :streaming when state.hold -> state
      :streaming -> deliver(state, File.read!(Dir.prompt_path(job_dir)))
      :prompt -> state
    end
  end

  # The shell reads the prompt into stdin, sends stderr to its file, and `exec`s `env -i`
  # with only the assignments we pass as arguments plus the secrets forwarded by name from
  # its own environment. `exec` keeps the wrapper the process group leader we signal.
  #
  # **In streaming mode the prompt redirect is omitted, and that is the whole point.** `<"$prompt"`
  # replaces the port's stdin pipe with a regular file already at EOF, so a harness started that
  # way can never be written to — the pipe Erlang holds is discarded before the process starts.
  # A conversation keeps the pipe and gets its first message through `Port.command/2` like every
  # message after it, which also means there is one path for the first turn and the rest.
  defp wrapper(secrets, :prompt) do
    ~s(prompt="$1"; stderr="$2"; shift 2; exec /usr/bin/env -i #{forwarded(secrets)} "$@" <"$prompt" 2>"$stderr")
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
  defp wrapper(secrets, :streaming) do
    relay =
      ~s(while IFS= read -r line; do ) <>
        ~s([ "$line" = "#{@close_sentinel}" ] && exit 0; ) <>
        ~s(printf '%s\\n' "$line"; done)

    ~s(stderr="$2"; shift 2; ) <>
      relay <> ~s( | exec /usr/bin/env -i #{forwarded(secrets)} "$@" 2>"$stderr")
  end

  defp forwarded(secrets) do
    Enum.map_join(secrets, " ", fn {k, _} -> ~s(${#{k}+"#{k}=$#{k}"}) end)
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
    prompt = Prompt.compose(%{state.spec | prompt: text}, state.job_dir)
    File.write!(Dir.prompt_path(state.job_dir), prompt)

    case write(state, state.harness.encode_message(prompt)) do
      :ok -> {:reply, :ok, %{state | hold: false}}
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

  def handle_info(:conclude, %{result: nil} = state) do
    state =
      if state.buffer == "", do: state, else: handle_line(state.buffer, %{state | buffer: ""})

    File.close(state.transcript)
    if state.slice, do: state.slice.cleanup(state.slice_context)
    result = conclude(state)
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))

    # A conversation's owner is not blocked on `await/1` — it has been handling turns all
    # along — so the result is sent to it rather than only left for a caller that will never
    # arrive. It goes before the stop, so it is in the mailbox ahead of the exit signal.
    if state.mode == :streaming, do: notify(state, {:ended, state.spec.job_id, result})

    stop_or_hold(%{state | result: result, waiters: []}, state.waiters)
  end

  # The end is reached by more than one road — the exit status and the end of output each ask for
  # it — and a runner holding its result for a late `await/1` (`stop_or_hold/2`) is still here to
  # receive the second. The first conclusion is the one.
  def handle_info(:conclude, state), do: {:noreply, state}

  # Sent only once a result is held, so there is nothing left to wait for.
  def handle_info(:release, state), do: {:stop, :normal, state}

  def handle_info(:wall_clock, %{result: nil} = state), do: {:noreply, kill(state, :wall_clock)}
  def handle_info(:wall_clock, state), do: {:noreply, state}

  def handle_info(:force_kill, %{port: port, result: nil} = state) do
    signal(port, "KILL")
    {:noreply, state}
  end

  def handle_info(:force_kill, state), do: {:noreply, state}

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
      "finished" -> finished(state, event)
      "started" -> %{state | started_event: event}
      "rate_limit" -> %{state | rate_limit: payload}
      _ -> state
    end
  end

  # A turn ended. In prompt mode there is exactly one and this is the end of the run; in
  # streaming mode there is one per turn and the process carries on, so the count is kept and
  # the owner is told. `finished_event` holds the latest rather than the first — the run's
  # result is built from the last thing the harness said, not the first.
  defp finished(state, event) do
    state = %{state | finished_event: event, turns: state.turns + 1}

    if state.mode == :streaming do
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
    signal(port, "TERM")
    Process.send_after(self(), :force_kill, state.grace_ms)
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
      harness: harness_summary(started, finished, state.exit_status, state.rate_limit)
    }

    decide(state, spec, run, base)
  end

  # A conversation has no outcome, ever, and nothing asks it for one: there is no state to leave
  # and no transition to select. Running `Outcome.decide/2` over it would invent a `declared`
  # from the last turn's document and hand the engine something to act on — see
  # `docs/design/conversations.md` § Shape, where the guard against exactly that is described as
  # belonging at the one place jobs complete.
  defp decide(%{mode: :streaming}, _spec, _run, base), do: base

  defp decide(_state, spec, run, base) do
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
  defp harness_summary(started, finished, exit_status, rate_limit) do
    started = started || %{}
    finished = finished || %{}

    # String keys, because this is the provider's own summary and it crosses the channel as
    # JSON. An atom key here would arrive as a string key there, and the platform would read
    # nil for the cost of every job.
    %{
      "session_id" => Map.get(finished, :session_id) || Map.get(started, :session_id),
      "model" => Map.get(started, :model),
      "subtype" => Map.get(finished, :subtype),
      "is_error" => Map.get(finished, :is_error),
      "turns" => Map.get(finished, :num_turns),
      "cost_usd" => Map.get(finished, :total_cost_usd),
      "duration_ms" => Map.get(finished, :duration_ms),
      "usage" => Map.get(finished, :usage),
      "exit_status" => exit_status,
      "rate_limit" => rate_limit && window_report(rate_limit)
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
