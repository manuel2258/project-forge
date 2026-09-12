defmodule ForgeWeb.Markdown do
  @moduledoc """
  Renders a document's Markdown for the browser. Agents wrote it, so the HTML is sanitised
  after rendering; front matter is stripped since the page shows its fields itself.
  """

  alias ForgeCore.Document

  @spec to_html(String.t() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: Phoenix.HTML.raw("")

  def to_html(markdown) when is_binary(markdown) do
    markdown
    |> body()
    |> Md.generate(format: :none)
    |> HtmlSanitizeEx.markdown_html()
    |> Phoenix.HTML.raw()
  end

  defp body(markdown) do
    case Document.parse(markdown) do
      {:ok, %Document{body: body}} -> body
      {:error, _} -> markdown
    end
  end
end
