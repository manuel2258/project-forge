defmodule ForgeWeb.RepoLiveTest do
  @moduledoc """
  The repository a project holds, read through its page.

  What is worth testing here is every bound the ticket set, because each of them is the kind
  that looks fine until the repository is large: the page of thirty and the page after it, the
  directory that is read only when it is opened, the file at exactly the size limit, and the
  binary file that must be named and never drawn. And the guard over all of it — a non-member
  gets a miss — plus the promise that none of this writes to the repository.

  The page's arrangement is CSS's (`areas/repo.css`): below 1440 one of history, tree and file
  is seen, chosen by `#repo[data-shown]`, and that attribute is what these tests read for it.
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

    test "the strip is the project's views, and the top bar's parent is the project", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      for {key, label} <- [{"tickets", "Tickets"}, {"merge", "Merge"}, {"proposals", "Proposals"}] do
        assert has_element?(
                 view,
                 ~s|#tab-#{key}[href="/projects/#{project.name}?view=#{key}"]|,
                 label
               )
      end

      assert has_element?(view, ~s|#top-bar a[href="/projects/#{project.name}"]|, project.name)
    end
  end

  describe "the branch sheet" do
    test "first load is on the project's default branch", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, "#branch-current", project.default_branch)
      assert has_element?(view, ~s|#branches-default a[data-branch="main"][aria-current]|)
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

      assert has_element?(view, ~s|#branches-other a[data-branch="ticket/4"]|)
      # Dropping the `refs/heads/` pattern from `Git.branches/1` offers this one, by its own
      # short name: the platform's pins are not somewhere a person chooses to look.
      refute has_element?(view, ~s|#branch-sheet a[data-branch="forge/approved/4"]|)
      refute has_element?(view, ~s|#branch-sheet a[data-branch="refs/forge/approved/4"]|)
    end

    test "an open ticket's branch is named by its ticket, and only this project's", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")

      for name <- ~w(forge/mine-41 forge/theirs forge/done-2) do
        :ok = Git.create_branch(repo, name, head)
      end

      mine = Forge.ForgeFixtures.ticket_fixture(%{project: project, branch: "forge/mine-41"})

      done =
        Forge.ForgeFixtures.ticket_fixture(%{
          project: project,
          branch: "forge/done-2",
          title: "Already merged"
        })

      Forge.Repo.update!(Ecto.Changeset.change(done, status: :done))

      # Another project's open ticket carrying a branch name this repository also has. The
      # mutation: read the tickets of every project, and this one labels a branch it has nothing
      # to do with.
      Forge.ForgeFixtures.ticket_fixture(%{branch: "forge/theirs", title: "Somebody else's"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      row = ~s|#branches-tickets a[data-branch="forge/mine-41"]|
      assert has_element?(view, row, "##{mine.number}")
      assert has_element?(view, row, mine.title)
      assert has_element?(view, row, "refining")
      assert has_element?(view, "#branches-tickets", "Open tickets · 1")

      for other <- ~w(forge/theirs forge/done-2) do
        assert has_element?(view, ~s|#branches-other a[data-branch="#{other}"]|)
      end

      refute render(view) =~ "Somebody else's"
      refute render(view) =~ "Already merged"
    end

    test "the search narrows the branches, a ticket's by its number and title too", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")

      for name <- ~w(forge/x experiment/sdf) do
        :ok = Git.create_branch(repo, name, head)
      end

      ticket = Forge.ForgeFixtures.ticket_fixture(%{project: project, branch: "forge/x"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      # Its first act is typing: the sheet names the search as the field to focus (UX re-check #10).
      assert has_element?(view, ~s|#branch-sheet[data-focus="#branch-search input"]|)
      assert has_element?(view, "#branch-sheet #branch-search input")

      view |> element("#branch-search") |> render_change(%{"q" => "SDF"})
      assert has_element?(view, ~s|#branch-sheet a[data-branch="experiment/sdf"]|)
      refute has_element?(view, ~s|#branch-sheet a[data-branch="forge/x"]|)
      refute has_element?(view, ~s|#branch-sheet a[data-branch="main"]|)

      view |> element("#branch-search") |> render_change(%{"q" => "high score"})
      assert has_element?(view, ~s|#branch-sheet a[data-branch="forge/x"]|)
      refute has_element?(view, ~s|#branch-sheet a[data-branch="experiment/sdf"]|)

      view |> element("#branch-search") |> render_change(%{"q" => "##{ticket.number}"})
      assert has_element?(view, ~s|#branch-sheet a[data-branch="forge/x"]|)

      view |> element("#branch-search") |> render_change(%{"q" => "nothing like it"})
      assert has_element?(view, "#branch-groups", "No branch matches.")
    end

    # The query is kept to a bound, not to its first letters: two branches that differ only past
    # them are still told apart.
    test "the search reads the whole of a query, not only its start", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")

      for name <- ~w(experiment/sdf experiment/abc) do
        :ok = Git.create_branch(repo, name, head)
      end

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      view |> element("#branch-search") |> render_change(%{"q" => "experiment/s"})
      assert has_element?(view, ~s|#branch-sheet a[data-branch="experiment/sdf"]|)
      refute has_element?(view, ~s|#branch-sheet a[data-branch="experiment/abc"]|)
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

      html = view |> element(~s|#branch-sheet a[data-branch="ticket/7"]|) |> render_click()

      assert html =~ "a commit only seven has"
      assert has_element?(view, "#branch-current", "ticket/7")

      # And the tree is the new branch's too, not the one the page mounted on.
      assert view |> element("#repo-tab-files") |> render_click() =~ "only-on-seven.txt"
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
      assert view |> element(~s|li[data-path="README.md"] a|) |> render_click() =~ "# Game"

      after_switch =
        view |> element(~s|#branch-sheet a[data-branch="ticket/7"]|) |> render_click()

      refute after_switch =~ "# Game"
      refute has_element?(view, "[data-file]")
    end

    # The address can carry the same file across a branch change — a link, or the address edited
    # — and the file that differs between the two must be read again from the new branch.
    test "a branch change that keeps the file reads it from the new branch", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/7", head)
      commit_to(repo, "ticket/7", %{"README.md" => "# Seven\n"})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.name}/repo?#{[tab: "files", file: "README.md"]}")

      assert view |> element("[data-file]") |> render() =~ "# Game"

      html =
        render_patch(
          view,
          ~p"/projects/#{project.name}/repo?#{[branch: "ticket/7", tab: "files", file: "README.md"]}"
        )

      assert has_element?(view, "#branch-current", "ticket/7")
      assert view |> element("[data-file]") |> render() =~ "# Seven"
      refute html =~ "# Game"
    end

    # A ticket's recorded branch the repository does not have (never pushed, or deleted) is no
    # row of the sheet, and the count beside it does not count it either.
    test "an open ticket whose branch is not in the repository is not counted", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "forge/here-1", head)
      Forge.ForgeFixtures.ticket_fixture(%{project: project, branch: "forge/here-1"})
      Forge.ForgeFixtures.ticket_fixture(%{project: project, branch: "forge/gone-2"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, ".repo-about-count", "2 branches · 1 for open tickets")
      refute has_element?(view, ~s|#branch-sheet a[data-branch="forge/gone-2"]|)
    end

    test "no branch row carries the open file or a file's history to another branch", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "forge/t", head)
      :ok = Git.create_branch(repo, "other", head)
      Forge.ForgeFixtures.ticket_fixture(%{project: project, branch: "forge/t"})

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.name}/repo?file=README.md&path=README.md")

      assert has_element?(view, "[data-file]")

      hrefs =
        html
        |> Floki.parse_document!()
        |> Floki.find("#branch-sheet a")
        |> Floki.attribute("href")

      assert length(hrefs) == 3

      for href <- hrefs do
        refute href =~ "file="
        refute href =~ "path="
      end
    end

    test "the default branch being gone does not split the picker from the page", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # A page that fell back to the deleted default's name drew the picker on one branch and
      # the missing branch's empty state underneath it.
      {:ok, head} = Git.resolve(repo, "refs/heads/main")
      :ok = Git.create_branch(repo, "ticket/9", head)
      :ok = Git.delete_branch(repo, project.default_branch)

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo")

      assert has_element?(view, "#branch-current", "ticket/9")
      assert html =~ "seed"
      refute html =~ "No commits on this branch at this page."
    end

    test "an unknown branch in the address falls back to the default", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?branch=gone")

      assert has_element?(view, "#branch-current", project.default_branch)
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

    # On a wide screen the list sits beside an open file: a commit opened from it comes back to
    # that file, on the view it was open on (r2 L3).
    test "a commit opened beside an open file comes back to that file", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files&file=README.md")

      {:error, {:live_redirect, %{to: to}}} =
        view |> element(~s|#commits li:first-child a|) |> render_click()

      {:ok, commit_view, _html} = live(conn, to)

      back =
        ~p"/projects/#{project.name}/repo?#{[branch: "main", tab: "files", file: "README.md"]}"

      assert has_element?(commit_view, ~s|#commit-back[href="#{back}"]|)
    end

    test "each row names its author, and the foot says which commits these are", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo")

      # `seed_commits/3` commits as `t` and the seeded root as `seed`: two authors, each drawn
      # on its own row.
      assert has_element?(view, "#commits li:first-child .commit-author", "t")
      assert has_element?(view, "#commits .repo-foot-at", "1–30")
      assert has_element?(view, "#commits .repo-foot-off", "‹ Newer")

      view |> element("a", "Older ›") |> render_click()
      assert has_element?(view, "#commits li:last-child .commit-author", "seed")
      refute has_element?(view, "#commits .commit-author", "t")
      assert has_element?(view, "#commits .repo-foot-at", "31–31")
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
      # A folder says so by its trailing slash, not by an icon.
      assert has_element?(view, ~s|li[data-path=".forge/agents"] summary|, "agents/")
      assert has_element?(view, ~s|li[data-path=".forge/agents"]|)
      # One level only: the directory inside it is named, and its own children still are not.
      refute has_element?(view, ~s|li[data-path=".forge/agents/plan.md"]|)
    end

    test "a file under the limit shows its exact content", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      html = view |> element(~s|li[data-path="README.md"] a|) |> render_click()

      assert drawn(html, "README.md") =~ "# Game"
    end

    test "a file is drawn highlighted, its markup escaped", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # The page's half of `ForgeWeb.HighlightTest`: the file it read is the one highlighted, by
      # its own name, and what the file says is text on the page and never markup in it.
      source = ~s|defmodule Evil do\n  # </span><script>alert(1)</script>\nend\n|
      commit_to(repo, "main", %{"evil.ex" => source})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      html = view |> element(~s|li[data-path="evil.ex"] a|) |> render_click()

      assert has_element?(view, ~s|[data-file="evil.ex"] .code-highlighted .l-comment|)
      refute html =~ "<script>"
      # Spaces aside: LiveViewTest's own tree drops the whitespace-only text between two spans,
      # which a browser keeps (`ForgeWeb.HighlightTest` holds the exact text).
      assert drawn(html, "evil.ex") |> String.replace(~r/\s/, "") ==
               source |> String.replace(~r/\s/, "")
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

      html = view |> element(~s|li[data-path="exactly.txt"] a|) |> render_click()
      # In the words Changes uses for the same file, from the same function (r2 L6).
      assert html =~
               "exactly.txt is 512 KB; this page draws a file under 512 KB. Read it with git."

      refute html =~ String.duplicate("a", 200)

      html = view |> element(~s|li[data-path="just-under.txt"] a|) |> render_click()
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
        drawn = view |> element(~s|li[data-path="#{name}"] a|) |> render_click()
        assert drawn =~ "This file is binary."
      end

      refute render(view) =~ "NOTTEXT"
      refute render(view) =~ "LATENUL"
      refute render(view) =~ "LATIN"
    end

    # The whole of it, not a window: the review's own probe was a file whose first bytes were
    # fine. `String.valid?` reads every byte, so there is no window left to get wrong.
    test "only one file is open at a time, as its own screen", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      commit_to(repo, "main", %{"one.txt" => "FIRSTFILE\n", "two.txt" => "SECONDFILE\n"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      assert has_element?(view, ~s|#repo[data-shown="tree"]|)

      assert view |> element(~s|li[data-path="one.txt"] a|) |> render_click() =~ "FIRSTFILE"
      assert has_element?(view, ~s|#repo[data-shown="file"]|)

      second = view |> element(~s|li[data-path="two.txt"] a|) |> render_click()
      assert second =~ "SECONDFILE"
      refute second =~ "FIRSTFILE"

      # And the back row closes it, onto the tree.
      closed = view |> element("#file-back") |> render_click()
      refute closed =~ "SECONDFILE"
      assert has_element?(view, ~s|#repo[data-shown="tree"]|)
    end

    test "the tree keeps its place while a file is open", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # The file is a screen of its own on a phone; the tree is still the page's, with every
      # directory it had read, so going back finds it as it was left.
      commit_to(repo, "main", %{"lib/game/scores.ex" => "defmodule Scores do\nend\n"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      view |> element(~s|li[data-path="lib"] summary|) |> render_click()
      view |> element(~s|li[data-path="lib/game"] summary|) |> render_click()
      view |> element(~s|li[data-path="lib/game/scores.ex"] a|) |> render_click()

      assert has_element?(view, ~s|#repo[data-shown="file"]|)
      assert has_element?(view, ~s|#files li[data-path="lib/game/scores.ex"] a[aria-current]|)
      assert has_element?(view, "#file-size", "2 lines")
      assert has_element?(view, "#file-path", "lib/game/scores.ex")
      assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "main at ")
    end

    test "a file opened from the address is shown where it sits in the tree", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      # A link to a file deep in the tree: on a wide screen the tree is beside it, and a tree
      # drawn at its root would not say where the file is (`10f`).
      commit_to(repo, "main", %{"lib/game/scores.ex" => "x\n", "lib/other/a.ex" => "y\n"})

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.name}/repo?tab=files&file=lib/game/scores.ex")

      assert has_element?(view, ~s|#files li[data-path="lib"] > details[open]|)
      assert has_element?(view, ~s|#files li[data-path="lib/game"] > details[open]|)
      assert has_element?(view, ~s|#files li[data-path="lib/game/scores.ex"] a[aria-current]|)
      # Only the way to it: a sibling directory is named and not opened.
      refute has_element?(view, ~s|#files li[data-path="lib/other"] > details[open]|)
      refute has_element?(view, ~s|#files li[data-path="lib/other/a.ex"]|)
    end

    test "a file's history is a link to the commits that changed it", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      commit_to(repo, "main", %{"one.txt" => "1\n"}, "touch one")
      commit_to(repo, "main", %{"two.txt" => "2\n"}, "touch two")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files&file=one.txt")

      html = view |> element("#file-history") |> render_click()

      assert has_element?(view, ~s|#repo[data-shown="commits"]|)
      assert has_element?(view, "#commits", "History of one.txt")
      # The path is drawn as it is named, out of the eyebrow's capitals (UX pass, C11).
      assert has_element?(view, "#commits .ui-eyebrow .ui-id", "one.txt")
      assert subjects(html) == ["touch one"]

      # The commit it opens comes back to this history.
      assert has_element?(view, ~s|#commits li:first-child a[href*="path=one.txt"]|)

      html = view |> element("#history-all") |> render_click()
      assert subjects(html) == ["touch two", "touch one", "seed"]
    end

    # The crash the patch guard did not reach: a *filename* that is not valid UTF-8. The only
    # link to this page is a `<.link navigate>`, so the first render of the files tab already
    # goes through the socket's serializer, which raises on such bytes in its own transport
    # process and takes every LiveView on the connection with it.
    test "a file whose name is not text is drawn, escaped, and still opens", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      raw = "caf" <> <<0xE9>> <> ".txt"
      commit_to(repo, "main", %{raw => "LATINCONTENT\n"})

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      # Valid UTF-8, which is what the socket can carry at all.
      assert String.valid?(html)
      assert html =~ ~s(caf\\351.txt)
      refute html =~ raw

      # And the escaped name still names the file. The browser holds exactly what is in the
      # attribute above, so sending that back is the round trip: the page reads it into the
      # bytes git wants before git sees it.
      escaped = ~s("caf\\351.txt")
      assert escaped in paths(html)

      opened = render_patch(view, ~p"/projects/#{project.name}/repo?#{[file: escaped]}")
      assert String.valid?(opened)
      assert opened =~ "LATINCONTENT"
    end

    test "a directory whose name is not text still expands", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      commit_to(repo, "main", %{("d" <> <<0xE9>> <> "r/inside.txt") => "in\n"})

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")
      assert String.valid?(html)

      escaped = ~s("d\\351r")
      assert escaped in paths(html)

      expanded = render_click(view, "expand", %{"path" => escaped})

      assert String.valid?(expanded)
      assert expanded =~ "inside.txt"
    end

    test "directories come before files, each in name order", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      commit_to(repo, "main", %{"aaa.txt" => "a\n", "zzz/inside.txt" => "z\n"})

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      assert paths(html) == [".forge", "zzz", "README.md", "aaa.txt"]
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
      refute has_element?(view, "#branch-button")
      refute has_element?(view, "#branch-sheet a")
      assert view |> element("#repo-tab-files") |> render_click() =~ "no branches yet"
    end

    # With no branch there is no commit to read a file from: the address's file opens nothing,
    # rather than being named a binary file.
    test "a file in the address of a repository with no commit opens nothing", %{
      conn: conn,
      project: project,
      repo: repo
    } do
      :ok = Git.delete_branch(repo, project.default_branch)

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.name}/repo?#{[tab: "files", file: "README.md"]}")

      refute has_element?(view, "[data-file]")
      refute html =~ "This file is binary"
    end

    test "a path the commit does not hold opens nothing and raises nothing", %{
      conn: conn,
      project: project
    } do
      # The path arrives in the address, so it is not only what the tree offered.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/repo?tab=files")

      # A real file first, so `data-file` is known to appear when something *is* open — the
      # first version of this asserted on `README.md`, which the seeded root draws either way.
      assert view |> element(~s|li[data-path="README.md"] a|) |> render_click() =~
               "data-file"

      for path <- ["../../etc/passwd", "../config", "/etc/passwd", "./README.md", ".forge"] do
        render_patch(view, ~p"/projects/#{project.name}/repo?#{[tab: "files", file: path]}")
        refute has_element?(view, "[data-file]")
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
      render_change(view, "search", %{"q" => %{"a" => "b"}})

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

      # A query parameter can be a list as easily as a string, and `Integer.parse/1` wants a
      # binary: `?page[]=2` raised `FunctionClauseError` in `handle_params` for any member.
      # `tab` and `branch` need no clause of their own — `in @tabs` and `in branches` are both
      # false for a list — which is why this is the one guard here.
      for query <- [
            "page[]=2",
            "page[]=2&page[]=3",
            "tab[]=files",
            "branch[]=main",
            "file[]=README.md",
            "path[]=README.md"
          ] do
        {:ok, _view, html} = live(conn, "/projects/#{project.name}/repo?#{query}")
        assert html =~ "seed"
      end
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

    view |> element(~s|#branch-sheet a[data-branch="ticket/8"]|) |> render_click()
    view |> element("#branch-search") |> render_change(%{"q" => "ticket"})
    view |> element("#repo-tab-files") |> render_click()
    view |> element(~s|li[data-path="nested"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep"] summary|) |> render_click()
    view |> element(~s|li[data-path="nested/deep/file.txt"] a|) |> render_click()
    view |> element("#file-history") |> render_click()
    view |> element("#repo-tab-commits") |> render_click()
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

  # What the browser holds for each row of the tree's top level — the value a click sends back.
  defp paths(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s|#files .repo-tree-body > ul > li|)
    |> Floki.attribute("data-path")
  end

  # The open file's text as the reader sees it, its lines joined again.
  defp drawn(html, path) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s|[data-file="#{path}"] .code-text|)
    |> Enum.map_join("\n", &LazyHTML.text/1)
  end

  # The subject of each commit row, in the order the page drew them.
  defp subjects(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("#commits li .commit-subject")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end
end
