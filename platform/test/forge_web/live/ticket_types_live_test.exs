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
      budget: { turns: 5, cost: 1.00 }
    review_ready: {}
  transitions:
    - { from: INITIAL, to: review_ready }
  limits: { ticket_cost: 5.00 }
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
      assert html =~ "starts in fixing"
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

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute has_element?(view, ~s(select[name="ticket[ticket_type]"]))
      assert has_element?(view, "#implied-type", "bug")
      assert html =~ "starts in fixing"

      view |> form("#ticket-form", %{"ticket" => %{"title" => "x"}}) |> render_submit()
      assert [%{ticket_type: "bug"}] = Tickets.list(project)
    end

    test "the single file asks nothing about types", %{conn: conn, register: register} do
      project = register.(%{})

      {:ok, view, html} = live(conn, ~p"/tickets/new?project=#{project.name}")

      refute has_element?(view, ~s(select[name="ticket[ticket_type]"]))
      refute html =~ "Type"
      assert html =~ "starts in refining"
    end
  end

  describe "the project page" do
    test "shows each type's workflow under its name", %{conn: conn, project: project} do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Workflows the next tickets will pin"
      assert has_element?(view, "#type-bug h3", "bug")
      assert has_element?(view, "#workflow-bug", "fixing")
      assert has_element?(view, "#workflow-feature", "building")
      refute has_element?(view, "#workflow-bug", "building")
      assert html =~ "Something new."
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

      html =
        view
        |> element("form[phx-submit=decide_proposal]")
        |> render_submit(%{"version_id" => version.id, "decision" => "accepted"})

      assert html =~
               "Not admitted: it has more than one ticket type, so one must be chosen: bug, feature."
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

  describe "the board" do
    alias ForgeWeb.Operator.Board

    test "draws a lane per type, each with its own workflow's columns", %{
      conn: conn,
      project: project
    } do
      {:ok, _bug} = Tickets.admit(project, %{title: "Lost slot", ticket_type: "bug"})
      {:ok, _feature} = Tickets.admit(project, %{title: "Co-op", ticket_type: "feature"})

      for path <- [~p"/projects/#{project.name}", ~p"/board"] do
        {:ok, view, _html} = live(conn, path)

        # `fixing` is bug's and `building` is feature's: each lane has its own, and neither has
        # the other's.
        bug_fixing = "#" <> Board.column_id(project.name, "bug", "fixing")
        feature_building = "#" <> Board.column_id(project.name, "feature", "building")

        assert has_element?(view, bug_fixing, "Lost slot")
        assert has_element?(view, feature_building, "Co-op")
        refute has_element?(view, "#" <> Board.column_id(project.name, "bug", "building"))
        refute has_element?(view, "#" <> Board.column_id(project.name, "feature", "fixing"))

        # `review_ready` is in both workflows, and is two columns.
        assert has_element?(view, "#" <> Board.column_id(project.name, "bug", "review_ready"))
        assert has_element?(view, "#" <> Board.column_id(project.name, "feature", "review_ready"))

        assert has_element?(view, "h3[data-lane]", "bug")
        assert has_element?(view, "h3[data-lane]", "feature")
      end
    end

    test "one lane draws no heading, and keeps the columns' old ids", %{
      conn: conn,
      register: register
    } do
      project = register.(%{})
      {:ok, _ticket} = Tickets.admit(project, %{title: "Persist scores"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(
               view,
               "#" <> Board.column_id(project.name, "refining"),
               "Persist scores"
             )

      refute has_element?(view, "h3[data-lane]")
    end

    test "tickets from the single file are a lane of their own once the project has types" do
      lanes =
        Board.lanes([
          ticket(nil, "refining"),
          ticket("bug", "fixing"),
          ticket("feature", "building")
        ])

      assert Enum.map(lanes, &{&1.ticket_type, &1.heading}) == [
               {nil, "workflow.yml"},
               {"bug", "bug"},
               {"feature", "feature"}
             ]

      assert [[%{name: "refining"}], [%{name: "fixing"}], [%{name: "building"}]] =
               Enum.map(lanes, & &1.columns)
    end

    # With several types and tickets of only one, the one lane still says whose columns they are.
    test "a type's lane is headed alone too; the single file's is not" do
      assert [%{heading: "bug"}] = Board.lanes([ticket("bug", "fixing")])
      assert [%{heading: nil}] = Board.lanes([ticket(nil, "refining")])
    end

    test "a type's lane is the type's column ids, not another lane's" do
      refute Board.column_id("p", "bug", "fixing") == Board.column_id("p", "feature", "fixing")
      refute Board.column_id("p", "bug", "fixing") == Board.column_id("p", "fixing")
      assert Board.column_id("p", nil, "fixing") == Board.column_id("p", "fixing")
    end

    defp ticket(type, state) do
      %Forge.Tickets.Ticket{ticket_type: type, state: state, workflow: %{}, status: :active}
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
