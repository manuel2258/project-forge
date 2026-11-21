defmodule Forge.Events.Retention.Sweeper do
  @moduledoc """
  Runs `Forge.Events.Retention.sweep/1` once a day, the first time ten minutes after boot (`first_after_ms`) so that
  a deploy does not sweep before it is serving. It runs where the scheduler does and is off in the
  suite, which calls the function.
  """

  use GenServer

  require Logger

  alias Forge.Events.Retention

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, Retention.first_after_ms())
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Retention.sweep() do
      {0, 0} -> :ok
      {rows, jobs} -> Logger.info("events: swept #{rows} harness events of #{jobs} job(s)")
    end

    schedule()
    {:noreply, state}
  rescue
    error ->
      Logger.error("events: sweep failed: #{Exception.message(error)}")
      schedule()
      {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, Retention.every_ms())
end
