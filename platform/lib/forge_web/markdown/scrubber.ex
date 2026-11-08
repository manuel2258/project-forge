defmodule ForgeWeb.Markdown.Scrubber do
  @moduledoc """
  What `ForgeWeb.Markdown` lets through to the page: `HtmlSanitizeEx`'s Markdown allow-list, with
  two additions for references (`docs/design/ui.md` § Documents → References) and two narrowings.

  Added: `loading` and `decoding` on an `img`, and the one class a note carries on a `span`.

  Narrowed, and this is a line of defence of its own and not only a second one: an `img`'s `src`
  is kept only when it is exactly an artifact route of the product —
  `/tickets/:project/:number/artifacts/:name/:version` or `/chats/:id/artifacts/:name/:version`,
  with no `.` or `..` segment, however percent-encoded — and an `a`'s `href` only when it is such a
  route, a `#fragment`, or `http`, `https` or `mailto`. A relative `href` is dropped: the renderer
  never leaves one, and a path an agent typed would resolve against the page's own address.
  """

  use HtmlSanitizeEx, extend: :markdown_html

  # A segment holds no `/`, `?`, `#`, no backslash (a browser reads `\` as `/` in an http(s) path,
  # so `..\..\x` would climb) and no control character.
  @route ~r{\A/(?:tickets/[^/?#\\\x00-\x1f\x7f]+/[1-9]\d*|chats/[^/?#\\\x00-\x1f\x7f]+)/artifacts/[^/?#\\\x00-\x1f\x7f]+/[1-9]\d*\z}
  @scheme ~r/\A([A-Za-z][A-Za-z0-9+.\-]*):/

  @doc "Whether `path` is an artifact route the renderer builds, and nothing that climbs out of one."
  @spec artifact_route?(String.t()) :: boolean()
  def artifact_route?(path) do
    Regex.match?(@route, path) and
      not Enum.any?(String.split(path, "/"), &dots?(URI.decode(&1)))
  end

  defp dots?(segment), do: segment in [".", ".."]

  def scrub_attribute("img", {"src", value}) do
    if artifact_route?(value), do: {"src", value}
  end

  def scrub_attribute("a", {"href", value}) do
    cond do
      String.starts_with?(value, "#") -> {"href", value}
      artifact_route?(value) -> {"href", value}
      match?([_, _], Regex.run(@scheme, value)) -> scheme_href(value)
      true -> nil
    end
  end

  defp scheme_href(value) do
    [_all, scheme] = Regex.run(@scheme, value)
    # `https:/oidc/github` and `https:plan.md` have a scheme and no authority, and a browser reads
    # them as the page's own host; only a full `http(s)://` URL or a `mailto:` is outside.
    if (String.downcase(scheme) in ["http", "https"] and value =~ ~r{\A[^:]+://}) or
         String.downcase(scheme) == "mailto",
       do: {"href", value}
  end

  allow_tag_with_these_attributes("img", ["loading", "decoding"])
  allow_tag_with_these_attributes("a", ["name", "title"])
  # `span` must be registered here, or the parent scrubs it and the class is dropped.
  allow_tag_with_these_attributes("span")
  allow_tag_with_this_attribute_values("span", "class", ["ref-note"])
end
