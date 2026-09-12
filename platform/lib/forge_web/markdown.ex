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
    state = markdown |> strip_front_matter() |> Md.parse()

    %{state | ast: Enum.map(state.ast, &escape_inline_code(&1, nil))}
    |> Md.generate(format: :none)
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
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
