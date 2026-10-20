defmodule ForgeWeb.RepoLive do
  @moduledoc """
  The repository a project holds: pick a branch, read its history, or walk its tree.

  The project page says what the repository means to the platform — the clone URL, the default
  branch, the workflow it carries. This says what is in it, which until now meant cloning. See
  `docs/design/ui.md` § The project's repository.

  Nothing here writes. Every read is `for-each-ref`, `log`, `ls-tree` or `cat-file` against the
  bare repository: no worktree, no checkout, and no ref touched.

  A directory is a directory and everything else is a file, the symlinks and the submodules
  included: a symlink's content is the path it names, which is what git stores and what reading
  it plainly says, and a submodule has no content here at all, so it reads as a file this commit
  does not hold. Neither is worth a kind of its own on a page whose subject is the project's own
  code.
  """

  use ForgeWeb, :live_view

  alias Forge.{Git, Projects}
  alias ForgeWeb.{Diff, Format}

  # A page of history. Thirty because a repository with thousands of commits must never load
  # them all, and paging because every commit still has to be reachable.
  @per_page 30

  # A file at or over this says so instead of being drawn. Asked of `blob_size/3` before the
  # content is ever read, so nothing past it is partially loaded.
  @max_file_bytes 512 * 1024

  # How much of a file is looked at to decide it is binary: the same heuristic git itself uses
  # to decide whether to diff a file as text.
  @sniff_bytes 8000

  @tabs ~w(commits files)

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    repo = Projects.repo_path(project)

    {:ok,
     socket
     |> assign(
       project: project,
       repo: repo,
       branches: branches(repo),
       page_title: "#{project.name} repository",
       branch: nil
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
        now: DateTime.utc_now()
      )
      |> then(&if(moved?, do: reset_tree(&1), else: &1))
      |> load_commits()

    {:noreply, socket}
  end

  # The branch in the address, when the repository has it; otherwise the project's default. A
  # stale link lands somewhere real rather than failing, and a name nothing matches is a typo,
  # not an error page.
  defp chosen(%{branches: branches, project: project}, asked) do
    if asked in branches, do: asked, else: project.default_branch
  end

  defp page(asked) do
    case Integer.parse(asked || "") do
      {number, ""} when number > 0 -> number
      _other -> 1
    end
  end

  defp branches(repo) do
    case Git.branches(repo) do
      {:ok, branches} -> branches
      {:error, _reason} -> []
    end
  end

  # A tree and the files opened out of it belong to one branch's head. Drawn under another
  # branch's name they would be wrong rather than stale-looking-fine, so moving branch drops
  # both and reads the new root.
  defp reset_tree(%{assigns: %{repo: repo, branch: branch}} = socket) do
    head =
      case Git.resolve(repo, "refs/heads/" <> branch) do
        {:ok, sha} -> sha
        {:error, _gone} -> nil
      end

    assign(socket, head: head, tree: %{"" => children(repo, head, "")}, open_files: %{})
  end

  defp load_commits(%{assigns: %{repo: repo, branch: branch, page: page}} = socket) do
    case Git.history(repo, "refs/heads/" <> branch, (page - 1) * @per_page, @per_page) do
      {:ok, %{commits: commits, more: more}} -> assign(socket, commits: commits, more: more)
      {:error, _reason} -> assign(socket, commits: [], more: false)
    end
  end

  defp children(_repo, nil, _dir), do: []

  defp children(repo, head, dir) do
    case Git.ls_dir(repo, head, dir) do
      {:ok, entries} -> Enum.sort_by(entries, &{&1.kind != :tree, &1.name})
      {:error, _reason} -> []
    end
  end

  @impl true
  def handle_event("branch", %{"branch" => branch}, socket) do
    {:noreply, push_patch(socket, to: address(socket.assigns, branch: branch, page: 1))}
  end

  # Read once, then held: collapsing and reopening a directory draws it from the page rather
  # than asking git again.
  def handle_event("expand", %{"path" => dir}, %{assigns: assigns} = socket) do
    if Map.has_key?(assigns.tree, dir) do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, tree: Map.put(assigns.tree, dir, children(assigns.repo, assigns.head, dir)))}
    end
  end

  # A path arrives off the wire, so it is not only one the tree offered. One the commit does not
  # hold opens nothing and says nothing — `..` in it is matched against git's own tree and
  # matches there as little as any other typo does, which is why no path guard is needed in
  # front of this.
  def handle_event("open", %{"path" => path}, %{assigns: assigns} = socket) do
    cond do
      Map.has_key?(assigns.open_files, path) -> {:noreply, socket}
      file = read(assigns, path) -> {:noreply, opened(socket, path, file)}
      true -> {:noreply, socket}
    end
  end

  defp opened(socket, path, file),
    do: assign(socket, open_files: Map.put(socket.assigns.open_files, path, file))

  # The size first, and the content only when the size allows it: the guarantee that nothing
  # past the limit is partially loaded is that `show/3` is not run at all.
  defp read(%{repo: repo, head: head}, path) do
    case Git.blob_size(repo, head, path) do
      {:ok, bytes} when bytes >= @max_file_bytes -> {:too_large, bytes}
      {:ok, _bytes} -> content(Git.show(repo, head, path))
      {:error, :not_found} -> nil
    end
  end

  defp content({:ok, text}), do: if(binary?(text), do: :binary, else: {:text, text})

  # **No test reaches this and none can usefully.** `blob_size/3` has already answered for this
  # exact path at this exact commit, so a `show/3` that then cannot find it is a repository
  # rewritten between two reads. It is here rather than left to crash the page, and its
  # removal is an equivalent mutant.
  defp content({:error, :not_found}), do: nil

  defp binary?(text), do: text |> binary_part(0, min(byte_size(text), @sniff_bytes)) |> nul?()

  defp nul?(head), do: String.contains?(head, <<0>>)

  # The page's own address with some of its three parameters replaced. Everything the view holds
  # beyond the tree and the files opened out of it is here, which is why every control patches
  # rather than navigating.
  defp address(assigns, overrides) do
    query =
      [branch: assigns.branch, tab: assigns.tab, page: assigns.page]
      |> Keyword.merge(overrides)
      |> Enum.reject(fn {key, value} -> key == :page and value == 1 end)

    ~p"/projects/#{assigns.project.name}/repo?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="74rem">
      <.link
        navigate={~p"/projects/#{@project.name}"}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name}
      </.link>

      <header class="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Repository</h1>
        <form id="branch-form" phx-change="branch" class="ml-auto flex items-center gap-2">
          <label for="branch" class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
            branch
          </label>
          <select
            id="branch"
            name="branch"
            class="min-h-[46px] rounded-field border border-base-300 bg-base-100 px-2 font-mono text-[12.5px]"
          >
            <option :for={name <- @branches} value={name} selected={name == @branch}>{name}</option>
          </select>
        </form>
      </header>

      <nav class="mt-5 flex gap-5 border-b border-base-300">
        <.link
          :for={{key, label} <- [{"commits", "Commits"}, {"files", "Files"}]}
          patch={address(assigns, tab: key, page: 1)}
          class={[
            "flex min-h-[46px] items-center border-b-2 font-mono text-[12.5px]",
            if(@tab == key, do: "border-primary", else: "border-transparent opacity-60")
          ]}
        >
          {label}
        </.link>
      </nav>

      <p :if={@branches == []} class="mt-6 text-sm/[1.55] opacity-70">
        This repository has no branches yet.
      </p>

      <section :if={@tab == "commits"} id="commits" class="mt-6">
        <ol class="flex flex-col">
          <li :for={commit <- @commits} class="border-b border-base-300/60">
            <.link
              navigate={commit_path(assigns, commit.sha)}
              class="flex min-h-[46px] items-center gap-3 py-1.5 text-[12.5px] hover:bg-base-200"
            >
              <span class="shrink-0 font-mono opacity-60">{Diff.short(commit.sha)}</span>
              <span class="min-w-0 flex-1 break-words text-sm/[1.4]">{commit.subject}</span>
              <span class="shrink-0 font-mono opacity-50">{Format.ago(commit.at, @now)}</span>
            </.link>
          </li>
        </ol>

        <p :if={@commits == []} class="text-sm/[1.55] opacity-70">
          No commits on this branch at this page.
        </p>

        <div :if={@more or @page > 1} class="mt-4 flex items-center gap-5">
          <.link
            :if={@page > 1}
            patch={address(assigns, page: @page - 1)}
            class="flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
          >
            ‹ Newer
          </.link>
          <.link
            :if={@more}
            patch={address(assigns, page: @page + 1)}
            class="flex min-h-[46px] items-center font-mono text-[12.5px] text-primary hover:underline"
          >
            Older ›
          </.link>
        </div>
      </section>

      <section :if={@tab == "files"} id="files" class="mt-6">
        <p :if={@head} class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">
          {@branch} at {Diff.short(@head)}
        </p>
        <div class="mt-3">
          <.tree_entries tree={@tree} open_files={@open_files} dir="" />
        </div>
      </section>
    </Layouts.app>
    """
  end

  # Where the commit page goes, carrying where it was opened from so its back link returns to
  # this branch and this page rather than to the top.
  defp commit_path(assigns, sha) do
    query = [branch: assigns.branch, page: assigns.page]
    ~p"/projects/#{assigns.project.name}/repo/commits/#{sha}?#{query}"
  end

  attr :tree, :map, required: true
  attr :open_files, :map, required: true
  attr :dir, :string, required: true

  # One directory's children, each folder recursing into its own. Plain identifier text — mono,
  # no colour, no icons — and a folder told from a file by its `▸` alone
  # (`docs/design/ui.md` § The project's repository).
  defp tree_entries(assigns) do
    ~H"""
    <ul class="flex flex-col font-mono text-[12.5px]">
      <li :for={entry <- @tree[@dir] || []} data-path={entry.path}>
        <details :if={entry.kind == :tree} phx-mounted={ForgeWeb.Actions.keep_open()}>
          <summary
            phx-click="expand"
            phx-value-path={entry.path}
            class="flex min-h-[46px] cursor-pointer items-center gap-2"
          >
            <span aria-hidden="true" class="opacity-40">▸</span>
            <span class="min-w-0 break-all">{entry.name}</span>
          </summary>
          <div class="pl-4">
            <.tree_entries tree={@tree} open_files={@open_files} dir={entry.path} />
          </div>
        </details>

        <div :if={entry.kind != :tree}>
          <button
            type="button"
            phx-click="open"
            phx-value-path={entry.path}
            class="flex min-h-[46px] w-full items-center gap-2 text-left"
          >
            <span aria-hidden="true" class="opacity-0">▸</span>
            <span class="min-w-0 break-all">{entry.name}</span>
          </button>
          <.file :if={@open_files[entry.path]} path={entry.path} file={@open_files[entry.path]} />
        </div>
      </li>
    </ul>
    """
  end

  attr :path, :string, required: true
  attr :file, :any, required: true

  # What was read, or which bound stopped it. Both are the row saying what the file is, not a
  # failure the page reports — and a path with nothing behind it is never in this map at all.
  defp file(assigns) do
    ~H"""
    <div data-file={@path} class="mb-3 ml-6">
      <%= case @file do %>
        <% {:text, text} -> %>
          <%!-- No ligatures, as for every `pre` (app.css): `|>` drawn as a triangle is not
                what the file says. --%>
          <pre class="overflow-x-auto border border-base-300 p-3 font-mono text-[12.5px] leading-[1.5] [font-variant-ligatures:none]"><code>{text}</code></pre>
        <% :binary -> %>
          <p class="opacity-70">This file is binary. Its content is not shown.</p>
        <% {:too_large, bytes} -> %>
          <p class="opacity-70">
            This file is {div(bytes, 1024)} KB, too large to show. Read it with git.
          </p>
      <% end %>
    </div>
    """
  end
end
