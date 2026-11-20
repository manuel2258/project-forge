defmodule Forge.Attachments.Sweeper do
  @moduledoc """
  Hourly, deletes staged uploads nobody sent and the bytes of withdrawn versions a delete after the
  commit missed (`Forge.Attachments.sweep/1`, `docs/design/attachments.md` § Staging, claiming and
  the sweep). It runs where the scheduler does and is off in the suite, which calls the function.
  """

  use GenServer

  require Logger

  @interval :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    case Forge.Attachments.sweep() do
      {0, 0} ->
        :ok

      {staged, withdrawn} ->
        Logger.info("attachments: swept #{staged} staged, #{withdrawn} withdrawn")
    end

    schedule()
    {:noreply, state}
  rescue
    error ->
      Logger.error("attachments: sweep failed: #{Exception.message(error)}")
      schedule()
      {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :sweep, @interval)
end
