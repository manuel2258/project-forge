defmodule Forge.Look.Steps do
  @moduledoc """
  The step list `bin/look` reads: one step a line, `#` comments, quoted arguments.

      width phone|portrait|wide|desktop
      visit /tickets/game/1            visit :ticket
      click "button.save"              click text "Save"
      fill "input[name=title]" "Hi"
      wait ".flash"                    wait text "Saved"
      text ".count"
      shot page queue-empty-phone.png  shot ".card" card.png

  Pure: it parses and validates and starts nothing. **A `visit` is refused here, before any
  browser exists**, unless it is a path on the app the look started (`docs/design/look.md`
  § Security): the validation is the first of two locks, and the proxy and
  the origin check in `Forge.Look` are the others, since a page can navigate by itself.
  """

  # The sizes the handoff drew each layout at (`docs/design/look.md` § The redesign's widths);
  # `desktop` is the one `.forge/agents/implement.md` names.
  @sizes %{
    phone: {412, 915},
    portrait: {1080, 1500},
    wide: {1600, 1000},
    desktop: {1280, 800}
  }
  @widths Map.keys(@sizes) |> Enum.map(&Atom.to_string/1)

  @type width :: :phone | :portrait | :wide | :desktop
  @type target :: {:css, String.t()} | {:text, String.t()}
  @type op ::
          {:width, width}
          | {:visit, {:path, String.t()} | {:named, String.t()}}
          | {:click, target}
          | {:fill, String.t(), String.t()}
          | {:wait, target}
          | {:text, String.t()}
          | {:shot, :page | {:css, String.t()}, String.t()}
          # the gate's browser test only; never parsed
          | {:call, (Wallaby.Session.t() -> term)}
  @type step :: %{n: pos_integer, text: String.t(), op: op}
  @type error :: %{n: pos_integer, text: String.t(), reason: String.t()}

  @doc "The viewport, width by height, a `width` step names."
  @spec size(width) :: {pos_integer, pos_integer}
  def size(width), do: Map.fetch!(@sizes, width)

  @doc "Parse a whole list; the first bad line is the error, with its number."
  @spec parse(String.t()) :: {:ok, [step]} | {:error, error}
  def parse(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> blank?(line) end)
    |> Enum.reduce_while({:ok, []}, fn {line, n}, {:ok, acc} ->
      case parse_line(String.trim(line)) do
        {:ok, op} -> {:cont, {:ok, [%{n: n, text: String.trim(line), op: op} | acc]}}
        {:error, reason} -> {:halt, {:error, %{n: n, text: String.trim(line), reason: reason}}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp blank?(line), do: String.trim(line) == "" or String.starts_with?(String.trim(line), "#")

  defp parse_line(line) do
    case split(line) do
      {:ok, tokens} -> op(tokens)
      :error -> {:error, "unbalanced quote"}
    end
  end

  # `OptionParser.split/1` takes both quote kinds and raises on none; an unbalanced quote is
  # swallowed as part of the last word, so it is checked first.
  defp split(line) do
    if rem(Enum.count(String.graphemes(line), &(&1 == "\"")), 2) == 0,
      do: {:ok, OptionParser.split(line)},
      else: :error
  end

  defp op(["width", width]) when width in @widths,
    do: {:ok, {:width, String.to_existing_atom(width)}}

  defp op(["width" | _]), do: {:error, "width is phone, portrait, wide or desktop"}
  defp op(["visit", ":" <> name]) when name != "", do: {:ok, {:visit, {:named, name}}}
  defp op(["visit", path]), do: with(:ok <- check_path(path), do: {:ok, {:visit, {:path, path}}})
  defp op(["visit" | _]), do: {:error, "visit takes one path"}
  defp op(["click", "text", t]), do: text_op(:click, t)
  defp op(["click", css]), do: {:ok, {:click, {:css, css}}}
  defp op(["fill", css, value]), do: {:ok, {:fill, css, value}}
  defp op(["wait", "text", t]), do: text_op(:wait, t)
  defp op(["wait", css]), do: {:ok, {:wait, {:css, css}}}
  defp op(["text", css]), do: {:ok, {:text, css}}
  defp op(["shot", "page", file]), do: file_op(:page, file)
  defp op(["shot", css, file]), do: file_op({:css, css}, file)

  defp op([word | _]) when word in ~w(click fill wait text shot),
    do: {:error, "wrong arguments for #{word}"}

  defp op([word | _]), do: {:error, "unknown step #{inspect(word)}"}

  defp text_op(kind, t) do
    # The text goes into an XPath literal, which has no escape for a quote of its own kind.
    if String.contains?(t, "\"") and String.contains?(t, "'"),
      do: {:error, "text may hold a double quote or a single quote, not both"},
      else: {:ok, {kind, {:text, t}}}
  end

  defp file_op(what, file) do
    if file == "", do: {:error, "shot needs a file name"}, else: {:ok, {:shot, what, file}}
  end

  @doc """
  Whether `path` is a path on the app and nothing else: one leading `/`, no scheme, no
  authority. `//host` and `/\\host` are what a browser reads as another host, `\\` being a `/`
  to it, and a control character is stripped by the URL parser before it decides which.
  """
  @spec check_path(String.t()) :: :ok | {:error, String.t()}
  def check_path(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, "a visit must be a path on the app, starting with one /; got #{inspect(path)}"}

      String.starts_with?(path, "//") or String.starts_with?(path, "/\\") ->
        {:error, "a visit must be a path on the app, not an address with a host"}

      String.match?(path, ~r/[\x00-\x20\x7f\\]/) ->
        {:error, "a visit must not hold spaces, control characters or backslashes"}

      true ->
        :ok
    end
  end
end
