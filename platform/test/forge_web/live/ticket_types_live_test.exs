defmodule ForgeWeb.TicketTypesLiveTest do
  @moduledoc """
  Ticket types where the operator meets them: the ticket form asks which when there is a choice
  and preselects nothing, the project page shows each type's workflow, and the API takes the type
  beside the title (`docs/design/ticket-types.md` § Admission, § The project page).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Projects, Tickets}

  @workflow """
  version: 1
  description: DESCRIPTION
  initial: INITIAL
  states:
    INITIAL:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [changeset]
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: INITIAL, to: review_ready }
  limits: { ticket_tokens: 1M }
  """

  defp workflow(initial, description) do
    @workflow |> String.replace("INITIAL", initial) |> String.replace("DESCRIPTION", description)
  end

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    register = fn files ->
      {:ok, project} =
        Projects.register(
          %{name: "typed-#{System.unique_integer([:positive])}", repo_path: seeded_repo(files)},
          user
        )

      project
    end

    typed =
      register.(%{
        ".forge/workflow.yml" => nil,
        ".forge/workflows/bug.yml" => workflow("fixing", "Something that worked and does not."),
        ".forge/workflows/feature.yml" => workflow("building", "Something new.")
      })

    %{register: register, project: typed}
  end

  describe "the ticket form" do
    test "asks which type, preselects nothing, and will not admit until one is chosen", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      assert html =~ "Choose a type"
      assert has_element?(view, ~s(select[name="ticket[ticket_type]"] option[value="bug"]))
      refute has_element?(view, ~s(select[name="ticket[ticket_type]"] option[selected]))
      assert has_element?(view, ~s(#ticket-form button[type="submit"][disabled]))
      # Nothing chosen is not a fault in the project, and draws no warning.
      refute html =~ "Not ready for a ticket"

      html =
        view
        |> form("#ticket-form", %{"ticket" => %{"ticket_type" => "bug", "title" => "Lost slot"}})
        |> render_change()

      assert html =~ "Something that worked and does not."
      # Said under the select that chose it, as its hint, not above the first step (ux/c.md C19).
      assert has_element?(view, "#ticket_ticket_type-hint", "Something that worked and does not.")
      refute has_element?(view, "#first-step", "Something that worked")
      assert has_element?(view, "#first-step .ui-state", "fixing")
      refute has_element?(view, ~s(#ticket-form button[type="submit"][disabled]))

      view
      |> form("#ticket-form", %{"ticket" => %{"ticket_type" => "bug", "title" => "Lost slot"}})
      |> render_submit()

      assert [%{title: "Lost slot", ticket_type: "bug", state: "fixing"}] = Tickets.list(project)
    end

    test "a broken type is offered as broken, and says why when chosen", %{
      conn: conn,
      register: register
    } do
      project =
        register.(%{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/bug.yml" => workflow("fixing", "Bugs."),
          ".forge/workflows/spike.yml" => "version: 1\n"
        })

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")
      assert html =~ "spike — does not parse"

      html =
        view
        |> form("#ticket-form", %{"ticket" => %{"ticket_type" => "spike"}})
        |> render_change()

      assert html =~ "This type cannot take a ticket: its workflow does not parse"
      assert has_element?(view, ~s(#ticket-form button[type="submit"][disabled]))
    end

    test "one type is said, not asked", %{conn: conn, register: register} do
      project =
        register.(%{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/bug.yml" => workflow("fixing", "Bugs.")
        })

      {:ok, view, _html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute has_element?(view, ~s(select[name="ticket[ticket_type]"]))
      assert has_element?(view, "#implied-type", "bug")
      assert has_element?(view, "#type-description", "Bugs.")
      refute has_element?(view, "#first-step", "Bugs.")
      assert has_element?(view, "#first-step .ui-state", "fixing")

      view |> form("#ticket-form", %{"ticket" => %{"title" => "x"}}) |> render_submit()
      assert [%{ticket_type: "bug"}] = Tickets.list(project)
    end

    test "the single file asks nothing about types", %{conn: conn, register: register} do
      project = register.(%{})

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute has_element?(view, ~s(select[name="ticket[ticket_type]"]))
      refute html =~ "Type"
      assert has_element?(view, "#first-step .ui-state", "refining")
    end
  end

  describe "the project page" do
    test "shows each type's workflow under its name", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "How a new ticket moves"
      assert has_element?(view, "#type-bug h3", "bug")
      assert has_element?(view, "#workflow-bug", "fixing")
      assert has_element?(view, "#workflow-feature", "building")
      refute has_element?(view, "#workflow-bug", "building")
      assert html =~ "Something new."
    end

    test "shows the type with the most open tickets first, each type's count in the switch", %{
      conn: conn,
      project: project
    } do
      # With nothing open, the first type is shown, as before.
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      refute has_element?(view, "#type-bug[hidden]")
      assert has_element?(view, "#type-feature[hidden]")

      for title <- ["One", "Two"] do
        {:ok, _} = Tickets.admit(project, %{title: title, ticket_type: "feature"}, :system)
      end

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      refute has_element?(view, "#type-feature[hidden]")
      assert has_element?(view, "#type-bug[hidden]")

      assert view |> element(~s(#workflow-types button[value="feature"] .ui-count)) |> render() =~
               ">2<"

      # What the person picks still wins.
      view |> element(~s(#workflow-types button[value="bug"])) |> render_click()
      refute has_element?(view, "#type-bug[hidden]")
    end

    test "says what is in the directory and is not a type, and a broken type's reason", %{
      conn: conn,
      register: register
    } do
      project =
        register.(%{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/bug.yml" => workflow("fixing", "Bugs."),
          ".forge/workflows/spike.yml" => "version: 1\n",
          ".forge/workflows/notes.md" => "x"
        })

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#not-types", ".forge/workflows/notes.md")
      assert has_element?(view, "#type-spike", "This type cannot take a ticket")
      assert has_element?(view, "#workflow-bug")
      refute html =~ "This project cannot take a ticket"
    end

    test "both forms at once is the project's fault, said once", %{
      conn: conn,
      register: register
    } do
      project = register.(%{".forge/workflows/bug.yml" => workflow("fixing", "Bugs.")})

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~
               "This project cannot take a ticket: it has both .forge/workflow.yml and " <>
                 ".forge/workflows/, and nothing says which a ticket runs."
    end
  end

  describe "accepting a proposal on the project page" do
    defp propose(project, front_matter) do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})

      proposal_fixture(%{
        job: job,
        content: front_matter <> "# Lost slot\n\nSaving twice loses it."
      })
    end

    test "offers the types, the suggestion chosen, and admits as the type chosen", %{
      conn: conn,
      project: project
    } do
      version = propose(project, "---\ntype: bug\n---\n")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "suggests bug"
      assert has_element?(view, ~s(select[name="ticket_type"] option[value="bug"][selected]))
      refute has_element?(view, ~s(#proposal-reader button[value="accepted"][disabled]))
      refute has_element?(view, ~s(select[name="ticket_type"] option[value="feature"][selected]))

      view
      |> element("form[phx-submit=decide_proposal]")
      |> render_submit(%{
        "version_id" => version.id,
        "decision" => "accepted",
        "ticket_type" => "feature"
      })

      assert [%{ticket_type: "feature", title: "Lost slot"}] =
               Enum.filter(Tickets.list(project), &(&1.title == "Lost slot"))
    end

    test "a suggestion that is not a type here is said, and nothing is chosen for it", %{
      conn: conn,
      project: project
    } do
      version = propose(project, "---\ntype: chore\n---\n")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "suggests chore, which is not a type here"
      refute has_element?(view, ~s(select[name="ticket_type"] option[selected]))

      # The server refuses an Admit with no type whatever the page drew.
      html =
        view
        |> element("form[phx-submit=decide_proposal]")
        |> render_submit(%{"version_id" => version.id, "decision" => "accepted"})

      assert html =~
               "Not admitted: it has more than one ticket type, so one must be chosen: bug, feature."

      # Admit waits for a type, and says so; choosing one lets it go.
      assert has_element?(view, ~s(#proposal-reader button[value="accepted"][disabled]))
      assert has_element?(view, "#proposal-admit-why", "Choose a type")

      view
      |> element("form[phx-submit=decide_proposal]")
      |> render_change(%{"draft" => "propose-#{version.id}", "ticket_type" => "bug"})

      refute has_element?(view, ~s(#proposal-reader button[value="accepted"][disabled]))
      refute has_element?(view, "#proposal-admit-why")
    end

    test "a type that does not parse is marked, and choosing it says why", %{
      conn: conn,
      register: register
    } do
      project =
        register.(%{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/bug.yml" => workflow("fixing", "Bugs."),
          ".forge/workflows/spike.yml" => "version: 1\n"
        })

      version = propose(project, "---\ntype: spike\n---\n")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(
               view,
               ~s(select[name="ticket_type"] option[value="spike"]),
               "does not parse"
             )

      html =
        view
        |> element("form[phx-submit=decide_proposal]")
        |> render_submit(%{
          "version_id" => version.id,
          "decision" => "accepted",
          "ticket_type" => "spike"
        })

      assert html =~ "Not admitted: its workflow does not parse:"
    end

    test "a proposal that cannot be read offers no type, only Decline", %{
      conn: conn,
      project: project
    } do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      proposal_fixture(%{job: job, content: "no heading here"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      refute has_element?(view, ~s(select[name="ticket_type"]))
    end

    test "with one type or none there is nothing to choose", %{conn: conn, register: register} do
      project = register.(%{})
      propose(project, "---\ntype: bug\n---\n")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")
      refute has_element?(view, ~s(select[name="ticket_type"]))
      # A project without types mentions none, the agent's suggestion included.
      refute html =~ "suggests bug"
    end
  end

  describe "the API" do
    setup %{user: user} do
      %{token: Forge.Accounts.create_api_token(user, "test")}
    end

    test "takes the type beside the title, and says what is wrong without one", %{
      conn: conn,
      project: project,
      token: token
    } do
      conn = put_req_header(conn, "authorization", "Bearer " <> token)

      assert %{"ticket_type" => "feature", "state" => "building"} =
               conn
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{
                 title: "Co-op",
                 ticket_type: "feature"
               })
               |> json_response(201)

      assert %{"error" => %{"reason" => "ticket_type_required", "detail" => detail}} =
               conn
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: "Co-op"})
               |> json_response(422)

      assert detail ==
               "it has more than one ticket type, so one must be chosen: bug, feature"

      version = propose(project, "---\ntype: bug\n---\n")

      assert %{"ticket_type" => "bug"} =
               conn
               |> post(~p"/api/v1/proposals/#{version.id}/accept", %{})
               |> json_response(200)

      assert %{"proposals" => []} =
               conn |> get(~p"/api/v1/projects/#{project.name}/proposals") |> json_response(200)

      other = propose(project, "---\ntype: bug\n---\n")

      assert [%{"suggested_type" => "bug"}] =
               conn
               |> get(~p"/api/v1/projects/#{project.name}/proposals")
               |> json_response(200)
               |> Map.fetch!("proposals")

      assert %{"ticket_type" => "feature"} =
               conn
               |> post(~p"/api/v1/proposals/#{other.id}/accept", %{ticket_type: "feature"})
               |> json_response(200)

      assert %{"error" => %{"reason" => "invalid_ticket_type"}} =
               conn
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{
                 title: "x",
                 ticket_type: %{a: 1}
               })
               |> json_response(422)

      assert %{"error" => %{"reason" => "unknown_ticket_type", "detail" => detail}} =
               conn
               |> post(~p"/api/v1/projects/#{project.name}/tickets", %{
                 title: "x",
                 ticket_type: "chore"
               })
               |> json_response(422)

      assert detail == "it has no ticket type chore; it has bug, feature"
    end

    test "says a single file has no types, and a project with both forms has none to admit", %{
      conn: conn,
      token: token,
      register: register
    } do
      conn = put_req_header(conn, "authorization", "Bearer " <> token)
      single = register.(%{})

      assert %{"error" => %{"reason" => "no_ticket_types", "detail" => detail}} =
               conn
               |> post(~p"/api/v1/projects/#{single.name}/tickets", %{
                 title: "x",
                 ticket_type: "bug"
               })
               |> json_response(422)

      assert detail == "it has no ticket types, only one workflow, so it has no type bug"

      both = register.(%{".forge/workflows/bug.yml" => workflow("fixing", "Bugs.")})

      assert %{"error" => %{"reason" => "both_workflow_forms"}} =
               conn
               |> post(~p"/api/v1/projects/#{both.name}/tickets", %{title: "x"})
               |> json_response(422)
    end
  end

  describe "the tickets and the map" do
    # The board drew a lane per type; its successor draws each ticket on its own type's workflow:
    # the row's track from the workflow the ticket pinned, and each type's map with its own
    # tickets as dots and nobody else's.
    test "each type's map draws its own states and its own tickets", %{
      conn: conn,
      project: project
    } do
      {:ok, bug} = Tickets.admit(project, %{title: "Lost slot", ticket_type: "bug"})
      {:ok, feature} = Tickets.admit(project, %{title: "Co-op", ticket_type: "feature"})
      # `review_ready` is a state of both types: a feature ticket in it is on feature's map only.
      Forge.Repo.update!(Ecto.Changeset.change(feature, state: "review_ready"))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#tickets-rest-#{bug.number}", "fixing")
      assert has_element?(view, "#map-bug", "fixing")
      refute has_element?(view, "#map-bug", "building")
      assert has_element?(view, "#map-feature", "building")
      assert has_element?(view, "#map-bug", "review_ready")

      # One ticket of each type, so one dot on each map: a map counting every type's tickets
      # would draw two.
      bug_map = view |> element("#map-bug") |> render()
      assert length(Regex.scan(~r/wf-map-dot /, bug_map)) == 1
    end

    test "the switch shows the chosen type's workflow and hides the others", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#type-bug:not([hidden])")
      assert has_element?(view, "#type-feature[hidden]")

      view |> element(~s(#workflow-types button[value="feature"])) |> render_click()

      assert has_element?(view, "#type-feature:not([hidden])")
      assert has_element?(view, "#type-bug[hidden]")
    end
  end

  describe "the ticket page" do
    test "names the ticket's type beside its state, and nothing on the single file", %{
      conn: conn,
      project: project,
      register: register
    } do
      {:ok, bug} = Tickets.admit(project, %{title: "Lost slot", ticket_type: "bug"})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{bug.number}")
      assert has_element?(view, "#ticket-type", "bug")

      single = register.(%{})
      {:ok, ticket} = Tickets.admit(single, %{title: "x"})
      {:ok, view, _html} = live(conn, ~p"/tickets/#{single.name}/#{ticket.number}")
      refute has_element?(view, "#ticket-type")
    end
  end

  # A re-pin that cannot be made says why, in the ticket's own words: the file is gone, the project
  # has both forms, or the workflow it would pin does not parse. Each fell to "something went
  # wrong" once.
  describe "re-pinning from the ticket page" do
    defp stuck_bug(project) do
      Forge.ForgeFixtures.funded!(project)
      store = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

      {:ok, ticket} = Tickets.admit(project, %{title: "Lost slot", ticket_type: "bug"})
      [job] = Forge.Jobs.for_ticket(ticket.id)
      {:ok, _job} = Forge.FakeWorker.run(job, Forge.FakeWorker.connect())
      assert %{status: :stuck} = Tickets.get!(ticket.id)
      ticket
    end

    defp repin(conn, project, ticket) do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      view |> element("#repin-ticket") |> render_click()
    end

    test "a type whose file is gone", %{conn: conn, project: project} do
      ticket = stuck_bug(project)
      commit_to_default(project, %{".forge/workflows/bug.yml" => nil})

      assert repin(conn, project, ticket) =~
               ".forge/workflows/bug.yml is not on the default branch any more"
    end

    test "both forms at once", %{conn: conn, project: project} do
      ticket = stuck_bug(project)
      commit_to_default(project, %{".forge/workflow.yml" => workflow("refining", "Old.")})

      assert repin(conn, project, ticket) =~
               "it has both .forge/workflow.yml and .forge/workflows/"
    end

    test "a workflow that does not parse", %{conn: conn, project: project} do
      ticket = stuck_bug(project)
      commit_to_default(project, %{".forge/workflows/bug.yml" => "version: 1\n"})

      assert repin(conn, project, ticket) =~ "the default branch&#39;s workflow does not parse"
    end
  end
end
