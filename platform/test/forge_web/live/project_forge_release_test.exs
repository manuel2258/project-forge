defmodule ForgeWeb.ProjectForgeReleaseTest do
  @moduledoc """
  The project page's *forge release* line and the notice above the workflow
  (`docs/design/ui.md` § The project page, `docs/design/changelog.md`).

  The node here runs `Forge.Changelog.running/0`; each case commits a different
  `.forge/forge-release` to the default branch and reads the page.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.ForgeFixtures

  alias Forge.{Changelog, Projects, Tickets}

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

    %{project: project, running: Changelog.running()}
  end

  defp record(project, content),
    do: commit_to_default(project, %{".forge/forge-release" => content})

  defp page(conn, project) do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")
    {view, html}
  end

  # The href of the upgrade link, decoded.
  defp upgrade_href(view) do
    view
    |> element("#forge-upgrade-link")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("href")
    |> hd()
  end

  test "behind: the line, the notice naming both releases, and a link to a new chat", %{
    conn: conn,
    project: project,
    running: running
  } do
    record(project, "0.17.0\n")
    {view, html} = page(conn, project)

    assert has_element?(view, "dt", "forge release")
    assert html =~ ~r/forge release<\/dt>\s*<dd[^>]*>\s*0\.17\.0/
    assert has_element?(view, "#forge-release-notice", "Written for forge 0.17.0.")
    assert has_element?(view, "#forge-release-notice", "This node runs forge #{running}.")

    # The request is the platform's, naming the release the node runs and not the recorded one.
    href = upgrade_href(view)
    assert href =~ "/chats/new?"
    assert href =~ "project=#{project.name}"

    assert URI.decode_query(URI.parse(href).query)["text"] ==
             "Bring this project up to forge #{running}."

    refute href =~ "0.17.0"
  end

  test "not recorded: the line says so, and the notice counts the project as 0.1.1", %{
    conn: conn,
    project: project
  } do
    {view, html} = page(conn, project)

    assert html =~ "not recorded"
    assert has_element?(view, "#forge-release-notice", "records no forge release")
    assert has_element?(view, "#forge-release-notice", "forge 0.1.1")
    assert has_element?(view, "#forge-upgrade-link")
  end

  test "current: the line alone, no notice and no link", %{
    conn: conn,
    project: project,
    running: running
  } do
    record(project, running <> "\n")
    {view, html} = page(conn, project)

    assert html =~ ~r/forge release<\/dt>\s*<dd[^>]*>\s*#{Regex.escape(running)}/
    refute has_element?(view, "#forge-release-notice")
    refute has_element?(view, "#forge-upgrade-link")
  end

  test "newer than the node: both named, features may not work, and no link", %{
    conn: conn,
    project: project,
    running: running
  } do
    record(project, "99.0.0\n")
    {view, _html} = page(conn, project)

    assert has_element?(view, "dd", "99.0.0")
    assert has_element?(view, "#forge-release-notice", "forge 99.0.0")
    assert has_element?(view, "#forge-release-notice", "forge #{running}")
    assert has_element?(view, "#forge-release-notice", "may not work here")
    refute has_element?(view, "#forge-upgrade-link")
  end

  test "not a release: what the file holds is quoted as text, never markup", %{
    conn: conn,
    project: project
  } do
    record(project, "<b>x</b><a href=\"http://evil\">y</a>\n")
    {view, html} = page(conn, project)

    assert html =~ "not a release"
    assert has_element?(view, "#forge-release-quote", ~s(<b>x</b><a href="http://evil">y</a>))
    refute has_element?(view, "#forge-release-notice b")
    refute has_element?(view, "#forge-release-notice a[href='http://evil']")
    refute has_element?(view, "#forge-upgrade-link")
  end

  test "a number with no section is not a release", %{conn: conn, project: project} do
    record(project, "0.12.9\n")
    {view, _html} = page(conn, project)

    assert has_element?(view, "#forge-release-quote", "0.12.9")
  end

  test "a long value is cut short with an ellipsis", %{conn: conn, project: project} do
    record(project, String.duplicate("z", 60))
    {view, _html} = page(conn, project)

    assert view |> element("#forge-release-quote") |> render() =~ String.duplicate("z", 40) <> "…"
    refute render(view) =~ String.duplicate("z", 41)
  end

  test "a value over 64 bytes is not read, only said to be too large", %{
    conn: conn,
    project: project
  } do
    record(project, String.duplicate("z", 65))
    {view, html} = page(conn, project)

    assert has_element?(view, "#forge-release-notice", "larger than 64 bytes")
    refute html =~ "zzzzz"
  end

  test "a symlink committed in its place is not followed", %{
    conn: conn,
    project: project,
    running: running
  } do
    repo = Projects.repo_path(project)
    {:ok, sha} = Forge.Git.resolve(repo, project.default_branch)
    scratch = tmp_dir("link")
    work = Path.join(scratch, "w")
    :ok = Forge.Git.create_branch(repo, "linked", sha)
    :ok = Forge.Git.worktree_add(repo, work, "linked")
    File.write!(Path.join(work, "VERSION"), running <> "\n")
    File.ln_s!("../VERSION", Path.join(work, ".forge/forge-release"))
    {:ok, _} = Forge.Git.run(work, ["add", "-A"])

    {:ok, _} =
      Forge.Git.run(work, [
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@forge",
        "commit",
        "-q",
        "-m",
        "link"
      ])

    {:ok, head} = Forge.Git.resolve(repo, "linked")
    # the default branch moves to it, as the platform's own merge would move it
    {:ok, _} = Forge.Git.run(repo, ["update-ref", "refs/heads/#{project.default_branch}", head])

    {view, _html} = page(conn, project)

    # Followed, it would read as the running release and be current: no notice at all.
    assert has_element?(view, "#forge-release-quote", "../VERSION")
  end

  test "it is read at the default branch's tip and redrawn with the workflow block", %{
    conn: conn,
    project: project,
    running: running
  } do
    record(project, "0.17.0\n")
    {view, _html} = page(conn, project)
    assert has_element?(view, "#forge-release-notice", "Written for forge 0.17.0.")

    record(project, running <> "\n")
    # A push is not drawn live; the next redraw of the workflow block is what shows it.
    assert has_element?(view, "#forge-release-notice")
    {:ok, _ticket} = Tickets.admit(project, %{title: "Anything"}, :system)

    refute has_element?(view, "#forge-release-notice")
  end

  test "a member who is not an admin sees the line, the notice and the link", %{
    conn: _conn,
    project: project
  } do
    record(project, "0.17.0\n")
    member = member_fixture(project, :member)
    {view, _html} = page(build_conn() |> log_in_user(member), project)

    assert has_element?(view, "dt", "forge release")
    assert has_element?(view, "#forge-release-notice", "Written for forge 0.17.0.")
    assert has_element?(view, "#forge-upgrade-link")
  end

  test "someone outside the project reaches nothing", %{project: project} do
    record(project, "0.17.0\n")
    outsider = member_fixture(project_fixture(), :admin)

    assert_raise Ecto.NoResultsError, fn ->
      build_conn() |> log_in_user(outsider) |> live(~p"/projects/#{project.name}")
    end
  end

  # Registering a repository makes a first commit, so "no tip" is the default branch gone: the
  # case with nothing to read the file from, which the page's own "cannot take a ticket" block
  # already speaks for.
  test "no default branch to read reads as not recorded and draws no notice", %{
    conn: conn,
    project: project
  } do
    {:ok, _} =
      Forge.Git.run(Projects.repo_path(project), [
        "update-ref",
        "-d",
        "refs/heads/#{project.default_branch}"
      ])

    {view, html} = page(conn, project)

    assert html =~ "not recorded"
    refute has_element?(view, "#forge-release-notice")
  end

  # `Tickets.types/2` reads where it is told to: the page resolves the default branch once and gives
  # the same sha to the workflow block and to the forge release, so that they are one commit.
  test "Tickets.types reads at the sha it is given, not at the branch's tip", %{project: project} do
    {:ok, first} = Forge.Git.resolve(Projects.repo_path(project), project.default_branch)

    commit_to_default(project, %{
      ".forge/agents/survey.md" => "Survey it.\n",
      ".forge/workflow.yml" => """
      version: 1
      initial: surveying
      states:
        surveying:
          prompt: agents/survey.md
          inputs: [ticket]
          produces: [survey.md]
          budget: { turns: 5, cost: 0.10 }
        done_state: {}
      transitions:
        - { from: surveying, to: done_state }
      limits: { ticket_cost: 1.00 }
      """
    })

    initial = fn opts ->
      {:ok, %{types: [%{workflow: {:ok, workflow}}]}} = Tickets.types(project, opts)
      workflow.initial
    end

    assert initial.([]) == "surveying"
    assert initial.(at: first) == "refining"
  end

  test "the line is read from the project's own default branch, whatever it is called", %{
    conn: conn,
    project: project
  } do
    repo = Projects.repo_path(project)

    # `trunk` is `main` as it stands at 0.17.0; `main` then moves on to 0.18.0, so a read of `main`
    # and a read of the project's default branch give different answers.
    record(project, "0.17.0\n")
    {:ok, _} = Forge.Git.run(repo, ["branch", "trunk", project.default_branch])
    record(project, "0.18.0\n")
    project |> Ecto.Changeset.change(default_branch: "trunk") |> Forge.Repo.update!()

    {view, _html} = page(conn, project)

    assert has_element?(view, "#forge-release-notice", "Written for forge 0.17.0.")
  end
end
