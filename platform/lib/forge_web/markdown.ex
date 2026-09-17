defmodule ForgeWeb.Markdown do
  @moduledoc """
  Renders a document's Markdown for the browser. Agents wrote it, so nothing they typed may
  reach the page as HTML: the renderer's inline code (which `md` leaves raw) is escaped at
  the AST level, and the whole result is sanitised. Front matter is stripped textually since
  the page shows its fields itself.
  """

  @front_matter ~r/\A\x{FEFF}?---\r?\n.*?\r?\n---\r?\n/su

  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: Phoenix.HTML.raw("")

  def to_html(markdown) when is_binary(markdown) do
    text = strip_front_matter(markdown)

    try do
      state = Md.parse(text)

      %{state | ast: Enum.map(state.ast, &escape_inline_code(&1, nil))}
      |> Md.generate(format: :none)
      |> HtmlSanitizeEx.markdown_html()
      |> Phoenix.HTML.raw()
    rescue
      # The renderer is a dependency and its parser raises on markdown people actually write:
      # `md` 0.13.1 dies on reference links (`[a][1]`) and on footnotes (`[^1]`), which is what
      # a citation-heavy verification report is made of. Every call site renders at mount, so
      # one such document used to make the ticket, review and chat pages raise for ever — an
      # agent could deny the operator the surfaces where merges are approved and money is spent,
      # by writing an ordinary footnote.
      #
      # Degrading is the right answer rather than a parser fix: the content is agent-written and
      # unbounded, so the next construct that raises should cost legibility and not the page.
      # The fallback escapes, so it is not a way around the sanitiser either.
      _error -> plain(text)
    end
  end

  # Escaped, with paragraphs kept, and nothing else. Deliberately not a second parser.
  defp plain(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map_join("<br>", &(&1 |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()))
    |> then(&Phoenix.HTML.raw("<p>" <> &1 <> "</p>"))
  end

  @doc "The Markdown without its leading YAML front matter, whether or not it parses."
  @spec strip_front_matter(String.t()) :: String.t()
  def strip_front_matter(markdown), do: Regex.replace(@front_matter, markdown, "", global: false)

  # `md` escapes text nodes and fenced blocks but not inline code; do it here. Fenced code
  # arrives as {:pre, _, [{:code, _, [already_escaped]}]} and must not be escaped twice.
  defp escape_inline_code({:code, attrs, children}, parent) when parent != :pre do
    {:code, attrs, Enum.map(children, &escape_text/1)}
  end

  defp escape_inline_code({tag, attrs, children}, _parent) when is_list(children) do
    {tag, attrs, Enum.map(children, &escape_inline_code(&1, tag))}
  end

  defp escape_inline_code(other, _parent), do: other

  defp escape_text(text) when is_binary(text),
    do: text |> Plug.HTML.html_escape_to_iodata() |> IO.iodata_to_binary()

  defp escape_text(other), do: escape_inline_code(other, :code)
end
