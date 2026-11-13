defmodule Forge.ImageBuilds.Runner do
  @moduledoc """
  Carries running image builds forward (`Forge.ImageBuilds`), ticking every ten seconds while any
  is running and sleeping when none is. Started next to the scheduler, so it runs where jobs run.

  **A restart picks up the rows still running** in `init/1`, so a platform stopped mid-build
  carries on rather than leaving a builder to be found by the sweep alone.
  """

  use GenServer

  alias Forge.ImageBuilds

  @tick_ms 10_000

  @doc "How often a running build is looked at, in milliseconds; the page that draws it asks as often."
  @spec tick_ms() :: pos_integer()
  def tick_ms, do: @tick_ms

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Wakes the runner now, because a build was just started. Nothing if it is not running."
  @spec poke() :: :ok
  def poke do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, :tick)
    end

    :ok
  end

  @impl GenServer
  def init(_opts) do
    send(self(), :tick)
    {:ok, %{timer: nil}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    timer =
      case ImageBuilds.advance_all() do
        0 -> nil
        _running -> Process.send_after(self(), :tick, @tick_ms)
      end

    {:noreply, %{state | timer: timer}}
  end
end
