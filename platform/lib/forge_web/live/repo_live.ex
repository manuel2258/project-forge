defmodule ForgeWeb.RepoLive do
  @moduledoc """
  The repository a project holds: pick a branch, read its history, walk its tree, read a file
  (`docs/design/ui.md` § The project's repository, `10a`–`10d`, `10f`).

  The project page says what the repository means to the platform — the clone URL, the default
  branch, the workflow it carries. This says what is in it, which until now meant cloning.

  Nothing here writes. Every read is `for-each-ref`, `log`, `rev-parse`, `ls-tree`, `cat-file` or
  `show` against the bare repository: no worktree, no checkout, and no ref touched.

  **Everything the view holds that is not read from the repository is in the address**: the
  branch, the view (Commits or Files), the page of history, the file open, and the path whose
  history is shown. Every control patches it, so the page survives a reload at any depth.

  **A path travels out and back in git's own printed form.** `Forge.Git` hands over every path
  through `printable_path/1`, so a file named `caf\xE9.txt` is drawn — and sent to the browser —
  as `"caf\351.txt"`, which is valid UTF-8 and therefore something the socket can carry. What
  comes back, on a click or in the address, is put through `unquote_path/1`, its exact inverse,
  before git sees it, so such a file still opens and such a directory still expands.

  **What the page holds is bounded.** The tree holds names, one directory per click, and the
  content of exactly one file — the one the address names — which `ForgeWeb.Blob` bounds at
  512 KB, so that is the whole of it.

  **One page, two arrangements.** Below 1440px a 56px bar holds the branch and a Commits · Files
  switch, and the page shows one of the history, the tree, or the open file as a screen of its
  own (`10d`); the tree stays in the page while a file is open, so going back finds it as it was
  left. From 1440 the switch goes, and the tree, the file and the history sit side by side
  (`10f`). All three are drawn at every width and `areas/repo.css` decides which are seen.

  A directory is a directory and everything else is a file, the symlinks and the submodules
  included: a symlink's content is the path it names, which is what git stores and what reading
  it plainly says, and a submodule has no content here at all, so it reads as a file this commit
  does not hold.
  """

  use ForgeWeb, :live_view

  alias Forge.{Git, Projects, Tickets}
  alias Forge.Git.Url
  alias ForgeWeb.{Blob, Diff, Format, Highlight}

  # A page of history. Thirty because a repository with thousands of commits must never load
  # them all, and paging because every commit still has to be reachable.
  @per_page 30
  @max_page 1_000_000

  @tabs ~w(commits files)

  # The colocated copy hook `ForgeWeb.Operator.Components.copyable/1` registers, by its full
  # name: it copies the text of the element `data-target` names, and says so on the button.
  @copy_hook "ForgeWeb.Operator.Components.CopyToClipboard"

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    repo = Projects.repo_path(project)
    branches = branches(repo)

    {:ok,
     socket
     |> assign(
       project: project,
       repo: repo,
       branches: branches,
       tickets: ticket_branches(project, branches),
       default_head: tip(repo, project.default_branch),
       clone_url: Url.for(project),
       copy_hook: @copy_hook,
       query: "",
       page_title: "#{project.name} repository",
       branch: nil,
       open: nil,
       revealed: MapSet.new()
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    branch = chosen(socket.assigns, params["branch"])
    moved? = branch != socket.assigns.branch

    socket =
      socket
      |> assign(
        branch: branch,
        tab: if(params["tab"] in @tabs, do: params["tab"], else: "commits"),
        page: page(params["page"]),
        path: text(params["path"]),
        now: DateTime.utc_now()
      )
      |> then(&if(moved?, do: reset_tree(&1), else: &1))
      |> open(text(params["file"]))
      |> load_commits()

    {:noreply, socket}
  end

  # A query parameter can be a list as easily as a string (`?file[]=a`); only a string names
  # anything here.
  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_other), do: nil

  # The branch in the address, when the repository has it; otherwise the project's default, and
  # otherwise the first branch there is. A stale link lands somewhere real rather than failing,
  # and a name nothing matches is a typo, not an error page.
  #
  # The third step is not decoration. A project whose default branch has been deleted still has
  # branches, and falling back to the name of one that is gone drew the picker on a real branch
  # while the page beneath it showed the missing one's empty state. The only name with no branch
  # behind it is the one a repository with no branches at all gets.
  defp chosen(%{branches: branches, project: project}, asked) do
    Enum.find(
      [asked, project.default_branch | branches],
      project.default_branch,
      &(&1 in branches)
    )
  end

  # A page out of range is the first page, not a `--skip` git refuses: `?page=9999999999999999`
  # made `git log` answer `fatal: not an integer`, which `load_commits/1` then drew as the same
  # empty page a reader gets past the end of a real history. The bound is thirty million commits
  # deep, which no repository this will ever serve has.
  defp page(asked) when not is_binary(asked), do: 1

  defp page(asked) do
    case Integer.parse(asked) do
      {number, ""} when number > 0 and number <= @max_page -> number
      _other -> 1
    end
  end

  defp branches(repo) do
    case Git.branches(repo) do
      {:ok, branches} -> branches
      {:error, _reason} -> []
    end
  end

  # Each open ticket's branch **of this project**, by name, with what the sheet says of it: the
  # ticket's number, title and step (`10b`). A branch is only a name, and another project's
  # ticket can carry the same one; the tickets are read through the project, so that one is not
  # this repository's and never labels a branch here.
  defp ticket_branches(project, branches) do
    tickets = Enum.filter(Tickets.list(project, open: true), &(&1.branch in branches))
    kinds = ForgeWeb.Topology.kinds(tickets)

    for ticket <- tickets, into: %{} do
      {ticket.branch,
       %{
         number: ticket.number,
         title: ticket.title,
         state: ticket.state,
         topology: kinds[ticket.id]
       }}
    end
  end

  # A tree and the file opened out of it belong to one branch's head. Drawn under another
  # branch's name they would be wrong rather than stale-looking-fine, so moving branch drops
  # both and reads the new root.
  defp reset_tree(%{assigns: %{repo: repo, branch: branch}} = socket) do
    head = with %{sha: sha} <- tip(repo, branch), do: sha
    assign(socket, head: head, tree: %{"" => children(repo, head, "")}, open: nil)
  end

  # A branch's newest commit, or nil for a branch that is not there.
  defp tip(repo, branch) do
    case Git.history(repo, "refs/heads/" <> branch, 0, 1) do
      {:ok, %{commits: [commit]}} -> commit
      _gone -> nil
    end
  end

  # The one file the address names, read when it changes and only then. A path the commit does
  # not hold opens nothing and says nothing — `..` in it is matched against git's own tree and
  # matches there as little as any other typo does, which is why no path guard is needed in front
  # of this.
  defp open(%{assigns: %{open: {path, _file}}} = socket, path), do: socket
  defp open(socket, nil), do: assign(socket, open: nil)

  defp open(%{assigns: assigns} = socket, path) do
    raw = Git.unquote_path(path)

    case Blob.read(assigns.repo, assigns.head, raw) do
      :missing -> assign(socket, open: nil)
      file -> socket |> assign(open: {path, file}) |> reveal(raw)
    end
  end

  # The directories a file opened from the address sits in, read and drawn open, so the tree
  # shows where it is (`10f`) — a link to a file deep in the tree lands on it, not on the root.
  # Only those the page has not read already: a file opened from the tree is under directories
  # the reader opened themselves.
  defp reveal(%{assigns: assigns} = socket, raw) do
    dirs =
      raw
      |> Path.split()
      |> Enum.drop(-1)
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.map(&Git.printable_path/1)

    tree =
      Enum.reduce(dirs, assigns.tree, fn dir, tree ->
        Map.put_new_lazy(tree, dir, fn -> children(assigns.repo, assigns.head, dir) end)
      end)

    assign(socket, tree: tree, revealed: MapSet.new(dirs))
  end

  defp load_commits(%{assigns: %{repo: repo, branch: branch, page: page, path: path}} = socket) do
    only = path && Git.unquote_path(path)
    ref = "refs/heads/" <> branch

    case Git.history(repo, ref, (page - 1) * @per_page, @per_page, only) do
      {:ok, %{commits: commits, more: more}} -> assign(socket, commits: commits, more: more)
      {:error, _reason} -> assign(socket, commits: [], more: false)
    end
  end

  defp children(_repo, nil, _dir), do: []

  defp children(repo, head, dir) do
    case Git.ls_dir(repo, head, Git.unquote_path(dir)) do
      {:ok, entries} -> Enum.sort_by(entries, &{&1.kind != :tree, &1.name})
      {:error, _reason} -> []
    end
  end

  # Read once, then held: collapsing and reopening a directory draws it from the page rather
  # than asking git again.
  #
  # **Dropping the memo is an equivalent mutant.** Re-reading a directory already in the map
  # produces the same entries from the same commit, so nothing a test can see changes; what it
  # costs is a `ls-tree` per toggle, which is a figure and not an assertion.
  @impl true
  def handle_event("expand", %{"path" => dir}, %{assigns: assigns} = socket)
      when is_binary(dir) do
    if Map.has_key?(assigns.tree, dir) do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, tree: Map.put(assigns.tree, dir, children(assigns.repo, assigns.head, dir)))}
    end
  end

  # The branch sheet's search: a filter over names the page already holds, reading nothing.
  def handle_event("search", %{"q" => query}, socket) when is_binary(query) do
    {:noreply, assign(socket, query: String.slice(query, 0, 200))}
  end

  # A payload whose `path` or `q` is not a string is a client that is not this page's. Without
  # this, a frame of `%{"path" => ["a", "b"]}` reached `dir <> "/"` and took the LiveView down
  # with an `ArgumentError`.
  def handle_event(event, _params, socket) when event in ~w(expand search),
    do: {:noreply, socket}

  # The page's own address with some of its parameters replaced, and the empty ones left out.
  # Everything the view holds beyond the tree is here, which is why every control patches rather
  # than navigating.
  defp address(assigns, overrides) do
    query =
      [
        branch: assigns.branch,
        tab: assigns.tab,
        page: assigns.page,
        file: open_path(assigns.open),
        path: assigns.path
      ]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {key, value} -> value == nil or (key == :page and value == 1) end)

    ~p"/projects/#{assigns.project.name}/repo?#{query}"
  end

  defp open_path({path, _file}), do: path
  defp open_path(nil), do: nil

  # Which of the three the narrow arrangement shows: the history on Commits, and on Files the
  # open file when there is one and the tree when there is not.
  defp shown(%{tab: "commits"}), do: "commits"
  defp shown(%{open: {_path, _file}}), do: "file"
  defp shown(_assigns), do: "tree"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, shown: shown(assigns))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Repository"
      subline={subline(assigns)}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      views={ForgeWeb.ProjectLive.strip(@project, %{}, :navigate)}
      measure={nil}
    >
      <div id="repo" class="repo" data-shown={@shown}>
        <div id="repo-about" class="repo-about">
          <span class="repo-about-count">{branch_count(@branches, @tickets)}</span>
          <span id="clone-url" class="repo-about-url">{@clone_url}</span>
          <button
            type="button"
            id="clone-url-copy"
            class="repo-copy"
            phx-hook={@copy_hook}
            data-target="clone-url"
          >
            <span data-label>Copy</span>
          </button>
        </div>

        <div id="repo-bar" class="repo-bar">
          <button
            :if={@branches != []}
            type="button"
            id="branch-button"
            class="repo-branch"
            phx-click={open_sheet("branch-sheet")}
            aria-haspopup="dialog"
          >
            <span class="repo-branch-label">branch</span>
            <span id="branch-current" class="repo-branch-name">{@branch}</span>
            <span :if={@head} class="repo-branch-sha">{Diff.short(@head)}</span>
            <span class="repo-branch-caret" aria-hidden="true">▾</span>
          </button>
          <nav id="repo-switch" class="ui-seg ui-seg--md repo-switch" aria-label="Repository">
            <.link
              :for={{key, label} <- [{"commits", "Commits"}, {"files", "Files"}]}
              id={"repo-tab-#{key}"}
              patch={address(assigns, tab: key, page: 1, path: nil)}
              class="ui-seg-opt"
              aria-current={@tab == key && "page"}
            >
              {label}
            </.link>
          </nav>
        </div>

        <p :if={@branches == []} class="repo-empty">This repository has no branches yet.</p>

        <section id="files" class="repo-tree" aria-label="Files">
          <.eyebrow :if={@head}>
            <span class="ui-id">{@branch}</span> at <span class="ui-id">{Diff.short(@head)}</span>
          </.eyebrow>
          <div class="repo-tree-body">
            <.tree_entries
              tree={@tree}
              open={open_path(@open)}
              revealed={@revealed}
              dir=""
              address={&address(assigns, &1)}
            />
          </div>
        </section>

        <section id="file" class="repo-file" aria-label="File">
          <.open_file
            :if={@open}
            path={elem(@open, 0)}
            file={elem(@open, 1)}
            back={address(assigns, file: nil)}
            history={address(assigns, tab: "commits", path: elem(@open, 0), page: 1)}
            copy_hook={@copy_hook}
          />
          <p :if={!@open} class="repo-empty repo-file-none">Open a file from the tree.</p>
        </section>

        <section id="commits" class="repo-commits" aria-label="Commits">
          <header class="repo-commits-head">
            <.eyebrow :if={!@path}>Commits on <span class="ui-id">{@branch}</span></.eyebrow>
            <.eyebrow :if={@path}>History of <span class="ui-id">{@path}</span></.eyebrow>
            <.link
              :if={@path}
              id="history-all"
              patch={address(assigns, path: nil, page: 1)}
              class="repo-link"
            >
              All commits
            </.link>
          </header>
          <ol class="repo-commits-list">
            <li :for={commit <- @commits} class="repo-commit">
              <Diff.commit_row
                commit={commit}
                now={@now}
                navigate={commit_path(assigns, commit.sha)}
              />
            </li>
          </ol>

          <p :if={@commits == []} class="repo-empty">No commits on this branch at this page.</p>

          <nav class="repo-foot" aria-label="Pages">
            <.link :if={@page > 1} patch={address(assigns, page: @page - 1)} class="repo-link">
              ‹ Newer
            </.link>
            <span :if={@page == 1} class="repo-foot-off" aria-disabled="true">‹ Newer</span>
            <span class="repo-foot-at">{range(@page, @commits)}</span>
            <.link :if={@more} patch={address(assigns, page: @page + 1)} class="repo-link">
              Older ›
            </.link>
            <span :if={!@more} class="repo-foot-off" aria-disabled="true">Older ›</span>
          </nav>
        </section>
      </div>

      <.sheet id="branch-sheet" label="Branches" title="Branch" focus="#branch-search input">
        <.branch_list
          branches={@branches}
          tickets={@tickets}
          default={@project.default_branch}
          current={@branch}
          query={@query}
          tip={@default_head}
          now={@now}
          address={&address(assigns, &1)}
        />
      </.sheet>
    </Layouts.app>
    """
  end

  # The object's subline: the project and how many branches, or, on a file's own screen, which
  # commit the file is read at.
  defp subline(%{open: {_path, _file}, head: head} = assigns) when head != nil,
    do: "#{assigns.project.name} · #{assigns.branch} at #{Diff.short(head)}"

  defp subline(assigns),
    do: "#{assigns.project.name} · #{count(length(assigns.branches), "branch", "branches")}"

  defp branch_count(branches, tickets) do
    case map_size(tickets) do
      0 -> count(length(branches), "branch", "branches")
      n -> "#{count(length(branches), "branch", "branches")} · #{n} for open tickets"
    end
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp range(_page, []), do: nil

  defp range(page, commits) do
    first = (page - 1) * @per_page + 1
    "#{first}–#{first + length(commits) - 1}"
  end

  # Where the commit page goes, carrying where it was opened from so its back link returns to
  # this branch, this page and this history rather than to the top.
  # Where the commit's back row returns to: the branch, the page and the file history the list
  # showed, and — on a wide screen, where the list sits beside an open file — that file and the
  # view it was opened on, so going back does not close it.
  defp commit_path(assigns, sha) do
    query =
      Enum.reject(
        [
          branch: assigns.branch,
          tab: if(assigns.tab != "commits", do: assigns.tab),
          page: assigns.page,
          path: assigns.path,
          file: open_path(assigns.open)
        ],
        fn {_key, value} -> value == nil end
      )

    ~p"/projects/#{assigns.project.name}/repo/commits/#{sha}?#{query}"
  end

  attr :branches, :list, required: true
  attr :tickets, :map, required: true
  attr :default, :string, required: true
  attr :current, :string, required: true
  attr :query, :string, required: true
  attr :tip, :any, required: true, doc: "the default branch's newest commit, or nil"
  attr :now, :any, required: true
  attr :address, :any, required: true

  # The branch sheet (`10b`): the default branch, then each open ticket's, then the rest, with a
  # search over all of them. Choosing a row patches the address and closes the sheet; nothing
  # here creates, moves or deletes a branch.
  defp branch_list(assigns) do
    matching = Enum.filter(assigns.branches, &matches?(&1, assigns.tickets[&1], assigns.query))
    ticket? = &(&1 != assigns.default and Map.has_key?(assigns.tickets, &1))

    assigns =
      assign(assigns,
        default_row: Enum.filter(matching, &(&1 == assigns.default)),
        ticket_rows:
          matching |> Enum.filter(ticket?) |> Enum.sort_by(&assigns.tickets[&1].number),
        other_rows: Enum.reject(matching, &(&1 == assigns.default or ticket?.(&1)))
      )

    ~H"""
    <form id="branch-search" phx-change="search" phx-submit="search" class="repo-search">
      <input
        type="search"
        name="q"
        value={@query}
        placeholder="Find a branch"
        aria-label="Find a branch"
        autocomplete="off"
        phx-debounce="150"
        class="repo-search-input"
      />
    </form>

    <div id="branch-groups" class="repo-groups">
      <div :if={@default_row != []} id="branches-default" class="repo-group">
        <.eyebrow>Default</.eyebrow>
        <.link
          :for={name <- @default_row}
          patch={@address.(branch: name, page: 1, file: nil, path: nil)}
          class="repo-branch-row"
          data-branch={name}
          aria-current={name == @current && "true"}
        >
          <span class="repo-branch-row-name">{name}</span>
          <span :if={@tip} class="repo-branch-row-meta">
            {Diff.short(@tip.sha)} · {Format.ago(@tip.at, @now)}
          </span>
        </.link>
      </div>

      <div :if={@ticket_rows != []} id="branches-tickets" class="repo-group">
        <.eyebrow>Open tickets · {length(@ticket_rows)}</.eyebrow>
        <.link
          :for={name <- @ticket_rows}
          patch={@address.(branch: name, page: 1, file: nil, path: nil)}
          class="repo-branch-row"
          data-branch={name}
          aria-current={name == @current && "true"}
        >
          <span class="repo-branch-row-name">{name}</span>
          <span class="repo-branch-row-meta">
            <ForgeWeb.Indicators.state
              name={"##{@tickets[name].number}"}
              topology={@tickets[name].topology}
            />
            <span class="repo-branch-row-title">{@tickets[name].title}</span>
            · {@tickets[name].state}
          </span>
        </.link>
      </div>

      <div :if={@other_rows != []} id="branches-other" class="repo-group">
        <.eyebrow>Other · {length(@other_rows)}</.eyebrow>
        <.link
          :for={name <- @other_rows}
          patch={@address.(branch: name, page: 1, file: nil, path: nil)}
          class="repo-branch-row"
          data-branch={name}
          aria-current={name == @current && "true"}
        >
          <span class="repo-branch-row-name">{name}</span>
        </.link>
      </div>

      <p :if={@default_row == [] and @ticket_rows == [] and @other_rows == []} class="repo-empty">
        No branch matches.
      </p>
    </div>
    """
  end

  # A row matches on its name, and a ticket's also on its number and title: "41" finds
  # `forge/game-41`, and so does a word of what #41 is about.
  defp matches?(_name, _ticket, ""), do: true

  defp matches?(name, ticket, query) do
    haystack =
      case ticket do
        nil -> name
        %{number: number, title: title} -> "#{name} ##{number} #{title}"
      end

    String.contains?(String.downcase(haystack), String.downcase(query))
  end

  attr :tree, :map, required: true
  attr :open, :any, required: true, doc: "the path of the file open, or nil"
  attr :revealed, :any, required: true, doc: "the directories drawn open for it"
  attr :dir, :string, required: true
  attr :address, :any, required: true

  # One directory's children, each folder recursing into its own. Plain identifier text — mono,
  # no colour, no icons — and a folder told from a file by its `▸` and a trailing slash alone
  # (`docs/design/ui.md` § The project's repository). Each level indents 18px (`repo.css`).
  defp tree_entries(assigns) do
    ~H"""
    <ul class="repo-tree-list">
      <li :for={entry <- @tree[@dir] || []} data-path={entry.path}>
        <details
          :if={entry.kind == :tree}
          open={MapSet.member?(@revealed, entry.path)}
          phx-mounted={ForgeWeb.Actions.keep_open()}
        >
          <summary phx-click="expand" phx-value-path={entry.path} class="repo-tree-row">
            <span aria-hidden="true" class="repo-tree-mark">▸</span>
            <span class="repo-tree-name">{entry.name}/</span>
          </summary>
          <div class="repo-tree-nest">
            <.tree_entries
              tree={@tree}
              open={@open}
              revealed={@revealed}
              dir={entry.path}
              address={@address}
            />
          </div>
        </details>

        <.link
          :if={entry.kind != :tree}
          patch={@address.(file: entry.path, tab: "files")}
          class="repo-tree-row"
          aria-current={@open == entry.path && "true"}
        >
          <span aria-hidden="true" class="repo-tree-mark repo-tree-mark--file">▸</span>
          <span class="repo-tree-name">{entry.name}</span>
        </.link>
      </li>
    </ul>
    """
  end

  attr :path, :string, required: true
  attr :file, :any, required: true
  attr :back, :string, required: true
  attr :history, :string, required: true
  attr :copy_hook, :string, required: true

  # A file as its own screen (`10d`): a back row to the tree, the path with a way to copy it,
  # what it weighs, its history, and its lines — or which bound stopped it, in the row's own
  # words: what the file is, not a failure the page reports.
  defp open_file(assigns) do
    ~H"""
    <div data-file={@path} class="repo-file-body">
      <header class="repo-file-head">
        <.link id="file-back" patch={@back} class="repo-back">‹ Files</.link>
        <div class="repo-file-title">
          <span id="file-path" class="repo-file-path"><Diff.path_name path={@path} /></span>
          <button
            type="button"
            id="file-path-copy"
            class="repo-copy"
            phx-hook={@copy_hook}
            data-target="file-path"
          >
            <span data-label>Copy</span>
          </button>
        </div>
        <div class="repo-file-meta">
          <span :if={size(@file)} id="file-size">{size(@file)}</span>
          <.link id="file-history" patch={@history} class="repo-link">History of this file</.link>
        </div>
      </header>

      <%= case @file do %>
        <% {:text, lines, _bytes} -> %>
          <Highlight.code lines={lines} class="repo-code" id="file-code" />
        <% :binary -> %>
          <p class="repo-empty">This file is binary. Its content is not shown.</p>
        <% {:too_large, bytes} -> %>
          <p class="repo-empty">{Blob.too_large(@path, bytes)}</p>
      <% end %>
    </div>
    """
  end

  defp size({:text, {_kind, lines}, bytes}),
    do: "#{bytes(bytes)} · #{count(length(lines), "line", "lines")}"

  defp size({:too_large, bytes}), do: bytes(bytes)
  defp size(:binary), do: nil

  defp bytes(n) when n < 1024, do: "#{n} B"

  defp bytes(n) do
    kb = Float.round(n / 1024, 1)
    if kb == trunc(kb), do: "#{trunc(kb)} KB", else: "#{kb} KB"
  end
end
