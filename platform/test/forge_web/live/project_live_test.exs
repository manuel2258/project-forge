defmodule ForgeWeb.ProjectLiveTest do
  @moduledoc """
  One project: its board, its workflow, and the repository behind it.

  The distinction worth testing is the one the page exists to make legible — the workflow it
  shows is the repository's current one, which the *next* ticket will pin, while the board is
  arranged by the workflow the tickets on it were admitted with. Those differ the moment a
  workflow changes, and a page that conflated them would be wrong exactly when it mattered.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Projects, Tickets}

  setup :register_and_log_in_user

  setup do
    repos = tmp_dir("repos")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    {:ok, project} =
      Projects.register(%{
        name: "proj-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    %{project: project}
  end

  test "shows the board, the workflow and the repository", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

    # The board, with the ticket in its state.
    assert html =~ "Persist scores"
    assert html =~ ticket.state
    assert html =~ "1 open"

    # The workflow the next ticket will pin, read off the repository. Asserted on content only
    # the workflow table can produce: "initial" alone matches the layout's viewport meta tag,
    # and "main" matches `data-phx-main` on every LiveView in the product.
    assert html =~ "Workflow the next ticket will pin"
    assert html =~ "agents/refine.md"
    assert html =~ "20 turns"
    assert has_element?(view, "dd", project.default_branch)

    # And the one thing an operator has to leave the product for.
    assert html =~ "/git/#{project.name}.git"
  end

  test "the workflow shown is the repository's, not the board's", %{conn: conn, project: project} do
    # The distinction the page is built around. The ticket pins `refining` at admission; the
    # repository then moves on, and the page has to show both truths at once.
    {:ok, _ticket} = Tickets.admit(project, %{title: "Admitted before the change"}, :system)
    rewrite_workflow(project)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

    # The board is arranged by what the ticket pinned.
    assert html =~ "refining"
    # The table is the repository's current workflow, which no ticket has ever been in.
    assert html =~ "surveying"
    assert html =~ "agents/survey.md"
  end

  # Commits a different workflow onto the project's default branch, so the repository's current
  # workflow and every pinned one disagree.
  defp rewrite_workflow(project) do
    repo = Forge.Projects.repo_path(project)
    work = tmp_dir("rewrite")
    {_, 0} = System.cmd("git", ["clone", "--quiet", repo, work])

    File.mkdir_p!(Path.join(work, ".forge/agents"))
    File.write!(Path.join(work, ".forge/agents/survey.md"), "Survey it.\n")

    File.write!(Path.join(work, ".forge/workflow.yml"), """
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
    """)

    for args <- [
          ["-C", work, "add", "-A"],
          ["-C", work, "-c", "user.name=t", "-c", "user.email=t@forge", "commit", "-qm", "new"],
          ["-C", work, "push", "-q", "origin", "HEAD:" <> project.default_branch]
        ] do
      {_out, 0} = System.cmd("git", args, env: [{"FORGE_INTERNAL", "1"}], stderr_to_stdout: true)
    end
  end

  test "an empty project says so rather than drawing an empty board", %{conn: conn} do
    {:ok, project} = Projects.register_named("bare-#{System.unique_integer([:positive])}", "main")

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "No tickets yet"
    # Registered but with nothing pushed: it cannot take a ticket, and the page says which.
    assert html =~ "cannot take a ticket"
    assert html =~ ".forge/workflow.yml"
  end

  test "it reloads when a ticket changes", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")
    refute html =~ "Arrived later"

    {:ok, _ticket} = Tickets.admit(project, %{title: "Arrived later"}, :system)

    assert render(view) =~ "Arrived later"
  end

  test "an unknown project is a 404", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/no-such-project") end
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/projects/#{project.name}")
  end

  test "the board links to it, and so does a ticket", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, _view, board} = live(conn, ~p"/board")
    assert board =~ ~s(href="/projects/#{project.name}")

    {:ok, _view, page} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert page =~ ~s(href="/projects/#{project.name}")
  end
end
