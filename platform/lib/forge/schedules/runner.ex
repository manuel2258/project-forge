defmodule Forge.Schedules.Runner do
  @moduledoc """
  Fires the schedules that have come due (`docs/design/schedules.md` § Firing), polling every
  `:schedule_poll_ms` (30 seconds by default) and doing one pass at a time, in a task so that a
  slow repository or a raising project cannot take the runner down with it.

  Started beside the job scheduler, so it runs where jobs run and never in the tests, which drive
  `Forge.Schedules.tick/2` with a clock of their own.

  **Nothing is kept between passes but a cache of parsed workflow files, per project and head**
  (`Forge.Schedules.read_types/1`): the cursor that says what has fired is in the database, so a
  restart at any moment fires neither twice nor never.
  """

  use GenServer

  require Logger

  @default_poll_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "How often a pass runs, in milliseconds."
  @spec poll_ms() :: pos_integer()
  def poll_ms, do: Application.get_env(:forge, :schedule_poll_ms, @default_poll_ms)

  @impl GenServer
  def init(_opts) do
    Forge.Schedules.create_cache()
    send(self(), :tick)
    {:ok, %{task: nil}}
  end

  @impl GenServer
  def handle_info(:tick, %{task: nil} = state) do
    task = Task.Supervisor.async_nolink(Forge.TaskSupervisor, fn -> Forge.Schedules.tick() end)
    {:noreply, %{state | task: task}}
  end

  # A pass still running when the next is due: the next waits for it, one tick at a time.
  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({ref, _done}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.send_after(self(), :tick, poll_ms())
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("a pass over the schedules stopped: #{inspect(reason)}")
    Process.send_after(self(), :tick, poll_ms())
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
