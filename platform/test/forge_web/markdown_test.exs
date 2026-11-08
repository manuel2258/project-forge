defmodule ForgeWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias ForgeWeb.Markdown

  defp html(markdown), do: markdown |> Markdown.to_html(%{}) |> Phoenix.HTML.safe_to_string()

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

  # -- references (`docs/design/ui.md` § Documents → References) -------------------------------

  @png %{where: {:ticket, "game", 3}, name: "screenshots/q.png", version: 2, raster?: true}
  @addr "/tickets/game/3/artifacts/screenshots%2Fq.png/2"

  defp drawn(markdown, resolved),
    do: markdown |> Markdown.to_html(resolved) |> Phoenix.HTML.safe_to_string()

  describe "an image that resolved to a raster blob" do
    test "is an image linked to its numbered address, fetched when near" do
      out = drawn("![queue](screenshots/q.png)", %{"screenshots/q.png" => {:ok, @png}})

      assert [{"a", [{"href", @addr}], [{"img", attrs, _}]}] =
               out |> Floki.parse_fragment!() |> Floki.find("a")

      assert Enum.sort(attrs) ==
               [{"alt", "queue"}, {"decoding", "async"}, {"loading", "lazy"}, {"src", @addr}]
    end

    test "inside a link it is not wrapped in a second one, and a figure draws it too" do
      resolved = %{
        "screenshots/q.png" => {:ok, @png},
        "plan.md" => {:ok, %{@png | name: "plan.md", raster?: false}}
      }

      out = drawn("[![in](screenshots/q.png)](plan.md)", resolved)
      assert length(Floki.find(Floki.parse_fragment!(out), "a")) == 1
      assert out =~ ~s(src="#{@addr}")

      figure = drawn("!![caption](screenshots/q.png)", resolved)
      assert figure =~ ~s(<img) and figure =~ "caption"
    end

    test "a chat's address is the chat's" do
      found = %{@png | where: {:chat, "c1"}, name: "n.md", raster?: true}
      assert drawn("![x](n.md)", %{"n.md" => {:ok, found}}) =~ "/chats/c1/artifacts/n.md/2"
    end
  end

  # Criteria 11 and 22: no cap on images, a long name is contained in its note (the CSS wraps it).
  describe "many images and long names" do
    test "every resolved image is drawn, however many, each lazy" do
      out =
        drawn(
          Enum.map_join(1..2_000, "\n\n", fn _ -> "![x](screenshots/q.png)" end),
          %{"screenshots/q.png" => {:ok, @png}}
        )

      html = Floki.parse_fragment!(out)
      assert length(Floki.find(html, "img")) == 2_000
      assert Floki.attribute(Floki.find(html, "img"), "loading") |> Enum.uniq() == ["lazy"]
    end

    test "a 200-character name sits whole in its note" do
      name = String.duplicate("a", 196) <> ".png"
      out = drawn("![](#{name})", %{name => {:error, {:missing, :ticket}}})
      assert [note] = out |> Floki.parse_fragment!() |> Floki.find("span.ref-note code")
      assert Floki.text(note) == name
    end
  end

  describe "every other image is a note and never an <img>" do
    test "whatever it points at, and whatever the caller resolved" do
      svg = %{@png | name: "a.svg", raster?: false}

      for {target, resolved, note} <- [
            {"screenshots/q.png", {:error, {:missing, :ticket}}, "is not on this ticket"},
            {"screenshots/q.png", {:error, {:missing, :chat}}, "chats keep no images"},
            {"screenshots/q.png", {:error, {:missing, 34}}, "is not on ticket 34"},
            {"screenshots/q.png@5", {:error, {:no_version, 5}}, "has no such version"},
            {"archive/99/q.png", {:error, {:no_ticket, 99}}, "this project has no ticket 99"},
            {"a.svg", {:ok, svg}, "is not drawn as an image"},
            {"https://x.test/a.png", {:error, :outside}, "images from outside the project"},
            {"data:image/png;base64,AAAA", {:error, :outside}, "images from outside"},
            {"//x.test/a.png", {:error, :outside}, "images from outside"},
            {"/tickets/game/1/artifacts/x/1", {:error, :outside}, "images from outside"},
            {"notes.md", {:ok, %{svg | where: {:chat, "c"}}}, "chats keep no images"},
            {"never-resolved.png", nil, "is not shown"}
          ] do
        resolved_map = if resolved, do: %{target => resolved}, else: %{}
        out = drawn("![alt](#{target})", resolved_map)

        refute out =~ "<img", target
        assert out =~ ~s(<span class="ref-note">alt — <code>), target
        assert out =~ note, target
      end
    end

    test "even when the caller resolved nothing at all, and with no alt text the name alone" do
      for markdown <- [
            "![](screenshots/q.png)",
            "![x](screenshots/q.png)",
            "!![cap](screenshots/q.png)",
            "![x](<script>)"
          ] do
        refute drawn(markdown, %{}) =~ "<img", markdown
      end

      assert drawn("![](screenshots/q.png)", %{}) =~
               ~s(<span class="ref-note"><code>screenshots/q.png</code>)
    end

    test "when the parser raises the fallback has no image either" do
      # `md` 0.13.1 raises on a footnote; the plain fallback escapes everything.
      out =
        drawn("![x](screenshots/q.png) [^1]\n\n[^1]: note", %{"screenshots/q.png" => {:ok, @png}})

      refute out =~ "<img"
    end

    test "markup in the alt, the name and the link text is text" do
      hostile = ~s|<script>alert(1)</script> & "q" <img src=x onerror=y>|
      out = drawn("![#{hostile}](screenshots/<b>q.png)", %{})
      refute out =~ "<script"
      refute out =~ "<img"
      refute out =~ "<b>"
      assert out =~ "&lt;script"

      link = drawn("[<i>x</i> <script>](plan.md)", %{})
      refute link =~ "<script"
      refute link =~ "<i>"
    end
  end

  describe "links" do
    test "one that resolved goes to the numbered address, whatever it is" do
      found = %{@png | raster?: false, name: "plan.md"}
      out = drawn("[the plan](plan.md)", %{"plan.md" => {:ok, found}})
      assert out =~ ~s(<a href="/tickets/game/3/artifacts/plan.md/2">the plan</a>)
    end

    test "one that did not keeps its words and loses its target" do
      for target <- ["plan.md", "docs/design/ui.md", "javascript:alert(1)", "/tickets/p/1/x"] do
        out = drawn("[the words](#{target})", %{target => {:error, :outside}})
        assert out =~ "the words"
        refute out =~ "href", target
      end
    end

    test "https:/path and https:name have no host, so they are not left as they are" do
      for target <- ["https:/oidc/github", "https:plan.md", "http:oidc"] do
        out = drawn("[x](#{target})", %{})
        refute out =~ "href", target
        assert out =~ "x"
      end
    end

    test "http, https, mailto and #fragment are left as they are" do
      out = drawn("[a](https://x.test/a) [b](http://x.test) [c](mailto:a@b.test) [d](#top)", %{})

      for href <- ["https://x.test/a", "http://x.test", "mailto:a@b.test", "#top"],
          do: assert(out =~ ~s(href="#{href}"))
    end
  end

  test "references/1 lists what needs resolving once: images and links but the kept ones" do
    refs = fn markdown -> markdown |> Markdown.parse() |> Markdown.references() end

    assert Enum.sort(refs.("![a](x.png) ![b](x.png) [c](plan.md) [d](https://x.test)")) ==
             ["plan.md", "x.png"]

    assert refs.("[e](#f) [g](mailto:a@b.test) [h](HTTP://x.test)") == []
    assert refs.("[![g](y.png)](z.md)") == ["z.md", "y.png"]
    assert refs.("[^1]\n\n[^1]: n") == []
  end

  # `md` leaves some text raw: double-backtick spans and what follows an unclosed `{{`. The
  # sanitiser's checks are lexical, so a raw `<img>` or `<a>` used to reach the page, and with it
  # a GET to any path of the platform with the reader's cookies (criteria 7, 9, 25, 28).
  describe "raw text md leaves unescaped" do
    test "never becomes an <img> or a link the resolver did not make" do
      for markdown <- [
            ~s|``<img src="/tickets/../oidc/github">``|,
            ~s|hi {{<img src="/tickets/a/1/artifacts/x/1">|,
            ~s|``<img src="/tickets/p/1/artifacts/x/1">``|,
            ~s|``<a href="plan.md">x</a>``|,
            ~s|``<a href="/tickets/p/1/artifacts/x/1">x</a>``|,
            ~s|hi {{<a href="plan.md">x</a>|,
            ~s|``<script>alert(1)</script>``|,
            ~s|`<img src=x onerror=y>`|
          ] do
        out = drawn(markdown, %{})
        refute out =~ "<img", markdown
        refute out =~ "<a ", markdown
        refute out =~ "<script", markdown
        assert out =~ "&lt;", markdown
      end
    end
  end

  describe "the scrubber, behind the renderer" do
    # What the renderer builds is the only `img` and `a` the scrubber lets through, whatever raw
    # HTML reaches it; so it is also tested on raw HTML, where it is the only thing standing.
    defp scrub(html), do: HtmlSanitizeEx.Scrubber.scrub(html, ForgeWeb.Markdown.Scrubber)

    test "keeps an artifact route's img and nothing else" do
      for src <- [
            "/tickets/p/1/artifacts/a/1",
            "/chats/c1/artifacts/n.md/12",
            "/tickets/p/3/artifacts/shots%2Fq.png/2"
          ] do
        assert scrub(~s(<img src="#{src}" loading="lazy" onerror="x">)) =~ ~s(src="#{src}"), src
      end

      for src <- [
            "https://x.test/a.png",
            "http://x.test/a.png",
            "/other",
            "data:image/png;base64,AA",
            "//x.test/a",
            "a.png",
            "/tickets/p/1/artifacts/a/1/extra",
            "/tickets/p/1/artifacts/a/0",
            "/tickets/p/0/artifacts/a/1",
            "/tickets/p/1/artifacts/..\\..\\oidc\\github/1",
            "/tickets/..\\oidc\\github\\x/1/artifacts/n/1",
            "/tickets/p/1/artifacts/a\\b/1",
            "/tickets/p/1/artifacts/a\u0001b/1",
            "/tickets/p\u0001q/1/artifacts/n/1",
            "/tickets/p\u007fq/1/artifacts/n/1",
            "/tickets/p/1/artifacts/a\u007fb/1",
            "/chats/..\\x/artifacts/n/1",
            "/chats/a\\b/artifacts/n/1",
            "/chats/a\u0001b/artifacts/n/1",
            "/chats/a\u007fb/artifacts/n/1",
            "/ticketsx/p/1/artifacts/a/1",
            "/tickets/../oidc/github",
            "/tickets/p/1/artifacts/../1",
            "/tickets/p/1/artifacts/%2e%2e/1",
            "/tickets/%2E%2e/1/artifacts/a/1",
            "/tickets/p/1/artifacts/a/1?x=1"
          ] do
        refute scrub(~s(<img src="#{src}">)) =~ "src=", src
      end

      refute scrub(~s(<img src="/tickets/p/1/artifacts/a/1" onerror="x">)) =~ "onerror"
      assert scrub(~s(<span class="ref-note">x</span>)) =~ "ref-note"
      refute scrub(~s(<span class="other" style="x">x</span>)) =~ "class"
    end

    test "keeps an a's href only when it is a route, a fragment or http, https, mailto" do
      for href <- [
            "/tickets/p/1/artifacts/a/1",
            "/chats/c1/artifacts/n.md/1",
            "#top",
            "https://x.test/a",
            "HTTP://x.test",
            "mailto:a@b.test"
          ] do
        assert scrub(~s(<a href="#{href}">x</a>)) =~ ~s(href="#{href}"), href
      end

      for href <- [
            "javascript://%0aalert(1)",
            "data://text/html,x",
            "ftp://x.test/a",
            "https:/oidc/github",
            "https:plan.md",
            "plan.md",
            "./plan.md",
            "/tickets/p/1",
            "/oidc/github",
            "//x.test",
            "javascript:alert(1)",
            "data:text/html,x"
          ] do
        refute scrub(~s(<a href="#{href}">x</a>)) =~ "href", href
      end
    end
  end
end
