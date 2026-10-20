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

    test "a file opened on one branch is not still open under another's name", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # The tree half of this was asserted and the opened file's was not, which is the half
      # that would show one branch's bytes under another branch's name — wrong rather than
      # stale-looking-fine, which is why `reset_tree/1` drops both.
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/7", head)
      commit_to(repo, "ticket/7", %{"README.md" => "# Seven\n"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      assert view |> element(~s|li[data-path="README.md"] button|) |> render_click() =~ "# Game"

      after_switch =
        view |> element("form[phx-change=branch]") |> render_change(%{"branch" => "ticket/7"})

      refute after_switch =~ "# Game"
      refute after_switch =~ "data-file"
    end

    test "the default branch being gone does not split the picker from the page", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # With no `selected` option the browser shows the first one, so a page that fell back to
      # the deleted default drew `ticket/9` in the picker and the missing branch's empty state
      # underneath it.
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/9", head)
      :ok = Git.delete_branch(repo, project.default_branch)

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, ~s|option[selected][value="ticket/9"]|)
      assert html =~ "seed"
      refute html =~ "No commits on this branch at this page."
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

      # The subjects themselves, in the order drawn: thirty, newest first, and the seed — the
      # thirty-first — behind rather than merely absent from the markup.
      assert subjects(html) == Enum.map(30..1//-1, &"commit #{&1}")
      assert has_element?(view, "a", "Older ›")
      refute has_element?(view, "a", "‹ Newer")
    end

    test "the page behind it holds the thirty-first and offers no more", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      html = view |> element("a", "Older ›") |> render_click()

      assert subjects(html) == ["seed"]
      assert has_element?(view, "a", "‹ Newer")
      refute has_element?(view, "a", "Older ›")
    end

    test "a commit opened from a page comes back to that page", %{conn: conn, project: project} do
      # `commit_path/2` is what writes the origin into the link; the commit page's own test
      # only ever proved that `back/2` reads one out of an address a test hand-wrote.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")
      view |> element("a", "Older ›") |> render_click()

      {:error, {:live_redirect, %{to: to}}} =
        view |> element(~s|#commits li:first-child a|) |> render_click()

      {:ok, commit_view, _html} = live(conn, to)
      back = ~p"/projects/#{project.name}/repo?#{[branch: "main", tab: "commits", page: 2]}"

      assert has_element?(commit_view, ~s|a[href="#{back}"]|)
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
      # Three shapes, because the sniff this replaced caught only the first. A PNG-like header
      # has its NUL at byte 0; a real archive can run thousands of bytes before one; and a
      # latin-1 source file has no NUL at all and is still not text this page can carry.
      commit_to(repo, "main", %{
        "logo.bin" => <<0, 1>> <> "NOTTEXT" <> <<0, 2>>,
        "late.bin" => String.duplicate("a", 9000) <> <<0>> <> "LATENUL",
        "latin1.txt" => "caf" <> <<0xE9>> <> "LATIN\n"
      })

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      for name <- ~w(logo.bin late.bin latin1.txt) do
        assert html =~ name
        drawn = view |> element(~s|li[data-path="#{name}"] button|) |> render_click()
        assert drawn =~ "This file is binary."
        # Closed again, so the next one is opened rather than added beside it.
        view |> element(~s|li[data-path="#{name}"] button|) |> render_click()
      end

      refute render(view) =~ "NOTTEXT"
      refute render(view) =~ "LATENUL"
      refute render(view) =~ "LATIN"
    end

    # The whole of it, not a window: the review's own probe was a file whose first bytes were
    # fine. `String.valid?` reads every byte, so there is no window left to get wrong.
    test "only one file is open at a time", %{conn: conn, project: project, repo: repo} do
      commit_to(repo, "main", %{"one.txt" => "FIRSTFILE\n", "two.txt" => "SECONDFILE\n"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      assert view |> element(~s|li[data-path="one.txt"] button|) |> render_click() =~ "FIRSTFILE"

      second = view |> element(~s|li[data-path="two.txt"] button|) |> render_click()
      assert second =~ "SECONDFILE"
      refute second =~ "FIRSTFILE"

      # And the open one closes.
      closed = view |> element(~s|li[data-path="two.txt"] button|) |> render_click()
      refute closed =~ "SECONDFILE"
    end

    test "directories come before files, each in name order", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      commit_to(repo, "main", %{"aaa.txt" => "a\n", "zzz/inside.txt" => "z\n"})

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      paths =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s|#files > div > ul > li|)
        |> Floki.attribute("data-path")

      assert paths == [".forge", "zzz", "README.md", "aaa.txt"]
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

      # A real file first, so `data-file` is known to appear when something *is* open — the
      # first version of this asserted on `README.md`, which the seeded root draws either way.
      assert view |> element(~s|li[data-path="README.md"] button|) |> render_click() =~
               "data-file"

      for path <- ["../../etc/passwd", "../config", "/etc/passwd", "./README.md", ".forge"] do
        refute render_click(view, "open", %{"path" => path}) =~ ~s|data-file="#{path}"|
      end
    end

    # The moduledoc reasons about a path's *value* arriving off the wire; these are its type.
    # Both took the LiveView down before they were guarded — one in `dir <> "/"`, one in git's
    # own argument list.
    test "a payload that is not this page's changes nothing and raises nothing", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      before = render(view)

      render_click(view, "expand", %{"path" => ["a", "b"]})
      render_click(view, "open", %{"path" => %{"a" => "b"}})
      render_change(view, "branch", %{"branch" => ["main"]})

      # Still alive, and showing exactly what it showed.
      assert render(view) == before
    end

    test "a page or a tab the address invents lands somewhere real", %{
      conn: conn,
      project: project
    } do
      # `?page=0` sent git `--skip=-30` and `?page=99999999999999999999` sent it a number it
      # refuses outright; both then drew the same empty page a reader gets past the end of a
      # real history, which is a failure wearing a correct answer's clothes.
      for page <- ["0", "-5", "1.5", "0x10", "99999999999999999999", "nonsense"] do
        {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo?page=#{page}")
        assert html =~ "seed"
        refute html =~ "No commits on this branch at this page."
      end

      # And a tab nothing names is the Commits tab, not a blank page under the nav.
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=bogus")
      assert html =~ "seed"
    end
  end

  # The ticket's last criterion. The first version of this test compared `for-each-ref` output,
  # which a page that writes a *file* into the bare repository walks straight past: one GET of
  # `/repo/commits/--output=HEAD` emptied the project's `HEAD` with every ref exactly where it
  # had been. What is compared now is the repository as a directory.
  test "browsing writes nothing to the repository", %{conn: conn, project: project, repo: repo} do
    {:ok, main} = Git.resolve(repo, "refs/heads/main")
    :ok = Git.create_branch(repo, "ticket/8", main)
    commit_to(repo, "ticket/8", %{"nested/deep/file.txt" => "deep\n"})
    before = tree_of(repo)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

    view |> element("form[phx-change=branch]") |> render_change(%{"branch" => "ticket/8"})
    view |> element("a", "Files") |> render_click()
    view |> element(~s|li[data-path="nested"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep/file.txt"] button|) |> render_click()
    view |> element("a", "Commits") |> render_click()
    view |> element(~s|#commits li:first-child a|) |> render_click()

    assert tree_of(repo) == before
  end

  # The address names a commit, and git reads any argument beginning with a dash as an option
  # wherever it sits: `log --output=<file>` writes a file, relative to the repository. Each of
  # these was an arbitrary create-or-truncate as the platform's own user, to any member of any
  # one project.
  test "a sha that git would read as an option writes nothing", %{
    conn: conn,
    project: project,
    repo: repo
  } do
    before = tree_of(repo)

    for sha <- ["--output=config", "--output=HEAD", "--output=../../forge-escaped", "-h"] do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/projects/#{project.name}/repo/commits/#{sha}")
      end
    end

    assert tree_of(repo) == before
    refute File.exists?(Path.join(repo, "../forge-escaped"))
    # And the repository still works, which `--output=HEAD` is what it is for.
    assert {:ok, _sha} = Git.resolve(repo, "refs/heads/" <> project.default_branch)
  end

  # The subject of each commit row, in the order the page drew them.
  defp subjects(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#commits li span.flex-1")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  # Every file under `repo`, by path and content hash. `for-each-ref` sees refs; this sees the
  # repository.
  defp tree_of(repo) do
    repo
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, repo), :crypto.hash(:sha256, File.read!(&1))})
  end
end
