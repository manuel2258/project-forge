defmodule ForgeWeb.Diff do
  @moduledoc """
  A change between two commits: how it is read out of the repository, and how it is drawn.

  Three pages show one, read the same way, in one drawing: a repository commit's page and the
  Changes view of a ticket and of a conversation all draw `file_table/1`, whose rows each expand
  to their own patch, tinted and numbered. What each says when there is no change to draw is the same sentence, from one
  place.

  **A diff is bounded.** Past a size it is not rendered inline: a page nobody can read is not a
  review, and the change is still named file by file with its counts. The same is true of a
  patch that is not valid UTF-8, for a harder reason than readability — see `inline?/2`. In
  both cases the map of the change survives and the patch gives way to the `git diff` that
  reads it. See `docs/design/ui.md` § Semantics that must not be lost.
  """

  use Phoenix.Component

  alias Forge.Git

  # Big enough for a real change, small enough that the page stays readable.
  @max_patch_bytes 512 * 1024
  @max_patch_files 60

  @typedoc "What `build/3` returns: the change, or why it could not be read."
  @type t :: %{optional(:error) => term(), optional(atom()) => term()}

  @doc "Reads the change from `base` to `head` out of `repo`."
  @spec build(String.t(), String.t() | nil, String.t() | nil) :: t() | nil
  def build(_repo, nil, _head), do: nil
  def build(_repo, _base, nil), do: nil

  def build(repo, base, head) do
    with {:ok, stat} <- Git.diff_stat(repo, base, head),
         {:ok, patch} <- Git.diff(repo, base, head) do
      text? = ForgeCore.Document.text?(patch)

      %{
        head: head,
        base: base,
        files: stat,
        added: total(stat, 1),
        removed: total(stat, 2),
        patch: patch,
        text: text?,
        inline: text? and small?(patch, stat),
        bytes: byte_size(patch)
      }
    else
      {:error, reason} -> %{error: reason}
    end
  end

  # A patch is drawn when it is small enough to read; `build/3` also requires that it be text the
  # page can carry. git diffs a file it thinks is binary as one line, but a file that is merely
  # not UTF-8 — `caf\xE9`, a latin-1 source file — it diffs in full, and those bytes then go out
  # in the HTML. On a plain GET that is a response body that is not valid UTF-8; through the
  # socket, `Phoenix.Socket.V2.JSONSerializer.encode!/1` raises on them in the socket's own
  # process and takes every LiveView on the connection with it. `ForgeCore.Document.text?/1` is
  # the rule the rest of the product already uses for exactly this question, and a *path* that is
  # not text is answered a layer down, by `Forge.Git.printable_path/1`.
  defp small?(patch, stat) do
    byte_size(patch) <= @max_patch_bytes and length(stat) <= @max_patch_files
  end

  defp total(stat, index) do
    stat
    |> Enum.map(&elem(&1, index))
    |> Enum.reject(&(&1 == :binary))
    |> Enum.sum()
  end

  @doc """
  The change file by file, for a table whose rows expand to their own patch in place:
  `%{path, added, removed, lines, hunks}`, in the file table's order. `lines` is the file's
  patch, with each hunk header as `{:hunk, header, line}` — the first line of the new side, which
  is what a reference to the hunk points at — and every other line as `{:line, text}`. It is nil
  when there is no patch to draw: the change is too large to draw inline (the table still names
  every file — it is the map), or the file is binary. `hunks` is each hunk's header and line.
  """
  @spec files(t() | nil) :: [map()]
  def files(%{files: files} = diff) when is_list(files) do
    patches = if diff[:inline], do: split(diff.patch || ""), else: %{}

    for {path, added, removed} <- files do
      lines = patch_lines(Map.get(patches, path))
      hunks = for {:hunk, header, line} <- lines || [], do: %{header: header, line: line}
      %{path: path, added: added, removed: removed, lines: lines, hunks: hunks}
    end
  end

  def files(_diff), do: []

  # Keyed by the path on the `+++` line — the old side's, on `---`, for a file the change
  # deletes — which is what `--numstat` names for anything but a rename. Not the `diff --git`
  # header: with a space in the path, `a/a b/c b/a b/c` has more than one reading, and the lazy
  # one put another file's patch under this one's name. Git marks a path with a space by a tab
  # after it on `+++`, and quotes one with a quote or a control character in it, the same way
  # `--numstat` does. A patch with neither line — a binary file, a mode change, a pure rename —
  # has no key and its row does not expand.
  defp split(patch) do
    patch
    |> String.split(~r/^(?=diff --git )/m, trim: true)
    |> Enum.flat_map(fn chunk ->
      case chunk_path(chunk) do
        nil -> []
        path -> [{path, String.trim_trailing(chunk, "\n")}]
      end
    end)
    |> Map.new()
  end

  defp chunk_path(chunk) do
    new = Regex.run(~r/^\+\+\+ (.*)$/m, chunk, capture: :all_but_first)
    old = Regex.run(~r/^--- (.*)$/m, chunk, capture: :all_but_first)

    case {new, old} do
      {["/dev/null"], [old]} -> side(old, "a/")
      {[new], _old} -> side(new, "b/")
      _neither -> nil
    end
  end

  defp side(printed, prefix) do
    printed
    |> String.trim_trailing("\t")
    |> Git.unquote_path()
    |> String.replace_prefix(prefix, "")
    # The same form `--numstat` gives the file table, so a row still finds its own patch.
    |> Git.printable_path()
  end

  defp patch_lines(nil), do: nil

  defp patch_lines(patch) do
    for line <- String.split(patch, "\n") do
      case Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)/, line) do
        [_all, start] -> {:hunk, line, String.to_integer(start)}
        nil -> {:line, line}
      end
    end
  end

  @doc """
  The lines `diff` adds, by file: `%{path => MapSet.t(line)}`, numbered on the new side — what an
  excerpt of the head commit tints as added (`docs/design/ui.md` § Changes). Empty for a file
  whose patch is not drawn: too large, or binary.
  """
  @spec added_lines(t() | nil) :: %{String.t() => MapSet.t(pos_integer())}
  def added_lines(diff) do
    for %{path: path, lines: lines} <- files(diff), lines != nil, into: %{} do
      {path, for({:add, number, _text} <- numbered(lines), into: MapSet.new(), do: number)}
    end
  end

  @doc """
  A file's patch as rows to draw: `{:hunk, header, line}` as `files/1` has it, and every line
  inside a hunk as `{:add | :del | :ctx | :meta, number, text}` — its number on the new side, or
  the old side's for a line taken out, and its text without the sign. The header lines before the
  first hunk (`diff --git`, `index`, `---`, `+++`) are the file's name again and are dropped;
  `\ No newline at end of file` is `:meta`, numbered nil.
  """
  @spec numbered([tuple()]) :: [tuple()]
  def numbered(lines) do
    {rows, _at} =
      Enum.flat_map_reduce(lines, nil, fn
        {:hunk, header, new}, _at -> {[{:hunk, header, new}], {old_start(header), new}}
        {:line, _text}, nil -> {[], nil}
        {:line, "+" <> text}, {old, new} -> {[{:add, new, text}], {old, new + 1}}
        {:line, "-" <> text}, {old, new} -> {[{:del, old, text}], {old + 1, new}}
        {:line, " " <> text}, {old, new} -> {[{:ctx, new, text}], {old + 1, new + 1}}
        {:line, ""}, at -> {[], at}
        {:line, text}, at -> {[{:meta, nil, text}], at}
      end)

    rows
  end

  defp old_start(header) do
    case Regex.run(~r/^@@ -(\d+)/, header) do
      [_all, start] -> String.to_integer(start)
      nil -> 0
    end
  end

  @doc """
  The Changes view's file list (`docs/design/ui.md` § Changes): never truncated, each file's
  `+ −`, each row opening its own patch in place — rows tinted at 10 % for lines added and taken
  out, numbered, wrapping rather than scrolling sideways — and, when `ask` names an event,
  *Ask about this* beside each row and each hunk header.

  The control is beside the row and never inside it: a row that expands is a control of its
  own, and one tap meaning two things is what `ui.md` § The affordance rule exists to prevent.
  """
  attr :diff, :map, required: true
  attr :id, :string, default: "changes-files"
  attr :ask, :string, default: nil, doc: "the event *Ask about this* sends, with `ref`"
  attr :open, :string, default: nil, doc: "the path of a row drawn open"

  def file_table(assigns) do
    assigns = assign(assigns, rows: files(assigns.diff))

    ~H"""
    <.unreadable diff={@diff} />

    <ul :if={@rows != []} id={@id} class="diff-files">
      <li
        :for={{row, index} <- Enum.with_index(@rows)}
        id={"#{@id}-#{index}"}
        class={["diff-file", @ask && "diff-file--ask"]}
        data-path={row.path}
      >
        <%!-- Kept open across a patch: a conversation's Changes tab is drawn again as its
              branch moves (`ui.md` § Motion and structure). --%>
        <details
          :if={row.lines}
          class="diff-details"
          open={@open == row.path}
          phx-mounted={ForgeWeb.Actions.keep_open()}
        >
          <summary class="diff-summary">
            <.path_name path={row.path} />
            <.counts added={row.added} removed={row.removed} />
            <span class="diff-chevron" aria-hidden="true">›</span>
          </summary>
          <%!-- No ligatures, as for every `pre` (base.css): `|>` drawn as a triangle is not
                what the file says. --%>
          <div class="diff-patch">
            <%= for line <- numbered(row.lines) do %>
              <%= case line do %>
                <% {:hunk, header, number} -> %>
                  <div class="diff-hunk" data-hunk={number}>
                    <span class="diff-hunk-text">{header}</span>
                    <.ask_button :if={@ask} event={@ask} ref={"#{row.path}:#{number}"} />
                  </div>
                <% {kind, number, text} -> %>
                  <div class={["diff-line", "diff-line--#{kind}"]}>
                    <span class="diff-num" aria-hidden="true">{number}</span><span
                      class="diff-sign"
                      aria-hidden="true"
                    >{sign(kind)}</span><span class="diff-text">{text}</span>
                  </div>
              <% end %>
            <% end %>
          </div>
        </details>

        <div :if={!row.lines} class="diff-summary">
          <.path_name path={row.path} />
          <.counts added={row.added} removed={row.removed} />
        </div>

        <div :if={@ask} class="diff-ask">
          <.ask_button event={@ask} ref={ref(row)} />
        </div>
      </li>
    </ul>

    <.not_drawn diff={@diff} />
    """
  end

  defp sign(:add), do: "+"
  defp sign(:del), do: "−"
  defp sign(_kind), do: ""

  @doc "A path as the design draws one: its directory muted, its name at full ink."
  attr :path, :string, required: true

  def path_name(assigns) do
    assigns = assign(assigns, split: split_path(assigns.path))

    ~H"""
    <span class="diff-path"><span class="diff-dir">{elem(@split, 0)}</span>{elem(@split, 1)}</span>
    """
  end

  defp split_path(path) do
    case String.split(path, "/") |> Enum.split(-1) do
      {[], [name]} -> {"", name}
      {dirs, [name]} -> {Enum.join(dirs, "/") <> "/", name}
    end
  end

  attr :added, :any, required: true
  attr :removed, :any, required: true

  # A binary file has no line counts: `--numstat` says `-`, which `Git` reads as `:binary`.
  defp counts(%{added: :binary} = assigns) do
    ~H"""
    <span class="diff-binary">binary</span>
    """
  end

  defp counts(assigns) do
    ~H"""
    <ForgeWeb.UI.Data.diff_stat added={@added} removed={@removed} />
    """
  end

  attr :diff, :map, required: true
  attr :class, :string, default: nil

  # Why a change has no rows: it could not be read, or it changes nothing.
  defp unreadable(assigns) do
    ~H"""
    <p :if={@diff[:error]} class={["text-sm/[1.55] text-danger", @class]}>
      The change cannot be read from the repository: {inspect(@diff[:error])}
    </p>

    <p :if={@diff[:files] == []} class={["text-sm/[1.55] text-ink-2", @class]}>
      The branch changes nothing against its base.
    </p>
    """
  end

  attr :diff, :map, required: true

  # Why the patch is not here, and where it can be read instead. Two reasons, one sentence each:
  # too much of it, or bytes the page cannot carry.
  defp not_drawn(assigns) do
    ~H"""
    <p
      :if={@diff[:files] not in [nil, []] and @diff[:inline] == false}
      class="mt-4 text-sm/[1.55] text-ink-2"
    >
      <span :if={@diff[:text] == false}>
        Part of this change is not valid UTF-8, so it is not text this page can draw.
      </span>
      <span :if={@diff[:text] != false}>
        This change is {bytes(@diff.bytes)} across {length(@diff.files)} files, too much to read on
        one page.
      </span>
      Read it with <span class="font-mono text-[12.5px]">git diff {short(@diff.base)}..{short(@diff.head)}</span>.
    </p>
    """
  end

  @doc "The strip's summary of a change: `+added −removed over N files`, when there is one."
  attr :diff, :any, required: true

  def stat(assigns) do
    ~H"""
    <span :if={@diff[:files]}>
      +{@diff.added} −{@diff.removed} over {length(@diff.files)} {if length(@diff.files) == 1,
        do: "file",
        else: "files"}
    </span>
    """
  end

  @doc "How many files a change touches — its Changes tab's count — or 0 when there is none."
  @spec file_count(t() | nil) :: non_neg_integer()
  def file_count(%{files: files}) when is_list(files), do: length(files)
  def file_count(_diff), do: 0

  @doc """
  The commits from `base` to `head` in `repo`, newest first — or none when either end is not
  there to read, as a branch that was deleted is not.
  """
  @spec commits(String.t(), String.t() | nil, String.t()) :: [map()]
  def commits(_repo, nil, _head), do: []

  def commits(repo, base, head) do
    case Git.log(repo, base, head) do
      {:ok, commits} -> commits
      {:error, _gone} -> []
    end
  end

  # A file row points at its first hunk, which is where its change starts; a file with no hunk to
  # point into — binary, or too large to draw — is named on its own.
  defp ref(%{path: path, hunks: [%{line: line} | _]}), do: "#{path}:#{line}"
  defp ref(%{path: path}), do: path

  attr :event, :string, required: true
  attr :ref, :string, required: true

  defp ask_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-ref={@ref}
      aria-label={"Ask about #{@ref}"}
      class="diff-ask-button"
    >
      Ask
    </button>
    """
  end

  @doc """
  One commit as every list of them draws it (`10a`): its subject, and under it the short sha, the
  author and how long ago it was committed — with a chevron, and the whole row a link, when
  `navigate` is given.

  Here rather than beside either of its two callers — a branch's commits on a work screen, and a
  repository's own history — because the two had drawn the same row with the same four class
  strings and two different sha lengths, and `short/1` exists so that there is one answer. A
  commit read before git was asked for its author has none, and the row then says nothing of it.
  """
  attr :commit, :map, required: true
  attr :now, :any, required: true, doc: "the moment ages are measured from"
  attr :navigate, :string, default: nil, doc: "where the row leads, when it leads anywhere"

  def commit_row(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class="flex min-h-[52px] items-center gap-3 py-2 hover:bg-surface-2"
    >
      <.commit_fields commit={@commit} now={@now} />
      <span class="shrink-0 text-ink-3" aria-hidden="true">›</span>
    </.link>

    <div :if={is_nil(@navigate)} class="flex min-h-[52px] items-center gap-3 py-2">
      <.commit_fields commit={@commit} now={@now} />
    </div>
    """
  end

  attr :commit, :map, required: true
  attr :now, :any, required: true

  defp commit_fields(assigns) do
    ~H"""
    <span class="flex min-w-0 flex-1 flex-col gap-0.5">
      <span class="commit-subject break-words text-[14px]/[1.4] text-ink">{@commit.subject}</span>
      <span class="commit-meta font-mono text-[11.5px] text-ink-3">
        {short(@commit.sha)}<span :if={@commit[:author]}> · <span class="commit-author">{@commit.author}</span></span>
        · {ForgeWeb.Format.ago(@commit.at, @now)}
      </span>
    </span>
    """
  end

  @doc "The first twelve characters of a sha, for reading rather than for resolving."
  @spec short(String.t() | nil) :: String.t()
  def short(nil), do: "—"
  def short(sha), do: String.slice(sha, 0, 12)

  defp bytes(count) when count >= 1_048_576, do: "#{Float.round(count / 1_048_576, 1)} MB"
  defp bytes(count) when count >= 1024, do: "#{div(count, 1024)} KB"
  defp bytes(count), do: "#{count} bytes"
end
