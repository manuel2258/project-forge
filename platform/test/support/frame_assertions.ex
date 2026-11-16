defmodule ForgeWeb.FrameAssertions do
  @moduledoc """
  What every view of a ticket and of a chat has in common (`docs/design/ui.md` § Three layouts):
  one width, so that the title row, the tabs and the content's left edge are where they were
  whichever view is open. The server draws the width as a class and a `style` on three elements,
  so two views drawn at different widths show as a difference in them.
  """

  import ExUnit.Assertions

  @doc "The attributes that decide where the title, the tabs and the content start."
  @spec frame_of(String.t()) :: %{String.t() => [String.t()]}
  def frame_of(html) do
    doc = Floki.parse_document!(html)

    for {key, selector, attribute} <- [
          {"title-row class", "#title-row", "class"},
          {"title-row style", "#title-row", "style"},
          {"main style", ".frame-main", "style"}
        ],
        into: %{} do
      {key, doc |> Floki.find(selector) |> Floki.attribute(attribute)}
    end
  end

  @doc """
  Every page in `pages`, `{name, html}`, is drawn at one width: the same frame, none of it
  carrying a measure of its own.
  """
  @spec assert_one_width([{String.t(), String.t()}]) :: :ok
  def assert_one_width([{first_name, first_html} | rest] = pages) do
    first = frame_of(first_html)
    assert first["title-row class"] != [], "#{first_name} drew no title row"

    for {name, html} <- rest do
      assert frame_of(html) == first, "#{name} is not drawn like #{first_name}"
    end

    for {name, html} <- pages do
      refute html =~ "--frame-measure", "#{name} carries a measure of its own"
    end

    :ok
  end
end
