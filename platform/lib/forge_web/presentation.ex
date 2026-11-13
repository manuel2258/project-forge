defmodule ForgeWeb.Presentation do
  @moduledoc """
  A ticket's presentations, read for the Changes view (`docs/design/ui.md` § Changes): what an
  agent wrote for the person deciding, with the source each paragraph quotes drawn beneath it.
  The whole file an excerpt was cut from is `ForgeWeb.Blob.read/3`'s, as the repository's is.

  **A presentation is free markdown.** The platform draws what the project's workflow wrote and
  gives it no sections of its own — "How it was checked", "Worth a look" are prose a workflow may
  write, never slots this module looks for. What it adds is the excerpt: where a paragraph quotes
  `` `path:line` `` or `` `path:start-end` `` in backticks, those lines from the changeset's head
  commit, highlighted, with the lines the change added tinted.

  **What is drawn is bounded**, and every bound is on what the page draws rather than on what
  the document says, because the prose is an agent's: quotes per presentation, lines and bytes
  per quote, bytes read out of git, and the length of prose rendered.
  Each bound that stops something says so where it would have drawn it, and nothing here can fail
  the page.
  """

  use Phoenix.Component

  alias Forge.{Artifacts, Git}
  alias ForgeWeb.{FileType, Highlight}

  # A file and a line or range quoted in backticks, which the prose that quotes it has drawn
  # beneath it (`docs/design/ui.md` § Changes). No colon, backtick or space in the path, because
  # the colon is the separator and the quote is one token of prose. The line numbers are bounded
  # here rather than parsed and judged: `String.to_integer` on an unbounded run of digits is work
  # proportional to the digits, and a million of them measured 177 ms before any of it could be
  # refused for naming a line no file has. The prose cap below holds a document to 64 KiB now, so
  # that is no longer the worst case; the bound stays because seven digits is every line of every
  # file anyone has, and refusing the eighth costs nothing.
  @quoted ~r/`([^`:\s]+):(\d{1,7})(?:-(\d{1,7}))?`/

  # A range longer than this is a file, not a quote: it would push the prose it belongs to off
  # the screen, which is the one thing a presentation exists to keep readable.
  @max_quoted_lines 60

  # And a long enough line is a file too, whatever the line count says — one minified line is a
  # megabyte. Both caps are on the slice, so neither depends on how the file is formatted.
  @max_quoted_bytes 16 * 1024

  # **How many bytes one presentation reads out of git, over all its quotes.** The caps above are
  # on the slice, and a slice is cut from a blob the whole of which `Git.show/3` has captured:
  # five lines quoted out of a 53 MB tracked file cost 98 MB of heap and half a second before
  # either cap could refuse them. So a blob's size is asked for first (`Git.blob_size/3`) and a
  # file that does not fit in what is left of this budget is never read.
  #
  # A budget for the presentation and not a cap per file, because a cap per file multiplies by
  # `@max_quotes`: twelve 1 MiB files are all held in `acc.files` at once until `blocks/4`
  # returns, and twelve of one-byte lines measured 8 s and 550 MiB — enough to be OOM-killed on a
  # 4 GB machine. **What this bounds is the bytes, not the cost of splitting them**: that scales
  # with the file's line count, and 1 MiB of one-byte lines is 524,289 lines, 665 ms and 46 MiB
  # retained. One such file per presentation is the worst case now, where twelve was.
  @max_read_bytes 1024 * 1024

  # **How many quotes are drawn at all**, counted over the whole presentation and over every
  # paragraph of it. The prose is an agent's and bounded only by the cap below, in which
  # `` `a:1` `a:2` … `` fits some thirteen thousand quotes; drawing them would be thirteen
  # thousand blocks of up to 16 KiB, built on every load, per viewer, and again on every patch of
  # the page. It counts what is *drawn* and not what is distinct: one quote named in forty
  # paragraphs is forty blocks against one path read, and bounding the reads is half of it.
  @max_quotes 12

  # **How much of a presentation's prose is drawn.** A document may be a megabyte, and `x\n\n` a
  # megabyte long is 300,000 paragraphs — ten seconds of Markdown per load, per viewer, because
  # each paragraph is parsed on its own so that what it quotes can be drawn beneath it. Past this
  # the page draws the beginning and says so, with its own `source ›` link to the whole. A
  # presentation is prose a person reads in a minute (`docs/design/ui.md` § Changes), which this
  # is many times over. It makes that cost 15 times smaller rather than nothing: 64 KiB of
  # paragraphs is still some 760 ms per load.
  @max_prose_bytes 64 * 1024

  @typedoc "One quote: where it points, and its lines or why there are none."
  @type quote_ :: %{
          path: String.t(),
          from: pos_integer(),
          to: pos_integer(),
          label: String.t(),
          lines: {:ok, String.t()} | :unresolved | :too_long | :not_text,
          code: Highlight.lines() | nil
        }

  @doc """
  The latest version of every presentation on the ticket, oldest first, each cut into paragraphs
  with the quotes each makes resolved at `head` — the changeset's commit, or nil before there is
  one, when every quote is a note. `added` is the lines the change added, `%{path => MapSet}`,
  for tinting what an excerpt shows (`added_lines/1`).
  """
  @spec build(map(), map(), String.t(), String.t() | nil, map()) :: [map()]
  def build(project, ticket, repo, head, added \\ %{}) do
    scope = Forge.References.ticket_scope(project.name, ticket)

    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :presentation,
        version = Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      {artifact.name, version}
    end
    |> Enum.sort_by(fn {_name, version} -> version.inserted_at end, DateTime)
    |> Enum.with_index()
    |> Enum.map(fn {{name, version}, index} ->
      Map.merge(
        %{name: name, version: version, index: index},
        blocks(version, repo, head, scope, added)
      )
    end)
  end

  @doc "Whether the ticket has a presentation at all: cheaper than `build/5`, for the default view."
  @spec any?([map()]) :: boolean()
  def any?(artifacts) do
    Enum.any?(artifacts, &(&1.artifact.kind == :presentation and &1.latest != nil))
  end

  # Paragraphs, each with the source it quotes beneath it, how many quotes the cap left out, and
  # whether the prose itself was cut short.
  #
  # Splitting on blank lines is the whole of the parsing, and it is meant to be: a quote inside a
  # list item spanning paragraphs is drawn under the part it sits in rather than beside its own
  # line, and a fenced block with a blank line in it is cut in two and its second half read as
  # prose. Both cost legibility in one paragraph and neither can fail the page. A bigger parser
  # would buy very little for prose this simple.
  defp blocks(version, repo, head, scope, added) do
    {prose, truncated} = prose(version.content)

    paragraphs =
      prose
      |> String.split(~r/\r?\n[ \t]*\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    # `files` and `read` are the reading budget, `drawn` and `dropped` the drawing cap: all four
    # are the presentation's and not the paragraph's, which is what the caps above say.
    budget = %{files: %{}, read: 0, drawn: 0, dropped: 0}

    # Parsed once, resolved together: the images and links of every paragraph in a constant
    # number of queries, against the moment the presentation version was written (`ui.md`
    # § Documents → References). Images are the one thing here with no cap.
    parsed = Enum.map(paragraphs, &ForgeWeb.Markdown.parse/1)

    refs = Enum.map(parsed, &ForgeWeb.Markdown.references/1)
    moment = if Enum.any?(refs, &(&1 != [])), do: Forge.References.moment(version)
    resolved = Forge.References.resolve(scope, refs |> Enum.with_index(&{&2, moment, &1}))

    {blocks, counted} =
      paragraphs
      |> Enum.zip(parsed)
      |> Enum.with_index()
      |> Enum.map_reduce(budget, fn {{paragraph, md}, index}, acc ->
        {quotes, acc} = draw(Enum.uniq(tokens(paragraph)), repo, head, acc)
        quotes = Enum.map(quotes, &excerpt(&1, added))

        {%{index: index, html: ForgeWeb.Markdown.render(md, resolved[index]), quotes: quotes},
         acc}
      end)

    %{blocks: blocks, dropped: counted.dropped, truncated: truncated}
  end

  # The slice, highlighted as the file it came from, and which of its lines the change added.
  # Highlighted here, once, and never in a template (`ForgeWeb.Highlight`); the slice and not the
  # file, because the slice is bounded at 16 KiB and the file only by the read budget.
  defp excerpt(%{lines: {:ok, text}} = quoted, added) do
    marks =
      for number <- quoted.from..quoted.to//1,
          MapSet.member?(Map.get(added, quoted.path, MapSet.new()), number),
          into: %{},
          do: {number, "code-line--add"}

    Map.merge(quoted, %{code: Highlight.file(quoted.path, text), marks: marks})
  end

  defp excerpt(quoted, _added), do: Map.merge(quoted, %{code: nil, marks: %{}})

  # The prose the page draws, and whether there was more of it. Cut at a whole character, since
  # a half of one is not a string any more and every caller downstream treats it as one.
  defp prose(content) do
    prose = ForgeWeb.Markdown.strip_front_matter(content)

    if byte_size(prose) > @max_prose_bytes,
      do: {whole_characters(binary_part(prose, 0, @max_prose_bytes)), true},
      else: {prose, false}
  end

  # A character is at most four bytes, so a cut inside one leaves at most three bytes to drop, and
  # three is where this stops. A prefix no such drop makes valid came from content that was
  # already invalid, which cannot be stored: a version's content is a Postgres `text` column, and
  # `Jason.decode/1` refuses a lone surrogate before the column ever sees it. Bounded rather than
  # walking back to the start of the document, which was quadratic on exactly the input it exists
  # for — an invalid byte at offset 0 of a 64 KiB prefix is 65,500 passes of `String.valid?/1`
  # over 64 KiB.
  defp whole_characters(prose) do
    Enum.find_value(0..3, prose, fn drop ->
      prefix = binary_part(prose, 0, byte_size(prose) - drop)
      if String.valid?(prefix), do: prefix
    end)
  end

  # One paragraph's quotes, against the cap for the whole presentation: `@max_quotes` drawn, the
  # rest counted. `acc.files` carries every path already read across paragraphs too, so a path
  # quoted in three of them is read once — which bounds the reads, where `drawn` bounds the HTML.
  defp draw(tokens, repo, head, acc) do
    Enum.flat_map_reduce(tokens, acc, fn {path, from, to}, acc ->
      if acc.drawn < @max_quotes do
        {lines, acc} = lines(acc, repo, head, path, from, to)
        quoted = %{path: path, from: from, to: to, label: label(path, from, to), lines: lines}
        {[quoted], %{acc | drawn: acc.drawn + 1}}
      else
        {[], %{acc | dropped: acc.dropped + 1}}
      end
    end)
  end

  # Every quote the prose makes, in the order it makes them: `{path, from, to}`.
  defp tokens(paragraph) do
    @quoted
    |> Regex.scan(paragraph)
    |> Enum.map(fn
      [_all, path, line] -> {path, to_line(line), to_line(line)}
      [_all, path, from, to] -> {path, to_line(from), to_line(to)}
    end)
  end

  # Bounded by the pattern to seven digits, so this is arithmetic on a short string and not on
  # whatever run of digits the prose held.
  defp to_line(digits), do: String.to_integer(digits)

  defp label(path, from, to),
    do: if(from == to, do: "#{path}:#{from}", else: "#{path}:#{from}-#{to}")

  # The changeset's own commit and no other: a presentation quotes the change it is about
  # (`docs/design/ui.md` § Changes). Anything that does not resolve there — no changeset yet, a
  # path that is not in that tree, a line before the first or after the last, a range the wrong
  # way round — is a note and never a raised page, because the prose is an agent's and unbounded.
  defp lines(acc, _repo, nil, _path, _from, _to), do: {:unresolved, acc}

  defp lines(acc, repo, head, path, from, to) when from >= 1 and to >= from do
    if to - from + 1 > @max_quoted_lines do
      {:too_long, acc}
    else
      {content, acc} = file(acc, repo, head, path)
      {slice(content, from, to), acc}
    end
  end

  defp lines(acc, _repo, _head, _path, _from, _to), do: {:unresolved, acc}

  # Keyed by the path, never by the quote: the whole file is cached and the slice taken after,
  # so one entry serves every range quoted out of it. Keying it by anything that is not the path
  # — a constant, say — would serve one file's lines under another's label, which is what the
  # two-file test of the Changes view holds. (That each path is read *once* is the saving, and is
  # an equivalent mutant: nothing a test can see distinguishes one `git show` from three.)
  defp file(acc, repo, head, path) do
    case Map.fetch(acc.files, path) do
      {:ok, cached} -> {cached, acc}
      :error -> read(acc, repo, head, path)
    end
  end

  # **The size first, then the bytes.** A quote names a path in a tree at head, not a path in the
  # change, so it reaches every blob the repository holds at that commit — `@max_read_bytes` is
  # what keeps drawing one bounded, since both caps above are on the slice and a slice is cut from
  # a file already in memory. What is left of the budget is what this file may be; spending it is
  # what a read costs, and a path already in `acc.files` costs nothing because it is not read
  # again.
  #
  # And a blob is only text if it says so. `Git.show/3` hands back whatever bytes are there, the
  # diff prints `Binary files … differ` rather than them, and invalid UTF-8 on the page is a
  # `Jason` exception in the socket's serializer — on the page where merges are approved, for
  # every viewer at once. So the bytes are checked before they can be drawn, which is the same
  # standard `ForgeWeb.Markdown` holds its own renderer to.
  defp read(acc, repo, head, path) do
    {read, bytes} =
      with {:ok, size} when size <= @max_read_bytes - acc.read <-
             Git.blob_size(repo, head, path),
           {:ok, content} <- Git.show(repo, head, path) do
        {if(String.valid?(content), do: source_lines(content), else: :not_text), size}
      else
        {:ok, _over_budget} -> {:too_big, 0}
        {:error, _reason} -> {:missing, 0}
      end

    {read, %{acc | files: Map.put(acc.files, path, read), read: acc.read + bytes}}
  end

  # A file's lines, counted the way an editor counts them. `String.split/2` on text ending in a
  # newline leaves a trailing `""`, so the last line used to be one past the end: an 18-line file
  # quoted as `:19` drew an empty block under the label, indistinguishable from a blank line.
  defp source_lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [_ | _] = lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
      [] -> []
    end
  end

  defp slice(:missing, _from, _to), do: :unresolved
  defp slice(:too_big, _from, _to), do: :too_long
  defp slice(:not_text, _from, _to), do: :not_text

  defp slice(all, from, to) when is_list(all) do
    if to <= length(all) do
      text = all |> Enum.slice(from - 1, to - from + 1) |> Enum.join("\n")
      if byte_size(text) > @max_quoted_bytes, do: :too_long, else: {:ok, text}
    else
      :unresolved
    end
  end

  @doc """
  `"14-19"` or `"14"` from an address, as a range of lines to mark, or nil. Bounded to seven
  digits like a quote, so a number off the address is never arithmetic on a megabyte of digits.
  """
  @spec range(String.t() | nil) :: Range.t() | nil
  def range(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{1,7})(?:-(\d{1,7}))?\z/, value) do
      [_all, line] -> to_line(line)..to_line(line)
      [_all, from, to] -> ordered(to_line(from), to_line(to))
      nil -> nil
    end
  end

  def range(_none), do: nil

  defp ordered(from, to) when from >= 1 and from <= to, do: from..to
  defp ordered(_from, _to), do: nil

  # -- drawing -------------------------------------------------------------------------------

  @doc """
  One presentation, drawn as the presentation kind is everywhere: dashed, *view only*, no
  approval slot. Each paragraph is an anchor (`para-<n>-<i>`) the whole-file view comes back to;
  each excerpt has its label, *Whole file ›* (`file_href`), and on a wide screen becomes a
  control that shows its file in the pane beside (`follow`).
  """
  attr :shown, :map, required: true
  attr :source, :string, required: true, doc: "the version's address"
  attr :file_href, :any, required: true, doc: "fn quote, paragraph id -> the whole-file address"
  attr :follow, :string, default: nil, doc: "the event that shows a file in the wide pane"

  def presentation(assigns) do
    ~H"""
    <article id={"presentation-#{@shown.name}"} class="pres" data-presentation>
      <header class="pres-head">
        <FileType.file_icon artifact={%{name: @shown.name, kind: :presentation}} />
        <span class="pres-name">{@shown.name}</span>
        <span>v{@shown.version.version}</span>
        <span class="pres-kind">view only</span>
      </header>

      <div
        :for={block <- @shown.blocks}
        id={para_id(@shown, block)}
        class="pres-para"
        data-follow={follow_path(block)}
        data-follow-lines={follow_lines(block)}
      >
        <div class="doc">{block.html}</div>
        <.excerpt
          :for={quoted <- block.quotes}
          quoted={quoted}
          href={@file_href.(quoted, para_id(@shown, block))}
          follow={@follow}
        />
      </div>

      <p :if={@shown.truncated} class="pres-note">
        This presentation is longer than the page draws; the rest is in its source.
      </p>

      <p :if={@shown.dropped > 0} class="pres-note">{dropped_note(@shown.dropped)}</p>

      <.link href={@source} class="pres-source">source ›</.link>
    </article>
    """
  end

  @doc "The anchor of one paragraph, which *‹ Presentation* returns to."
  @spec para_id(map(), map()) :: String.t()
  def para_id(shown, block), do: "para-#{shown.index}-#{block.index}"

  # The first quote a paragraph draws is the file the wide pane follows while it is in view.
  defp follow_path(%{quotes: [%{code: code, path: path} | _]}) when code != nil, do: path
  defp follow_path(_block), do: nil

  defp follow_lines(%{quotes: [%{code: code} = quoted | _]}) when code != nil,
    do: "#{quoted.from}-#{quoted.to}"

  defp follow_lines(_block), do: nil

  attr :quoted, :map, required: true
  attr :href, :string, required: true
  attr :follow, :string, default: nil

  defp excerpt(assigns) do
    ~H"""
    <div class="excerpt" data-quote={@quoted.label}>
      <div class="excerpt-head">
        <span class="excerpt-label">{@quoted.label}</span>
        <.link :if={@quoted.code} patch={@href} class="excerpt-whole">Whole file ›</.link>
        <button
          :if={@quoted.code && @follow}
          type="button"
          class="excerpt-follow"
          phx-click={@follow}
          phx-value-path={@quoted.path}
          phx-value-lines={"#{@quoted.from}-#{@quoted.to}"}
        >
          {Path.basename(@quoted.path)} {@quoted.from}–{@quoted.to} ›
        </button>
      </div>
      <Highlight.code
        :if={@quoted.code}
        lines={@quoted.code}
        first={@quoted.from}
        marks={@quoted.marks}
        class="excerpt-code"
      />
      <p :if={!@quoted.code} class="excerpt-note">{note(@quoted)}</p>
    </div>
    """
  end

  # One sentence rather than interpolation around the markup's own whitespace: what it says is
  # read, and a page that quietly drew a dozen of thirty would be read as having drawn them all.
  defp dropped_note(1),
    do: "1 further quote is not drawn: a presentation draws at most #{@max_quotes}."

  defp dropped_note(dropped),
    do: "#{dropped} further quotes are not drawn: a presentation draws at most #{@max_quotes}."

  defp note(%{label: label, lines: :too_long}),
    do: "#{label} is too much to draw here; read it in Files"

  defp note(%{label: label, lines: :not_text}),
    do: "#{label} is not text; read it in Files"

  defp note(%{label: label}), do: "#{label} is not in this changeset's commit"
end
