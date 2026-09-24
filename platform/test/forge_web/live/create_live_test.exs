defmodule ForgeWeb.CreateLiveTest do
  @moduledoc """
  Making a project and admitting a ticket from the product.

  The case worth testing is the one that used to be unreachable: a project the operator has just
  made is empty, so it has no workflow, so it cannot take a ticket. The product has to say that
  where the operator is standing rather than fail on submit — `docs/design/ui.md` § Creating
  things.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)
    :ok
  end

  describe "a project" do
    test "is registered, and then says what has to happen next", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      name = "made-#{System.unique_integer([:positive])}"

      html =
        view
        |> form("#project-form", %{"project" => %{"name" => name, "default_branch" => "main"}})
        |> render_submit()

      assert Projects.by_name(name)

      # Not a redirect to the board: the project has no workflow and the operator needs to be
      # told what to do about it.
      assert html =~ "is registered"
      assert html =~ ".forge/workflow.yml"

      # The primary action is a conversation: an empty project has no branch to merge and no
      # history to import, and telling anyone to "push a workflow" is what this page used to say
      # and nothing could carry out. The default-branch credential that now exists is for
      # importing a repository, which is not this.
      assert html =~ "/chats/new?project=#{name}"
      assert html =~ "Set it up in a chat"

      # The clone URL is still here, for working by hand, with the credential a click away.
      assert html =~ "/git/#{name}.git"
      assert html =~ ~s(data-target="clone-url")
      assert html =~ "/projects/#{name}/settings"
    end

    test "a duplicate name is refused in place", %{conn: conn, user: user} do
      {:ok, project} = Projects.register(%{name: "taken", repo_path: seeded_repo()}, user)

      {:ok, view, _html} = live(conn, ~p"/projects/new")

      html =
        view
        |> form("#project-form", %{
          "project" => %{"name" => project.name, "default_branch" => "main"}
        })
        |> render_submit()

      assert html =~ "has already been taken"
      refute html =~ "is registered"
    end
  end

  describe "a ticket" do
    test "reached from a project does not ask which project", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "fixed-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      # Stated, not asked — and the way back names where you came from.
      refute has_element?(view, "select[name='ticket[project]']")
      assert has_element?(view, "input[type=hidden][name='ticket[project]']")
      assert html =~ ~s(href="/projects/#{project.name}")
    end

    test "the bare route still offers the choice", %{conn: conn, user: user} do
      {:ok, _project} =
        Projects.register(
          %{
            name: "choice-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/new")

      assert has_element?(view, "select[name='ticket[project]']")
    end

    test "a project named in the address that does not exist falls back to the choice", %{
      conn: conn,
      user: user
    } do
      {:ok, _project} =
        Projects.register(
          %{
            name: "real-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=no-such-project")

      assert has_element?(view, "select[name='ticket[project]']")
    end

    test "is admitted and lands on its own page", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "ready-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      # The state the first job will run in, named before anything is typed.
      assert html =~ "starts in"

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#ticket-form", %{
                 "ticket" => %{
                   "project" => project.name,
                   "title" => "Persist scores",
                   "body" => "They vanish on restart."
                 }
               })
               |> render_submit()

      assert [ticket] = Tickets.list(project)
      assert ticket.title == "Persist scores"
      assert ticket.body == "They vanish on restart."
      assert to == "/tickets/#{project.name}/#{ticket.number}"
    end

    test "a project with no workflow says so before a title is typed", %{conn: conn, user: user} do
      # Exactly what `/projects/new` has just made: registered, and empty.
      {:ok, project} =
        Projects.register_named("empty-#{System.unique_integer([:positive])}", "main", user)

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      assert html =~ "Not ready for a ticket"
      # The sentence and not the filename. `ForgeWeb.Operator.Admission` has two clauses for a
      # project that cannot take a ticket and both name `.forge/workflow.yml`, so the filename
      # on its own holds whichever of them fired — and they say different things to do next.
      assert html =~ "there is no .forge/workflow.yml on its default branch"

      # The attribute, not the string: `disabled:opacity-40` is in the button's class list on
      # every render, so `html =~ "disabled"` would pass however the control behaved.
      assert has_element?(view, "#ticket-form button[type=submit][disabled]")
    end

    test "and is offered when the project is ready", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "offered-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute has_element?(view, "#ticket-form button[type=submit][disabled]")
      assert has_element?(view, "#ticket-form button[type=submit]")
    end

    test "a title is required", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "titled-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      html =
        view
        |> form("#ticket-form", %{
          "ticket" => %{"project" => project.name, "title" => "   ", "body" => ""}
        })
        |> render_submit()

      assert html =~ "a title is required"
      assert Tickets.list(project) == []
    end

    test "with no projects at all it points at making one", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/tickets/new")

      assert html =~ "no projects yet"
      assert html =~ "/projects/new"
    end
  end

  # A workflow with no `approve:` on any transition — the t1 fixture's shape, and any project
  # that does not gate on documents.
  defp no_approvals_workflow do
    """
    version: 1
    initial: looping
    states:
      looping:
        prompt: agents/loop.md
        inputs: [ticket]
        produces: [out.md]
        outcomes: [done, retry]
        budget: { turns: 3, cost: 0.10 }
      done_state: {}
    transitions:
      - { from: looping, to: looping, when: retry, max: 1 }
      - { from: looping, to: done_state, when: done }
    limits: { ticket_cost: 0.50 }
    """
  end

  describe "approval marks on the ticket page" do
    # The headline of the commit that introduced `Artifacts.approvable/1`. Testing the function
    # alone left the place it is *applied* uncovered, and reverting that one line passed the
    # whole suite — the bug was re-introducible with nothing noticing.
    test "a workflow that approves nothing marks nothing unapproved", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "noappr-#{System.unique_integer([:positive])}",
            repo_path:
              seeded_repo(%{
                ".forge/workflow.yml" => no_approvals_workflow(),
                ".forge/agents/loop.md" => "Do it.\n"
              })
          },
          user
        )

      {:ok, ticket} = Tickets.admit(project, %{title: "Nothing to approve"}, {:user, user.id})

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      # The ticket body is an artifact and has no approval row; before the fix it was marked.
      assert html =~ "ticket"
      refute html =~ "unapproved"
      refute html =~ "approved"
    end

    test "a workflow that does approve still marks it", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{
            name: "appr-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo()
          },
          user
        )

      {:ok, ticket} = Tickets.admit(project, %{title: "Something to approve"}, {:user, user.id})

      {:ok, _} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Refined\n"
        })

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      assert html =~ "unapproved"
    end
  end

  test "new project is a top-bar action, and new ticket belongs to a project", %{
    conn: conn,
    user: user
  } do
    {:ok, project} =
      Projects.register(
        %{
          name: "placed-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    {:ok, _ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    # The top bar carries New project on every page; the board and the queue carry neither.
    {:ok, board, board_html} = live(conn, ~p"/board")
    assert has_element?(board, ~s(header a[href="/projects/new"]))
    refute board_html =~ "New ticket"

    {:ok, queue, queue_html} = live(conn, ~p"/")
    assert has_element?(queue, ~s(header a[href="/projects/new"]))
    refute queue_html =~ "New ticket"

    # The project page is the one place a ticket is offered.
    {:ok, page, _html} = live(conn, ~p"/projects/#{project.name}")
    assert has_element?(page, ~s(a[href="/tickets/new?project=#{project.name}"]))
  end

  test "both pages require a logged-in operator" do
    conn = build_conn()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/projects/new")
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/tickets/new")
  end
end
