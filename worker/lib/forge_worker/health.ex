defmodule ForgeWorker.Health do
  @moduledoc """
  Whether this machine can still run anything, and what to do when it cannot
  (`docs/design/worker-tier.md` § A machine whose systemd stops answering).

  **Two signals, either enough.** A run whose `systemd-run` failed on the bus says so through
  `unreachable/1`, from the runner or the command that saw it; and a probe asks PID 1 for its
  version once a minute, in a task of its own, and two failures in a row are the second signal.
  Both come from the slice, and only a slice with a systemd to ask has either:
  `Slice.Direct` answers `:none` to the probe and never reports a bus error.

  **Once unhealthy, always unhealthy, until the worker restarts.** The machine's log gets
  `machine.unhealthy`, the link is told — it stops the jobs, says so to the platform, and puts it
  in every join from then on — and the platform's answer comes back through `answered/1`. A
  reboot needs two keys: the platform's yes, and this machine being one a driver made
  (`ForgeWorker.Config.managed?/0`). Nothing here ever reboots a machine its owner provisioned.

  The probe and the reboot are functions the start options may replace, so that no test ever
  asks a real PID 1 anything, and none reboots the machine running it.
  """

  use GenServer

  alias ForgeWorker.{Config, Log}

  require Logger

  @probe_ms :timer.minutes(1)
  # Longer than the probe's own `timeout -k 5 10`, so the task is only ever a backstop for a
  # `timeout` that did not do its job.
  @probe_deadline_ms :timer.seconds(20)

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The health process this worker asks: the one the application starts, unless configured — which
  is how a test stands one of its own in, with a probe and a reboot it controls.
  """
  @spec server() :: GenServer.server()
  def server, do: Application.get_env(:forge_worker, :health, __MODULE__)

  @doc """
  A run's `systemd-run` could not reach PID 1: the machine is unhealthy now. Synchronous, so the
  caller's own report — which the link will then withhold — cannot overtake it. A machine with no
  health process running (a shell) is told nothing, and says so in its journal.
  """
  @spec unreachable(String.t(), GenServer.server()) :: :ok
  def unreachable(reason, server \\ server()) do
    GenServer.call(server, {:unhealthy, reason})
  catch
    :exit, _not_running ->
      Logger.error(
        "PID 1 did not answer, and nothing is watching this machine's health: #{reason}"
      )

      :ok
  end

  @doc "Why this machine is unhealthy, or nil while it is not."
  @spec unhealthy(GenServer.server()) :: String.t() | nil
  def unhealthy(server \\ server()) do
    GenServer.call(server, :unhealthy)
  catch
    :exit, _not_running -> nil
  end

  @doc """
  The platform's reply to `unhealthy`: `%{"reboot" => boolean, "why" => text}`, or an error when
  it would not take the message. Reboots only on a yes, and only a machine a driver made.
  """
  @spec answered(term(), GenServer.server()) :: :ok
  def answered(reply, server \\ server()), do: GenServer.cast(server, {:answered, reply})

  # -- the process ------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    slice = Keyword.get(opts, :slice) || ForgeWorker.Slice.impl()

    state = %{
      reason: nil,
      failures: 0,
      probing: nil,
      probe: Keyword.get(opts, :probe, &slice.probe/0),
      probe_ms: Keyword.get(opts, :probe_ms, setting(:health_probe_ms, @probe_ms)),
      probe_deadline_ms: Keyword.get(opts, :probe_deadline_ms, @probe_deadline_ms),
      reboot: Keyword.get(opts, :reboot, &reboot/0),
      managed: Keyword.get(opts, :managed, &Config.managed?/0),
      link: Keyword.get(opts, :link, ForgeWorker.Link)
    }

    {:ok, schedule(state)}
  end

  defp setting(key, default), do: Application.get_env(:forge_worker, key, default)

  @impl true
  def handle_call({:unhealthy, reason}, _from, state), do: {:reply, :ok, mark(state, reason)}
  def handle_call(:unhealthy, _from, state), do: {:reply, state.reason, state}

  @impl true
  def handle_cast({:answered, {:ok, %{"reboot" => true}}}, state) do
    if state.managed.() do
      Log.line(
        "machine.rebooting",
        :warning,
        "the platform said to reboot, and this is a machine it made: rebooting now"
      )

      case state.reboot.() do
        :ok ->
          :ok

        {:error, why} ->
          Log.line("machine.unrebooted", :error, "the reboot itself failed: #{why}")
      end
    else
      Log.line(
        "machine.unrebooted",
        :warning,
        "the platform said to reboot, and this machine was not made by it: its owner decides"
      )
    end

    {:noreply, state}
  end

  def handle_cast({:answered, reply}, state) do
    Log.line("machine.unrebooted", :warning, "not rebooting: #{why(reply)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(:probe, %{reason: nil, probing: nil} = state) do
    task = Task.Supervisor.async_nolink(ForgeWorker.TaskSupervisor, state.probe)
    Process.send_after(self(), {:probe_deadline, task.ref}, state.probe_deadline_ms)
    {:noreply, %{state | probing: task}}
  end

  # Unhealthy already: nothing is left to learn until the worker restarts. Not scheduling the
  # next one is an equivalent mutant — a timer that fired into this clause would ask nothing
  # either — and is kept so an unhealthy worker is not woken every minute for nothing. A probe
  # still out never meets a `:probe`: one is scheduled only once the last has answered or been
  # given up on.
  def handle_info(:probe, state), do: {:noreply, state}

  def handle_info({ref, answer}, %{probing: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> Map.put(:probing, nil) |> probed(answer) |> schedule()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probing: %Task{ref: ref}} = state) do
    answer = {:error, "the probe crashed: #{Exception.format_exit(reason)}"}
    {:noreply, state |> Map.put(:probing, nil) |> probed(answer) |> schedule()}
  end

  def handle_info({:probe_deadline, ref}, %{probing: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    answer = {:error, "the probe did not return within #{state.probe_deadline_ms}ms"}
    {:noreply, state |> Map.put(:probing, nil) |> probed(answer) |> schedule()}
  end

  def handle_info(_stale, state), do: {:noreply, state}

  # **Two in a row.** One missed answer on a loaded machine is not a wedge; two a minute apart is.
  defp probed(state, :ok), do: %{state | failures: 0}
  # A slice with nothing to ask is asked no more.
  defp probed(state, :none), do: %{state | probe_ms: nil}

  defp probed(state, {:error, why}) do
    case state.failures + 1 do
      1 ->
        Logger.warning("PID 1 did not answer the probe: #{why}; asking again")
        %{state | failures: 1}

      _twice ->
        mark(%{state | failures: 0}, "PID 1 did not answer twice in a row: #{why}")
    end
  end

  defp mark(%{reason: nil} = state, reason) do
    Log.line(
      "machine.unhealthy",
      :error,
      "#{reason}. It has stopped its jobs and takes no more; the platform requeues them"
    )

    if pid = GenServer.whereis(state.link), do: send(pid, {:unhealthy, reason})
    %{state | reason: reason}
  end

  # Said once: the first reason is the one that stopped the machine.
  defp mark(state, _reason), do: state

  defp schedule(%{probe_ms: nil} = state), do: state

  defp schedule(state) do
    Process.send_after(self(), :probe, state.probe_ms)
    state
  end

  defp why({:ok, %{"why" => why}}) when is_binary(why), do: why
  defp why({:ok, _reply}), do: "the platform said not to"
  defp why({:error, reply}), do: "the platform would not take the report: #{inspect(reply)}"
  defp why(reply), do: inspect(reply)

  @doc """
  Reboots the machine without asking PID 1: with `--force` twice, `systemctl` syncs and calls
  `reboot(2)` itself (`docs/design/worker-tier.md` § What happens then). Never called by the test
  suite; `nix/worker-health.nix` calls it on a machine whose PID 1 is wedged, and it reboots. With
  one `--force` it did not, which by `systemctl(1)` still has the service manager do it.
  """
  @spec reboot() :: :ok | {:error, String.t()}
  def reboot do
    case System.cmd("systemctl", ["--force", "--force", "reboot"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "systemctl exited #{code}: #{String.trim(out)}"}
    end
  end
end
