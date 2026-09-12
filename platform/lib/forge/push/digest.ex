defmodule Forge.Push.Digest do
  @moduledoc "Sends the queue digest once a day at the configured UTC hour."

  use GenServer

  alias Forge.Push

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    hour = Keyword.get(opts, :hour_utc, 9)
    schedule(hour)
    {:ok, %{hour: hour, last_sent_on: nil}}
  end

  @impl true
  # Once per day, however the clock behaves around the tick.
  def handle_info(:digest, %{hour: hour, last_sent_on: last} = state) do
    today = Date.utc_today()
    if today != last, do: Push.digest()
    schedule(hour)
    {:noreply, %{state | last_sent_on: today}}
  end

  # Milliseconds until the next occurrence of `hour`:00 UTC.
  defp schedule(hour) do
    now = DateTime.utc_now()
    today = %{now | hour: hour, minute: 0, second: 0, microsecond: {0, 0}}
    next = if DateTime.compare(today, now) == :gt, do: today, else: DateTime.add(today, 1, :day)
    Process.send_after(self(), :digest, DateTime.diff(next, now, :millisecond))
  end
end
