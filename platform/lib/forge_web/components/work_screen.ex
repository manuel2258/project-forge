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

  def docs(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.docs))

    ~H"""
    <p :if={@docs == [] and @unrecorded == %{}} class="text-sm text-ink-2">{@empty}</p>

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
            {meta(["v#{version.version}", "superseded", version.author, ago(version.at, @now)])}
          </span>
          <span aria-hidden="true">›</span>
        </.link>
      </details>
    </section>
    """
  end

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
        <span class="min-w-0 break-all">{@entry.name}</span>
      </span>
      <span class="work-doc-meta">
        {meta([@entry[:by] || @entry.latest.author, ago(@entry.latest[:at], @now)])}
      </span>
      <%!-- The icon already says this to a screen reader; said again it is said twice. --%>
      <span :if={@entry.type == :apk} class="work-doc-meta" aria-hidden="true">Android app</span>
    </span>
    <span class="work-doc-mark">
      <span :if={@entry.kind == :presentation} class="text-ink-3">view only</span>
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
  # `system` message into one of these, and `thinking_tokens` alone can outnumber everything else
  # in a job. Recorded, and hidden behind their count (`docs/design/ui.md` § Motion and structure).
  @telemetry ["job.harness.notice"]

  @doc "How many of `events` are the harness's notices about itself."
  @spec notice_count([map()]) :: non_neg_integer()
  def notice_count(events), do: Enum.count(events, &(&1.type in @telemetry))

  @doc """
  The stream as it is drawn, newest first: each `tool_use` as an action paired with its result,
  whose own row is then not drawn again; every other event as itself; notices only when asked.
  """
  @spec entries([map()], boolean()) :: [{:action, map(), map()} | {:event, map()}]
  def entries(events, notices) do
    results =
      for %{type: "job.harness.tool_result", payload: payload} <- events,
          into: %{},
          do: {payload["tool_use_id"], payload}

    calls =
      for %{type: "job.harness.tool_use", payload: payload} <- events,
          into: MapSet.new(),
          do: payload["id"]

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
  defp paired?(%{type: "job.harness.tool_result", payload: payload}, calls),
    do: MapSet.member?(calls, payload["tool_use_id"])

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
  A job's event stream (`docs/design/ui.md` § Activity): newest first, a page at a time
  (`ForgeWeb.JobStream.page/0`), notices behind their count. Tool calls are action lines, the
  same component the transcript draws them with; every other event keeps the job page's row,
  wrapped, its whole text past 200 characters behind a control (`ForgeWeb.Actions.clip/1`).

  Newest first needs no pinning: what arrives appears at the top, where the reader already is.
  The page owning it starts with `ForgeWeb.JobStream.init/1` and hands `more` and `notices` to
  `ForgeWeb.JobStream.handle_event/3`.
  """
  attr :id, :string, default: "job-events"
  attr :events, :list, required: true
  attr :shown, :integer, required: true
  attr :notices, :boolean, required: true
  attr :heading, :string, required: true
  attr :since, :any, default: nil, doc: "the person's previous look: what is newer is marked"

  attr :class, :any,
    default: nil,
    doc: "for the list: a page that is not a work screen bounds it itself, since no tab body does"

  attr :hrefs, :map,
    default: %{},
    doc: "`version_hrefs/1` of the page's docs: where a version an event names is read"

  def activity(assigns) do
    entries = entries(assigns.events, assigns.notices)

    assigns =
      assign(assigns,
        entries: Enum.take(entries, assigns.shown),
        more: length(entries) > assigns.shown,
        notice_count: notice_count(assigns.events)
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
            <%!-- A turn is where one exchange ends and the next begins: a divider, not a row. --%>
            <span class="work-act-turn" data-activity="turn">turn {event.payload["turn"]}</span>
          <% {:event, %{type: "chat.message"} = event} -> %>
            <div class="work-act-main work-act-said" data-activity="message">
              <span class="work-act-who">{ForgeWeb.Format.author(event.actor) || "you"}:</span>
              <span class="work-act-words"><.clip text={Forge.Events.detail(event)} /></span>
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
      <button
        :if={@more}
        type="button"
        phx-click="more"
        class="ui-btn ui-btn--secondary ui-btn--md"
      >
        Load {ForgeWeb.JobStream.page()} more
      </button>

      <%!-- Only when there is something behind it. --%>
      <button
        :if={@notice_count > 0}
        type="button"
        phx-click="notices"
        id="job-notices"
        class="ui-btn ui-btn--quiet ui-btn--md"
      >
        {if @notices, do: "Hide", else: "Show"} {@notice_count} harness notices
      </button>
    </div>
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
  A stream's heading: a run that has ended says so, one still going says how far it got. It
  counts what the stream draws without being asked for the notices — a call and its result are
  one entry — so it is the same figure the Activity tab carries.
  """
  @spec stream_heading(map(), [map()]) :: String.t()
  def stream_heading(%{status: :finished}, events) do
    count = activity_count(events)
    "complete · #{count} #{if count == 1, do: "entry", else: "entries"}"
  end

  def stream_heading(job, events), do: "#{job.status} · #{activity_count(events)} so far"

  @doc "The Activity tab's count: what it draws without being asked for the notices."
  @spec activity_count([map()]) :: non_neg_integer()
  def activity_count(events), do: events |> entries(false) |> length()
end
