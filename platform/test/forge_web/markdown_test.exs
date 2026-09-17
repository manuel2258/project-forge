defmodule ForgeWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias ForgeWeb.Markdown

  defp html(markdown), do: markdown |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()

  test "renders headings, paragraphs and fenced code" do
    out = html("# Plan\n\nDo the thing.\n\n```elixir\nIO.puts(1)\n```\n")
    assert out =~ "<h1>Plan</h1>"
    assert out =~ "<p>Do the thing.</p>"
    assert out =~ "<pre>" and out =~ "IO.puts(1)"
  end

  test "strips front matter, with or without a BOM, and leaves a lone rule alone" do
    assert html("---\noutcome: done\n---\n# Plan\n") =~ "<h1>Plan</h1>"
    refute html("---\noutcome: done\n---\n# Plan\n") =~ "outcome"
    assert html("﻿---\noutcome: done\r\n---\r\n# Plan\n") =~ "<h1>Plan</h1>"
    assert Markdown.strip_front_matter("---\n\nnot front matter") =~ "not front matter"
  end

  test "nothing an agent typed reaches the page as HTML" do
    out = html("Hi <script>alert(1)</script> and `<img src=x onerror=alert(1)>` there\n")
    refute out =~ "<script"
    refute out =~ "<img"
    assert out =~ "&lt;img src=x onerror=alert(1)&gt;"

    out = html("```\n<b>raw</b>\n```\n")
    refute out =~ "<b>"
    assert out =~ "&lt;b&gt;raw&lt;/b&gt;"
    refute out =~ "&amp;lt;"

    out = html("[click](javascript:alert(1))\n")
    refute out =~ "javascript:"
  end

  describe "markdown the renderer cannot parse" do
    # `md` 0.13.1 raises on reference links and footnotes — ordinary constructs a
    # citation-heavy verification report uses. Every call site renders at mount, so one such
    # document made the ticket, review and chat pages raise for ever: an agent could deny the
    # operator the exact surfaces where merges are approved and money is spent.
    #
    # The renderer degrades to escaped plain text rather than taking the page with it.
    test "a reference link degrades instead of raising" do
      html = html("[a][1]\n\n[1]: https://example.com")

      assert html =~ "example.com"
      refute html =~ "<script"
    end

    test "a footnote degrades instead of raising" do
      html = html("A claim.[^1]\n\n[^1]: the evidence")

      assert html =~ "the evidence"
    end

    test "the fallback still escapes, so unparseable markdown is not an XSS hole" do
      # A footnote forces the fallback; the script tag rides along in the same document.
      html = html("A claim.[^1]\n\n[^1]: note\n\n<script>alert(1)</script>")

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
