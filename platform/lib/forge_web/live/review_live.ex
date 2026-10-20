defmodule ForgeWeb.ReviewLive do
  @moduledoc """
  The merge decision: the diff, beside what only the platform knows about it.

  The diff on its own is what any forge shows. What this page adds is the chain of documents the
  change was built from, the verification report at the end of it, every question a person
  answered along the way, and what the whole ticket consumed — so the decision is taken on the
  reasoning rather than on the patch alone.

  Approval pins an exact `changeset` version, which is an exact commit. The diff is bounded, and
  says where it was bound rather than trailing off. See `docs/design/ui.md`.
  """

  use ForgeWeb, :live_view

  import ForgeWeb.Indicators
  import ForgeWeb.Operator.Components

  alias Forge.{Artifacts, Events, Git, Merge, Projects, Tickets}
  alias ForgeCore.Workflow
  alias ForgeWeb.{Diff, FileType, Format}
  alias ForgeWeb.Operator.Actions
  alias ForgeWeb.Operator.Board
  alias ForgeWeb.Operator.Drafts

  # A file and a line or range quoted in backticks, which the prose that quotes it has drawn
  # beneath it (`docs/design/ui.md` § Changes). No colon, backtick or space in the path, because
  # the colon is the separator and the quote is one token of prose.
  @quoted ~r/`([^`:\s]+):(\d+)(?:-(\d+))?`/

  # A range longer than this is a file, not a quote: it would push the prose it belongs to off
  # the screen, which is the one thing this section exists to keep readable.
  @max_quoted_lines 60

  # And a long enough line is a file too, whatever the line count says — one minified line is a
  # megabyte. Both caps are on the slice, so neither depends on how the file is formatted.
  @max_quoted_bytes 16 * 1024

  # **How many quotes are drawn at all.** The prose is an agent's and bounded only by a document's
  # megabyte, in which `` `a:1` `a:2` … `` fits a hundred thousand distinct quotes; drawing them
  # would be a hundred thousand `git show` calls and hundreds of megabytes of HTML, inside
  # `mount/3`, per viewer, and again on every patch of the page. The cap is applied before
  # anything is read from git, so what a presentation can cost to open does not depend on what it
  # says. A page nobody can read is not a review, which is the same standard the patch is bounded
  # to.
  @max_quotes 12

  # Beyond this the patch is offered per file instead. A page nobody can read is not a review.
  @impl true
  def mount(%{"project" => name, "number" => number}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)
    if connected?(socket), do: Events.subscribe()

    {:ok,
     socket
     |> assign(project: project, ticket_id: ticket.id, drafts: Drafts.init())
     |> ForgeWeb.Capacity.project(project)
     |> load()}
  end

  defp load(%{assigns: %{ticket_id: id, project: project}} = socket) do
    ticket = Tickets.get!(id)
    workflow = Tickets.workflow(ticket)
    changeset = Artifacts.latest(ticket.id, Workflow.changeset_artifact())

    assign(socket,
      page_title: "#{project.name}##{ticket.number} review",
      ticket: ticket,
      workflow: workflow,
      changeset: changeset,
      merged: Merge.merged?(ticket),
      diff: diff(project, ticket, changeset),
      documents: documents(ticket),
      presentations: presentations(ticket, project, Artifacts.commit(changeset)),
      answers: Artifacts.answered(ticket.id),
      pending: ticket.pending_transition,
      approve: approve_pins(project, ticket, changeset),
      now: DateTime.utc_now()
    )
  end

  # The map of the change is never truncated; the patch under it may be.
  defp diff(_project, _ticket, nil), do: nil

  defp diff(project, ticket, changeset) do
    case Artifacts.commit(changeset) do
      nil -> %{error: {:not_a_commit, changeset.blob_uri}}
      head -> Diff.build(Projects.repo_path(project), ticket.base_commit, head)
    end
  end

  # The chain the change was built from, in the order it was written. The last document is the
  # verification report in every workflow that has one; naming it by convention would hard-code a
  # state name the grammar leaves to the project.
  defp documents(ticket) do
    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :document,
        version = Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      %{
        name: artifact.name,
        version: version,
        approved: Artifacts.approved?(version),
        body: FileType.render_document(artifact.name, version.content)
      }
    end
    |> Enum.sort_by(& &1.version.inserted_at, DateTime)
  end

  # What an agent wrote for the person deciding, newest material last, drawn before the diff: a
  # presentation is the reasoning the patch cannot carry (`docs/design/ui.md` § Changes). Loaded by
  # kind and not by name, for the reason `documents/1` gives: the name is the project's.
  defp presentations(ticket, project, head) do
    repo = Projects.repo_path(project)

    for artifact <- Artifacts.list(ticket.id),
        artifact.kind == :presentation,
        version = Artifacts.latest(ticket.id, artifact.name),
        version != nil do
      %{name: artifact.name, version: version}
      |> Map.merge(blocks(version.content, repo, head))
    end
    |> Enum.sort_by(& &1.version.inserted_at, DateTime)
  end

  # Paragraphs, each with the source it quotes beneath it, and how many quotes the cap left out.
  #
  # Splitting on blank lines is the whole of the parsing, and it is meant to be: a quote inside a
  # list item spanning paragraphs is drawn under the part it sits in rather than beside its own
  # line, and a fenced block with a blank line in it is cut in two and its second half read as
  # prose. Both cost legibility in one paragraph and neither can fail the page. A bigger parser
  # would buy very little for prose this simple.
  defp blocks(content, repo, head) do
    paragraphs =
      content
      |> ForgeWeb.Markdown.strip_front_matter()
      |> String.split(~r/\r?\n[ \t]*\r?\n/)
      |> Enum.reject(&(String.trim(&1) == ""))

    tokens = paragraphs |> Enum.flat_map(&tokens/1) |> Enum.uniq()
    drawn = Enum.take(tokens, @max_quotes)
    resolved = resolve(drawn, repo, head)

    blocks =
      Enum.map(paragraphs, fn paragraph ->
        quotes = for token <- Enum.uniq(tokens(paragraph)), token in drawn, do: resolved[token]
        %{html: ForgeWeb.Markdown.to_html(paragraph), quotes: quotes}
      end)

    %{blocks: blocks, dropped: length(tokens) - length(drawn)}
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

  defp to_line(digits), do: String.to_integer(digits)

  # Each quote with its source, reading each path from git at most once however many quotes name
  # it: a presentation quoting one file three times used to run three `git show`es.
  defp resolve(tokens, repo, head) do
    {resolved, _files} =
      Enum.map_reduce(tokens, %{}, fn {path, from, to} = token, files ->
        {lines, files} = lines(files, repo, head, path, from, to)
        {{token, %{label: label(path, from, to), lines: lines}}, files}
      end)

    Map.new(resolved)
  end

  defp label(path, from, to),
    do: if(from == to, do: "#{path}:#{from}", else: "#{path}:#{from}-#{to}")

  # The changeset's own commit and no other: a presentation quotes the change it is about
  # (`docs/design/ui.md` § Changes). Anything that does not resolve there — no changeset yet, a
  # path that is not in that tree, a line before the first or after the last, a range the wrong
  # way round — is a note and never a raised page, because the prose is an agent's and unbounded.
  defp lines(files, _repo, nil, _path, _from, _to), do: {:unresolved, files}

  defp lines(files, repo, head, path, from, to) when from >= 1 and to >= from do
    if to - from + 1 > @max_quoted_lines do
      {:too_long, files}
    else
      {content, files} = file(files, repo, head, path)
      {slice(content, from, to), files}
    end
  end

  defp lines(files, _repo, _head, _path, _from, _to), do: {:unresolved, files}

  defp file(files, repo, head, path) do
    case Map.fetch(files, path) do
      {:ok, cached} ->
        {cached, files}

      :error ->
        read =
          case Git.show(repo, head, path) do
            {:ok, content} -> source_lines(content)
            {:error, _reason} -> :missing
          end

        {read, Map.put(files, path, read)}
    end
  end

  # A file's lines, counted the way an editor counts them. `String.split/2` on text ending in a
  # newline leaves a trailing `""`, so the last line used to be one past the end: an 18-line file
  # quoted as `:19` drew an empty `pre` under the label, indistinguishable from a blank line.
  defp source_lines(content) do
    case String.split(content, ~r/\r?\n/) do
      [_ | _] = lines -> if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
      [] -> []
    end
  end

  defp slice(:missing, _from, _to), do: :unresolved

  defp slice(all, from, to) when is_list(all) do
    if to <= length(all) do
      text = all |> Enum.slice(from - 1, to - from + 1) |> Enum.join("\n")
      if byte_size(text) > @max_quoted_bytes, do: :too_long, else: {:ok, text}
    else
      :unresolved
    end
  end

  # One sentence rather than interpolation around the markup's own whitespace: what it says is
  # read, and a page that quietly drew a dozen of thirty would be read as having drawn them all.
  defp dropped_note(1),
    do: "1 further quote is not drawn: a presentation draws at most #{@max_quotes}."

  defp dropped_note(dropped),
    do: "#{dropped} further quotes are not drawn: a presentation draws at most #{@max_quotes}."

  defp note(%{label: label, lines: :too_long}),
    do: "#{label} is too much to draw here; read it in the diff"

  defp note(%{label: label}), do: "#{label} is not in this changeset's commit"

  defp approve_pins(project, ticket, changeset) do
    for name <- Forge.Engine.awaiting_approval(ticket),
        changeset && name == Workflow.changeset_artifact(),
        do: pinned(project.name, ticket, name, changeset)
  end

  @impl true
  def handle_info({:ticket_changed, id}, %{assigns: %{ticket_id: id}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ticket_changed, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_event(event, params, socket) do
    case Actions.handle(event, params, socket) do
      {:handled, socket} -> {:noreply, load(socket)}
      {:state, socket} -> {:noreply, socket}
      :unknown -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="74rem">
      <.link
        navigate={~p"/tickets/#{@project.name}/#{@ticket.number}"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}#{@ticket.number} · {@ticket.title}
      </.link>

      <header class="mt-4 flex flex-col gap-2">
        <div class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">The change</div>
        <h1 class="text-[23px] font-semibold -tracking-[.03em] sm:text-3xl">{@ticket.title}</h1>
        <div class="flex flex-wrap items-center gap-3">
          <.state name={@ticket.state} topology={Board.topology(@workflow, @ticket.state)} />
          <.status_flag status={@ticket.status} age={Format.ago(@ticket.updated_at, @now)} />
          <span :if={@merged} class="font-mono text-[12.5px] text-success">✓ merged</span>
        </div>
      </header>

      <section
        :if={@pending && @approve != []}
        class="mt-6 rounded-box border border-accent bg-accent/5 p-4"
        id="merge-decision"
      >
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase text-accent">Waiting on you</h2>
        <div class="mt-3">
          <.approval_card ticket={@ticket} pending={@pending} approve={@approve} drafts={@drafts} />
        </div>
      </section>

      <%!-- Before the diff and outside its columns: a presentation is written to be read first,
            and it is the one thing on this page that is neither the patch nor a contract between
            states. Dashed and `view only`, like the kind everywhere else, so it can never be
            misread as something to approve (`docs/design/ui.md` § Changes). --%>
      <section :if={@presentations != []} class="mt-6" id="review-presentations">
        <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Presented</h2>
        <article
          :for={shown <- @presentations}
          id={"review-presentation-#{shown.name}"}
          class="mt-3 min-w-0 rounded-box border border-dashed border-base-300 px-4 py-3"
        >
          <header class="flex min-h-[46px] flex-wrap items-center gap-x-3 font-mono text-[12.5px]">
            <FileType.file_icon artifact={%{name: shown.name, kind: :presentation}} />
            <span class="min-w-0 break-all">{shown.name}</span>
            <span class="opacity-60">v{shown.version.version}</span>
            <span class="tracking-[.14em] uppercase opacity-50">view only</span>
          </header>

          <div :for={block <- shown.blocks} class="mt-2 min-w-0">
            <div class="doc">{block.html}</div>
            <div :for={quoted <- block.quotes} class="mt-2 min-w-0">
              <div class="font-mono text-[11px] opacity-50">{quoted.label}</div>
              <pre
                :if={match?({:ok, _}, quoted.lines)}
                class="mt-1 overflow-x-auto rounded-box bg-base-200 px-3 py-2 font-mono text-[12px]/[1.5]"
              >{elem(quoted.lines, 1)}</pre>
              <p :if={not match?({:ok, _}, quoted.lines)} class="mt-1 text-[12.5px] opacity-60">
                {note(quoted)}
              </p>
            </div>
          </div>

          <p :if={shown.dropped > 0} class="mt-2 text-[12.5px] opacity-60">
            {dropped_note(shown.dropped)}
          </p>

          <.link
            href={
              ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{shown.name}/#{shown.version.version}"
            }
            class="mt-2 flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
          >
            source ›
          </.link>
        </article>
      </section>

      <p :if={is_nil(@changeset)} class="mt-6 text-sm/[1.55] opacity-70">
        No job has produced a changeset on this ticket yet. The state that declares
        <span class="font-mono text-[12.5px]">changeset</span>
        records one when it finishes.
      </p>

      <div :if={@changeset} class="mt-8 flex flex-col gap-10 lg:flex-row lg:gap-0">
        <div class="lg:min-w-0 lg:flex-1 lg:pr-8">
          <Diff.section diff={@diff} id="review-diff" />

          <section :if={@documents != []} class="mt-8 border-t border-base-300 pt-5">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              What it was built from
            </h2>
            <%!-- The page reloads on every change to its ticket, and a patch must not close what
                  the reader opened (`ui.md` § Motion and structure). --%>
            <details
              :for={doc <- @documents}
              class="mt-3 min-w-0"
              id={"review-doc-#{doc.name}"}
              phx-mounted={ForgeWeb.Actions.keep_open()}
            >
              <summary class="flex min-h-[46px] cursor-pointer items-center gap-2 font-mono text-[12.5px]">
                <FileType.file_icon artifact={%{name: doc.name, kind: :document}} />
                {doc.name}
                <span class="opacity-60">v{doc.version.version}</span>
                <span :if={doc.approved} class="text-success">✓ approved</span>
              </summary>
              <div class="mt-2 min-w-0 rounded-box bg-base-200 px-4 py-3">
                <FileType.document_body body={doc.body} />
                <.link
                  href={
                    ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{doc.name}/#{doc.version.version}"
                  }
                  class="mt-3 flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
                >
                  source ›
                </.link>
              </div>
            </details>
          </section>

          <section class="mt-8 border-t border-base-300 pt-5" id="review-answers">
            <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
              Questions answered
            </h2>
            <ol :if={@answers != []} class="mt-3 flex flex-col gap-5">
              <li :for={entry <- @answers} class="flex flex-col gap-1.5">
                <blockquote
                  :if={entry.question.anchor}
                  class="border-l-2 border-base-300 pl-3 text-sm/[1.55] opacity-70"
                >
                  {entry.question.anchor}
                </blockquote>
                <p class="text-sm/[1.55]">{entry.question.text}</p>
                <p class="text-sm/[1.55]">
                  <span class="opacity-50">answered</span>
                  <span :if={entry.answer.choice} class="font-mono text-[12.5px]">
                    {entry.answer.choice}
                  </span>
                  <span :if={entry.answer.text}>{entry.answer.text}</span>
                </p>
                <div class="font-mono text-[12.5px] opacity-50">
                  {entry.question.key} ·
                  <.link
                    href={
                      ~p"/tickets/#{@project.name}/#{@ticket.number}/artifacts/#{entry.artifact}/#{entry.version}"
                    }
                    class="hover:opacity-100"
                  >
                    {entry.artifact} v{entry.version}
                  </.link>
                </div>
              </li>
            </ol>
            <p :if={@answers == []} class="mt-3 text-sm/[1.55] opacity-60">
              No question stopped a job on this ticket. Everything the agents needed, they had.
            </p>
          </section>
        </div>

        <aside class="lg:w-[21rem] lg:shrink-0 lg:border-l lg:border-base-300 lg:pl-8">
          <h2 class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Usage</h2>
          <div class="mt-3">
            <div class="font-mono text-[17px]">{Format.windows(@ticket.cost_usd) || "—"}</div>
            <div class="mt-2 h-[5px] w-full bg-base-300">
              <div class="h-full bg-accent" style={"width: #{usage_pct(@ticket, @workflow)}%"} />
            </div>
            <div class="mt-1 font-mono text-[11px] opacity-50">
              allowance {Format.windows(@workflow.limits.ticket_cost) || "—"}
            </div>
          </div>

          <h2 class="mt-6 font-mono text-[11px] tracking-[.14em] uppercase opacity-60">Facts</h2>
          <dl class="mt-3 flex flex-col gap-2 text-[12.5px]">
            <.fact label="changeset" value={"v#{@changeset.version}"} />
            <.fact label="commit" value={short(@diff[:head])} />
            <.fact label="base" value={short(@ticket.base_commit)} />
            <.fact label="branch" value={@ticket.branch} />
            <.fact label="files" value={files_label(@diff)} />
            <.fact label="lines" value={lines_label(@diff)} />
          </dl>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  defp short(nil), do: "—"
  defp short(sha), do: String.slice(sha, 0, 12)

  defp files_label(%{files: files}), do: Integer.to_string(length(files))
  defp files_label(_diff), do: "—"

  defp lines_label(%{added: added, removed: removed}), do: "+#{added} −#{removed}"
  defp lines_label(_diff), do: "—"

  defp usage_pct(ticket, workflow) do
    cap = workflow.limits.ticket_cost

    if is_number(cap) and cap > 0 do
      ticket.cost_usd
      |> Decimal.to_float()
      |> Kernel./(cap)
      |> Kernel.*(100)
      |> min(100)
      |> round()
    else
      0
    end
  end
end
