defmodule ForgeWeb.Changes do
  @moduledoc """
  A ticket's Changes view (`docs/design/ui.md` § Changes, `19d`–`19g`, `18b`, `18f`): **the review
  page and Changes are one view**, under a switch of **Presentation · Files · Commits**.

  It opens on the presentation while the ticket is in review and has one — its decision row is
  an approval of the change — and otherwise on Files, with Presentation dimmed and the reason.
  Every excerpt of the presentation links to its whole file at the changeset's commit, the lines
  it showed marked and a way back to its paragraph; on a wide screen the file sits beside the
  presentation and follows the paragraph in view. Files carries, beneath the list, what the merge
  approval needs beside the diff (`docs/decisions.md`): the documents the change was built from,
  the questions answered and the ticket's usage.

  What each sub-view reads is read only while that sub-view is on screen: a presentation is
  paragraphs of Markdown and some git, the whole file a bounded read and a highlight, the
  documents a render each, and the ticket's page loads again on every change to the ticket.
  """

  use ForgeWeb, :html

  alias Forge.{Artifacts, Projects}
  alias ForgeWeb.{Blob, Diff, FileType, Format, Highlight, Presentation, WorkScreen}
  alias Phoenix.LiveView.JS

  @subs ~w(presentation files commits)

  # -- the page's state ----------------------------------------------------------------------

  @doc """
  What the address says about Changes: the sub-view, the file opened whole, the lines to mark in
  it and the paragraph it was opened from. Anything else in the address is ignored.
  """
  @spec params(map()) :: map()
  def params(params) do
    %{
      sub: if(params["sub"] in @subs, do: params["sub"]),
      file: blank_to_nil(params["file"]),
      lines: Presentation.range(params["lines"]),
      para: para(params["para"])
    }
  end

  # An anchor this page writes, `para-<n>-<i>`, and nothing else: it goes back into a link.
  defp para(value) when is_binary(value),
    do: if(Regex.match?(~r/\Apara-\d{1,4}-\d{1,6}\z/, value), do: value)

  defp para(_none), do: nil

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value) when is_binary(value), do: value
  defp blank_to_nil(_other), do: nil

  @doc "The assigns a page starts with: nothing read, nothing followed."
  @spec init(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def init(socket) do
    Phoenix.Component.assign(socket,
      changes_params: params(%{}),
      changes: nil,
      changes_key: nil,
      changes_default: nil,
      follow: nil
    )
  end

  @doc """
  Forgets the sub-view chosen when none was named, so the next `load/1` chooses it again: as the
  page is opened or navigated, and after the person's own decision — never because the ticket
  changed under a reader (`docs/design/ui.md` § The ticket).
  """
  @spec choose_again(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def choose_again(socket), do: Phoenix.Component.assign(socket, changes_default: nil)

  @doc """
  Reads what the sub-view on screen needs (see the module doc), from the page's `project`,
  `ticket`, `workflow`, `artifacts`, `changeset`, `diff` and `decision`. A presentation is built
  again only when what it is built from changed: its versions, the commit, the diff.
  """
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(%{assigns: assigns} = socket) do
    presented = Presentation.any?(assigns.artifacts)
    # With nothing named, the sub-view chosen first is kept: someone reading Files is not moved
    # to Presentation when an approval arrives. A kept Presentation the ticket no longer has is
    # still Files (`sub/3`).
    named = assigns.changes_params
    kept = assigns[:changes_default]
    unnamed? = is_nil(named.sub) and is_nil(named.file)

    sub =
      sub(
        if(unnamed? and kept, do: %{named | sub: kept}, else: named),
        presented,
        assigns.decision
      )

    socket =
      if unnamed? and is_nil(kept),
        do: Phoenix.Component.assign(socket, changes_default: sub),
        else: socket

    head = head(assigns.changeset)
    repo = Projects.repo_path(assigns.project)

    base = %{sub: sub, presented: presented, head: head, file: nil, presentations: []}

    {changes, key} =
      case sub do
        "presentation" -> presentations(assigns, base, repo)
        "files" -> {files(assigns, base, repo), nil}
        "commits" -> {base, nil}
      end

    Phoenix.Component.assign(socket, changes: changes, changes_key: key)
  end

  @doc """
  The sub-view on screen: the one the address names, unless it names a presentation there is
  none of; else Presentation while the ticket is in review and has one, else Files.
  """
  @spec sub(map(), boolean(), map() | nil) :: String.t()
  def sub(%{file: file}, _presented, _decision) when file != nil, do: "files"
  def sub(%{sub: "presentation"}, false, _decision), do: "files"
  def sub(%{sub: sub}, _presented, _decision) when sub != nil, do: sub

  def sub(_params, true, decision),
    do: if(in_review?(decision), do: "presentation", else: "files")

  def sub(_params, false, _decision), do: "files"

  # In review: what waits is an approval of the change — one that merges, or that pins the
  # changeset.
  defp in_review?(%{kind: :approval, merges: true}), do: true
  defp in_review?(%{kind: :approval, pins: pins}), do: Enum.any?(pins, & &1.changeset)
  defp in_review?(_none), do: false

  defp head(nil), do: nil
  defp head(changeset), do: Artifacts.commit(changeset)

  defp presentations(assigns, base, repo) do
    added = if assigns.diff[:head] == base.head, do: Diff.added_lines(assigns.diff), else: %{}

    key =
      {base.head, assigns.diff[:head],
       for(a <- assigns.artifacts, a.artifact.kind == :presentation, a.latest, do: a.latest.id)}

    shown =
      if key == assigns.changes_key and assigns.changes,
        do: assigns.changes.presentations,
        else: Presentation.build(assigns.project, assigns.ticket, repo, base.head, added)

    {%{base | presentations: shown}, key}
  end

  defp files(%{changes_params: %{file: nil}} = assigns, base, _repo) do
    Map.merge(base, %{
      documents: documents(assigns.project, assigns.ticket),
      answers: Artifacts.answered(assigns.ticket.id)
    })
  end

  # The whole file, at the changeset's commit — or, before there is one, at the branch's head,
  # which is what Files is showing then.
  defp files(%{changes_params: %{file: path}} = assigns, base, repo) do
    at = base.head || assigns.diff[:head]
    %{base | file: %{path: path, at: at, whole: Blob.read(repo, at, path)}}
  end

  # The chain the change was built from, in the order it was written, each marked with whether a
  # person approved it.
  defp documents(project, ticket) do
    scope = Forge.References.ticket_scope(project.name, ticket)

    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :document,
        version = Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      %{
        name: artifact.name,
        version: version,
        approved: Artifacts.approved?(version),
        body: FileType.render_document(artifact.name, version, scope)
      }
    end
    |> Enum.sort_by(& &1.version.inserted_at, DateTime)
  end

  @doc """
  `changes:follow`: the file the wide screen's pane shows (`19g`), sent by the paragraph that
  comes into view and by the pane's file tabs. Reads one bounded file at the changeset's commit
  and writes nothing.
  """
  @spec follow(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def follow(%{assigns: assigns} = socket, %{"path" => path} = params) when is_binary(path) do
    lines = Presentation.range(params["lines"])

    case assigns.follow do
      %{path: ^path, lines: ^lines} ->
        socket

      _other ->
        head = head(assigns.changeset)
        repo = Projects.repo_path(assigns.project)
        whole = Blob.read(repo, head, path)
        Phoenix.Component.assign(socket, follow: %{path: path, lines: lines, whole: whole})
    end
  end

  def follow(socket, _params), do: socket

  # -- drawing -------------------------------------------------------------------------------

  @doc "The view: the switch, then the sub-view on screen."
  def view(assigns) do
    assigns =
      assign(assigns,
        path: ~p"/tickets/#{assigns.project.name}/#{assigns.ticket.number}",
        files: Diff.file_count(assigns.diff)
      )

    ~H"""
    <div class={["changes", "changes--#{@changes.sub}"]} data-sub={@changes.sub}>
      <nav id="changes-switch" class="ui-seg ui-seg--md changes-switch" aria-label="Changes">
        <.link
          :if={@changes.presented}
          id="changes-sub-presentation"
          patch={"#{@path}?tab=changes&sub=presentation"}
          class="ui-seg-opt"
          aria-current={@changes.sub == "presentation" && "page"}
        >
          Presentation
        </.link>
        <span
          :if={!@changes.presented}
          id="changes-sub-presentation"
          class="ui-seg-opt changes-switch-off"
          aria-disabled="true"
          title="No presentation yet"
        >
          Presentation
        </span>
        <.link
          id="changes-sub-files"
          patch={"#{@path}?tab=changes&sub=files"}
          class="ui-seg-opt"
          aria-current={@changes.sub == "files" && "page"}
        >
          Files <span class="changes-switch-count">{@files}</span>
        </.link>
        <.link
          id="changes-sub-commits"
          patch={"#{@path}?tab=changes&sub=commits"}
          class="ui-seg-opt"
          aria-current={@changes.sub == "commits" && "page"}
        >
          Commits <span class="changes-switch-count">{length(@commits)}</span>
        </.link>
      </nav>

      <.presentation_view :if={@changes.sub == "presentation"} {assigns} />
      <.whole_file :if={@changes.sub == "files" and @changes.file != nil} {assigns} />
      <.files_view :if={@changes.sub == "files" and @changes.file == nil} {assigns} />
      <div :if={@changes.sub == "commits"} id="changes-commits">
        <WorkScreen.commits commits={@commits} now={@now} />
        <p :if={@commits == []} class="changes-empty">No commits on its branch since its base.</p>
      </div>
    </div>
    """
  end

  defp presentation_view(assigns) do
    assigns =
      assign(assigns,
        tabs:
          for(
            shown <- assigns.changes.presentations,
            block <- shown.blocks,
            quoted <- block.quotes,
            quoted.code != nil,
            uniq: true,
            do: quoted.path
          ),
        file_href: fn quoted, para ->
          "#{assigns.path}?" <>
            URI.encode_query(
              tab: "changes",
              sub: "files",
              file: quoted.path,
              lines: "#{quoted.from}-#{quoted.to}",
              para: para
            )
        end
      )

    ~H"""
    <div id="changes-presentation" class="changes-pres-cols">
      <div class="changes-pres">
        <Presentation.presentation
          :for={shown <- @changes.presentations}
          shown={shown}
          source={
            ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{shown.name}/#{shown.version.version}"
          }
          file_href={@file_href}
          follow="changes:follow"
        />
        <p :if={is_nil(@changes.head)} class="changes-empty">
          No job has produced a changeset on this ticket yet, so nothing it quotes can be drawn.
        </p>
      </div>

      <%!-- The wide screen's pane (`19g`): the whole file the paragraph in view points at. The
            hook reports that paragraph only from 1440 up, where the pane is drawn. --%>
      <aside id="changes-follow" class="changes-follow" phx-hook=".Follow">
        <nav :if={@tabs != []} class="changes-follow-tabs" aria-label="Quoted files">
          <button
            :for={path <- @tabs}
            type="button"
            class="changes-follow-tab"
            aria-current={@follow && @follow.path == path && "true"}
            phx-click="changes:follow"
            phx-value-path={path}
          >
            {Path.basename(path)}
          </button>
          <span class="changes-follow-hint">follows the paragraph in view</span>
        </nav>
        <.file_body
          :if={@follow}
          path={@follow.path}
          whole={@follow.whole}
          lines={@follow.lines}
          added={added(@diff, @changes.head, @follow.path)}
        />
      </aside>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Follow">
      // The pane beside the presentation follows the paragraph in view (`docs/design/ui.md`
      // § Changes, `19g`): the first paragraph with a quote whose top is in the upper part of the
      // scroller is the one followed. Only where the pane is drawn, so a phone reads no file.
      const WIDE = "(min-width: 1440px)"

      export default {
        mounted() {
          this.sent = null
          this.scroller = this.el.closest("[id='changes']") || window
          this.onScroll = () => {
            if (this.frame) return
            this.frame = requestAnimationFrame(() => { this.frame = null; this.pick() })
          }
          this.scroller.addEventListener("scroll", this.onScroll, {passive: true})
          window.addEventListener("resize", this.onScroll)
          this.pick()
        },
        updated() { this.pick() },
        destroyed() {
          this.scroller.removeEventListener("scroll", this.onScroll)
          window.removeEventListener("resize", this.onScroll)
        },
        pick() {
          if (!window.matchMedia(WIDE).matches) return
          const top = this.scroller === window ? 0 : this.scroller.getBoundingClientRect().top
          const paras = document.querySelectorAll("#changes-presentation [data-follow]")
          let chosen = null
          for (const para of paras) {
            const rect = para.getBoundingClientRect()
            if (rect.bottom > top + 24) { chosen = para; break }
          }
          if (!chosen) return
          const key = chosen.dataset.follow + ":" + chosen.dataset.followLines
          if (key === this.sent) return
          this.sent = key
          this.pushEvent("changes:follow", {path: chosen.dataset.follow, lines: chosen.dataset.followLines})
        }
      }
    </script>
    """
  end

  defp added(diff, head, path) do
    if diff[:head] == head,
      do: Map.get(Diff.added_lines(diff), path, MapSet.new()),
      else: MapSet.new()
  end

  defp whole_file(assigns) do
    file = assigns.changes.file
    paths = for {path, _added, _removed} <- assigns.diff[:files] || [], do: path
    index = Enum.find_index(paths, &(&1 == file.path))

    assigns =
      assign(assigns,
        file: file,
        stat: Enum.find(assigns.diff[:files] || [], &(elem(&1, 0) == file.path)),
        index: index,
        count: length(paths),
        previous: index && index > 0 && Enum.at(paths, index - 1),
        next: index && Enum.at(paths, index + 1),
        back:
          if(assigns.changes_params.para,
            do: "#{assigns.path}?tab=changes&sub=presentation##{assigns.changes_params.para}"
          )
      )

    ~H"""
    <section
      id="changes-file"
      class="changes-file"
      data-path={@file.path}
      phx-hook=".ScrollToMark"
    >
      <header class="changes-file-head">
        <.link :if={@back} id="changes-back" patch={@back} class="changes-back">‹ Presentation</.link>
        <.link
          :if={!@back}
          id="changes-back"
          patch={"#{@path}?tab=changes&sub=files"}
          class="changes-back"
        >
          ‹ Files
        </.link>
        <Diff.path_name path={@file.path} />
        <span :if={@stat && is_integer(elem(@stat, 1))} class="changes-file-stat">
          <.diff_stat added={elem(@stat, 1)} removed={elem(@stat, 2)} />
        </span>
      </header>

      <.file_body
        path={@file.path}
        whole={@file.whole}
        lines={@changes_params.lines}
        added={added(@diff, @file.at, @file.path)}
      />

      <nav :if={@index} class="changes-file-foot" aria-label="Neighbouring files">
        <.link
          :if={@previous}
          patch={"#{@path}?#{URI.encode_query(tab: "changes", sub: "files", file: @previous)}"}
          class="changes-file-prev"
        >
          ‹ {Path.basename(@previous)}
        </.link>
        <span class="changes-file-at">{@index + 1} of {@count}</span>
        <.link
          :if={@next}
          patch={"#{@path}?#{URI.encode_query(tab: "changes", sub: "files", file: @next)}"}
          class="changes-file-next"
        >
          {Path.basename(@next)} ›
        </.link>
      </nav>
    </section>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToMark">
      // A file opened from an excerpt opens at the lines it showed (`19e`), once per file: a
      // patch of the same file leaves the reader where they scrolled to. It lands three lines
      // above the first marked one, under the sticky head, so the file's name and the way back
      // are on screen with the lines and the lines are read in their context (UX pass, B3).
      const ABOVE = 3

      export default {
        mounted() { this.go() },
        updated() { if (this.el.dataset.path !== this.path) this.go() },
        go() {
          this.path = this.el.dataset.path
          let line = this.el.querySelector(".code-line--marked")
          for (let i = 0; line && i < ABOVE && line.previousElementSibling; i++) {
            line = line.previousElementSibling
          }
          if (line) line.scrollIntoView({block: "start"})
        }
      }
    </script>
    """
  end

  attr :path, :string, required: true
  attr :whole, :any, required: true
  attr :lines, :any, required: true, doc: "the range to mark, or nil"
  attr :added, :any, required: true, doc: "the lines the change added"

  # One file, whole: highlighted, the lines the change added tinted and the lines an excerpt
  # showed marked in the margin — or why it is not drawn.
  defp file_body(%{whole: {:text, lines, _bytes}} = assigns) do
    # The marked range off the address is cut to the file before it is walked: seven digits
    # is a range of ten million lines. Without the cut the same rows are marked, only after a
    # walk of the whole range — time and memory, which no assertion here can see, so dropping it
    # is an equivalent mutant as far as a test goes.
    marked =
      case assigns.lines do
        first..last//_ ->
          Map.new(max(first, 1)..min(last, length(elem(lines, 1)))//1, &{&1, "code-line--marked"})

        nil ->
          %{}
      end

    marks =
      assigns.added
      |> Map.new(&{&1, "code-line--add"})
      |> Map.merge(marked, fn _number, added, mark -> "#{added} #{mark}" end)

    assigns = assign(assigns, code: lines, marks: marks)

    ~H"""
    <Highlight.code lines={@code} marks={@marks} class="changes-file-code" id="changes-file-code" />
    <p :if={@lines} class="changes-file-note">The lines the presentation showed are marked.</p>
    """
  end

  defp file_body(%{whole: {:too_large, bytes}} = assigns) do
    assigns = assign(assigns, bytes: bytes)

    ~H"""
    <p class="changes-empty">{Blob.too_large(@path, @bytes)}</p>
    """
  end

  defp file_body(%{whole: :binary} = assigns) do
    ~H"""
    <p class="changes-empty">{@path} is not text this page can draw.</p>
    """
  end

  defp file_body(assigns) do
    ~H"""
    <p class="changes-empty">{@path} is not in this changeset's commit.</p>
    """
  end

  defp files_view(assigns) do
    ~H"""
    <%!-- From 1440 the index and the patches are side by side (`18f`): the first patch opens by
          itself and the index marks the file in view, so the two columns are not the same list
          twice (UX pass, B21). Below 1440 the list is the map and every row starts closed. --%>
    <div id="changes-files-view" class="changes-files-cols" phx-hook=".FilesIndex">
      <nav
        :if={Diff.file_count(@diff) > 0}
        id="changes-index"
        class="changes-index"
        aria-label="Files"
      >
        <.eyebrow>Files · {Diff.file_count(@diff)}</.eyebrow>
        <button
          :for={{{path, added, removed}, index} <- Enum.with_index(@diff.files)}
          type="button"
          class="changes-index-row"
          data-index={index}
          phx-click={
            JS.set_attribute({"open", "open"}, to: "#changes-files-#{index} details")
            |> JS.focus(to: "#changes-files-#{index} summary")
          }
        >
          <Diff.path_name path={path} />
          <.diff_stat :if={is_integer(added)} added={added} removed={removed} />
        </button>
      </nav>

      <div class="changes-files-main">
        <%!-- First: it says what the list below is, so read after the list it explained nothing
              (UX pass, B28). --%>
        <p :if={!@changes.presented} id="changes-no-presentation" class="changes-empty">
          No presentation yet. Until one is written, this is the work in progress on {@ticket.branch}.
        </p>

        <.will_commit decision={@decision} />

        <Diff.file_table :if={@diff} diff={@diff} ask="ask" />
        <p :if={!@diff} class="changes-empty">Its branch is not in the repository.</p>

        <.needs {assigns} />
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".FilesIndex">
      // Only where the index is drawn beside the patches. Opening the first patch is done once,
      // as the view mounts, and only when the reader has opened none: a patch never reopens what
      // they closed. The row marked is the last file whose top has passed the scroller's top.
      const WIDE = "(min-width: 1440px)"

      export default {
        mounted() {
          this.scroller = this.el.closest("[id='changes']") || window
          this.onScroll = () => {
            if (this.frame) return
            this.frame = requestAnimationFrame(() => { this.frame = null; this.mark() })
          }
          this.scroller.addEventListener("scroll", this.onScroll, {passive: true})
          if (window.matchMedia(WIDE).matches) {
            const all = this.el.querySelectorAll("#changes-files > li > details")
            if (all.length && ![...all].some((d) => d.open)) all[0].open = true
          }
          this.mark()
        },
        updated() { this.mark() },
        destroyed() { this.scroller.removeEventListener("scroll", this.onScroll) },
        mark() {
          if (!window.matchMedia(WIDE).matches) return
          const top = this.scroller === window ? 0 : this.scroller.getBoundingClientRect().top
          let current = null
          this.el.querySelectorAll("#changes-files > li").forEach((li, i) => {
            if (li.getBoundingClientRect().top <= top + 8 || current === null) current = i
          })
          this.el.querySelectorAll(".changes-index-row").forEach((row) => {
            if (Number(row.dataset.index) === current) row.setAttribute("aria-current", "true")
            else row.removeAttribute("aria-current")
          })
        }
      }
    </script>
    """
  end

  attr :decision, :any, required: true

  # What the merge will commit, read before anything else on a phone (`18b`): the one drawing of
  # a commit message (`WorkScreen.commit_message/1`), as the panel draws it beside Approve.
  defp will_commit(
         %{decision: %{kind: :approval, merges: true, commit_message: %{} = v}} = assigns
       ) do
    assigns = assign(assigns, :version, v)

    ~H"""
    <WorkScreen.commit_message version={@version} id="changes-will-commit" />
    """
  end

  defp will_commit(assigns), do: ~H""

  # Beside the diff, what the merge approval needs (`docs/decisions.md`): the documents it was
  # built from, the questions answered on the ticket, and what the ticket used.
  defp needs(assigns) do
    ~H"""
    <section :if={@changes.documents != []} id="changes-built-from" class="changes-needs">
      <.eyebrow>Built from</.eyebrow>
      <%!-- The page reloads on every change to its ticket, and a patch must not close what
            the reader opened (`ui.md` § Motion and structure). --%>
      <details
        :for={doc <- @changes.documents}
        id={"changes-doc-#{doc.name}"}
        class="changes-doc"
        phx-mounted={ForgeWeb.Actions.keep_open()}
      >
        <summary class="changes-doc-head">
          <FileType.file_icon artifact={%{name: doc.name, kind: :document}} />
          <span class="changes-doc-name">{doc.name}</span>
          <span class="changes-doc-version">v{doc.version.version}</span>
          <span :if={doc.approved} class="changes-doc-approved">✓ approved</span>
        </summary>
        <div class="changes-doc-body">
          <FileType.document_body body={doc.body} />
          <.link
            href={
              ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{doc.name}/#{doc.version.version}"
            }
            class="changes-doc-source"
          >
            source ›
          </.link>
        </div>
      </details>
    </section>

    <section id="changes-answers" class="changes-needs">
      <.eyebrow>Questions answered</.eyebrow>
      <ol :if={@changes.answers != []} class="changes-answers">
        <li :for={entry <- @changes.answers} class="changes-answer">
          <blockquote :if={entry.question.anchor} class="changes-answer-anchor">
            {entry.question.anchor}
          </blockquote>
          <p>{entry.question.text}</p>
          <p>
            <span class="text-ink-3">answered</span>
            <span :if={entry.answer.choice} class="font-mono text-[12.5px]">
              {entry.answer.choice}
            </span>
            <span :if={entry.answer.text}>{entry.answer.text}</span>
            <span :if={entry.answer.token_id} class="font-mono text-[12.5px] text-ink-3">
              · API · {entry.token_name}
            </span>
          </p>
          <div class="changes-answer-meta">
            {entry.question.key} ·
            <.link href={
              ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{entry.artifact}/#{entry.version}"
            }>
              {entry.artifact} v{entry.version}
            </.link>
          </div>
        </li>
      </ol>
      <p :if={@changes.answers == []} class="changes-empty">
        No question stopped a job on this ticket. Everything the agents needed, they had.
      </p>
    </section>

    <section id="changes-usage" class="changes-needs">
      <.eyebrow>Usage</.eyebrow>
      <%!-- At zero, said in words with no bar: a meter at `0` was the one zero left on the page
            (UX re-check #7). --%>
      <div class="changes-usage">
        <span class="changes-usage-figure">
          {Format.spent(@ticket.usage) || "nothing spent yet"}
        </span>
        <ForgeWeb.TicketViews.allowance
          :if={Format.spent(@ticket.usage)}
          ticket={@ticket}
          workflow={@workflow}
          class="changes-usage-bar"
        />
        <span class="changes-usage-cap">
          allowance {Format.windows(@workflow.limits.ticket_tokens) || "—"}
        </span>
      </div>
    </section>
    """
  end
end
