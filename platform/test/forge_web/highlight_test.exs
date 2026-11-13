defmodule ForgeWeb.HighlightTest do
  @moduledoc """
  A file's text, highlighted or plain (`ForgeWeb.Highlight`). What matters is less the colours
  than the guards: hostile text comes out escaped on both paths, the size bound sits exactly
  where it says, a language with no parser and an error are plain, and both answers hold the
  same lines so a caller's numbering never depends on which it got.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias ForgeWeb.Highlight

  @hostile "</span><script>alert(1)</script>"

  describe "hang/1" do
    # A wrapped line's rest hangs under its own indent and two more (`code.css`): at the code's
    # first column it read as a new line of code.
    test "is the line's own indent and two more, a tab as four, through any markup" do
      assert Highlight.hang("def x, do: 1") == 2
      assert Highlight.hang("        order_by: [desc: s.score,") == 10
      assert Highlight.hang("\t\tx") == 10
      assert Highlight.hang({:safe, ~s|    <span class="l-keyword">def</span> x|}) == 6
      assert Highlight.hang({:safe, ~s|<span class="l-comment">  # x</span>|}) == 4
    end

    test "is set on every line it draws" do
      assigns = %{lines: {:plain, ["a", "    b"]}}
      html = rendered_to_string(~H"<Highlight.code lines={@lines} />")
      assert html =~ ~s|style="--hang: 2ch"|
      assert html =~ ~s|style="--hang: 6ch"|
    end
  end

  describe "file/2" do
    test "Elixir comes back as lines of Lumis's classes, which code.css colours" do
      source = ~s|defmodule A do\n  # note\n  def x, do: {:ok, "s", 1}\nend\n|

      assert {:highlighted, lines} = Highlight.file("lib/a.ex", source)
      html = Enum.map_join(lines, "\n", &Phoenix.HTML.safe_to_string/1)

      for class <- ~w(l-keyword l-module l-function l-comment l-string l-number),
          do: assert(html =~ ~s|class="#{class}|, "no #{class} in #{html}")

      # No colour of its own: the palette is the tokens', in both themes.
      refute html =~ "style="
    end

    test "a name that says nothing is settled by a shebang" do
      assert {:highlighted, _lines} =
               Highlight.file("bin/check", "#!/usr/bin/env bash\necho hi\n")
    end

    test "a name that is not UTF-8 is guessed from the content, and is not an error" do
      # The mutation: handing Lumis the name as it is raises, and the file is drawn plain under
      # a warning for nothing more than what it is called.
      log =
        capture_log([level: :warning], fn ->
          assert {:highlighted, _lines} =
                   Highlight.file("caf" <> <<0xE9>> <> ".sh", "#!/usr/bin/env bash\necho hi\n")
        end)

      # This module's own words only: the capture is node-wide, and another test's error may land
      # in it.
      refute log =~ "Drawing"
    end

    test "hostile text comes out escaped whether it is highlighted or not" do
      # The mutation: drawing the plain branch's lines with `raw/1` (or answering them as
      # `{:safe, line}`) would put a live script into the repository's file view.
      for name <- ["lib/evil.ex", "notes.unknown-extension"] do
        html = draw(Highlight.file(name, @hostile))
        doc = Floki.parse_fragment!(html)

        refute html =~ "<script>", "#{name} drew a live script: #{html}"
        assert Floki.find(doc, "script") == []
        # Escaped, so the reader sees what the file says, every character of it.
        assert texts(html) == [@hostile]
      end

      assert {:plain, _lines} = Highlight.file("notes.unknown-extension", @hostile)
      assert {:highlighted, _lines} = Highlight.file("lib/evil.ex", @hostile)
    end

    test "exactly the bound is highlighted, a byte over is plain" do
      # The mutation: `>=` for `>` makes the first of these plain.
      at = sized("x = 1\n", Highlight.max_bytes())
      over = sized("x = 1\n", Highlight.max_bytes() + 1)

      assert byte_size(at) == 100 * 1024
      assert {:highlighted, _lines} = Highlight.file("big.ex", at)
      assert {:plain, lines} = Highlight.file("big.ex", over)
      assert hd(lines) == "x = 1"
    end

    test "a language with no parser here is plain, and says nothing about it" do
      # Haskell is a language Lumis knows and this platform carries no parser for; the other has
      # no language at all. Neither is a failure, so neither is logged.
      log =
        capture_log([level: :warning], fn ->
          assert {:plain, ["main = print 1"]} = Highlight.file("Main.hs", "main = print 1\n")
          assert {:plain, ["a", "b"]} = Highlight.file("notes.unknown-extension", "a\nb\n")
        end)

      # This module's own words only: the capture is node-wide, and another test's error may land
      # in it.
      refute log =~ "Drawing"
    end

    test "an error on the way is plain, and logged as a warning rather than an error" do
      # Not UTF-8: Lumis raises an `ArgumentError` passing it to the NIF. The mutation: dropping
      # the `rescue` lets that reach the page.
      source = "x = " <> <<0xFF>> <> "\n"

      log =
        capture_log([level: :warning], fn ->
          assert {:plain, ["x = " <> <<0xFF>>]} = Highlight.file("lib/a.ex", source)
        end)

      # Its own line, read alone: the capture is node-wide.
      assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ ~s(Drawing "lib/a.ex")))
      assert line =~ "[warning]"
    end

    test "both answers hold the same lines" do
      # The mutation: not dropping the final newline in the plain answer gives it one more line
      # than the highlighted one for every file that ends in a newline, which is nearly all.
      for {source, count} <- [
            {"", 1},
            {"a", 1},
            {"a\n", 1},
            {"a\n\n", 2},
            {"a\nb\n", 2},
            {"a\r\nb", 2},
            {~s|x = """\nm\n  n\n"""\n|, 4}
          ] do
        assert {:highlighted, highlighted} = Highlight.file("a.ex", source)
        assert {:plain, plain} = Highlight.file("a.unknown-extension", source)

        assert length(highlighted) == count, "#{inspect(source)}: #{inspect(highlighted)}"
        assert length(plain) == count, "#{inspect(source)}: #{inspect(plain)}"
      end
    end

    test "a token across lines is closed on each, so every line stands alone" do
      {:highlighted, lines} = Highlight.file("a.ex", ~s|x = """\nm\n"""\n|)

      for line <- lines do
        html = Phoenix.HTML.safe_to_string(line)

        assert length(Regex.scan(~r/<span/, html)) == length(Regex.scan(~r{</span>}, html)),
               html
      end
    end
  end

  describe "code/1" do
    test "numbers each line in a gutter the reader's selection skips" do
      html = draw(Highlight.file("a.ex", "a = 1\nb = 2\n"))
      doc = Floki.parse_fragment!(html)

      assert doc |> Floki.find(".code-line") |> length() == 2

      assert doc |> Floki.find(".code-number") |> Enum.map(&Floki.text/1) == ["1", "2"]
      assert doc |> Floki.find(".code-number[aria-hidden=true]") |> length() == 2
      assert texts(html) == ["a = 1", "b = 2"]
      assert doc |> Floki.find(".code.code-highlighted") |> length() == 1
    end

    # An excerpt is numbered from where it was cut, and the rows a change added or an excerpt
    # showed carry their mark (`docs/design/ui.md` § Changes).
    test "numbers from `first`, and marks the rows `marks` names by number" do
      html =
        Phoenix.LiveViewTest.render_component(&Highlight.code/1,
          lines: Highlight.file("a.txt", "c\nd\ne\n"),
          first: 14,
          marks: %{15 => "code-line--add", 99 => "code-line--add"}
        )

      doc = Floki.parse_fragment!(html)

      assert doc |> Floki.find(".code-number") |> Enum.map(&Floki.text/1) == ["14", "15", "16"]
      assert doc |> Floki.find(".code-line--add") |> Floki.attribute("data-line") == ["15"]
    end

    test "plain is drawn without the highlighted mark, and keeps a caller's classes" do
      lines = Highlight.file("a.unknown-extension", "a\n")
      assigns = %{lines: lines}

      doc =
        ~H"""
        <Highlight.code lines={@lines} class="border" data-file="a" />
        """
        |> rendered_to_string()
        |> Floki.parse_fragment!()

      assert [{"div", attrs, _children}] = Floki.find(doc, ".code")
      assert {"class", "code border"} in attrs
      assert {"data-file", "a"} in attrs
    end
  end

  defp draw(lines) do
    assigns = %{lines: lines}

    rendered_to_string(~H"""
    <Highlight.code lines={@lines} />
    """)
  end

  # Each line's text as a browser reads it. LazyHTML and not Floki, whose parser drops the
  # whitespace-only text between two spans — the spaces of `a = 1`.
  defp texts(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(".code-text") |> Enum.map(&LazyHTML.text/1)
  end

  # `line` repeated and then padded with a comment, to exactly `bytes`.
  defp sized(line, bytes) do
    body = String.duplicate(line, div(bytes - 2, byte_size(line)) - 1)
    body <> "# " <> String.duplicate("y", bytes - byte_size(body) - 2)
  end
end
