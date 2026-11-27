defmodule ForgeWeb.ExploreLive do
  @moduledoc """
  The explorer: one of a ticket's kept command copies, looked at on the machine that holds it,
  inside the ticket's frame (`docs/design/ui.md` § The explorer, ticket 84).

  **Nothing of a copy is here.** Every folder, file, size, time and hash is asked of the machine at
  the moment it is shown (`Forge.Explore`), and the answer is held by this page and by nothing
  else. The copy and the place in it are in the address (`?path=…`, `&show=…`), so a reload, a
  reconnect and a shared link open the same place. A path that is not valid text travels as
  `path64` (`ForgeWeb.BuildViews.path_query/2`).

  **A person who opens it holds the copy** on its machine for ten minutes after the last action:
  each answer is that action, and the header says until when.

  **When the machine cannot answer, the page says so in words**, never a spinner alone: asking,
  did not answer in 15 seconds, not connected, an older release, the copy no longer there.
  Names, paths and link targets are somebody's: they are drawn as text, break at any character,
  and a link is shown as its target and never followed.

  The machine is asked by `Application.get_env(:forge, :explore_module, Forge.Explore)`, which the
  tests and the looks replace with a stand-in; nothing else reads that key.
  """

  use ForgeWeb, :live_view

  alias Forge.{Jobs, Tickets, WarmBuilds}
  alias ForgeCore.Explore, as: Limits
  alias ForgeWeb.{Blob, BuildViews, Format, TicketViews}

  @page Limits.page_size()
  # The most entries a shared address may ask to be shown at once: a bound on what one page holds.
  @show_max 20_000

  @impl true
  def mount(%{"project" => name, "number" => number, "job_id" => job_id}, _session, socket) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(socket.assigns.current_scope, project)

    copy =
      with {:ok, uuid} <- Ecto.UUID.cast(job_id),
           {:ok, copy} <- WarmBuilds.copy(ticket, uuid) do
        copy
      else
        _not_this_tickets -> raise Ecto.NoResultsError, queryable: Jobs.Job
      end

    jobs = Jobs.for_ticket(ticket.id)

    {:ok,
     socket
     |> assign(
       project: project,
       ticket: ticket,
       copy: copy,
       row: BuildViews.copy_row(copy),
       job_id: copy.job.id,
       strip: TicketViews.strip_of(project, ticket, List.last(jobs)),
       page_title: "#{project.name}##{ticket.number} · build",
       path: "",
       show: @page,
       view: nil,
       asking: false,
       ask_ref: nil,
       hash: nil,
       last_action: nil,
       info: %{}
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = BuildViews.path_param(params)

    if is_nil(path) or not Limits.path_ok?(path) do
      {:noreply, assign(socket, path: "", view: {:error, :path_refused}, asking: false)}
    else
      socket = assign(socket, path: path, show: entries_shown(params))
      {:noreply, if(connected?(socket), do: ask(socket), else: assign(socket, asking: true))}
    end
  end

  defp entries_shown(%{"show" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= @page -> min(n, @show_max)
      _other -> @page
    end
  end

  defp entries_shown(_params), do: @page

  defp explore_module, do: Application.get_env(:forge, :explore_module, Forge.Explore)

  # -- asking the machine -------------------------------------------------------------------

  # Every ask carries its own reference, so an answer to a place the person has left is dropped.
  defp ask(%{assigns: %{copy: copy, path: path, show: show}} = socket) do
    module = explore_module()
    ref = make_ref()

    socket
    |> assign(asking: true, ask_ref: ref)
    |> start_async(:ask, fn -> {ref, answer(module, copy, path, show)} end)
  end

  defp answer(module, copy, path, show) do
    case module.list(copy, path, 0) do
      {:ok, listing} -> {:folder, fill(module, copy, path, listing, show)}
      {:error, :not_a_folder} -> file_answer(module, copy, path)
      {:error, code} -> {:error, code}
    end
  end

  # The pages of a folder up to what the address asks to be shown, each from where the last ended.
  defp fill(module, copy, path, listing, show) do
    held = length(listing.entries)

    if held < show and held < listing.total do
      case module.list(copy, path, held) do
        {:ok, %{entries: [_ | _] = more}} ->
          fill(module, copy, path, %{listing | entries: listing.entries ++ more}, show)

        _nothing_more_or_failed ->
          listing
      end
    else
      listing
    end
  end

  defp file_answer(module, copy, path) do
    case module.file(copy, path) do
      {:ok, facts} -> {:file, facts}
      {:error, code} -> {:error, code}
    end
  end

  @impl true
  def handle_async(:ask, {:ok, {ref, answer}}, %{assigns: %{ask_ref: ref}} = socket) do
    {:noreply, socket |> settle(answer) |> assign(asking: false)}
  end

  def handle_async(:ask, {:ok, {_stale, _answer}}, socket), do: {:noreply, socket}

  # The task itself crashed: the machine's answer is not what failed, so the page says what it
  # can and offers the same retry.
  def handle_async(:ask, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, asking: false, view: {:error, :failed}, info: %{})}

  def handle_async(:hash, {:ok, {path, answer}}, %{assigns: %{path: path}} = socket) do
    hash =
      case answer do
        {:ok, %{sha256: sha}} -> {:ok, sha}
        {:error, code} -> {:error, code}
      end

    {:noreply, assign(socket, hash: hash)}
  end

  def handle_async(:hash, _stale_or_exit, socket), do: {:noreply, socket}

  defp settle(socket, {:error, code}) do
    assign(socket, view: {:error, code}, info: info(socket, code), hash: nil)
  end

  defp settle(socket, {:file, facts} = view) do
    socket = assign(socket, view: view, last_action: DateTime.utc_now(), hash: nil)
    if kind(facts.kind) == "file", do: hash(socket), else: socket
  end

  defp settle(socket, view),
    do: assign(socket, view: view, last_action: DateTime.utc_now(), hash: nil)

  # The SHA-256 is asked after the facts, so a big file shows its size and content at once and the
  # hash follows with its progress.
  defp hash(%{assigns: %{copy: copy, path: path}} = socket) do
    module = explore_module()
    pid = self()
    progress = fn done, total -> send(pid, {:hash_progress, path, done, total}) end

    socket
    |> assign(hash: {:progress, 0, nil})
    |> start_async(:hash, fn -> {path, module.hash(copy, path, progress)} end)
  end

  @impl true
  def handle_info(
        {:hash_progress, path, done, total},
        %{assigns: %{path: path, hash: hash}} = socket
      )
      when is_tuple(hash) and elem(hash, 0) == :progress do
    {:noreply, assign(socket, hash: {:progress, done, total})}
  end

  def handle_info({:hash_progress, _path, _done, _total}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("retry", _params, socket), do: {:noreply, ask(socket)}

  def handle_event("more", _params, %{assigns: %{path: path, show: show}} = socket) do
    {:noreply,
     push_patch(socket, to: place(socket.assigns, path, show: min(show + @page, @show_max)))}
  end

  # What the page says of a place the machine could not give, read when the answer comes so it is
  # the state of that moment: when the machine is explorable until, and what became of the copy.
  defp info(%{assigns: %{ticket: ticket, copy: copy}}, code)
       when code in [:machine_not_connected] do
    %{until: WarmBuilds.explorable_until(ticket, copy.worker.id)}
  end

  defp info(%{assigns: %{ticket: ticket, copy: copy}}, code)
       when code in [:copy_gone, :no_copy] do
    %{gone: WarmBuilds.gone(ticket, copy.job.id, copy.worker.id)}
  end

  defp info(_socket, _code), do: %{}

  # -- addresses ----------------------------------------------------------------------------

  # Of the page's assigns, which a function component receives whole as `assigns`.
  defp place(a, path, extra \\ []),
    do: BuildViews.explore_path(a.project, a.ticket, a.job_id, path, extra)

  defp download(a, path), do: BuildViews.download_path(a.project, a.ticket, a.job_id, path)

  defp join(path, name), do: if(path == "", do: name, else: path <> "/" <> name)

  # The components of a path with the path each one opens, for the breadcrumb.
  defp crumbs(""), do: []

  defp crumbs(path) do
    parts = :binary.split(path, "/", [:global])

    parts
    |> Enum.with_index(1)
    |> Enum.map(fn {name, n} -> {name, parts |> Enum.take(n) |> Enum.join("/")} end)
  end

  defp kind(kind), do: to_string(kind)

  defp entries_label(1), do: "1 entry"
  defp entries_label(n), do: "#{n} entries"

  # A saved ignored folder's path as an address component: text or base64, without the slash git
  # puts after a folder.
  defp folder_path(%{"path" => path}), do: String.trim_trailing(path, "/")

  defp folder_path(%{"path_base64" => encoded}) do
    case Base.decode64(encoded) do
      {:ok, path} -> String.trim_trailing(path, "/")
      :error -> ""
    end
  end

  defp folder_path(_other), do: ""

  # -- the page -----------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title={@ticket.title}
      subline={"##{@ticket.number} · build · #{@row.machine}"}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      back={{"#{@project.name}##{@ticket.number}", ~p"/tickets/#{@project.name}/#{@ticket.number}"}}
      views={@strip}
      measure={nil}
    >
      <div id="explore-page" class="explore-page">
        <header class="explore-head">
          <div class="job-back-row">
            <.link
              navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@copy.job.id}"}
              class="job-back"
            >
              ‹ Command
            </.link>
            <span id="explore-name" class="job-name">
              $ {@row.command} {ForgeCore.Workflow.Command.argv(@row.args)}
            </span>
          </div>
          <p id="explore-facts" class="job-figures break-words">
            {@row.machine} · {@row.commit}<span :if={@row.at}> · kept {Format.ago_phrase(
              @row.at,
              DateTime.utc_now()
            )}</span><span :if={@row.size}> · {Blob.size_label(@row.size)}</span><span :if={
              @row.cleared
            }> · cleared</span><span :if={@row.next}> · next command starts here</span>
          </p>
          <p :if={@last_action} id="explore-held" class="job-caption">
            {held_line(@last_action)}
          </p>
        </header>

        <nav id="explore-crumbs" class="explore-crumbs" aria-label="Where in the copy">
          <.link patch={place(assigns, "")} class="explore-crumb">the copy</.link>
          <span :for={{name, prefix} <- crumbs(@path)} class="explore-crumb-sep">
            ›
            <.link patch={place(assigns, prefix)} class="explore-crumb break-all">
              {BuildViews.shown(name)}
            </.link>
          </span>
        </nav>

        <p :if={@asking && @view == nil} id="explore-asking" class="explore-state">
          Asking {@row.machine}…
        </p>
        <p :if={@asking && @view != nil} id="explore-refreshing" class="job-none">
          Asking {@row.machine}…
        </p>

        <.saved_sizes :if={@path == "" && match?({:folder, _}, @view)} {assigns} />

        <.failure :if={match?({:error, _}, @view)} {assigns} />
        <.folder :if={match?({:folder, _}, @view)} {assigns} />
        <.file_view :if={match?({:file, _}, @view)} {assigns} />
      </div>
    </Layouts.app>
    """
  end

  # Criterion 18: how long the machine keeps the copy as it was, from the last answer it gave.
  defp held_line(last_action) do
    until =
      last_action |> DateTime.add(Limits.hold_ms(), :millisecond) |> Calendar.strftime("%H:%M")

    "held as it was until #{until}, #{div(Limits.hold_ms(), 60_000)} minutes after the last action"
  end

  # The sentences for a machine that cannot answer (criteria 19 to 21), whole, so a line the
  # template's formatter breaks cannot break one.
  defp did_not_answer(machine),
    do: "#{machine} did not answer in #{div(Limits.answer_ms(), 1_000)} seconds"

  defp not_connected(machine, %{until: %DateTime{} = until}) do
    "#{machine} is not connected. This copy can be explored when it reconnects, until " <>
      "#{Calendar.strftime(until, "%Y-%m-%d %H:%M")} UTC."
  end

  defp not_connected(machine, _info), do: "#{machine} is not connected."

  defp outdated(machine),
    do: "#{machine} runs an older release: update it to explore this copy."

  # What was saved when the copy was kept (criteria 7 and 14): the ignored folders, largest first,
  # and the totals. The only folder sizes the explorer shows: none is measured while browsing.
  defp saved_sizes(assigns) do
    saved = assigns.copy |> Map.get(:folders) |> normalised()

    assigns =
      assign(assigns,
        folders: saved && Enum.sort_by(saved["folders"], & &1["bytes"], :desc),
        saved: saved
      )

    ~H"""
    <section id="explore-saved" class="explore-saved">
      <.eyebrow>Saved when it was kept</.eyebrow>
      <p :if={@saved == nil} id="explore-saved-none" class="job-none break-words">
        {ForgeCore.WarmBuild.no_folders_sentence()}
      </p>
      <ul :if={@saved} class="explore-list">
        <li
          :for={{folder, n} <- Enum.with_index(@folders)}
          id={"explore-saved-#{n}"}
          class="explore-row"
        >
          <.link patch={place(assigns, folder_path(folder))} class="explore-name break-all min-w-0">
            {BuildViews.shown(folder_path(folder))}/
          </.link>
          <span class="explore-meta">{Blob.size_label(folder["bytes"])}</span>
          <a
            href={download(assigns, folder_path(folder))}
            download
            class="explore-download"
            aria-label={"Download #{BuildViews.shown(folder_path(folder))} (#{Blob.size_label(folder["bytes"])})"}
          >
            Download
          </a>
        </li>
        <li :if={@saved["more"]["count"] > 0} id="explore-saved-more" class="explore-row">
          <span class="explore-name job-dim">
            {@saved["more"]["count"]} smaller ignored folders
          </span>
          <span class="explore-meta">{Blob.size_label(@saved["more"]["bytes"])}</span>
        </li>
        <li :if={@saved["loose"]["count"] > 0} id="explore-saved-loose" class="explore-row">
          <span class="explore-name job-dim">
            {@saved["loose"]["count"]} ignored files outside any ignored folder
          </span>
          <span class="explore-meta">{Blob.size_label(@saved["loose"]["bytes"])}</span>
        </li>
        <li id="explore-saved-rest" class="explore-row">
          <span class="explore-name job-dim">everything else</span>
          <span class="explore-meta">{Blob.size_label(@saved["rest"] || 0)}</span>
        </li>
      </ul>
    </section>
    """
  end

  # What a copy saved, with the totals a release may have left out read as nothing.
  defp normalised(%{} = saved) do
    none = %{"count" => 0, "bytes" => 0}

    %{
      "folders" => saved["folders"] || [],
      "more" => saved["more"] || none,
      "loose" => saved["loose"] || none,
      "rest" => saved["rest"] || 0
    }
  end

  defp normalised(_nothing_saved), do: nil

  # The words for each way the machine cannot answer (criteria 19 to 22).
  defp failure(%{view: {:error, code}} = assigns) do
    assigns = assign(assigns, code: code, machine: assigns.row.machine)

    ~H"""
    <section id="explore-problem" class="explore-problem" data-code={@code}>
      <p :if={@code == :machine_not_answering} id="explore-did-not-answer" class="explore-state">
        {did_not_answer(@machine)}
      </p>
      <p :if={@code == :machine_not_connected} id="explore-not-connected" class="explore-state">
        {not_connected(@machine, @info)}
      </p>
      <p :if={@code == :machine_outdated} id="explore-outdated" class="explore-state">
        {outdated(@machine)}
      </p>
      <p :if={@code in [:copy_gone, :no_copy]} id="explore-gone" class="explore-state">
        This copy is no longer on {@machine}<.gone info={@info} project={@project} ticket={@ticket} />
      </p>
      <p
        :if={
          @code not in [
            :machine_not_answering,
            :machine_not_connected,
            :machine_outdated,
            :copy_gone,
            :no_copy
          ]
        }
        id="explore-refused"
        class="explore-state break-words"
      >
        {Limits.sentence(@code)}.
        <.link :if={@path != ""} patch={place(assigns, "")} class="text-link">
          Back to the top of the copy
        </.link>
      </p>
      <button
        :if={@code in [:machine_not_answering, :machine_not_connected, :failed]}
        id="explore-retry"
        type="button"
        phx-click="retry"
        class="ui-btn ui-btn--secondary ui-btn--lg"
      >
        Try again
      </button>
    </section>
    """
  end

  attr :info, :map, required: true
  attr :project, :map, required: true
  attr :ticket, :map, required: true

  # Why the copy is gone, in as many words as forge knows (criterion 22): replaced, linking the
  # command that replaced it; swept, past its two days; or no more than the sentence.
  defp gone(%{info: %{gone: %{why: :replaced, replaced_by: %{} = by}}} = assigns) do
    assigns = assign(assigns, by: by, name: (Jobs.spec(by).command || %{})["name"])

    ~H"""
    : it was replaced by the build
    <.link
      id="explore-replaced-by"
      navigate={~p"/tickets/#{@project.name}/#{@ticket.number}/jobs/#{@by.id}"}
      class="text-link"
    >$ {@name}</.link>
    kept there.
    """
  end

  defp gone(%{info: %{gone: %{why: :replaced}}} = assigns), do: ~H": it was replaced."

  defp gone(%{info: %{gone: %{why: :swept}}} = assigns),
    do: ~H": it was swept, being past its two days."

  defp gone(assigns), do: ~H"."

  defp folder(%{view: {:folder, listing}} = assigns) do
    assigns =
      assign(assigns,
        listing: listing,
        more: listing.total - length(listing.entries),
        size: if(assigns.path == "", do: assigns.row.size)
      )

    ~H"""
    <section id="explore-folder" class="explore-folder">
      <div class="explore-actions">
        <a
          id="explore-download"
          href={download(assigns, @path)}
          download
          class="ui-btn ui-btn--secondary ui-btn--lg"
        >
          Download {if @path == "", do: "the whole copy", else: "this folder"}<span :if={@size}> ({Blob.size_label(
            @size
          )})</span>
        </a>
      </div>
      <p :if={@listing.entries == []} id="explore-empty" class="job-none">This folder is empty.</p>
      <ul id="explore-entries" class="explore-list">
        <li
          :for={{entry, n} <- Enum.with_index(@listing.entries)}
          id={"explore-entry-#{n}"}
          class="explore-row"
          data-kind={kind(entry.kind)}
        >
          <.link
            patch={place(assigns, join(@path, entry.name))}
            class="explore-name min-w-0 break-all"
          >
            {BuildViews.shown(entry.name)}{if kind(entry.kind) == "dir", do: "/"}
          </.link>
          <span :if={kind(entry.kind) == "file"} class="explore-meta">{Blob.size_label(
            entry.size || 0
          )}</span>
          <span :if={kind(entry.kind) == "dir"} class="explore-meta">{entries_label(
            entry.entries || 0
          )}</span>
          <span :if={kind(entry.kind) == "link"} class="explore-meta explore-target break-all min-w-0">
            → {BuildViews.shown(entry.target)}
          </span>
          <span class="explore-time">{BuildViews.stamp(entry.mtime)}</span>
        </li>
      </ul>
      <button
        :if={@more > 0}
        id="explore-more"
        type="button"
        phx-click="more"
        class="ui-btn ui-btn--secondary ui-btn--lg"
      >
        show {min(@more, 200)} more
      </button>
    </section>
    """
  end

  defp file_view(%{view: {:file, facts}} = assigns) do
    assigns = assign(assigns, facts: facts, kind: kind(facts.kind))

    ~H"""
    <section id="explore-file" class="explore-file">
      <.fact_list id="explore-file-facts" dense>
        <:fact label="kind">{@kind}</:fact>
        <:fact :if={@facts[:size]} label="size">{Blob.size_label(@facts.size)}</:fact>
        <:fact label="modified">{BuildViews.stamp(@facts[:mtime])}</:fact>
        <:fact :if={@kind == "file"} label="sha-256">
          <.sha256 hash={@hash} />
        </:fact>
      </.fact_list>

      <p :if={@kind == "link"} id="explore-link-target" class="explore-target break-all">
        links to {BuildViews.shown(@facts[:target])}. A link is shown, never followed.
      </p>

      <div :if={@kind in ["file", "dir"]} class="explore-actions">
        <a
          id="explore-download"
          href={download(assigns, @path)}
          download
          class="ui-btn ui-btn--secondary ui-btn--lg"
        >
          Download<span :if={@facts[:size]}> ({Blob.size_label(@facts.size)})</span>
        </a>
      </div>

      <p :if={@kind == "file" && !@facts[:text?]} id="explore-not-text" class="job-none">
        Not text: its content is not shown here.
      </p>
      <pre :if={@kind == "file" && @facts[:text?]} id="explore-content" class="explore-content">{BuildViews.shown(@facts[:content])}</pre>
      <p
        :if={@kind == "file" && @facts[:text?] && @facts[:truncated?]}
        id="explore-truncated"
        class="job-none"
      >
        showing the first {BuildViews.iec(Limits.text_limit())} of {BuildViews.iec(@facts.size)}
      </p>
    </section>
    """
  end

  attr :hash, :any, required: true

  defp sha256(assigns) do
    ~H"""
    <span :if={@hash == nil} class="job-dim">—</span>
    <span :if={match?({:progress, _, _}, @hash)} id="explore-hash-progress" class="job-dim">
      hashing{progress(@hash)}…
    </span>
    <span :if={match?({:ok, _}, @hash)} id="explore-hash" class="break-all">{elem(@hash, 1)}</span>
    <span :if={match?({:error, _}, @hash)} id="explore-hash-error" class="job-dim break-words">
      {Limits.sentence(elem(@hash, 1))}
    </span>
    """
  end

  defp progress({:progress, done, total}) when is_integer(total) and total > 0,
    do: " #{min(div(done * 100, total), 100)}%"

  defp progress(_unknown), do: ""
end
