defmodule ForgeWorker.Update do
  @moduledoc """
  A permanent machine bringing itself up to the platform's worker
  (`docs/design/worker-tier.md` § Updating a permanent machine).

  **The platform says what to update to; this decides when and does it**, through a root-only
  script in the image (`nix/system-update.sh`) that does what only root may. The steps: space,
  download and check, install beside the running system, check the target again, pause the work,
  arm a trial boot entry and reboot; on the new system, keep it once the platform has accepted
  its worker.

  **It never calls the link, and the link never calls it**: both send casts and messages, and
  the join payload reads this process's state from a `:persistent_term` (`snapshot/0`) it writes.
  A call either way would deadlock the first time each waited on the other. **Nor does it need the
  link to exist**: it is started before the link and settles what the last boot left at once, and a machine
  with no platform configured never starts a link, so a message to a link nobody holds is dropped
  (`tell_link/2`) and the join payload carries the snapshot it has already published.

  Messages to the link: `{:update_pause, requested_by}` (take no work, hibernate what runs, end
  chats after their turn), `:update_resume`, and `{:update_report, snapshot}` (pushed to the
  platform as `update`). What the link sends here: `told/3` (the platform's word: a target or
  nothing), `link_down/1`, `accepted/1` and `drained/1`.

  **Retries and the rules about them are `ForgeWorker.Update.State`**; the limits are
  `ForgeCore.WorkerUpdate`'s, shared with the platform.
  """

  use GenServer

  alias ForgeCore.WorkerUpdate
  alias ForgeWorker.{Config, Log}
  alias ForgeWorker.Update.State

  require Logger

  @snapshot {__MODULE__, :snapshot}

  # -- the other processes' side ----------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The platform's word on what this machine should be running: a target map, or nil — *stand down*.
  `source: :join` is the reply to a join, accepted or refused; a message with `requested_by` is
  the owner pressing *Update now*, and one without it is the owner flipping the switch.
  """
  @spec told(term(), keyword(), GenServer.server()) :: :ok
  def told(target, opts \\ [], server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, {:told, target, opts})
    :ok
  end

  @doc "The channel is down: a target seen before is no longer known to be the platform's."
  @spec link_down(GenServer.server()) :: :ok
  def link_down(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :link_down)
    :ok
  end

  @doc "The platform accepted this machine's join: a system on trial may be kept."
  @spec accepted(GenServer.server()) :: :ok
  def accepted(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :accepted)
    :ok
  end

  @doc "Nothing is running here and nothing is waiting to be acknowledged: it may restart."
  @spec drained(GenServer.server()) :: :ok
  def drained(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :drained)
    :ok
  end

  @doc "What the join payload says of the update: a map of known keys, empty when there is nothing."
  @spec snapshot() :: map()
  def snapshot, do: :persistent_term.get(@snapshot, %{})

  # -- the process ------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, Config.update_dir())

    state = %{
      dir: dir,
      script: Keyword.get(opts, :script, Config.update_script()),
      run: Keyword.get(opts, :run),
      own_build: Keyword.get(opts, :own_build, &ForgeWorker.Link.build/0),
      version: Keyword.get(opts, :version, &version/0),
      reboot: Keyword.get(opts, :reboot, &reboot/0),
      running: Keyword.get(opts, :running, &running_system/0),
      layout: Keyword.get(opts, :layout, Config.update_layout()),
      link: Keyword.get(opts, :link, ForgeWorker.Link),
      now: Keyword.get(opts, :now, fn -> System.os_time(:millisecond) end),
      pause_ms: Keyword.get(opts, :pause_ms, setting(:update_pause_ms, WorkerUpdate.pause_ms())),
      st: load_state(dir),
      target: nil,
      automatic: false,
      requested_by: nil,
      fresh: false,
      phase: :idle,
      attempt: nil,
      trial: nil,
      retry_timer: nil,
      pause_timer: nil,
      unable_logged: false,
      base: %{}
    }

    state = state |> put_unable() |> publish(%{})
    {:ok, state, {:continue, :settle}}
  end

  defp setting(key, default), do: Application.get_env(:forge_worker, key, default)

  # What the previous boot left: the result of a fallback, a trial this very system is on, or an
  # attempt that was cut off.
  @impl true
  def handle_continue(:settle, state) do
    state = settle(state)
    {:noreply, state}
  end

  defp settle(state) do
    state
    |> consume_trial()
    |> consume_result()
    |> consume_interrupted()
  end

  defp consume_trial(state) do
    case read_kv(Path.join(state.dir, "trial")) do
      %{"system" => system} = trial ->
        if state.running.() == system do
          report(%{state | phase: :trial, trial: trial}, %{
            "step" => "trying",
            "target_build" => trial["build"]
          })
        else
          # The new system never came up and the firmware went back by itself (boot counting), or
          # the machine was reset by hand: the script clears the trial and says why.
          reason = "the new system did not come up, and the machine is back on the one it left"
          _ = run(state, ["fallback", reason])
          state
        end

      _none ->
        state
    end
  end

  defp consume_result(state) do
    path = Path.join(state.dir, "result")

    case read_kv(path) do
      %{"outcome" => "fell_back"} = result ->
        File.rm(path)
        reason = result["reason"] || "the new system was not accepted"
        build = result["build"] || state.st.target_build
        {st, outcome} = State.failure(for_build(state.st, build), "trying", reason, state.now.())
        state = persist(%{state | st: st, phase: :idle, trial: nil})

        Log.line(
          "update.reverted",
          :error,
          "went back to the previous system: " <> reason <> next_try(st, outcome)
        )

        report(state, failure_report("fell_back", "trying", reason, st, outcome))

      _none ->
        state
    end
  end

  defp consume_interrupted(%{phase: :idle, st: st} = state) do
    case State.interrupted(st, state.now.()) do
      :nothing ->
        state

      {after_it, outcome} ->
        reason = "the worker stopped while it was updating"
        state = persist(%{state | st: after_it})
        Log.line("update.failed", :error, "failed: " <> reason <> next_try(after_it, outcome))
        report(state, failure_report("failed", st.phase, reason, after_it, outcome))
    end
  end

  defp consume_interrupted(state), do: state

  defp for_build(st, nil), do: st
  defp for_build(st, build), do: State.for_target(st, build)

  # -- what the platform says -------------------------------------------------------------------

  @impl true
  def handle_cast({:told, raw, opts}, state) do
    target = target(raw)
    requested_by = if is_binary(opts[:requested_by]), do: opts[:requested_by]

    state = %{
      state
      | target: target,
        # An owner's button is not a change of the switch: the platform's latest word about the
        # switch is the join reply or a message that is not a request.
        automatic: if(requested_by, do: state.automatic, else: target != nil),
        requested_by: requested_by || state.requested_by,
        fresh: true
    }

    st = if target, do: State.for_target(state.st, target.build), else: state.st
    st = if requested_by && target, do: State.requested(st), else: st
    state = persist(%{state | st: st})

    {:noreply, route(state, requested_by != nil)}
  end

  def handle_cast(:link_down, state), do: {:noreply, %{state | fresh: false}}

  def handle_cast(:accepted, %{phase: :trial, trial: trial} = state) do
    if state.own_build.() == trial["build"],
      do: {:noreply, keep(state)},
      else: {:noreply, state}
  end

  def handle_cast(:accepted, state), do: {:noreply, state}

  def handle_cast(:drained, %{phase: :pausing} = state), do: {:noreply, arm(state)}
  def handle_cast(:drained, state), do: {:noreply, state}

  defp target(nil), do: nil

  defp target(raw) do
    case WorkerUpdate.target(raw) do
      {:ok, target} -> Map.new(target, fn {key, value} -> {String.to_atom(key), value} end)
      :error -> nil
    end
  end

  # What a new word does to whatever is going on.
  defp route(%{phase: phase} = state, requested?) when phase in [:idle, :failed] do
    state |> cancel_retry() |> decide(requested?)
  end

  # An attempt is in flight; the target it was started on is compared when it is done.
  defp route(%{phase: :attempt} = state, _requested?), do: state
  # Installed, and waiting for a target seen on a link that has joined since.
  defp route(%{phase: :waiting} = state, _requested?), do: after_install(state)
  # Past the point of starting over: the attempt runs to its end.
  defp route(state, _requested?), do: state

  defp decide(state, requested?) do
    target = state.target

    # **Who pressed the button is who started *that* attempt.** A retry, a switch turned on or a new
    # build is automatic, and the log must not name a person for what they did not do.
    state = if requested?, do: state, else: %{state | requested_by: nil}

    decision =
      State.decide(state.st, %{
        build: target && target.build,
        own: state.own_build.(),
        now: state.now.(),
        automatic: state.automatic,
        requested: requested?
      })

    case {decision, unable(state)} do
      {:idle, _unable} ->
        state

      {{:wait, at}, _unable} ->
        %{state | retry_timer: Process.send_after(self(), :retry, max(at - state.now.(), 0))}

      {:start, nil} ->
        start_attempt(state)

      {:start, reason} ->
        unable_line(state, reason)
    end
  end

  defp unable_line(%{unable_logged: true} = state, _reason), do: state

  defp unable_line(state, reason) do
    Log.line("update.unable", :warning, "cannot update itself: " <> unable_text(reason))
    %{state | unable_logged: true}
  end

  defp unable_text("layout"),
    do: "its boot partition holds one system; reinstall it once from the current image"

  defp unable_text("not_an_image"), do: "this worker does not run on the forge image"

  # Why this machine cannot update at all, as a code the page turns into a sentence, or nil.
  defp unable(state) do
    cond do
      is_nil(state.script) -> "not_an_image"
      layout(state.layout) != "2" -> "layout"
      true -> nil
    end
  end

  defp layout(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      {:error, _reason} -> nil
    end
  end

  defp put_unable(state) do
    base = if reason = unable(state), do: %{"unable" => reason}, else: %{}
    %{state | base: base}
  end

  @impl true
  def handle_info(:retry, state), do: {:noreply, decide(%{state | retry_timer: nil}, false)}

  def handle_info(:pause_timeout, %{phase: :pausing} = state) do
    Log.line(
      "update.paused",
      :warning,
      "some work had not stopped after #{div(state.pause_ms, 60_000)} minutes; restarting anyway"
    )

    {:noreply, arm(state)}
  end

  def handle_info(:pause_timeout, state), do: {:noreply, state}

  def handle_info({ref, result}, %{attempt: %{ref: ref} = attempt} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | attempt: nil}

    case result do
      :ok -> {:noreply, installed(state, attempt)}
      {:error, step, reason} -> {:noreply, fail(state, step, reason)}
    end
  end

  def handle_info({:step, token, step}, %{attempt: %{token: token}} = state) do
    {:noreply, report(state, %{"step" => step, "target_build" => state.attempt.target.build})}
  end

  def handle_info({:DOWN, ref, :process, _pid, why}, %{attempt: %{ref: ref}} = state) do
    {:noreply, fail(%{state | attempt: nil}, "installing", "the update stopped: #{inspect(why)}")}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- one attempt ------------------------------------------------------------------------------

  defp start_attempt(state) do
    target = state.target
    how = if state.requested_by, do: "pressed by #{state.requested_by}", else: "automatic"

    Log.line(
      "update.started",
      :info,
      "updating to #{target.version} (#{how}), attempt #{state.st.failures + 1} of #{WorkerUpdate.tries()}"
    )

    me = self()
    token = make_ref()
    run = fn args -> run(state, args) end

    task =
      Task.Supervisor.async_nolink(ForgeWorker.TaskSupervisor, fn ->
        steps(run, target, me, token)
      end)

    st = state.st |> State.started()

    %{state | st: st, phase: :attempt, attempt: %{ref: task.ref, token: token, target: target}}
    |> persist()
    |> report(%{
      "step" => "downloading",
      "target_build" => target.build,
      "automatic" => state.requested_by == nil
    })
  end

  # Runs in a task. The first two commands are the download: the room for it, then the download
  # and every check on it. Only then the install, which is what the platform is told next.
  defp steps(run, target, me, token) do
    with {:ok, _out} <- tag("downloading", space(run, target)),
         {:ok, _out} <-
           tag(
             "downloading",
             run.([
               "fetch",
               target.repository,
               target.version,
               target.digest,
               target.raw_sha256,
               to_string(target.raw_size)
             ])
           ),
         :ok <- downloaded(target, me, token),
         {:ok, _out} <- tag("installing", run.(["install", target.build])) do
      :ok
    end
  end

  # The room for it. A collection of the Nix store the script had to run says how much it freed,
  # and that is a cleanup like the others for the disk report — **the only one of the store's the
  # worker sees** (Nix's own `min-free` collection happens inside its daemon).
  defp space(run, target) do
    case run.(["space", to_string(target.raw_size)]) do
      {:ok, out} = ok ->
        case Regex.run(~r/forge-update: collected (\d+)/, out) do
          [_all, bytes] -> ForgeWorker.Disk.cleaned("nix_store", String.to_integer(bytes))
          nil -> :ok
        end

        ok

      other ->
        other
    end
  end

  defp downloaded(target, me, token) do
    Log.line(
      "update.downloaded",
      :info,
      "downloaded #{target.version} and checked its size and checksum"
    )

    send(me, {:step, token, "installing"})
    :ok
  end

  defp tag(_step, {:ok, out}), do: {:ok, out}
  defp tag(step, {:error, why}), do: {:error, step, why}

  defp installed(state, attempt) do
    Log.line(
      "update.installed",
      :info,
      "installed #{attempt.target.version} beside the running system"
    )

    state = %{state | phase: :after_install, attempt: attempt}
    after_install(state)
  end

  # **Checked again before any work is paused** (criterion 5): the build the platform names now,
  # on a link that has joined since.
  defp after_install(%{attempt: attempt} = state) do
    cond do
      is_nil(state.target) ->
        discard(state, "the platform no longer asks for an update")

      state.target.build != attempt.target.build ->
        discard(
          state,
          "the platform's build moved to #{state.target.version} while this was installing"
        )

      not state.fresh ->
        %{state | phase: :waiting}

      true ->
        pause(state)
    end
  end

  defp discard(state, why) do
    _ = run(state, ["discard"])
    Log.line("update.discarded", :info, "dropped the new system: " <> why)

    st = %{state.st | phase: "idle"}
    state = persist(%{state | st: st, attempt: nil, phase: :idle})
    state = if state.target, do: decide(state, false), else: state

    # **Nothing is under way unless that began a new attempt**, and the row must say so: the last
    # report was `installing`, which the platform counts as under way and which every later join
    # would repeat, so the row would read *updating* and offer no *Update now* until a restart.
    # The reason is in the log line above.
    if state.phase == :idle, do: report(state, %{}), else: state
  end

  defp pause(%{attempt: attempt} = state) do
    st = State.phase(state.st, "pausing")
    timer = Process.send_after(self(), :pause_timeout, state.pause_ms)

    # **Not reported from here**: the link says `pausing` itself, with the ids it will hibernate,
    # and a second report from here would overwrite them on the platform's row. This only keeps
    # the join payload's snapshot.
    publish(
      state,
      Map.merge(state.base, %{"step" => "pausing", "target_build" => attempt.target.build})
    )

    # Said to the link last: it is what makes the link push `pausing`, with the ids.
    tell_link(state, {:update_pause, state.requested_by})

    %{state | phase: :pausing, st: st, pause_timer: timer}
    |> persist()
  end

  defp arm(%{attempt: attempt} = state) do
    if state.pause_timer, do: Process.cancel_timer(state.pause_timer)
    state = %{state | pause_timer: nil}

    case run(state, ["arm", attempt.target.build]) do
      {:ok, _out} -> restart(state, attempt)
      {:error, why} -> arm_failed(state, why)
    end
  end

  defp restart(state, attempt) do
    st = State.phase(state.st, "restarting")
    Log.line("update.restarting", :info, "restarting into #{attempt.target.version}, on trial")

    state =
      %{state | phase: :restarting, st: st}
      |> persist()
      |> report(%{"step" => "restarting", "target_build" => attempt.target.build})

    case state.reboot.() do
      :ok ->
        state

      {:error, why} ->
        # The trial entry is armed and the machine did not go: take it back out, or the next
        # reboot, whenever it comes, would be into a system nobody is waiting for.
        _ = run(state, ["fallback", "the reboot failed: #{why}"])
        File.rm(Path.join(state.dir, "result"))
        arm_failed(state, "the reboot failed: #{why}")
    end
  end

  defp arm_failed(state, why) do
    resume(state)
    fail(state, "restarting", why)
  end

  defp resume(state), do: tell_link(state, :update_resume)

  # -- the new system, on trial -----------------------------------------------------------------

  defp keep(%{trial: trial} = state) do
    case run(state, ["keep"]) do
      {:ok, _out} ->
        Log.line(
          "update.kept",
          :info,
          "kept #{trial["build"]}: the platform accepted it, and the previous system is the fallback"
        )

        %{state | phase: :idle, trial: nil, st: State.reached(state.st)}
        |> persist()
        |> report(%{"step" => "kept", "target_build" => trial["build"]})

      {:error, why} ->
        # The trial stays, and so does the timer that will take the machine back.
        Log.line("update.failed", :error, "could not keep the new system: " <> why)
        state
    end
  end

  # -- failing ----------------------------------------------------------------------------------

  defp fail(state, step, reason) do
    _ = run(state, ["discard"])
    {st, outcome} = State.failure(state.st, step, reason, state.now.())
    state = persist(%{state | st: st, phase: :idle, attempt: nil})

    case outcome do
      :gave_up ->
        Log.line("update.failed", :error, "failed while #{step}: #{reason}")

        Log.line(
          "update.stopped",
          :error,
          "stopped trying after #{WorkerUpdate.tries()} failures; it waits for a new build or its owner"
        )

      {:retry, _at} ->
        Log.line(
          "update.failed",
          :error,
          "failed while #{step}: #{reason}" <> next_try(st, outcome)
        )
    end

    state = report(state, failure_report("failed", step, reason, st, outcome))

    case outcome do
      {:retry, at} when state.automatic ->
        %{state | retry_timer: Process.send_after(self(), :retry, max(at - state.now.(), 0))}

      _other ->
        state
    end
  end

  defp failure_report(step, failed_step, reason, st, outcome) do
    base = %{
      "step" => step,
      "failed_step" => failed_step,
      "reason" => reason,
      "attempt" => st.failures
    }

    case outcome do
      {:retry, at} -> Map.merge(base, %{"next_at" => at, "attempt" => st.failures + 1})
      :gave_up -> Map.put(base, "step", "gave_up")
    end
  end

  defp next_try(_st, :gave_up), do: "; stopped after #{WorkerUpdate.tries()} tries"

  defp next_try(st, {:retry, at}) do
    time = at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M")
    "; tries again at #{time} UTC (#{st.failures + 1} of #{WorkerUpdate.tries()})"
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(%{retry_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | retry_timer: nil}
  end

  # -- reporting and keeping --------------------------------------------------------------------

  # What the platform and the join payload are told: cleaned by the same module the platform reads
  # it with, kept for the join and sent to the link for the platform's `update` message.
  defp report(state, fields) do
    snapshot =
      state.base
      |> Map.merge(fields)
      |> Map.put("at", state.now.())
      |> then(
        &WorkerUpdate.normalise(Map.put_new(&1, "target_version", target_version(state, &1)))
      )

    publish(state, snapshot)
    tell_link(state, {:update_report, snapshot})
    state
  end

  # **The link may not be there**: it is started after this process, which settles what the last
  # boot left as soon as it starts, and on a machine with no platform configured it is never
  # started. A `send/2` to a name nobody holds raises, and that crashed this process four times
  # over until the application went down. Nothing is lost by skipping the message: the snapshot is
  # already published, and the join payload carries it (`snapshot/0`).
  defp tell_link(%{link: link}, message) do
    case GenServer.whereis(link) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end

  defp target_version(%{attempt: %{target: %{version: version}}}, _fields), do: version
  defp target_version(%{target: %{version: version}}, _fields), do: version
  defp target_version(_state, _fields), do: nil

  defp publish(state, snapshot) do
    :persistent_term.put(@snapshot, Map.merge(state.base, snapshot))
    state
  end

  defp load_state(dir) do
    with {:ok, text} <- File.read(Path.join(dir, "state.json")),
         {:ok, raw} <- Jason.decode(text) do
      State.load(raw)
    else
      _unreadable -> State.new()
    end
  end

  defp persist(state) do
    File.mkdir_p(state.dir)
    path = Path.join(state.dir, "state.json")

    # Written beside and renamed over, so a stop between the two leaves the old state and never an
    # empty file that reads as a machine that has tried nothing.
    with :ok <- File.write(path <> ".new", Jason.encode!(State.dump(state.st))),
         do: File.rename(path <> ".new", path)

    state
  end

  defp read_kv(path) do
    case File.read(path) do
      {:ok, text} -> text |> String.split("\n", trim: true) |> Enum.flat_map(&pair/1) |> Map.new()
      {:error, _reason} -> %{}
    end
  end

  defp pair(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> [{key, value}]
      _other -> []
    end
  end

  # -- the script -------------------------------------------------------------------------------

  # `{:ok, output}`, or `{:error, why}` with the last line the script printed, which names the
  # refusal (`forge-update: <code>: <why>`).
  defp run(%{run: run}, args) when is_function(run, 1), do: run.(args)

  defp run(%{script: nil}, _args), do: {:error, "this worker does not run on the forge image"}

  defp run(%{script: script}, args) do
    case System.cmd(script, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _status} -> {:error, reason(out)}
    end
  rescue
    error in ErlangError -> {:error, "could not run #{script}: #{inspect(error.original)}"}
  end

  defp reason(out) do
    line = out |> String.split("\n", trim: true) |> List.last() || "the update script failed"

    case Regex.run(~r/^forge-update: [a-z_]+: (.*)$/, line) do
      [_all, why] -> why
      nil -> String.slice(line, 0, 300)
    end
  end

  defp reboot do
    case System.cmd("systemctl", ["reboot"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, _status} -> {:error, String.trim(out)}
    end
  rescue
    error in ErlangError -> {:error, inspect(error.original)}
  end

  defp running_system do
    case File.read_link(Config.running_system()) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp version, do: to_string(Application.spec(:forge_worker, :vsn))
end
