defmodule ForgeWeb.RepoCommitLive do
  @moduledoc """
  One commit of a project's repository: what it changed, against its own parent.

  The same `ForgeWeb.Diff.section/1` the review page draws, so a binary file already reads
  *binary* with no attempted content and an oversized change already says where to read it. A
  root commit is shown against the empty tree, so the first commit in a repository opens like
  any other. See `docs/design/ui.md` § The project's repository.
  """

  use ForgeWeb, :live_view

  alias Forge.{Git, Projects}
  alias Forge.Projects.Project
  alias ForgeWeb.{Diff, Format}

  @impl true
  def mount(%{"name" => name, "sha" => sha}, _session, socket) do
    {project, _scope} = ForgeWeb.Access.project_by_name!(socket.assigns.current_scope, name)
    repo = Projects.repo_path(project)
    commit = commit!(repo, sha)

    {:ok,
     socket
     |> assign(
       project: project,
       commit: commit,
       diff: Diff.build(repo, base(repo, commit.sha), commit.sha),
       page_title: "#{project.name} #{Diff.short(commit.sha)}",
       now: DateTime.utc_now()
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  # One page of history, one commit long: the sha the address names, with the subject and the
  # time a header draws.
  #
  # A sha that names no commit here is a miss, not an error — there is no reason to tell a typo
  # apart from a repository that does not hold it, and none to tell either apart from a project
  # that is not the viewer's, which `ForgeWeb.Access` has already answered the same way.
  defp commit!(repo, sha) do
    case Git.history(repo, sha, 0, 1) do
      {:ok, %{commits: [commit]}} -> commit
      _miss -> raise Ecto.NoResultsError, queryable: Project
    end
  end

  # Against the first parent, which is what a merge commit's own change is.
  defp base(repo, sha) do
    case Git.parent(repo, sha) do
      {:ok, parent} ->
        parent

      # A root commit's change is against the empty tree, which `Diff` then reads as any other
      # base rather than being given a special case of its own. A repository that cannot write
      # the empty tree has stopped existing between two reads, and crashes here rather than
      # drawing a commit against nothing.
      {:error, :no_parent} ->
        {:ok, tree} = Git.empty_tree(repo)
        tree
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, back: back(socket.assigns.project, params))}
  end

  # Where the reader came from, off this page's own query string: the branch they were looking
  # at and how far back they had paged.
  defp back(project, params) do
    query =
      [branch: params["branch"], tab: "commits", page: params["page"]]
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "1"] end)

    ~p"/projects/#{project.name}/repo?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} capacity={@capacity} measure="74rem">
      <.link
        navigate={@back}
        class="flex min-h-[46px] items-center font-mono text-[12.5px] opacity-60 hover:opacity-100"
      >
        ‹ {@project.name} repository
      </.link>

      <header class="mt-4 flex flex-col gap-2">
        <div class="font-mono text-[11px] tracking-[.14em] uppercase opacity-60">The commit</div>
        <h1 class="text-[23px] font-semibold -tracking-[.03em] sm:text-2xl">{@commit.subject}</h1>
        <div class="flex flex-wrap items-center gap-3 font-mono text-[12.5px] opacity-60">
          <span class="break-all">{@commit.sha}</span>
          <span>{Format.ago(@commit.at, @now)}</span>
        </div>
      </header>

      <div class="mt-8">
        <Diff.section diff={@diff} id="commit-diff" title="What it changed" />
      </div>
    </Layouts.app>
    """
  end
end
