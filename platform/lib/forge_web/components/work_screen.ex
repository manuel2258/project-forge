defmodule ForgeWeb.WorkScreen do
  @moduledoc """
  The frame a conversation and a ticket are both drawn in (`docs/design/ui.md` § The work screen),
  and the tabs they share.

  **The frame fills the viewport exactly**, inside `Layouts.app`'s `frame={:work}`: a fixed
  header, the context strip, a row of tabs, a body that is the page's only scroller, and — on a
  conversation — a fixed footer holding the composer. The page never scrolls as a whole, so the
  box you type in is never below the fold. The rail is the details sheet below `lg` and beside
  the body at `lg` and up (`ForgeWeb.Sheet`), opened from the strip.

  The tab is in the URL (`?tab=changes`, by patch), so back, reload and a pushed link land on it.
  A count of zero is drawn muted and never hidden, so the tabs never move.
  """

  use Phoenix.Component

  import ForgeWeb.Actions, only: [clip: 1, line: 1]

  alias Forge.Artifacts
  alias ForgeWeb.{Format, Layouts, Markdown, Sheet}

  attr :tabs, :list, required: true, doc: "`{key, label, count | nil}`, in order"
  attr :tab, :string, required: true, doc: "the key of the tab being shown"
  attr :path, :string, required: true, doc: "the page's own path, which each tab patches to"
  attr :strip_label, :string, default: "Details"

  attr :capacity, :any,
    default: nil,
    doc: "the page's pool (`ForgeWeb.Capacity`), whose gauge ends the strip"

  slot :header, required: true
  slot :strip, required: true, doc: "the context strip's identifiers"
  slot :inner_block, required: true, doc: "the body: the tab being shown"
  slot :footer, doc: "what sits under the body — a conversation's composer"
  slot :rail, required: true, doc: "the facts: the rail at `lg`, the details sheet below it"

  def frame(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col lg:flex-row">
      <div class="flex min-h-0 min-w-0 flex-1 flex-col lg:pr-8">
        <%!-- The header and the strip are what give way when the frame is short — the
              on-screen keyboard is up — so the tabs and the composer stay: `min-h-0` and
              `overflow-hidden` let this block shrink, where everything else in the column
              keeps its height and the body scrolls. --%>
        <div class="min-h-0 shrink overflow-hidden">
          <header>{render_slot(@header)}</header>

          <%!-- One line of identifiers. Below `lg` it is how the rail is reached, so it is a
                control; at `lg` the rail is beside it and the sheet will not open. --%>
          <button
            type="button"
            id="context-strip"
            phx-click={Sheet.open("details")}
            aria-label={@strip_label}
            class="mt-1 flex min-h-[46px] w-full items-center gap-3 text-left font-mono text-[12px] opacity-70 lg:pointer-events-none lg:min-h-0 lg:py-1"
          >
            <span class="flex min-w-0 flex-1 items-center gap-x-3 overflow-hidden whitespace-nowrap">
              {render_slot(@strip)}
              <Layouts.capacity_gauge
                :if={@capacity not in [nil, %{}]}
                capacity={@capacity}
                prefix="strip"
              />
            </span>
            <span class="shrink-0 lg:hidden" aria-hidden="true">details ›</span>
          </button>
        </div>

        <nav
          id="work-tabs"
          class="flex shrink-0 overflow-x-auto border-b border-base-300"
          aria-label="Views of this work"
        >
          <.link
            :for={{key, label, count} <- @tabs}
            patch={"#{@path}?tab=#{key}"}
            id={"tab-#{key}"}
            aria-current={key == @tab && "page"}
            class={[
              "-mb-px flex h-[46px] shrink-0 items-center gap-1.5 border-b-2 px-3 text-sm",
              if(key == @tab,
                do: "border-base-content font-medium",
                else: "border-transparent opacity-60 hover:opacity-100"
              )
            ]}
          >
            {label}
            <span :if={count} class={["font-mono text-[11.5px]", count == 0 && "opacity-40"]}>
              {count}
            </span>
          </.link>
        </nav>

        <div class="flex min-h-0 flex-1 flex-col">{render_slot(@inner_block)}</div>

        <div :if={@footer != []} class="shrink-0">{render_slot(@footer)}</div>
      </div>

      <Sheet.sheet id="details" label="Details" rail>
        {render_slot(@rail)}
      </Sheet.sheet>
    </div>
    """
  end

  @doc "A tab's body when it is not the transcript: it scrolls, and nothing else does."
  attr :id, :string, required: true
  slot :inner_block, required: true

  def body(assigns) do
    ~H"""
    <div id={@id} class="min-h-0 flex-1 overflow-y-auto overscroll-contain py-4">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  The Docs tab (`docs/design/ui.md` § Docs): every document written, **rendered**, the latest
  version of each first and earlier ones as links to their addresses; approval marks only where
  approval is possible; and what the last turn wrote that was not recorded, with why.

  A doc is what `doc/4` builds.
  """
  attr :docs, :list, required: true
  attr :unrecorded, :map, default: %{}
  attr :empty, :string, default: "Nothing written yet."

  def docs(assigns) do
    ~H"""
    <p :if={@docs == [] and @unrecorded == %{}} class="text-sm opacity-60">{@empty}</p>

    <section
      :for={doc <- @docs}
      id={"doc-#{doc.name}"}
      class="min-w-0 border-b border-base-300/60 pb-5 not-first:pt-5"
    >
      <div class="flex flex-wrap items-center gap-x-3 font-mono text-[12.5px]">
        <.link href={doc.latest.href} class="flex min-h-[46px] items-center gap-2 hover:underline">
          {doc.name} <span class="opacity-60">v{doc.latest.version}</span>
        </.link>
        <span :if={doc.kind == :presentation} class="tracking-[.14em] uppercase opacity-50">
          view only
        </span>
        <span :if={doc.approvable and doc.approved} class="text-success">✓ approved</span>
        <span :if={doc.approvable and not doc.approved} class="text-warning">◇ unapproved</span>
      </div>

      <div :if={doc.latest.html} class="mt-1 min-w-0 rounded-box bg-base-200 px-4 py-3">
        <div class="doc">{doc.latest.html}</div>
      </div>

      <p :if={doc.earlier != []} class="mt-2 flex flex-wrap items-center gap-x-3 text-[12.5px]">
        <span class="opacity-50">earlier</span>
        <.link
          :for={version <- doc.earlier}
          href={version.href}
          class="flex min-h-[46px] items-center font-mono text-primary hover:underline"
        >
          v{version.version}
        </.link>
      </p>
    </section>

    <%!-- Without this a document that did not arrive is only absent, which reads the same as
          one that was never written. --%>
    <ul :if={@unrecorded != %{}} id="unrecorded" class="mt-5 flex flex-col gap-2">
      <li :for={{name, why} <- Enum.sort(@unrecorded)} class="text-[12.5px]">
        <span class="font-mono break-all">{name}</span>
        <span class="text-error">not recorded:</span>
        <span class="opacity-70">{why}</span>
      </li>
    </ul>
    """
  end

  @doc """
  One entry of the Docs tab: `%{name, kind, latest, earlier, approvable, approved}`, from an
  artifact and the versions of it to show, oldest first. `latest` is `%{version, href, html}` —
  rendered when it is a document — `earlier` the versions before it, newest first, and the
  approval fields are about the latest. `href` gives a version number's address, and
  `approvable` is the page's to say: where approval is possible at all.
  """
  @spec doc(map(), [map()], (pos_integer() -> String.t()), boolean()) :: map()
  def doc(artifact, versions, href, approvable) do
    latest = List.last(versions)

    %{
      name: artifact.name,
      kind: artifact.kind,
      latest: %{
        version: latest.version,
        href: href.(latest.version),
        html: artifact.kind == :document && Markdown.to_html(latest.content)
      },
      earlier:
        for version <- versions |> Enum.drop(-1) |> Enum.reverse() do
          %{version: version.version, href: href.(version.version)}
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
        <li
          :for={commit <- @commits}
          class="flex min-h-[46px] items-center gap-3 border-b border-base-300/60 py-1.5 text-[12.5px]"
        >
          <span class="shrink-0 font-mono opacity-60">{String.slice(commit.sha, 0, 7)}</span>
          <span class="min-w-0 flex-1 break-words text-sm/[1.4]">{commit.subject}</span>
          <span class="shrink-0 font-mono opacity-50">{Format.ago(commit.at, @now)}</span>
        </li>
      </ol>
    </section>
    """
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

  attr :class, :any,
    default: nil,
    doc: "for the list: a page that is not a work screen bounds it itself, since no tab body does"

  def activity(assigns) do
    entries = entries(assigns.events, assigns.notices)

    assigns =
      assign(assigns,
        entries: Enum.take(entries, assigns.shown),
        more: length(entries) > assigns.shown,
        notice_count: notice_count(assigns.events)
      )

    ~H"""
    <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">{@heading}</h2>

    <ol class={["mt-3 flex flex-col", @class]} id={@id}>
      <%!-- Two rows narrow, one row wide. The type column is 196px because the longest type in
            the product, `artifact.version_written`, is 24 mono characters and a column narrower
            than its content does not clip — it overlaps the next one. --%>
      <%!-- Keyed and named by the event, so a row a reader opened is still that event's row after
            a newer one is drawn above it — by index, every row was another event's next time. --%>
      <li
        :for={entry <- @entries}
        :key={seq(entry)}
        id={"#{@id}-#{seq(entry)}"}
        class="grid grid-cols-[64px_1fr] gap-x-2 border-b border-base-300/60 py-1.5 font-mono text-[12.5px] sm:grid-cols-[64px_196px_1fr]"
      >
        <%= case entry do %>
          <% {:action, event, action} -> %>
            <span class="pt-1 opacity-50">{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</span>
            <div class="min-w-0 sm:col-span-2" data-activity="action">
              <.line line={{:one, action}} />
            </div>
          <% {:event, event} -> %>
            <span class="opacity-50">{Calendar.strftime(event.inserted_at, "%H:%M:%S")}</span>
            <%!-- A memory row's type in `warning`: not waiting on a person, and not an error
                  either (`docs/design/capacity.md` § Memory, which a job holds rather than
                  spends). --%>
            <span class={[
              "min-w-0 truncate",
              String.ends_with?(event.type, "error") && "text-error",
              event.type == "job.harness.memory" && "text-warning"
            ]}>
              {String.replace_prefix(event.type, "job.harness.", "")}
            </span>
            <%!-- Wrapped, never truncated, and past 200 characters opened in place
                  (`docs/design/ui.md` § Activity): the whole of an agent's text, not the
                  bounded line a list draws. --%>
            <div class="col-start-2 min-w-0 break-words opacity-70 sm:col-start-3">
              <.clip text={Forge.Events.detail(event)} />
            </div>
        <% end %>
      </li>
    </ol>

    <div class="mt-3 flex flex-wrap items-center gap-2">
      <button
        :if={@more}
        type="button"
        phx-click="more"
        class="min-h-[46px] rounded-field border border-base-300 px-4 text-sm hover:border-base-content/30"
      >
        Load {ForgeWeb.JobStream.page()} more
      </button>

      <%!-- Only when there is something behind it. --%>
      <button
        :if={@notice_count > 0}
        type="button"
        phx-click="notices"
        id="job-notices"
        class="min-h-[46px] rounded-field px-4 text-sm opacity-60 hover:opacity-100"
      >
        {if @notices, do: "Hide", else: "Show"} {@notice_count} harness notices
      </button>
    </div>
    """
  end

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
