defmodule ForgeWeb.Highlight do
  @moduledoc """
  A file's text, highlighted on the server (`docs/design/ui.md` § The project's repository).

  `file/2` asks Lumis for the language the file's name says — a shebang settles a name that says
  nothing, like `bin/check` — and answers with the file's lines: `{:highlighted, lines}`, each
  line HTML whose spans carry Lumis's classes and no colour of their own (`code.css` maps them to
  the `--syntax-*` tokens), or `{:plain, lines}`, each line a string HEEx escapes like any other.

  **Plain is the answer whenever highlighting is not certain**: a file over 100 KB, a language
  this platform carries no parser for, and any error or raise on the way, which is logged as a
  warning and never as an error (`Forge.Look.Watch` fails a look on an error log, and a file that
  will not highlight is not the page failing). The two answers always hold the same lines, so a
  caller numbering them never has to ask which one it got.

  Called once, where the file is read, never from a template: a template is drawn again on every
  patch, and highlighting is the one expensive thing a page does to a file it already has.
  """

  use Phoenix.Component

  require Logger

  # Bytes, not lines: one minified line is as costly as a thousand short ones. Over this the
  # file is drawn plain rather than refused, so the reader still has it.
  @max_bytes 100 * 1024

  # What `Lumis.Languages.guess/2` answers for a name and a content it finds no language in.
  @no_language "plaintext"

  @type lines :: {:highlighted, [Phoenix.HTML.safe()]} | {:plain, [String.t()]}

  @doc "The largest file, in bytes, that is highlighted rather than drawn plain."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  `source`'s lines, highlighted as the language `name` says, or plain (see the module doc).
  `source` is a file's whole text; `name` its path or name, which is only ever looked at.
  """
  @spec file(String.t(), String.t()) :: lines()
  def file(name, source) when is_binary(name) and is_binary(source) do
    if byte_size(source) > @max_bytes do
      plain(source)
    else
      highlight(name, source)
    end
  end

  defp highlight(name, source) do
    # A path git holds need not be UTF-8 (`caf\xE9.txt`), and Lumis raises on one that is not.
    # Such a name is guessed from the content alone, like a name that says nothing.
    language = Lumis.Languages.guess(if(String.valid?(name), do: name), source)

    with false <- language == @no_language,
         :ok <- Lumis.Languages.load(language),
         {:ok, html} <- Lumis.highlight(source, formatter: {:html_linked, language: language}) do
      {:highlighted, split(html)}
    else
      # No language, or one whose parser is not a dependency: what the file is, not a failure.
      true -> plain(source)
      {:error, reason} when reason in [:not_installed, :unknown_language] -> plain(source)
      {:error, reason} -> fallback(name, source, reason)
    end
  rescue
    # `Lumis.highlight/2` raises an `ArgumentError` on a binary that is not UTF-8, and `split/1`
    # a `MatchError` on a block it does not recognise. Neither is the reader's problem.
    error -> fallback(name, source, error)
  end

  defp fallback(name, source, reason) do
    Logger.warning("Drawing #{inspect(name)} plain, not highlighted: #{inspect(reason)}")
    plain(source)
  end

  # Lumis writes `<pre …><code …>`, one `<span class="l-line" data-line="N">` per line joined by
  # a newline, and `</code></pre>`. A token that runs across lines is closed and reopened at each
  # one, so a line's spans are whole and each line stands on its own. Escaped text cannot hold a
  # raw `<`, so nothing the file says can look like this markup.
  defp split(html) do
    [_whole, body] = Regex.run(~r{\A<pre[^>]*><code[^>]*>(.*)</code></pre>\z}s, html)

    body
    |> String.split("\n")
    |> Enum.map(fn line ->
      [_whole, inner] = Regex.run(~r{\A<span class="l-line" data-line="\d+">(.*)</span>\z}, line)
      {:safe, inner}
    end)
  end

  # Lumis's lines, so that both answers hold the same ones: a final newline ends the last line
  # rather than starting another, as an editor numbers them, and `\r\n` is one line break.
  defp plain(source) do
    {:plain,
     source
     |> String.replace_suffix("\n", "")
     |> String.split("\n")
     |> Enum.map(&String.trim_trailing(&1, "\r"))}
  end

  @doc """
  What `file/2` answered, drawn: one row per line, its number in a gutter a reader's selection
  skips, its text wrapping rather than scrolling sideways (`code.css`).

  `first` numbers a slice from where it was cut (an excerpt of lines 14–19 is numbered from 14),
  and `marks` adds a class to the rows it names by number — the lines a change added, the lines
  an excerpt showed (`docs/design/ui.md` § Changes).
  """
  attr :lines, :any, required: true, doc: "what `file/2` returned"
  attr :first, :integer, default: 1, doc: "the number of the first line drawn"
  attr :marks, :map, default: %{}, doc: "`%{number => class}` for the rows to mark"
  attr :class, :any, default: nil, doc: "added to the block's own classes"
  attr :rest, :global

  def code(assigns) do
    ~H"""
    <div
      class={["code", match?({:highlighted, _}, @lines) && "code-highlighted", @class]}
      translate="no"
      {@rest}
    >
      <div
        :for={{line, number} <- Enum.with_index(elem(@lines, 1), @first)}
        class={["code-line", @marks[number]]}
        data-line={number}
      >
        <span class="code-number" aria-hidden="true">{number}</span><span
          class="code-text"
          style={"--hang: #{hang(line)}ch"}
        >{line}</span>
      </div>
    </div>
    """
  end

  @doc """
  How far a wrapped line's continuation hangs, in characters: the line's own indent and two
  more, so the rest of `order_by: [desc: s.score,` sits under its own line and never back at the
  code's first column, where it read as a new line (UX pass, B4, C12). A tab is four, as
  `tab-size` draws it.
  """
  @spec hang(Phoenix.HTML.safe() | String.t()) :: non_neg_integer()
  def hang({:safe, _iodata} = line) do
    line
    |> Phoenix.HTML.safe_to_string()
    |> String.replace(~r/<[^>]*>/, "")
    |> hang()
  end

  def hang(line) when is_binary(line) do
    [indent] = Regex.run(~r/^[ \t]*/, line)
    String.length(String.replace(indent, "\t", "    ")) + 2
  end
end
