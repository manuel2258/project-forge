defmodule Forge.Changelog do
  @moduledoc """
  What each forge release changed for the projects it hosts, as the text every job and
  conversation is handed (`docs/design/changelog.md`).

  The text is `priv/changelog.md`, embedded at compile time. **The platform reads one thing in it**:
  the `## N.N.N` headings, which are the releases it knows (`releases/1`). What a section says is for
  an agent, and nothing here parses it.
  """

  @path Path.join([__DIR__, "..", "..", "priv", "changelog.md"])
  @external_resource @path
  @text File.read!(@path)

  # The first version `VERSION` held. It has no section and is the release a project that records
  # none counts as being at.
  @baseline "0.1.1"

  @doc "The first release `VERSION` held, which a project recording none counts as being at."
  @spec baseline() :: String.t()
  def baseline, do: @baseline

  @doc "The changelog, byte for byte as it is handed to a job."
  @spec text() :: String.t()
  def text, do: @text

  @doc """
  The releases the changelog has a section for: its `## N.N.N` headings, in file order.

  A heading inside a fenced code block is not one — a before-and-after in an entry may well be a
  YAML file with a `## 1.2.3` comment — and a `###` heading never is.
  """
  @spec releases(String.t()) :: [String.t()]
  def releases(text) do
    {found, _in_fence} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], false}, fn line, {found, fenced?} ->
        cond do
          fence?(line) -> {found, not fenced?}
          fenced? -> {found, fenced?}
          true -> {heading(line, found), fenced?}
        end
      end)

    Enum.reverse(found)
  end

  # A fence opens and closes on a line that starts, after any indentation, with three backticks or
  # three tildes. An indented one counts: the changelog's entries put their examples inside list
  # items.
  defp fence?(line), do: String.starts_with?(String.trim_leading(line), ["```", "~~~"])

  defp heading(line, found) do
    case Regex.run(~r/\A## (\d+\.\d+\.\d+)\s*\z/, line) do
      [_, version] -> [version | found]
      nil -> found
    end
  end

  @doc "Every forge release: the baseline and the changelog's sections."
  @spec releases() :: [String.t()]
  def releases, do: [@baseline | releases(@text)]

  @doc "The forge release this platform is."
  @spec running() :: String.t()
  def running, do: :forge |> Application.spec(:vsn) |> to_string()
end
