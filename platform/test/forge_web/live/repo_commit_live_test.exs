defmodule ForgeWeb.RepoCommitLiveTest do
  @moduledoc """
  One commit of a project's repository, on its own page.

  Three things are worth a test: a commit is drawn against its own parent and not against
  something else, the repository's *first* commit opens at all — it has no parent, which is the
  case a naive `sha^` fails on — and a sha the repository does not hold is a miss rather than
  an exception of some other shape.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Git, Projects}

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

  test "a non-member gets the miss a project that does not exist gets", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    {:ok, head} = Git.resolve(repo, "refs/heads/main")
    outsider = user_fixture()
    Forge.ForgeFixtures.join!(Forge.ForgeFixtures.project_fixture(), outsider)

    assert_raise Ecto.NoResultsError, fn ->
      conn
      |> log_in_user(outsider)
      |> live(~p"/projects/#{project.name}/repo/commits/#{head}")
    end
  end

  test "a commit draws its own change, against its parent", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    head = commit_to(repo, "main", %{"score.txt" => "high\n"}, "keep the high score")

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}")

    assert html =~ "keep the high score"
    assert html =~ "score.txt"
    # The patch itself, which is only there if the base was the parent: against the empty tree
    # every seeded file would be added too.
    assert html =~ "+high"
    refute html =~ "README.md"
  end

  # No parent to diff against, which is the case `sha^` cannot resolve. The empty tree stands
  # in, so the first commit in a repository opens like any other.
  test "the repository's root commit opens against the empty tree", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    {:ok, root} = Git.resolve(repo, "refs/heads/main")
    assert {:error, :no_parent} = Git.parent(repo, root)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{root}")

    assert html =~ "seed"
    assert html =~ "README.md"
    assert html =~ ".forge/workflow.yml"
  end

  test "a sha the repository does not hold is a miss", %{conn: conn, project: project} do
    # Valid hex with nothing behind it reaches git and misses; everything else is refused by
    # the shape of the address before git is reached at all.
    for sha <- [String.duplicate("b", 40), "not-a-sha", "main", "HEAD", "abc", "ABCDEF12"] do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/projects/#{project.name}/repo/commits/#{sha}")
      end
    end
  end

  # Every commit on every branch of every project is reachable from this page, so a commit
  # touching a latin-1 source file is a 200 whose body is not valid UTF-8 — and the first patch
  # pushed over the socket after it raises inside the socket's own process.
  test "a commit whose patch is not UTF-8 is served as valid UTF-8", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    head = commit_to(repo, "main", %{"latin1.ex" => "def caf" <> <<0xE9>> <> ", do: :ok\n"})

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}")

    assert String.valid?(html)
    assert html =~ "latin1.ex"
    assert html =~ "not valid UTF-8"
  end

  test "the header names the commit short, as every other sha in the product is named", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    {:ok, head} = Git.resolve(repo, "refs/heads/main")

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}")

    assert html =~ String.slice(head, 0, 12)
    refute html =~ head
  end

  test "the back link carries the branch and the page it was opened from", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    {:ok, main} = Git.resolve(repo, "refs/heads/main")
    :ok = Git.create_branch(repo, "ticket/7", main)
    head = commit_to(repo, "ticket/7", %{"a.txt" => "a\n"})

    {:ok, view, _html} =
      live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}?branch=ticket/7&page=3")

    came_from =
      ~p"/projects/#{project.name}/repo?#{[branch: "ticket/7", tab: "commits", page: 3]}"

    assert has_element?(view, ~s|a[href="#{came_from}"]|)

    # And nothing invented when there was nowhere in particular to go back to.
    {:ok, plain, _html} = live(conn, ~p"/projects/#{project.name}/repo/commits/#{head}")
    top = ~p"/projects/#{project.name}/repo?#{[tab: "commits"]}"
    assert has_element?(plain, ~s|a[href="#{top}"]|)
  end
end
