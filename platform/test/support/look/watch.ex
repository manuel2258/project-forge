defmodule Forge.Look.Watch do
  @moduledoc """
  What the browser cannot report: the server's side of a look (`docs/design/look.md` § What fails
  a step).

  A LiveView that raises in `mount` shows the browser a reconnecting page, not an error, and a 500
  is a page that looks like any page. So the platform is listened to as well: a status of 500 or
  more at the endpoint, an exception in a LiveView's `mount`, `handle_params` or `handle_event`
  (or a component's), and any error-level log report — which is what a crashed LiveView process
  makes. The runner drains the list after each step and fails the step naming what happened.

  Global by nature (telemetry and the logger are), held in one named ETS table the attaching
  process owns.
  """

  @table __MODULE__
  @telemetry_id "forge-look-watch"
  @logger_id :forge_look_watch
  @exceptions [
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_component, :handle_event, :exception]
  ]

  @doc "Start listening. Idempotent for the owner; detach when the look ends."
  @spec attach() :: :ok
  def attach do
    detach()
    :ets.new(@table, [:named_table, :public, :duplicate_bag])

    :telemetry.attach(
      @telemetry_id <> "-stop",
      [:phoenix, :endpoint, :stop],
      &__MODULE__.handle_stop/4,
      nil
    )

    :telemetry.attach_many(
      @telemetry_id <> "-exception",
      @exceptions,
      &__MODULE__.handle_exception/4,
      nil
    )

    _ = :logger.add_handler(@logger_id, __MODULE__, %{level: :error})
    :ok
  end

  @doc "Stop listening and drop what was recorded."
  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@telemetry_id <> "-stop")
    :telemetry.detach(@telemetry_id <> "-exception")
    _ = :logger.remove_handler(@logger_id)
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    :ok
  end

  @doc "What has happened since the last drain, oldest first, and forget it."
  @spec drain() :: [String.t()]
  def drain do
    if :ets.whereis(@table) == :undefined do
      []
    else
      events = @table |> :ets.tab2list() |> Enum.sort() |> Enum.map(fn {_, text} -> text end)
      :ets.delete_all_objects(@table)
      events
    end
  end

  @doc false
  def handle_stop(_event, _measurements, %{conn: %{status: status} = conn}, _config)
      when is_integer(status) and status >= 500 do
    record("the server answered #{status} for #{conn.method} #{conn.request_path}")
  end

  def handle_stop(_event, _measurements, _metadata, _config), do: :ok

  # A miss is an answer, not a crash: a page that raises `Ecto.NoResultsError` for a row it cannot
  # see renders the not-found page (`ui.md` § Not found), which a look photographs. Whatever has a
  # status under 500 is the platform answering; the endpoint's status still records a 500.
  @doc false
  def handle_exception(event, _measurements, metadata, _config) do
    if answer?(metadata), do: :ok, else: exception(event, metadata)
  end

  defp answer?(%{kind: :error, reason: reason}) when is_exception(reason),
    do: Plug.Exception.status(reason) < 500

  defp answer?(_metadata), do: false

  defp exception(event, metadata) do
    callback = event |> Enum.slice(1..-2//1) |> Enum.map_join(" ", &to_string/1)
    reason = metadata |> Map.get(:reason, Map.get(metadata, :kind, :error)) |> inspect(limit: 5)
    record("#{callback} raised: #{String.slice(reason, 0, 300)}")
  end

  # The `:logger` handler callback.
  @doc false
  def log(%{msg: msg}, _config), do: record("error logged: " <> format(msg))

  defp format({:string, text}), do: text |> IO.chardata_to_string() |> clip()
  defp format({:report, report}), do: report |> inspect(limit: 8) |> clip()
  defp format({fmt, args}), do: fmt |> :io_lib.format(args) |> IO.chardata_to_string() |> clip()
  defp clip(text), do: String.slice(text, 0, 300)

  defp record(text) do
    if :ets.whereis(@table) != :undefined,
      do: :ets.insert(@table, {System.unique_integer([:monotonic]), text})

    :ok
  end
end
