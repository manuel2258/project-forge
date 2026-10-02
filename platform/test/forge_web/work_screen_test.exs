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

  defp classes(node), do: node |> Floki.attribute("class") |> Enum.join(" ") |> String.split()

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

  # `docs/design/ui.md` § Activity: a row wraps rather than truncating, and past 200 characters
  # shows its first 200 and opens the whole in place. The whole is in the page, so the closed
  # control's text and the open body are both read here without a click.
  describe "a long line" do
    test "is wrapped, and whole when it is short" do
      doc = draw([event(1, "job.harness.text", %{"text" => "short and sweet"})])

      assert [row] = rows(doc)
      assert Floki.find(row, "[data-clipped]") == []
      assert Floki.find(row, ".truncate") |> Floki.text() =~ "text"
      refute Floki.find(row, ".truncate") |> Floki.text() =~ "short and sweet"
      assert Floki.text(row) =~ "short and sweet"

      # What wraps it: a word longer than the column breaks rather than pushing past it.
      assert [cell] = Floki.find(row, ".break-words")
      assert Floki.text(cell) =~ "short and sweet"
    end

    test "past 200 characters shows the first 200 and opens to the whole" do
      long = String.duplicate("a", 200) <> String.duplicate("b", 50)
      doc = draw([event(1, "job.harness.text", %{"text" => long})])

      assert [row] = rows(doc)
      assert [clipped] = Floki.find(row, "details[data-clipped]")

      summary = clipped |> Floki.find("summary") |> Floki.text()
      assert summary =~ String.duplicate("a", 200) <> "…"
      refute summary =~ "b"
      assert summary =~ "show all 250 characters"

      assert Floki.text(clipped) =~ long

      # Open, the preview gives way to the whole, which keeps its line breaks like the short
      # form does; without `group-open:hidden` the first 200 would be drawn twice.
      assert [preview, whole] = Floki.find(clipped, ".whitespace-pre-wrap")
      assert "group-open:hidden" in (clipped |> Floki.find("summary > span") |> hd() |> classes())
      assert Floki.text(preview) =~ "…"
      assert Floki.text(whole) == long
    end

    # Characters, not bytes: agent text is full of "—", three bytes each.
    test "counts characters, not bytes" do
      dashes = String.duplicate("—", 150)

      assert [] =
               [event(1, "job.harness.text", %{"text" => dashes})]
               |> draw()
               |> rows()
               |> Floki.find("[data-clipped]")

      long = String.duplicate("—", 250)
      doc = draw([event(1, "job.harness.text", %{"text" => long})])
      summary = doc |> rows() |> Floki.find("summary") |> Floki.text()
      assert summary =~ String.duplicate("—", 200) <> "…"
      assert summary =~ "show all 250 characters"
    end

    # `↗ url` and `? query` are plain lines, and a URL can be longer than a glance.
    test "clips a plain line as it clips a command" do
      url = "https://example.com/" <> String.duplicate("p", 300)

      doc =
        draw([
          event(1, "job.harness.tool_use", %{
            "id" => "f1",
            "name" => "WebFetch",
            "input" => %{"url" => url}
          })
        ])

      assert [clipped] = doc |> rows() |> Floki.find("[data-action=fetch] details[data-clipped]")
      assert Floki.text(clipped) =~ "↗ " <> url
    end

    test "at exactly 200 characters is whole" do
      doc = draw([event(1, "job.harness.text", %{"text" => String.duplicate("a", 200)})])
      assert doc |> rows() |> Floki.find("[data-clipped]") == []
    end

    # The box that keeps line breaks holds the text and nothing else: a command's mark inside
    # it brought the caller's indentation with it, and a newline before the ✓.
    test "keeps the text alone in the box that keeps its line breaks" do
      doc = draw([call(1, "b1", "mix test"), result(2, "b1", false, "ok")])
      assert [line] = doc |> rows() |> Floki.find("[data-action=bash]")
      assert line |> Floki.find(".whitespace-pre-wrap") |> Floki.text() == "$ mix test"
      assert Floki.text(line) =~ "✓"

      doc = draw([event(1, "job.harness.text", %{"text" => "two\nlines"})])
      assert doc |> rows() |> Floki.find(".whitespace-pre-wrap") |> Floki.text() == "two\nlines"
    end

    # A command's mark is read at a glance, so a clipped command still shows it while closed.
    test "keeps a command's mark beside its first 200 characters" do
      command = "echo " <> String.duplicate("x", 300)
      doc = draw([call(1, "b1", command), result(2, "b1", false, "ok")])

      assert [clipped] = doc |> rows() |> Floki.find("[data-action=bash] details[data-clipped]")
      assert clipped |> Floki.find("summary") |> Floki.text() =~ "✓"

      # And open: the summary's copy is hidden then, so the body carries its own.
      {"details", _attrs, children} = clipped
      body = Enum.reject(children, &match?({"summary", _, _}, &1))
      assert Floki.text(body) =~ "✓"
    end
  end

  # A patch of a running job's stream used to close whatever the reader had opened: the server
  # never renders `open`, and rows matched by index were another event's next time.
  describe "an opened line" do
    test "is left open by a patch: every <details> ignores `open`" do
      doc =
        draw([
          event(1, "job.harness.text", %{"text" => String.duplicate("a", 300)}),
          event(2, "job.harness.tool_use", %{
            "id" => "e1",
            "name" => "Edit",
            "input" => %{"file_path" => "/w/a.ex", "old_string" => "a", "new_string" => "b"}
          }),
          event(3, "job.harness.tool_use", %{
            "id" => "r1",
            "name" => "Read",
            "input" => %{"file_path" => "/w/a.ex"}
          })
        ])

      details = Floki.find(doc, "details")
      assert length(details) == 3

      for node <- details do
        assert [mounted] = Floki.attribute(node, "phx-mounted")
        assert mounted =~ "ignore_attrs"
        assert mounted =~ "open"
      end
    end

    test "is the same event's row after a newer one is drawn above it" do
      older = [
        event(1, "job.harness.text", %{"text" => "one"}),
        event(2, "job.harness.text", %{"text" => "two"})
      ]

      newer = older ++ [event(3, "job.harness.text", %{"text" => "three"})]

      for events <- [older, newer] do
        assert [row] = events |> draw() |> Floki.find("#job-events-2")
        assert Floki.text(row) =~ "two"
      end
    end
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
