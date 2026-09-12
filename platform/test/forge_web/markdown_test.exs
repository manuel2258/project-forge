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
end
