defmodule Forge.Look.WatchTest do
  # Sync: telemetry handlers and the logger are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Forge.Look.Watch

  setup do
    Watch.attach()
    on_exit(&Watch.detach/0)
  end

  defp stop(status) do
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{
      conn: %Plug.Conn{status: status, method: "GET", request_path: "/boom"}
    })
  end

  test "a server error is recorded and a success is not" do
    stop(200)
    stop(404)
    assert Watch.drain() == []
    stop(500)
    assert [text] = Watch.drain()
    assert text =~ "answered 500 for GET /boom"
  end

  test "an exception in a live view callback is recorded, whichever callback" do
    for callback <- [:mount, :handle_params, :handle_event] do
      :telemetry.execute([:phoenix, :live_view, callback, :exception], %{duration: 1}, %{
        kind: :error,
        reason: %RuntimeError{message: "nope"}
      })
    end

    assert [mount, params, event] = Watch.drain()
    assert mount =~ "live_view mount raised"
    assert params =~ "handle_params raised"
    assert event =~ "handle_event raised"
    assert mount =~ "nope"
  end

  # The not-found page is what a miss renders (`ui.md` § Not found): a LiveView that cannot see a
  # row raises with a 404 status, which is the platform answering and no crash.
  test "a miss raised in a live view is an answer, not a failure" do
    for reason <- [%Ecto.NoResultsError{message: "none"}, %ForgeWeb.NotAllowed{}] do
      :telemetry.execute([:phoenix, :live_view, :mount, :exception], %{duration: 1}, %{
        kind: :error,
        reason: reason
      })
    end

    assert Watch.drain() == []
  end

  test "an error-level log is recorded and a warning is not" do
    capture_log(fn ->
      require Logger
      Logger.warning("just a warning")
      Logger.error("a live view crashed")
    end)

    assert [text] = Watch.drain()
    assert text =~ "error logged: a live view crashed"
  end

  test "draining forgets, and a detached watch hears nothing" do
    stop(500)
    assert length(Watch.drain()) == 1
    assert Watch.drain() == []
    Watch.detach()
    stop(500)
    assert Watch.drain() == []
  end
end
