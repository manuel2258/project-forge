defmodule ForgeWeb.WorkScreenTest do
  @moduledoc """
  The Activity stream as it is drawn (`docs/design/ui.md` § Activity): a call and its result on
  one line, a result with no call on a row of its own, notices behind their count, a page at a
  time, and a count that is what the stream draws. The three pages that hold a stream draw it
  with this; here the events are written out, so each rule is aimed at directly.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Forge.Events.Event
  alias ForgeWeb.WorkScreen

  @at ~U[2026-09-26 12:00:00Z]

  defp event(seq, type, payload),
    do: %Event{seq: seq, type: type, payload: payload, inserted_at: @at}

  defp call(seq, id, command),
    do:
      event(seq, "job.harness.tool_use", %{
        "id" => id,
        "name" => "Bash",
        "input" => %{"command" => command}
      })

  defp result(seq, id, error?, excerpt),
    do:
      event(seq, "job.harness.tool_result", %{
        "tool_use_id" => id,
        "is_error" => error?,
        "excerpt" => excerpt,
        "bytes" => byte_size(excerpt)
      })

  defp notice(seq), do: event(seq, "job.harness.notice", %{"subtype" => "thinking_tokens"})

  defp draw(events, opts \\ []) do
    render_component(&WorkScreen.activity/1,
      events: events,
      shown: Keyword.get(opts, :shown, 50),
      notices: Keyword.get(opts, :notices, false),
      heading: "Activity"
    )
    |> Floki.parse_fragment!()
  end

  defp rows(doc), do: Floki.find(doc, "#job-events > li")

  # A call's result is on its line — the mark and, for a failure, what failed — and not a row
  # that says the same thing again.
  test "draws a call's result on the call's line" do
    doc = draw([call(1, "b1", "mix test"), result(2, "b1", true, "1 failure")])

    assert [row] = rows(doc)
    assert [line] = Floki.find(row, "[data-action=bash]")
    assert Floki.text(line) =~ "✗"
    assert row |> Floki.find("[data-failure]") |> Floki.text() =~ "1 failure"
  end

  # Its call is not in the log — cut off, or never recorded — so it has nowhere else to be seen.
  test "draws a result with no call as a row of its own" do
    doc = draw([result(1, "lost", false, "ok")])

    assert [row] = rows(doc)
    assert Floki.text(row) =~ "tool_result"
  end

  test "counts what it draws: a call with its result once, no notices, a lone result" do
    events = [
      call(1, "b1", "mix test"),
      result(2, "b1", false, "ok"),
      notice(3),
      result(4, "lost", false, "ok")
    ]

    assert WorkScreen.activity_count(events) == 2
    assert events |> draw() |> rows() |> length() == 2
    assert events |> draw(notices: true) |> rows() |> length() == 3
  end

  describe "a page at a time" do
    test "offers more once there is more than a page" do
      events = for seq <- 1..51, do: event(seq, "job.harness.text", %{"text" => "#{seq}"})

      more = events |> draw() |> Floki.find(~s(button[phx-click="more"]))
      assert [_button] = more
      assert events |> draw() |> rows() |> length() == 50

      assert events |> Enum.take(50) |> draw() |> Floki.find(~s(button[phx-click="more"])) ==
               []
    end
  end
end
