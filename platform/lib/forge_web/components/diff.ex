defmodule ForgeWeb.Diff do
  @moduledoc """
  A change between two commits: how it is read out of the repository, and how it is drawn.

  Four pages show one, read the same way, in two drawings. A ticket's review page and a
  repository commit's page both draw `section/1` — the file table and the whole patch beneath it,
  which is what an approval is given on — and the Changes tab of a ticket and of a conversation
  draws `file_table/1`, whose rows each expand to their own patch. What each says when there is
  no change to draw is the same sentence, from one place.

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

  attr :diff, :map, required: true
  attr :id, :string, default: "diff"
  attr :title, :string, default: "The diff"

  def section(assigns) do
    ~H"""
    <section id={@id}>
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">{@title}</h2>

      <.unreadable diff={@diff} class="mt-3" />

      <table :if={@diff[:files] not in [nil, []]} class="mt-3 w-full text-[12.5px]">
        <tbody>
          <tr :for={{path, added, removed} <- @diff.files} class="border-b border-base-300/60">
            <td class="py-1.5 font-mono break-all">{path}</td>
            <td class="w-24 py-1.5 text-right font-mono opacity-60">
              {count(added, "+")} {count(removed, "−")}
            </td>
          </tr>
        </tbody>
      </table>

      <pre
        :if={@diff[:inline] && @diff[:patch] not in [nil, ""]}
        class="mt-4 overflow-x-auto border border-base-300 p-3 font-mono text-[12.5px] leading-[1.5]"
      ><code>{@diff.patch}</code></pre>

      <.not_drawn diff={@diff} />
    </section>
    """
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
  The Changes tab's file table (`docs/design/ui.md` § Changes): never truncated, each row
  expanding to its own patch in place, and — when `ask` names an event — *Ask about this* beside
  each row and each hunk header.

  The control is beside the row and never inside it: a row that expands is a control of its
  own, and one tap meaning two things is what `ui.md` § The affordance rule exists to prevent.
  """
  attr :diff, :map, required: true
  attr :id, :string, default: "changes-files"
  attr :ask, :string, default: nil, doc: "the event *Ask about this* sends, with `ref`"

  def file_table(assigns) do
    assigns = assign(assigns, rows: files(assigns.diff))

    ~H"""
    <.unreadable diff={@diff} />

    <ul :if={@rows != []} id={@id} class="flex flex-col">
      <li :for={row <- @rows} class="relative border-b border-base-300/60" data-path={row.path}>
        <%!-- Kept open across a patch: a conversation's Changes tab is drawn again as its
              branch moves (`ui.md` § Motion and structure). --%>
        <details :if={row.lines} class="group" phx-mounted={ForgeWeb.Actions.keep_open()}>
          <summary class={[
            "flex min-h-[46px] cursor-pointer items-center gap-3 py-1.5 font-mono text-[12.5px]",
            @ask && "pr-16"
          ]}>
            <span aria-hidden="true" class="opacity-40 group-open:rotate-90">▸</span>
            <span class="min-w-0 flex-1 break-all">{row.path}</span>
            <span class="shrink-0 opacity-60">{count(row.added, "+")} {count(row.removed, "−")}</span>
          </summary>
          <%!-- No ligatures, as for every `pre` (app.css): `|>` drawn as a triangle is not
                what the file says. --%>
          <div class="mb-3 overflow-x-auto rounded-field border border-base-300 font-mono text-[12.5px] leading-[1.5] [font-variant-ligatures:none]">
            <%= for line <- row.lines do %>
              <%= case line do %>
                <% {:hunk, header, number} -> %>
                  <div
                    class="flex items-center gap-2 border-y border-base-300/60 bg-base-200 pl-3"
                    data-hunk={number}
                  >
                    <span class="min-w-0 flex-1 whitespace-pre opacity-70">{header}</span>
                    <.ask_button :if={@ask} event={@ask} ref={"#{row.path}:#{number}"} />
                  </div>
                <% {:line, text} -> %>
                  <div class="whitespace-pre px-3">{text}</div>
              <% end %>
            <% end %>
          </div>
        </details>

        <div
          :if={!row.lines}
          class={[
            "flex min-h-[46px] items-center gap-3 py-1.5 font-mono text-[12.5px]",
            @ask && "pr-16"
          ]}
        >
          <span class="min-w-0 flex-1 break-all">{row.path}</span>
          <span class="shrink-0 opacity-60">{count(row.added, "+")} {count(row.removed, "−")}</span>
        </div>

        <div :if={@ask} class="absolute top-0 right-0">
          <.ask_button event={@ask} ref={ref(row)} />
        </div>
      </li>
    </ul>

    <.not_drawn diff={@diff} />
    """
  end

  attr :diff, :map, required: true
  attr :class, :string, default: nil

  # Why a change has no rows: it could not be read, or it changes nothing.
  defp unreadable(assigns) do
    ~H"""
    <p :if={@diff[:error]} class={["text-sm/[1.55] text-error", @class]}>
      The change cannot be read from the repository: {inspect(@diff[:error])}
    </p>

    <p :if={@diff[:files] == []} class={["text-sm/[1.55] opacity-70", @class]}>
      The branch changes nothing against its base.
    </p>
    """
  end

  attr :diff, :map, required: true

  # Why the patch is not here, and where it can be read instead. Two reasons, one sentence each:
  # too much of it, or bytes the page cannot carry.
  defp not_drawn(assigns) do
    ~H"""
    <p :if={@diff[:files] not in [nil, []] and @diff[:inline] == false} class="mt-4 text-sm/[1.55]">
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
      class="min-h-[46px] shrink-0 px-2 font-sans text-[12.5px] text-primary hover:underline"
    >
      Ask
    </button>
    """
  end

  defp count(:binary, _sign), do: "binary"
  defp count(number, sign), do: "#{sign}#{number}"

  @doc """
  One commit as every list of them draws it: its sha, its subject, and how long ago it was
  committed. A whole row when `navigate` is given, and the row's contents otherwise.

  Here rather than beside either of its two callers — a branch's commits on a work screen, and a
  repository's own history — because the two had drawn the same row with the same four class
  strings and two different sha lengths, and `short/1` exists so that there is one answer.
  """
  attr :commit, :map, required: true
  attr :now, :any, required: true, doc: "the moment ages are measured from"
  attr :navigate, :string, default: nil, doc: "where the row leads, when it leads anywhere"

  def commit_row(assigns) do
    ~H"""
    <.link
      :if={@navigate}
      navigate={@navigate}
      class="flex min-h-[46px] items-center gap-3 py-1.5 text-[12.5px] hover:bg-base-200"
    >
      <.commit_fields commit={@commit} now={@now} />
    </.link>

    <div
      :if={is_nil(@navigate)}
      class="flex min-h-[46px] items-center gap-3 py-1.5 text-[12.5px]"
    >
      <.commit_fields commit={@commit} now={@now} />
    </div>
    """
  end

  attr :commit, :map, required: true
  attr :now, :any, required: true

  defp commit_fields(assigns) do
    ~H"""
    <span class="shrink-0 font-mono opacity-60">{short(@commit.sha)}</span>
    <span class="min-w-0 flex-1 break-words text-sm/[1.4]">{@commit.subject}</span>
    <span class="shrink-0 font-mono opacity-50">{ForgeWeb.Format.ago(@commit.at, @now)}</span>
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
