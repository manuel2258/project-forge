defmodule ForgeWeb.RepoCommitLive do
  @moduledoc """
  One commit of a project's repository: what it changed, against its own parent (`10e`).

  The header is the commit's subject, short sha, author and age, the size of the change and the
  parent it is read against; the change is the same file list a ticket's Changes draws
  (`ForgeWeb.Diff.file_table/1`), each row opening its own patch in place, so a binary file
  already reads *binary* with no attempted content and an oversized change already says where
  to read it. A root commit is shown against the empty tree, so the first commit in a repository
  opens like any other — named rather than written, so nothing on this page touches the
  repository at all. See `docs/design/ui.md` § The project's repository.
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
    {parent, base} = base(repo, commit.sha)

    {:ok,
     socket
     |> assign(
       project: project,
       commit: commit,
       parent: parent,
       diff: Diff.build(repo, base, commit.sha),
       page_title: "#{project.name} #{Diff.short(commit.sha)}",
       now: DateTime.utc_now()
     )
     |> ForgeWeb.Capacity.project(project)}
  end

  # The address names an object, so only an object name is read out of it: hex, as long as the
  # repository's hash makes them. Anything else is the same miss a sha the repository does not
  # hold gets, and never reaches git at all.
  #
  # This is the second guard, not the first. `Forge.Git.run/3` refuses a caller's value that
  # begins with a dash wherever git would read one as an option, which is what closed
  # `/repo/commits/--output=config` — a single GET that truncated the project's `HEAD`. This one
  # is here because the page knows something `Forge.Git` cannot: the segment is a commit's name,
  # and nothing that is not one has any business being tried.
  @object_name ~r/\A[0-9a-f]{4,64}\z/

  # One page of history, one commit long: the sha the address names, with the subject and the
  # time a header draws.
  #
  # A sha that names no commit here is a miss, not an error — there is no reason to tell a typo
  # apart from a repository that does not hold it, and none to tell either apart from a project
  # that is not the viewer's, which `ForgeWeb.Access` has already answered the same way.
  defp commit!(repo, sha) do
    with true <- Regex.match?(@object_name, sha),
         {:ok, %{commits: [commit]}} <- Git.history(repo, sha, 0, 1) do
      commit
    else
      _miss -> raise Ecto.NoResultsError, queryable: Project
    end
  end

  # Against the first parent, which is what a merge commit's own change is: `{parent, base}`,
  # the parent drawn in the header (nil for a root commit) and what the change is read against.
  defp base(repo, sha) do
    case Git.parent(repo, sha) do
      {:ok, parent} ->
        {parent, parent}

      # A root commit's change is against the empty tree, which `Diff` then reads as any other
      # base rather than being given a special case of its own. Named and not written: git
      # carries the empty tree whether or not the repository holds it, so this page — like every
      # other read here — leaves the repository exactly as it found it.
      {:error, :no_parent} ->
        {:ok, tree} = Git.empty_tree(repo)
        {nil, tree}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     assign(socket,
       back: back(socket.assigns.project, params),
       branch: if(is_binary(params["branch"]), do: params["branch"])
     )}
  end

  # Where the reader came from, off this page's own query string: the branch they were looking
  # at, the view (Commits unless it said Files), how far back they had paged, the file whose
  # history it was, and the file open beside the list on a wide screen.
  defp back(project, params) do
    tab = if params["tab"] == "files", do: "files", else: "commits"

    query =
      [
        branch: params["branch"],
        tab: tab,
        page: params["page"],
        path: params["path"],
        file: params["file"]
      ]
      |> Enum.reject(fn {_key, value} -> not is_binary(value) or value in ["", "1"] end)

    ~p"/projects/#{project.name}/repo?#{query}"
  end

  # The parent opens the same page, carrying the same origin, so its back row still returns to
  # where the reader started.
  defp parent_path(project, parent, back) do
    %URI{query: query} = URI.parse(back)
    ~p"/projects/#{project.name}/repo/commits/#{parent}" <> if(query, do: "?" <> query, else: "")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      frame={@frame}
      capacity={@capacity}
      title="Repository"
      subline={if @branch, do: "#{@project.name} · #{@branch}", else: @project.name}
      context={{@project.name, ~p"/projects/#{@project.name}"}}
      back={{"#{@project.name} repository", @back}}
      views={ForgeWeb.ProjectLive.strip(@project, %{}, :navigate)}
      measure="56rem"
    >
      <div id="repo-commit" class="repo-commit-page">
        <.link id="commit-back" navigate={@back} class="repo-back">‹ Commits</.link>

        <header class="repo-commit-head">
          <.eyebrow>The commit</.eyebrow>
          <h2 id="commit-subject" class="repo-commit-subject">{@commit.subject}</h2>
          <div id="commit-meta" class="repo-commit-meta">
            <span class="repo-commit-sha">{Diff.short(@commit.sha)}</span>
            <span id="commit-author">{@commit.author}</span>
            <span>{Format.ago(@commit.at, @now)}</span>
            <.link
              :if={@parent}
              id="commit-parent"
              navigate={parent_path(@project, @parent, @back)}
              class="repo-link"
            >
              parent {Diff.short(@parent)}
            </.link>
            <span :if={!@parent} id="commit-parent">root commit</span>
          </div>
          <div :if={@diff[:files]} id="commit-size" class="repo-commit-size">
            <.diff_stat added={@diff.added} removed={@diff.removed} />
            <span>{files(length(@diff.files))}</span>
          </div>
        </header>

        <section id="commit-diff" class="repo-commit-diff" aria-label="What it changed">
          <.eyebrow>What it changed</.eyebrow>
          <Diff.file_table diff={@diff} id="commit-files" />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp files(1), do: "1 file"
  defp files(n), do: "#{n} files"
end
