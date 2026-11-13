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
      # The URL may break after a `/` (`breakable/1`), so it is read as text.
      assert html |> LazyHTML.from_document() |> LazyHTML.text() =~ "/git/#{name}.git"
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

      # Under the field it belongs to (`11c`), not in a line of its own beneath the form.
      assert has_element?(view, "#project_name-error", "has already been taken")
      refute html =~ "is registered"
    end

    test "an invalid name is refused under the name, and the branch's under the branch", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      view
      |> form("#project-form", %{
        "project" => %{"name" => "Not A Name", "default_branch" => "-rf"}
      })
      |> render_submit()

      assert has_element?(view, "#project_name-error", "Not a valid name: lowercase letters")
      assert has_element?(view, "#project_default_branch-error", "valid git branch name")
      refute has_element?(view, "#project_name-error", "branch")
    end

    # The clone URL the name would make, as it is typed, from the function that makes the real
    # one — so a typo is seen before it becomes the repository's name.
    #
    # Drawn from the first render — with `<name>` standing in while the name is blank — so that it
    # never appears under the finger and pushes *Create it* down (ux/c.md C2).
    test "previews the clone URL the name will make", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      assert has_element?(
               view,
               ~s(#clone-preview[data-preview="blank"]),
               Forge.Git.Url.for(%Forge.Projects.Project{name: "<name>"})
             )

      view
      |> form("#project-form", %{"project" => %{"name" => "leader-1", "default_branch" => "main"}})
      |> render_change()

      assert has_element?(
               view,
               ~s(#clone-preview[data-preview="ok"]),
               Forge.Git.Url.for(%Forge.Projects.Project{name: "leader-1"})
             )

      view
      |> form("#project-form", %{"project" => %{"name" => "  ", "default_branch" => "main"}})
      |> render_change()

      assert has_element?(view, ~s(#clone-preview[data-preview="blank"]))
    end

    # A name the platform would refuse is refused as it is typed, by the same changeset, and the
    # preview stops presenting it as the address you will get.
    test "refuses a bad name as it is typed, and does not promise its address", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      view
      |> form("#project-form", %{
        "project" => %{"name" => "Bad Name!", "default_branch" => "main"}
      })
      |> render_change()

      assert has_element?(
               view,
               "#project_name-error",
               "Not a valid name: lowercase letters, digits, - or _, starting with a letter or digit."
             )

      assert has_element?(view, ~s(#clone-preview[data-preview="invalid"]), "Not a valid name")
      refute has_element?(view, "#clone-preview", "first administrator")

      # A blank field is not shouted at while it is typed.
      view
      |> form("#project-form", %{"project" => %{"name" => "", "default_branch" => ""}})
      |> render_change()

      refute has_element?(view, "#project_name-error")
      refute has_element?(view, "#project_default_branch-error")
    end

    # A project made here has no template, machine or credential yet, and the projects page says
    # it runs nothing; the next steps say so first, with where each is added, and the chat is no
    # longer the loud action, since it would sit there with nothing to run it (ux/c.md C3).
    test "says first that it has nowhere to run, and where to add it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")
      name = "bare-#{System.unique_integer([:positive])}"

      html =
        view
        |> form("#project-form", %{"project" => %{"name" => name, "default_branch" => "main"}})
        |> render_submit()

      assert has_element?(view, "#run-somewhere", "no template or machine, and no credential")
      assert has_element?(view, ~s(#run-somewhere a[href="/templates"]))
      assert has_element?(view, ~s(#run-somewhere a[href="/users/settings#credentials"]))
      assert has_element?(view, "#chat-needs", "once the project has somewhere to run")
      refute has_element?(view, "#set-up-in-chat.ui-btn--primary")

      run = :binary.match(html, ~s(id="run-somewhere")) |> elem(0)
      chat = :binary.match(html, ~s(id="set-up-in-chat")) |> elem(0)
      assert run < chat
    end

    # `11d`'s routes in their order, the old link to the board gone with it, and on a wide
    # screen the new project already in the table beside them (`11e`).
    test "ends on three routes, in order, beside a table that holds it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")
      name = "routes-#{System.unique_integer([:positive])}"

      html =
        view
        |> form("#project-form", %{"project" => %{"name" => name, "default_branch" => "main"}})
        |> render_submit()

      chat = :binary.match(html, ~s(href="/chats/new?project=#{name}")) |> elem(0)
      clone = :binary.match(html, ~s(id="clone-url")) |> elem(0)
      ticket = :binary.match(html, ~s(id="first-ticket")) |> elem(0)
      assert chat < clone and clone < ticket

      # Not a button to the ticket form, which can only say "not ready" until the workflow is
      # merged: a line saying where the first ticket goes, linking the project (ux/c.md C3).
      refute html =~ ~s(href="/tickets/new?project=#{name}")
      assert has_element?(view, ~s(#first-ticket a[href="/projects/#{name}"]))

      refute html =~ "/board"
      assert has_element?(view, "#top-bar a.ui-top-context[href='/projects/#{name}']")
      assert has_element?(view, "#projects-table a[href='/projects/#{name}']")
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

      # The state the first job will run in, its budget, and its job in small print, named before
      # anything is typed (`12e`), each once (ux/c.md C19).
      assert html =~ "First step"
      assert has_element?(view, "#first-step .ui-state", "refining")
      assert has_element?(view, "#first-step .ui-state-mark", "▸")
      assert has_element?(view, "#first-step .first-step-line", "20 turns")
      assert has_element?(view, "#first-step .first-step-job", "refine.md → refinement.md")
      refute has_element?(view, "#first-step .first-step-line", "refine.md")

      assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "admitted to ready-")

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

      # The attribute, not the string: a class list can say "disabled" however the control
      # behaved.
      assert has_element?(view, "#ticket-form button[type=submit][disabled]")

      # The way to fix it is a chat, as the created screen says — not the clone URL, which this
      # card used to offer while that screen said pushing to the default branch is not the way.
      assert has_element?(view, ~s(#not-ready a[href="/chats/new?project=#{project.name}"]))
      refute has_element?(view, "#not-ready", "clone URL")

      # Nobody types a ticket they cannot submit (ux/c.md C3).
      assert has_element?(view, "#ticket_title[disabled]")
      assert has_element?(view, "#ticket_body[disabled]")
    end

    test "a ready project's boxes are open to type in", %{conn: conn, user: user} do
      {:ok, project} =
        Projects.register(
          %{name: "open-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      assert has_element?(view, "#ticket_title")
      refute has_element?(view, "#ticket_title[disabled]")
      refute has_element?(view, "#ticket_body[disabled]")
      refute has_element?(view, "#not-ready")
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
        budget: { turns: 3, tokens: 20k }
      done_state: {}
    transitions:
      - { from: looping, to: looping, when: retry, max: 1 }
      - { from: looping, to: done_state, when: done }
    limits: { ticket_tokens: 100k }
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

  test "new project is the projects page's action, and new ticket belongs to a project", %{
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

    # A project is made from the projects page, its `+ New` the top bar's right end; the queue
    # offers no ticket.
    {:ok, projects, _html} = live(conn, ~p"/projects")
    assert has_element?(projects, ~s(#top-bar a.ui-top-context[href="/projects/new"]))

    {:ok, _queue, queue_html} = live(conn, ~p"/")
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
