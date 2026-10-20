defmodule ForgeWeb.RepoLiveTest do
  @moduledoc """
  The repository a project holds, read through its page.

  What is worth testing here is every bound the ticket set, because each of them is the kind
  that looks fine until the repository is large: the page of thirty and the page after it, the
  directory that is read only when it is opened, the file at exactly the size limit, and the
  binary file that must be named and never drawn. And the guard over all of it — a non-member
  gets a miss — plus the promise that none of this writes to the repository.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Git, Projects}

  @limit 512 * 1024

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    {:ok, project} =
      Projects.register(
        %{name: "proj-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    %{project: project, repo: Projects.repo_path(project)}
  end

  describe "who may look" do
    test "a non-member gets the miss a project that does not exist gets", %{
      conn: conn,
      project: project
    } do
      # The mutation: delete the `ForgeWeb.Access` call in `RepoLive.mount/3` and this user —
      # a member of somewhere else, never of nothing — reads the whole repository.
      outsider = user_fixture()
      Forge.ForgeFixtures.join!(Forge.ForgeFixtures.project_fixture(), outsider)

      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/projects/#{project.name}/repo")
      end
    end

    test "the project page links here", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, ~s|a[href="/projects/#{project.name}/repo"]|, "Repository")
    end
  end

  describe "the branch picker" do
    test "first load selects the project's default branch", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, ~s|option[selected][value="#{project.default_branch}"]|)
    end

    test "every branch is offered and none of the platform's own refs is", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/4", head)
      :ok = Git.pin(repo, "refs/forge/approved/4", head)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, ~s|option[value="ticket/4"]|)
      # Dropping the `refs/heads/` pattern from `Git.branches/1` offers this one, by its own
      # short name: the platform's pins are not somewhere a person chooses to look.
      refute has_element?(view, ~s|option[value="forge/approved/4"]|)
      refute has_element?(view, ~s|option[value="refs/forge/approved/4"]|)
    end

    test "picking a branch changes the commit list and the file tree", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/7", head)
      commit_to(repo, "ticket/7", %{"only-on-seven.txt" => "x\n"}, "a commit only seven has")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")
      refute render(view) =~ "a commit only seven has"

      html =
        view
        |> element("form[phx-change=branch]")
        |> render_change(%{"branch" => "ticket/7"})

      assert html =~ "a commit only seven has"

      # And the tree is the new branch's too, not the one the page mounted on.
      assert view |> element("a", "Files") |> render_click() =~ "only-on-seven.txt"
    end

    test "an unknown branch in the address falls back to the default", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?branch=gone")

      assert has_element?(view, ~s|option[selected][value="#{project.default_branch}"]|)
    end
  end

  describe "the commit list" do
    setup %{repo: repo} do
      # Thirty-one commits: the seed and thirty of our own. The boundary is what matters — a
      # page of thirty, `Older ›`, and the thirty-first on the page behind it.
      seed_commits(repo, "main", 30)
      :ok
    end

    test "thirty newest first, with a way further back", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert html =~ "commit 30"
      assert html =~ "commit 1"
      refute html =~ ">seed<"
      assert length(html |> Floki.parse_document!() |> Floki.find("#commits li")) == 30
      assert has_element?(view, "a", "Older ›")
      refute has_element?(view, "a", "‹ Newer")
    end

    test "the page behind it holds the thirty-first and offers no more", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      html = view |> element("a", "Older ›") |> render_click()

      assert html =~ "seed"
      assert length(html |> Floki.parse_document!() |> Floki.find("#commits li")) == 1
      assert has_element?(view, "a", "‹ Newer")
      refute has_element?(view, "a", "Older ›")
    end

    test "a page beyond the history is empty rather than an error", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo?page=9")

      assert html =~ "No commits on this branch at this page."
    end
  end

  describe "the file tree" do
    test "the root is open and a directory's children appear only once expanded", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      # The root is drawn without a click.
      assert html =~ "README.md"
      assert html =~ ".forge"

      # And nothing under it is, which is the assertion the lazy read exists for: a repository
      # with ten thousand files costs the same as one with ten until somebody looks.
      refute has_element?(view, ~s|li[data-path=".forge/workflow.yml"]|)

      view |> element(~s|li[data-path=".forge"] summary|) |> render_click()

      assert has_element?(view, ~s|li[data-path=".forge/workflow.yml"]|)
      assert has_element?(view, ~s|li[data-path=".forge/agents"]|)
      # One level only: the directory inside it is named, and its own children still are not.
      refute has_element?(view, ~s|li[data-path=".forge/agents/plan.md"]|)
    end

    test "a file under the limit shows its exact content", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      html = view |> element(~s|li[data-path="README.md"] button|) |> render_click()

      assert html =~ "# Game"
    end

    test "a file at the limit is named and not loaded; one a byte under is drawn", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # The mutation target: `>=` flipped to `>` in `RepoLive.read/2` passes the first of these
      # and fails the second.
      commit_to(repo, "main", %{
        "exactly.txt" => String.duplicate("a", @limit),
        "just-under.txt" => String.duplicate("b", @limit - 1)
      })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      html = view |> element(~s|li[data-path="exactly.txt"] button|) |> render_click()
      assert html =~ "too large to show"
      refute html =~ String.duplicate("a", 200)

      html = view |> element(~s|li[data-path="just-under.txt"] button|) |> render_click()
      assert html =~ String.duplicate("b", 200)
    end

    test "a binary file is named and its content never drawn", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # NULs around something recognisable, so "never rendered" is an assertion and not a hope.
      commit_to(repo, "main", %{"logo.bin" => <<0, 1>> <> "NOTTEXT" <> <<0, 2>>})

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      assert html =~ "logo.bin"

      html = view |> element(~s|li[data-path="logo.bin"] button|) |> render_click()

      assert html =~ "This file is binary."
      refute html =~ "NOTTEXT"
    end
  end

  describe "a repository with nothing in it" do
    test "a branch that is gone leaves the page standing", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # Registering a project gives its default branch a root commit, so the only way to a
      # repository with no branches is one whose branch went away — which is the case every
      # fallback in this view is for: no picker, no head, no tree and no commits, and a page
      # that still renders.
      :ok = Git.delete_branch(repo, project.default_branch)

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert html =~ "This repository has no branches yet."
      assert html =~ "No commits on this branch at this page."
      refute has_element?(view, "option")
      assert view |> element("a", "Files") |> render_click() =~ "no branches yet"
    end

    test "a path the commit does not hold opens nothing and raises nothing", %{
      conn: conn,
      project: project
    } do
      # The path arrives off the wire, so it is not only what the tree offered.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      html = render_click(view, "open", %{"path" => "../../etc/passwd"})

      # Nothing opened and nothing raised: `..` is matched against git's own tree, where it
      # matches as little as any other typo, so no path guard is needed in front of it.
      refute html =~ "data-file"
      assert html =~ "README.md"
    end
  end

  # The ticket's last criterion, and the one nothing else would catch: a stray `checkout`,
  # `branch` or `commit` anywhere in this view would move a ref, and every other test here would
  # still pass.
  test "browsing writes nothing to the repository", %{conn: conn, project: project, repo: repo} do
    {:ok, main} = Git.resolve(repo, "refs/heads/main")
    :ok = Git.create_branch(repo, "ticket/8", main)
    commit_to(repo, "ticket/8", %{"nested/deep/file.txt" => "deep\n"})
    before = state(repo)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

    view |> element("form[phx-change=branch]") |> render_change(%{"branch" => "ticket/8"})
    view |> element("a", "Files") |> render_click()
    view |> element(~s|li[data-path="nested"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep/file.txt"] button|) |> render_click()
    view |> element("a", "Commits") |> render_click()

    {:ok, head} = Git.resolve(repo, "refs/heads/ticket/8")
    {:ok, _commit_view, _html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}")

    assert state(repo) == before
  end

  # Every ref the repository holds and what each points at. A branch created, moved or deleted,
  # or a commit made, changes this.
  defp state(repo) do
    {:ok, refs} = Git.run(repo, ["for-each-ref", "--format=%(refname) %(objectname)"])
    refs
  end

  # `count` commits on `branch`, made in one clone and pushed once: a clone per commit is most
  # of this file's runtime for nothing.
  defp seed_commits(repo, branch, count) do
    work = Path.join(tmp_dir("history"), "work")
    {:ok, _out} = Git.run(tmp_dir("history-parent"), ["clone", "-q", "-b", branch, repo, work])

    for n <- 1..count do
      File.write!(Path.join(work, "n.txt"), "#{n}\n")
      {:ok, _out} = Git.run(work, ["add", "n.txt"])

      {:ok, _out} =
        Git.run(work, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@forge",
          "commit",
          "-q",
          "-m",
          "commit #{n}"
        ])
    end

    {:ok, _out} =
      Git.run(work, ["push", "-q", "origin", "HEAD:refs/heads/" <> branch],
        env: [{"FORGE_INTERNAL", "1"}]
      )

    :ok
  end
end
