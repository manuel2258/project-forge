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

  alias Forge.{Conversations, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = tmp_dir("repos")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    {:ok, project} =
      Projects.register(
        %{
          name: "proj-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

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

  test "an empty project says so rather than drawing an empty board", %{conn: conn, user: user} do
    {:ok, project} =
      Projects.register_named("bare-#{System.unique_integer([:positive])}", "main", user)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "No tickets yet"
    # Registered but with nothing pushed: it cannot take a ticket, and the page says which.
    # The whole sentence, not the filename: `ForgeWeb.Operator.Admission` has two clauses for
    # this and both name `.forge/workflow.yml`, so the filename alone holds whichever fired.
    assert html =~ "cannot take a ticket"
    assert html =~ "there is no .forge/workflow.yml on its default branch"
  end

  # The other clause, which is a different fact and not a different wording of the same one: a
  # branch with no workflow file on it is a repository waiting for one commit, while a branch that
  # does not exist is a repository the platform cannot find its footing in at all. Told the wrong
  # one, an operator spends the afternoon pushing a file onto a branch that is not there.
  test "a project whose default branch is missing is told that, not that a file is", %{
    conn: conn,
    project: project
  } do
    {:ok, _out} =
      Forge.Git.run(Projects.repo_path(project), [
        "update-ref",
        "-d",
        "refs/heads/#{project.default_branch}"
      ])

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "nothing has been pushed to its #{project.default_branch} branch yet"
    refute html =~ "there is no .forge/workflow.yml on its default branch"
  end

  test "it reloads when a ticket changes", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")
    refute html =~ "Arrived later"

    {:ok, _ticket} = Tickets.admit(project, %{title: "Arrived later"}, :system)

    assert render(view) =~ "Arrived later"
  end

  # `/chats` and this page share one row component, and it takes `project={false}` here. That attr
  # exists for this page alone: the name is already the heading and already the URL, so repeating
  # it on every row is noise on the one surface where it tells you nothing. Nothing page-wide can
  # see the difference — the name is in the heading either way — so both halves are scoped to the
  # row, and the second half is what stops the attr being "fixed" by always hiding the name.
  test "a chat row names its project only where that is news", %{conn: conn, project: project} do
    {:ok, chat} = Conversations.open(project, "about the parser")
    row = ~s(a[href="/chats/#{chat.id}"])

    {:ok, own_page, _html} = live(conn, ~p"/projects/#{project.name}")
    assert own_page |> element(row) |> render() =~ "about the parser"
    refute own_page |> element(row) |> render() =~ project.name

    {:ok, all_chats, _html} = live(conn, ~p"/chats")
    assert all_chats |> element(row) |> render() =~ project.name
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

  describe "ticket proposals" do
    setup %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job | _] = Forge.Jobs.for_ticket(ticket.id)

      version =
        Forge.ForgeFixtures.proposal_fixture(%{
          job: job,
          title: "Extract the score table",
          body: "The plan assumes a module that is not there."
        })

      %{ticket: ticket, version: version}
    end

    test "are listed with what they say and where they came from", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Extract the score table"
      assert html =~ "The plan assumes a module that is not there."
      assert html =~ "ticket #{ticket.number}"
      assert html =~ "Accept as a ticket"
      assert html =~ "Decline"
    end

    test "accepting one admits a ticket and stops listing it", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      # Dispatched rather than submitted through the form: the decision is carried by the
      # button's own value, which `form/3` cannot set. The markup that offers both buttons is
      # asserted in the test above.
      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "accepted"
        })

      assert html =~ "Admitted as ticket"
      refute html =~ "Accept as a ticket"

      assert Enum.any?(Tickets.list(project), &(&1.title == "Extract the score table"))
    end

    test "declining one records it and stops listing it", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "declined",
          "comment" => "out of scope"
        })

      assert html =~ "Declined."
      refute html =~ "Extract the score table"
      refute Enum.any?(Tickets.list(project), &(&1.title == "Extract the score table"))
    end

    # A page rendered minutes ago offers a button the context will refuse — the same trap
    # `conversations.md` names for a conversation that has stopped. The refusal has to be
    # legible rather than a crash or a silent no-op.
    test "deciding one that someone already decided says so", %{
      conn: conn,
      project: project,
      user: user,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      {:ok, _} = Forge.Proposals.decline(version.id, user.id, nil)

      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "accepted"
        })

      assert html =~ "already decided"
    end

    # Nothing else in the product admits a ticket the operator did not type, so the page has to
    # say that accepting is what starts work — otherwise it reads as filing, not as spending.
    test "says plainly that nothing runs until one is accepted", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Nothing runs until you accept one."
    end
  end
end
