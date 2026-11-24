defmodule ForgeWeb.WorkScreen do
  @moduledoc """
  What a conversation and a ticket both draw inside the frame (`docs/design/ui.md` § The frame):
  a state row, then the body of the view on screen, which is the page's only scroller.

  The frame itself is `Layouts.app` with `fill`: the title and the parent are its top bar, the
  views its strip and title-row tabs (`views/2`), the facts its details panel. The view is in the
  URL (`?tab=changes`, by patch), so back, reload and a pushed link land on it. A count of zero is
  drawn muted and never hidden, so the tabs never move.
  """

  use Phoenix.Component

  import ForgeWeb.Actions, only: [clip: 1, keep_open: 0, line: 1]
  import ForgeWeb.CoreComponents, only: [button: 1]
  import ForgeWeb.UI.Data, only: [eyebrow: 1]

  alias Forge.Artifacts
  alias ForgeWeb.FileType

  @doc """
  The object's views as the frame takes them, from `{key, label, count | nil}` in order: each
  patches the page's own `path` to `?tab=key`.
  """
  @spec views([{String.t(), String.t(), non_neg_integer() | nil}], String.t()) :: [map()]
  def views(tabs, path) do
    for {key, label, count} <- tabs,
        do: %{key: key, label: label, count: count, patch: "#{path}?tab=#{key}"}
  end

  @doc "A tab's body when it is not the transcript: it scrolls, and nothing else does."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def body(assigns) do
    ~H"""
    <%!-- No top padding: the frame's body already has it, and the two together put the first row
          56px under the bar (UX pass, B28). --%>
    <div id={@id} class="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-4">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The Docs view (`docs/design/ui.md` § Docs, `6a`): every artifact written, one row each — its
  type's tile (§ Artifact types), its name and latest version, who wrote it and when, and its
  approval mark only where approval is possible — with its earlier versions as links folded under
  it, and what the last turn wrote that was not recorded, with why.

  **Grouped by what each asks of you** when the docs carry a `group` (a ticket's do): *Waiting
  on you*, then *Built from*, then *Produced*. A conversation's docs carry none and are one list.

  A document's row is collapsed until it is opened, and opens to the document **rendered** — or
  to its text, when its name says text, a log or code. A file or a presentation has no body here:
  its row is the link to its bytes.

  A doc is what `doc/5` builds; a page may add `by`, who wrote the latest version in words.
  """
  attr :docs, :list, required: true
  attr :unrecorded, :map, default: %{}
  attr :empty, :string, default: "Nothing written yet."
  attr :now, :any, default: nil, doc: "the moment ages are measured from; none drawn without it"

  attr :refusal, :map,
    default: nil,
    doc: "the page's `:refusal`: a withdrawal refused is drawn above the rows"

  def docs(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.docs))

    ~H"""
    <p :if={@docs == [] and @unrecorded == %{}} class="text-sm text-ink-2">{@empty}</p>

    <ForgeWeb.Operator.Actions.refused
      id="withdraw-refusal"
      refusal={@refusal}
      at={["attachments:withdraw"]}
    />

    <div :for={{group, docs} <- @groups} id={group && "docs-#{group}"} class="work-docs">
      <div :if={group} class="work-docs-head">
        <.eyebrow>{group_label(group)}</.eyebrow>
      </div>
      <.doc_row :for={doc <- docs} doc={doc} now={@now} />
    </div>

    <%!-- Without this a document that did not arrive is only absent, which reads the same as
          one that was never written. --%>
    <ul :if={@unrecorded != %{}} id="unrecorded" class="mt-5 flex flex-col gap-2">
      <li :for={{name, why} <- Enum.sort(@unrecorded)} class="text-[12.5px]">
        <span class="font-mono break-all">{name}</span>
        <span class="text-danger">not recorded:</span>
        <span class="text-ink-2">{why}</span>
      </li>
    </ul>
    """
  end

  @order [:waiting, :built_from, :produced]

  # In the order a person reads them; a group with nothing in it is not drawn. Docs without a
  # group are one list with no heading.
  defp groups(docs) do
    if Enum.any?(docs, &Map.has_key?(&1, :group)) do
      by = Enum.group_by(docs, & &1.group)
      for group <- @order, by[group], do: {group, by[group]}
    else
      if docs == [], do: [], else: [{nil, docs}]
    end
  end

  defp group_label(:waiting), do: "Waiting on you"
  defp group_label(:built_from), do: "Built from"
  defp group_label(:produced), do: "Produced"

  attr :doc, :map, required: true
  attr :now, :any, required: true

  defp doc_row(assigns) do
    ~H"""
    <section id={"doc-#{@doc.name}"} class="work-doc">
      <%!-- The version link is beside the summary, not inside it: the summary is a control of
            its own, and one tap meaning two things is what `ui.md` § The affordance rule
            forbids. --%>
      <details :if={@doc.latest.body} class="group" phx-mounted={keep_open()}>
        <summary class="work-doc-row">
          <.doc_name entry={@doc} now={@now} />
        </summary>
        <div class="work-doc-body">
          <FileType.document_body body={@doc.latest.body} />
        </div>
      </details>
      <.link
        :if={@doc.latest.body}
        href={@doc.latest.href}
        aria-label={"#{@doc.name} v#{@doc.latest.version}"}
        class="work-doc-version"
      >
        v{@doc.latest.version} <span aria-hidden="true">›</span>
      </.link>

      <.link :if={!@doc.latest.body} href={@doc.latest.href} class="work-doc-row">
        <.doc_name entry={@doc} now={@now} />
        <span class="work-doc-version-inline">
          v{@doc.latest.version} <span aria-hidden="true">›</span>
        </span>
      </.link>

      <ForgeWeb.UI.Attach.names
        :if={@doc[:came_with] && @doc.came_with != []}
        files={@doc.came_with}
        path={& &1.href}
      />

      <.withdraw :if={@doc[:attached] && @doc.attached.withdrawable} doc={@doc} />

      <%!-- Folded: the latest is what is read, and a long history would push the next row away. --%>
      <details :if={@doc.earlier != []} class="work-doc-earlier-fold">
        <summary class="work-doc-earlier-count">
          {length(@doc.earlier)} earlier {if length(@doc.earlier) == 1,
            do: "version",
            else: "versions"}
        </summary>
        <.link
          :for={version <- @doc.earlier}
          href={version.href}
          class="work-doc-earlier"
        >
          <span>
            {meta([
              "v#{version.version}",
              if(version[:withdrawn], do: "withdrawn", else: "superseded"),
              version.author,
              ago(version.at, @now)
            ])}
          </span>
          <span aria-hidden="true">›</span>
        </.link>
      </details>
    </section>
    """
  end

  attr :doc, :map, required: true

  # What withdrawing a person's file says it cannot do is said before it is done, where it is done
  # (`docs/design/attachments.md` § Withdrawing): it stops the file going further, and recalls
  # nothing that was read.
  defp withdraw(assigns) do
    live =
      for {version, %{state: :live}} <- assigns.doc.attached.versions, do: version

    assigns = assign(assigns, live: Enum.sort(live), dom: dom_id(assigns.doc.name))

    ~H"""
    <details :if={@live != []} class="work-doc-withdraw" id={"withdraw-#{@dom}"}>
      <summary class="work-doc-earlier-count">Withdraw</summary>
      <form phx-submit="attachments:withdraw" class="work-doc-withdraw-form">
        <input type="hidden" name="name" value={@doc.name} />
        <label class="text-sm">
          Which
          <select name="which" aria-label={"Which version of #{@doc.name}"}>
            <option value="all">Every version</option>
            <option :for={version <- @live} value={version}>Version {version} only</option>
          </select>
        </label>
        <label class="text-sm">
          Why (optional) <input type="text" name="reason" maxlength="500" autocomplete="off" />
        </label>
        <p class="ui-field-hint">
          The file's bytes are deleted and nothing after this is given it; the record that it was
          attached stays. An agent that already read it may have quoted it in a reply, a document,
          a commit or a transcript, and a machine that downloaded it may hold it until that job's
          directory goes. Withdrawing stops it going further; it does not recall what was read.
          There is no undo.
        </p>
        <.button type="submit" variant="danger" phx-disable-with="Withdrawing…">Withdraw</.button>
      </form>
    </details>
    """
  end

  defp dom_id(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "-")

  @doc """
  Marks a Docs entry that is a person's file (`Forge.Attachments`): each version's state, which a
  row says as *withdrawn*, and whether this viewer may withdraw it. Any other entry is as it was.
  `scope` is the viewer's scope on the project, `user` the viewer.
  """
  @spec mark_attached(map(), [struct()], struct() | nil, struct() | nil) :: map()
  def mark_attached(%{name: "attachments/" <> _} = doc, versions, scope, user) do
    entries =
      versions
      |> Enum.map(& &1.id)
      |> Forge.Attachments.for_versions()
      |> Map.values()
      |> Forge.Attachments.entries()
      |> Map.new(&{&1.version, &1})

    withdrawn? = fn version -> match?(%{state: :withdrawn}, entries[version]) end

    # Who attached the latest version, as every Docs row says who wrote it: a person by their
    # address, a token by its name (`Forge.Attachments.describe/1`).
    by =
      case entries[doc.latest.version] do
        nil ->
          nil

        %{row: row} ->
          row
          |> List.wrap()
          |> Forge.Attachments.describe()
          |> Map.values()
          |> hd()
          |> Map.get(:by)
      end

    %{
      doc
      | latest: Map.put(doc.latest, :withdrawn, withdrawn?.(doc.latest.version)),
        earlier: Enum.map(doc.earlier, &Map.put(&1, :withdrawn, withdrawn?.(&1.version)))
    }
    |> Map.put(:by, by || doc[:by])
    |> Map.put(:attached, %{
      versions: entries,
      withdrawable:
        Enum.any?(entries, fn {_version, entry} ->
          Forge.Attachments.withdrawable_by?(scope, user, entry.row)
        end)
    })
  end

  def mark_attached(doc, _versions, _scope, _user), do: doc

  defp ago(_at, nil), do: nil
  defp ago(nil, _now), do: nil
  defp ago(at, now), do: ForgeWeb.Format.ago_phrase(at, now)

  defp meta(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  attr :entry, :map, required: true
  attr :now, :any, required: true

  # What a row says of its artifact, open or closed: its type, its name and where it stands.
  defp doc_name(assigns) do
    ~H"""
    <FileType.file_icon artifact={@entry} />
    <span class="work-doc-text">
      <%!-- The version once, at the row's end, where its link is: drawn here as well it was
            `plan.md v2 … v2 ›` (UX pass, B29). --%>
      <span class="work-doc-name">
        <%!-- A person's file is cut short with the whole name in the title; any other name breaks,
              which is how a long artifact name has always read (criterion 22). --%>
        <span
          :if={@entry[:attached]}
          class="min-w-0 work-doc-name-cut"
          title={@entry.name}
        >
          {@entry.name}
        </span>
        <span :if={!@entry[:attached]} class="min-w-0 break-all">{@entry.name}</span>
      </span>
      <span class="work-doc-meta">
        {meta([@entry[:by] || @entry.latest.author, ago(@entry.latest[:at], @now)])}
      </span>
      <%!-- The icon already says this to a screen reader; said again it is said twice. --%>
      <span :if={@entry.type == :apk} class="work-doc-meta" aria-hidden="true">Android app</span>
    </span>
    <span class="work-doc-mark">
      <span :if={@entry.kind == :presentation} class="text-ink-3">view only</span>
      <span :if={@entry.latest[:withdrawn]} class="text-ink-3">withdrawn</span>
      <span :if={@entry.approved} class="text-success">✓ approved</span>
      <span :if={@entry.approvable and not @entry.approved} class="text-accent-text">◇ unapproved</span>
    </span>
    """
  end

  @doc """
  One entry of the Docs view: `%{name, kind, type, latest, earlier, approvable, approved}`, from an
  artifact and the versions of it to show, oldest first. `type` is `ForgeWeb.FileType.of/1`'s.
  `latest` is `%{version, href, author, at, body}`, where a document's body is
  `ForgeWeb.FileType.render_document/3`'s and a blob's or a presentation's is nil. `earlier` is
  the versions before it, newest first, and the approval fields are about the latest. `href`
  gives a version number's address, and `approvable` is the page's to say: where approval is
  possible at all.
  """
  @spec doc(
          map(),
          [map()],
          (pos_integer() -> String.t()),
          boolean(),
          Forge.References.scope()
        ) :: map()
  def doc(artifact, versions, href, approvable, scope) do
    latest = List.last(versions)

    %{
      name: artifact.name,
      kind: artifact.kind,
      type: FileType.of(artifact),
      latest: %{
        version: latest.version,
        href: href.(latest.version),
        author: ForgeWeb.Format.author(latest.author),
        at: latest.inserted_at,
        # A blob's bytes are in the store, and drawing its row does not read them.
        body:
          if(artifact.kind == :document,
            do: FileType.render_document(artifact.name, latest, scope)
          )
      },
      earlier:
        for version <- versions |> Enum.drop(-1) |> Enum.reverse() do
          %{
            version: version.version,
            href: href.(version.version),
            author: ForgeWeb.Format.author(version.author),
            at: version.inserted_at
          }
        end,
      approvable: approvable,
      approved: approvable and Artifacts.approved?(latest)
    }
  end

  @doc "The commits on the branch, newest first, under the change they make (Changes)."
  attr :commits, :list, required: true
  attr :now, :any, required: true, doc: "the moment ages are measured from"

  def commits(assigns) do
    ~H"""
    <section :if={@commits != []} id="commits" class="mt-8">
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
        {length(@commits)} {if length(@commits) == 1, do: "commit", else: "commits"} on its branch
      </h2>
      <ol class="mt-3 flex flex-col">
        <li :for={commit <- @commits} class="border-b border-border-soft">
          <ForgeWeb.Diff.commit_row commit={commit} now={@now} />
        </li>
      </ol>
    </section>
    """
  end

  @doc """
  What the merge commit will say, read-only, directly above the control that merges
  (`docs/design/ui.md` § Changes).

  An agent's text, used as written: there is no editor here and never will be one. **One drawing
  wherever a merge is decided** — the decision panel, the queue's approval, Changes, a chat's
  merge — as git will write it: the subject in mono 13/500, a blank line, the body in mono
  `pre-wrap`, on `--surface-1` with no border (it is read, not tapped) and no *view only* (nothing
  near it is editable). It replaced three shapes for one object, one of which ran the body into the
  subject's sentence (UX pass, A15, B11, B23). Absent, it says there is nothing to merge yet
  instead of drawing an empty box.

  **It shows the string the commit will carry**, which is the version's body and not its raw
  text: `ForgeCore.Document.body/1`, the one the merge writes, so that an operator cannot approve
  one text and find git recording another. By convention there is no front matter to strip.
  """
  attr :version, :any, required: true, doc: "the `commit-message` version, or nil"
  attr :id, :string, default: "commit-message"

  def commit_message(assigns) do
    assigns = assign(assigns, :message, assigns.version && message(assigns.version))

    ~H"""
    <section id={@id}>
      <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
        The commit it will make
        <span :if={@version} class="ml-1 normal-case tracking-normal">
          · commit-message v{@version.version}
        </span>
      </h2>
      <div :if={@version} class="commit-message mt-2 min-w-0 rounded-card bg-surface-1 px-4 py-3">
        <p class="commit-message-subject">{elem(@message, 0)}</p>
        <pre :if={elem(@message, 1) != ""} class="commit-message-body">{elem(@message, 1)}</pre>
      </div>
      <p :if={is_nil(@version)} class="mt-2 text-sm/[1.55] opacity-70">
        Nothing has written the message this merge would carry, so there is nothing to merge yet.
      </p>
    </section>
    """
  end

  @doc """
  A commit message as git keeps it: `{subject, body}`, the subject its first line and the body
  what follows the blank line, from the version's body (`ForgeCore.Document.body/1`).
  """
  @spec message(%{content: String.t()}) :: {String.t(), String.t()}
  def message(%{content: content}) do
    case content |> ForgeCore.Document.body() |> String.trim() |> String.split("\n", parts: 2) do
      [subject, body] -> {subject, String.trim(body)}
      [subject] -> {subject, ""}
    end
  end

  # What the harness says about itself rather than about the work: Claude Code turns every
  # `system` message into one of these. Recorded, hidden behind their count, and **swept like the
  # rest of a finished job's stream** (`docs/design/ui.md` § Motion and structure,
  # `docs/design/storage.md` § Retention). `thinking_tokens`, which alone could outnumber everything
  # else in a job, is not recorded at all.
  @telemetry ["job.harness.notice"]

  @doc """
  The stream as it is drawn, newest first: each `tool_use` as an action paired with its result,
  whose own row is then not drawn again; every other event as itself; notices only when asked. A
  result with no call id is never paired, as `Forge.Events.Stream` reads it: SQL `=` does not
  match NULL, and the two must agree.
  """
  @spec entries([map()], boolean()) :: [{:action, map(), map()} | {:event, map()}]
  def entries(events, notices) do
    results =
      for %{type: "job.harness.tool_result", payload: %{"tool_use_id" => id} = payload} <- events,
          is_binary(id),
          into: %{},
          do: {id, payload}

    calls =
      for %{type: "job.harness.tool_use", payload: %{"id" => id}} <- events,
          is_binary(id),
          into: MapSet.new(),
          do: id

    events
    |> Enum.reject(&(hidden?(&1, notices) or paired?(&1, calls)))
    |> Enum.reverse()
    |> Enum.map(fn
      %{type: "job.harness.tool_use"} = event -> {:action, event, action(event, results)}
      event -> {:event, event}
    end)
  end

  defp hidden?(event, notices), do: not notices and event.type in @telemetry

  # A result is drawn on its call's line, so its own row would say it twice.
  defp paired?(%{type: "job.harness.tool_result", payload: %{"tool_use_id" => id}}, calls)
       when is_binary(id),
       do: MapSet.member?(calls, id)

  defp paired?(_event, _calls), do: false

  # The fold's own reading of a call and its result, so a field in the wrong type is read the
  # same way here as in the transcript.
  defp action(%{payload: payload} = event, results) do
    action = Forge.Conversations.action(payload, event.inserted_at)

    case results[payload["id"]] do
      nil -> action
      result -> %{action | result: Forge.Conversations.result(result)}
    end
  end

  @doc """
  A job's event stream (`docs/design/ui.md` § Activity): newest first, **what its `JobStream` holds**
  — a page, and more as the reader reaches the bottom — with notices behind their count. Tool
  calls are action lines, the same component the transcript draws them with; every other event
  keeps the job page's row, wrapped, its whole text past 200 characters behind a control
  (`ForgeWeb.Actions.clip/1`).

  Newest first needs no pinning: what arrives appears at the top, where the reader already is.
  The page owning it holds a `ForgeWeb.JobStream` and answers `more` with `JobStream.older/1` and
  `notices` with `JobStream.toggle_notices/2`. The end of what is held is where `.LoadOlder` loads
  the next page on its own; *Load 50 more* is the same press for when that does not.
  """
  attr :id, :string, default: "job-events"
  attr :stream, :any, required: true, doc: "the `ForgeWeb.JobStream` of the job, opened"
  attr :heading, :string, required: true
  attr :since, :any, default: nil, doc: "the person's previous look: what is newer is marked"

  attr :class, :any,
    default: nil,
    doc: "for the list: a page that is not a work screen bounds it itself, since no tab body does"

  attr :hrefs, :map,
    default: %{},
    doc: "`version_hrefs/1` of the page's docs: where a version an event names is read"

  attr :transcripts, :list,
    default: [],
    doc: "`transcript_links/3` of the job: what the swept line links"

  def activity(assigns) do
    assigns =
      assign(assigns,
        entries: entries(ForgeWeb.JobStream.held(assigns.stream), assigns.stream.notices)
      )

    ~H"""
    <div class="work-act-head">
      <.eyebrow>{@heading}</.eyebrow>
    </div>

    <ol class={["work-acts", @class]} id={@id}>
      <%!-- What happened first, when it happened at the row's end (`5d`): the time is the least
            of what a row says. --%>
      <%!-- Keyed and named by the event, so a row a reader opened is still that event's row after
            a newer one is drawn above it — by index, every row was another event's next time. --%>
      <li
        :for={entry <- @entries}
        :key={seq(entry)}
        id={"#{@id}-#{seq(entry)}"}
        class={[
          "work-act",
          turn?(entry) && "work-act--turn",
          @since && new?(entry, @since) && "work-act--new"
        ]}
      >
        <%!-- Every event that has a form in words is drawn in it, never as its type and payload
              — a 36-character `version_id` wrapped over three lines of a phone was noise
              (UX pass, B10). The raw form is the job page's raw log. --%>
        <%= case entry do %>
          <% {:action, _event, action} -> %>
            <div class="work-act-main" data-activity="action">
              <.line line={{:one, action}} />
            </div>
          <% {:event, %{type: "chat.turn"} = event} -> %>
            <%!-- A turn is where one exchange ends and the next begins: a divider, not a row. A file
                  the machine could not put where the agent reads it is a line under it, the words
                  of the transcript's own (`Conversations.files_lost_notice/1`). --%>
            <div class="work-act-turnbox">
              <span class="work-act-turn" data-activity="turn">turn {event.payload["turn"]}</span>
              <p
                :if={lost = Forge.Conversations.files_lost_notice(event.payload["files_lost"])}
                class="work-act-lost"
                data-activity="files-lost"
              >
                {lost}
              </p>
            </div>
          <% {:event, %{type: "chat.message"} = event} -> %>
            <div class="work-act-main work-act-said" data-activity="message">
              <span class="work-act-who">{ForgeWeb.Format.author(event.actor) || "you"}:</span>
              <span class="work-act-words"><.clip text={Forge.Events.detail(event)} /></span>
            </div>
          <% {:event, %{type: "job.swept"} = event} -> %>
            <div class="work-act-main" data-activity="swept">
              <.swept_line days={event.payload["days"]} transcripts={@transcripts} />
            </div>
          <% {:event, %{type: "artifact.version_written", payload: %{"artifact" => name, "version" => v}}} -> %>
            <div class="work-act-main work-act-said" data-activity="wrote">
              <span class="work-act-who">wrote</span>
              <.link :if={@hrefs[{name, v}]} href={@hrefs[{name, v}]} class="work-act-version">
                {name} v{v} ›
              </.link>
              <span :if={!@hrefs[{name, v}]} class="work-act-version">{name} v{v}</span>
            </div>
          <% {:event, event} -> %>
            <div class="work-act-main">
              <%!-- A memory row's type in `warning`: not waiting on a person, and not an error
                    either (`docs/design/capacity.md` § Memory, which a job holds rather than
                    spends). --%>
              <span class={[
                "work-act-type truncate",
                String.ends_with?(event.type, "error") && "text-danger",
                event.type == "job.harness.memory" && "text-warning"
              ]}>
                {label(event.type)}
              </span>
              <%!-- Wrapped, never truncated, and past 200 characters opened in place
                    (`docs/design/ui.md` § Activity): the whole of an agent's text, not the
                    bounded line a list draws. --%>
              <div class="work-act-detail break-words">
                <.clip text={Forge.Events.detail(event)} />
              </div>
            </div>
        <% end %>
        <span :if={!turn?(entry)} class="work-act-time">{Calendar.strftime(at(entry), "%H:%M:%S")}</span>
      </li>
    </ol>

    <div class="mt-3 flex flex-wrap items-center gap-2">
      <.load_older :if={@stream.more} id={@id <> "-more"} event="more">
        Load {ForgeWeb.JobStream.page()} more
      </.load_older>

      <%!-- Only when there is something behind it. --%>
      <button
        :if={@stream.notice_count > 0}
        type="button"
        phx-click="notices"
        id="job-notices"
        class="ui-btn ui-btn--quiet ui-btn--md"
      >
        {if @stream.notices, do: "Hide", else: "Show"} {@stream.notice_count} harness notices
      </button>
    </div>
    """
  end

  @doc """
  The control that loads the next older page, **and loads it on its own** when the reader reaches
  it (`.LoadOlder`): the same press as clicking it, once, until the page has arrived, under a quiet
  *Loading earlier…*. Drawn only while there is more to read, so the start of a stream shows nothing
  and loads nothing (`docs/design/ui.md` § Activity).
  """
  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :class, :any, default: "ui-btn ui-btn--secondary ui-btn--md"
  slot :inner_block, required: true

  def load_older(assigns) do
    ~H"""
    <button type="button" id={@id} phx-click={@event} phx-hook=".LoadOlder" class={@class}>
      {render_slot(@inner_block)}
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LoadOlder">
      // Reaching the old end of what is shown loads the next page without a press
      // (`docs/design/ui.md` § Activity). An observer rooted at the nearest `[data-load-root]` or
      // element whose id ends `-pane`, or the viewport when there is none; it presses the control once, says so quietly, and watches
      // again when the page has arrived and the control is still there (the page did not fill the
      // pane), which stops when `more` is false and the control is gone.
      export default {
        mounted() {
          this.label = this.el.textContent
          this.pressed = false
          this.root = this.el.closest("[data-load-root]") || this.el.closest("[id$='-pane']") || null
          this.observer = new IntersectionObserver((entries) => {
            if (this.pressed || !entries.some((entry) => entry.isIntersecting)) return
            this.pressed = true
            this.el.textContent = "Loading earlier…"
            this.el.click()
          }, {root: this.root, rootMargin: "120px"})
          this.observer.observe(this.el)
        },
        updated() {
          // The page arrived, and there is still more behind it: ready for the next one.
          this.pressed = false
          this.el.textContent = this.label
          this.observer.unobserve(this.el)
          this.observer.observe(this.el)
        },
        destroyed() { this.observer && this.observer.disconnect() }
      }
    </script>
    """
  end

  @doc """
  The transcript files of a job that was swept, as `{label, href}` for `swept_line/1`: one per run,
  each at the exact version's address on the route that serves it — the ticket's for a workflow
  job, the conversation's own for a conversation (`docs/design/storage.md` § Retention). `[]` for a
  job nobody swept, which draws no line, and for a swept one that has no transcript, which says
  so. Reads nothing for a job with no `job.swept` event but that one.
  """
  @spec transcript_links(map(), map(), map() | nil) :: [{String.t(), String.t()}]
  def transcript_links(job, project, ticket) do
    if Forge.Events.latest_for_job(job.id, "job.swept") do
      {scope, name, base} =
        case job do
          %{kind: :chat} ->
            {{:job, job.id}, "transcript-chat.jsonl",
             "/chats/#{job.id}/artifacts/transcript-chat.jsonl"}

          job ->
            name = "transcript-#{job.state}-#{job.attempt}.jsonl"
            {ticket.id, name, "/tickets/#{project.name}/#{ticket.number}/artifacts/#{name}"}
        end

      versions = Forge.Artifacts.versions(scope, name)

      for {version, n} <- Enum.with_index(versions, 1) do
        {if(length(versions) == 1, do: "transcript", else: "transcript, run #{n}"),
         "#{base}/#{version.version}"}
      end
    else
      []
    end
  end

  @doc """
  The line a swept job draws at its newest end, after what was kept (`docs/design/storage.md` § Retention): what
  was removed and when, and a link to each of its transcript files — or that none was recorded.
  `transcripts` is `transcript_links/3`'s `{label, href}`.
  """
  attr :days, :any, required: true, doc: "how many days after the job ended its stream was swept"
  attr :transcripts, :list, default: []

  def swept_line(assigns) do
    ~H"""
    <p class="job-dim" data-swept>
      Tool calls and harness notices were removed {@days} days after this job ended.
      <span :if={@transcripts == []}>No transcript of it was recorded.</span>
      <span :if={@transcripts != []}>
        Its transcript:
        <.link :for={{label, href} <- @transcripts} href={href} class="underline" download>
          {label}
        </.link>
      </span>
    </p>
    """
  end

  defp at({:action, event, _action}), do: event.inserted_at
  defp at({:event, event}), do: event.inserted_at

  defp turn?({:event, %{type: "chat.turn"}}), do: true
  defp turn?(_entry), do: false

  # A row's head: what the harness's own types are called once their prefix is gone, and the
  # agent's words named as the agent's rather than as `text`.
  defp label("job.harness.text"), do: "agent"
  defp label(type), do: String.replace_prefix(type, "job.harness.", "")

  @doc """
  Where each version the docs name is read, by `{name, version}`: what Activity links a written
  version to, so it is the address Docs links it to, in the page's own scope.
  """
  @spec version_hrefs([map()]) :: %{{String.t(), pos_integer()} => String.t()}
  def version_hrefs(docs) do
    for doc <- docs, version <- [doc.latest | doc.earlier], into: %{} do
      {{doc.name, version.version}, version.href}
    end
  end

  # Since the person last looked: what arrived after it is marked.
  defp new?(entry, since), do: DateTime.compare(at(entry), since) == :gt

  defp seq({:action, event, _action}), do: event.seq
  defp seq({:event, event}), do: event.seq

  @doc """
  A stream's heading: a run that has ended says so, one still going says how far it got. `count` is
  what the stream draws without being asked for the notices — a call and its result are one
  entry — so it is the same figure the Activity tab carries (`Forge.Events.Stream.count/1`).
  """
  @spec stream_heading(map(), non_neg_integer()) :: String.t()
  def stream_heading(%{status: :finished}, count),
    do: "complete · #{count} #{if count == 1, do: "entry", else: "entries"}"

  def stream_heading(job, count), do: "#{job.status} · #{count} so far"
end
