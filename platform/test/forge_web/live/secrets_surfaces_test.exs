defmodule ForgeWeb.SecretsSurfacesTest do
  @moduledoc """
  Where a secret shows up once jobs hold them (`docs/design/secrets.md` § Surfaces): picked when a
  conversation is opened; read backwards on its settings row — who receives it, the last run that
  held it, the live conversations holding it; on a job's page, by name and version; and on a
  conversation's page, with what it no longer holds.

  No test here refutes a value on a page: none of these pages loads one — `Forge.Secrets.Secret`
  keeps it out of every query — so such a refute could not fail.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Events, Jobs, Operator, Projects, Tickets}

  @workflow """
  version: 1
  initial: refining
  commands:
    publish:
      run: .forge/commands/publish.sh
      timeout: 10m
      secrets: [STRIPE_TEST_KEY]
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 20, cost: 0.50 }
      secrets: [STRIPE_TEST_KEY]
    done: {}
  transitions:
    - { from: refining, to: done }
  limits:
    ticket_cost: 5
  """

  @value "sk_test_51Hx-never-on-a-page"

  setup :register_and_log_in_user

  setup %{user: user} do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/publish.sh" => "#!/bin/sh\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "surf-#{System.unique_integer([:positive])}", repo_path: repo},
        user
      )

    {:ok, secret} = Operator.set_secret(project, user, "STRIPE_TEST_KEY", @value)
    {:ok, _} = Operator.set_secret(project, user, "UNNAMED_KEY", "sk_test_nobody-names-it")
    %{project: project, secret: secret}
  end

  describe "opening a conversation" do
    test "offers the project's secrets unticked, and holds the ones ticked", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert has_element?(view, ~s(#chat-secrets input[value="STRIPE_TEST_KEY"]))
      assert has_element?(view, ~s(#chat-secrets input[value="UNNAMED_KEY"]))
      refute html =~ ~s(checked)

      view
      |> form("#chat-form", chat: %{text: "hi", secrets: ["STRIPE_TEST_KEY"]})
      |> render_submit()

      [chat] = Conversations.list_for_project(project.id)
      assert chat.secret_names == ["STRIPE_TEST_KEY"]

      # Who picked which, for the record.
      [opened] = chat.id |> Events.for_job() |> Enum.filter(&(&1.type == "chat.opened"))
      assert opened.payload["secrets"] == ["STRIPE_TEST_KEY"]
      assert opened.actor == %{"kind" => "user", "id" => user.id}
    end

    test "with none ticked holds none", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")
      view |> form("#chat-form", chat: %{text: "hi"}) |> render_submit()

      [chat] = Conversations.list_for_project(project.id)
      assert chat.secret_names == []
    end

    # Deleted between drawing the page and submitting it: refused by name, never started without.
    test "a secret deleted since the page was drawn is refused by name", %{
      conn: conn,
      user: user,
      project: project,
      secret: secret
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")
      {:ok, _} = Operator.delete_secret(project, user, secret.id)

      html =
        view
        |> form("#chat-form", chat: %{text: "hi", secrets: ["STRIPE_TEST_KEY"]})
        |> render_submit()

      assert html =~ "no secret named STRIPE_TEST_KEY in this project any more"
      assert Conversations.list_for_project(project.id) == []

      # And the boxes are drawn again from what is set now, so it is not offered a second time.
      refute has_element?(view, ~s(#chat-secrets input[value="STRIPE_TEST_KEY"]))
      assert has_element?(view, ~s(#chat-secrets input[value="UNNAMED_KEY"]))
    end

    # A refusal for anything else keeps what was ticked, as it keeps what was typed.
    test "a form refused for another reason keeps its boxes as they were ticked", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      html =
        view
        |> form("#chat-form", chat: %{text: "hi", memory: "2 gigs", secrets: ["STRIPE_TEST_KEY"]})
        |> render_submit()

      assert html =~ "2 gigs"
      assert has_element?(view, ~s(#chat-secrets input[value="STRIPE_TEST_KEY"][checked]))
      refute has_element?(view, ~s(#chat-secrets input[value="UNNAMED_KEY"][checked]))
      assert Conversations.list_for_project(project.id) == []
    end

    # Opened from nowhere, the page asks which project; the boxes are that project's, and choosing
    # another draws its own.
    test "offers the chosen project's secrets, and another's when another is chosen", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other} =
        Projects.register(
          %{name: "other-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, _} = Operator.set_secret(other, user, "OTHER_KEY", "sk_test_the-other-one")
      {:ok, view, _html} = live(conn, ~p"/chats/new")

      view |> form("#chat-form", chat: %{project: project.name}) |> render_change()
      assert has_element?(view, ~s(#chat-secrets input[value="STRIPE_TEST_KEY"]))
      refute has_element?(view, ~s(#chat-secrets input[value="OTHER_KEY"]))

      view |> form("#chat-form", chat: %{project: other.name}) |> render_change()
      assert has_element?(view, ~s(#chat-secrets input[value="OTHER_KEY"]))
      refute has_element?(view, ~s(#chat-secrets input[value="STRIPE_TEST_KEY"]))
    end
  end

  describe "a settings row" do
    test "says who receives it, the run that last held it, and the conversations holding it", %{
      conn: conn,
      project: project,
      secret: secret
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Take payments"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _} =
        Events.append("job.secrets", :system, %{
          ticket_id: ticket.id,
          job_id: job.id,
          payload: %{
            "held" => [%{"secret_id" => secret.id, "name" => "STRIPE_TEST_KEY", "version" => 1}],
            "gone" => []
          }
        })

      {:ok, _chat} = Conversations.open(project, "hi", secrets: ["STRIPE_TEST_KEY"])

      # Another project's conversation holding a secret of the same name is another project's.
      their_admin = Forge.AccountsFixtures.user_fixture()

      {:ok, elsewhere} =
        Projects.register(
          %{name: "theirs-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          their_admin
        )

      {:ok, _} = Operator.set_secret(elsewhere, their_admin, "STRIPE_TEST_KEY", @value)
      {:ok, _} = Conversations.open(elsewhere, "theirs", secrets: ["STRIPE_TEST_KEY"])

      # A closed one holds nothing, so it is not counted.
      {:ok, closed} = Conversations.open(project, "bye", secrets: ["STRIPE_TEST_KEY"])

      Forge.Repo.update_all(
        from(j in Jobs.Job, where: j.id == ^closed.id),
        set: [status: :finished]
      )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

      row = view |> element("#secret-rows tr", "STRIPE_TEST_KEY") |> render()
      assert row =~ "command `publish`, state `refining`"
      assert row =~ "held by 1 live conversation"
      refute row =~ "live conversations"
      assert row =~ "last held"

      other = view |> element("#secret-rows tr", "UNNAMED_KEY") |> render()
      assert other =~ "no state or command names it"
      assert other =~ "no run has held it"
      refute other =~ "live conversation"
    end
  end

  describe "a settings row, before the workflow names anything" do
    # A project with no workflow yet names nothing, and says so; one whose workflow is refused
    # cannot say who receives what, and says that instead — not the same answer.
    test "says the default branch has no workflow, or that it is not valid", %{
      conn: conn,
      user: user
    } do
      for {files, text} <- [
            {%{".forge/workflow.yml" => nil}, "the default branch has no workflow yet"},
            {%{".forge/workflow.yml" => "version: 2\n"}, "workflow is not valid"},
            # Both forms at once is a layout nothing can be read from (`ticket-types.md`).
            {%{".forge/workflows/bug.yml" => "version: 1\n"}, "workflow is not valid"}
          ] do
        {:ok, project} =
          Projects.register(
            %{name: "row-#{System.unique_integer([:positive])}", repo_path: seeded_repo(files)},
            user
          )

        {:ok, _} = Operator.set_secret(project, user, "STRIPE_TEST_KEY", @value)
        {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

        assert view |> element("#secret-rows tr", "STRIPE_TEST_KEY") |> render() =~ text
      end
    end
  end

  describe "a settings row, in a project with ticket types" do
    # Every type's workflow is read, and says which type names it; one whose workflow is refused
    # names nothing that can be read, and the row says so rather than looking complete.
    test "names each type's states and commands, and the types it could not read", %{
      conn: conn,
      user: user
    } do
      repo =
        seeded_repo(%{
          ".forge/workflow.yml" => nil,
          ".forge/workflows/feature.yml" => @workflow,
          ".forge/workflows/bug.yml" => "version: 2\n",
          ".forge/commands/publish.sh" => "#!/bin/sh\n"
        })

      {:ok, project} =
        Projects.register(
          %{name: "typed-#{System.unique_integer([:positive])}", repo_path: repo},
          user
        )

      {:ok, _} = Operator.set_secret(project, user, "STRIPE_TEST_KEY", @value)
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}/settings")

      row = view |> element("#secret-rows tr", "STRIPE_TEST_KEY") |> render()
      assert row =~ "command `publish` of `feature`, state `refining` of `feature`"
      assert row =~ "not read: the workflow of `bug`, which is not valid"
    end
  end

  describe "a job's page" do
    test "names the secrets and versions each run held", %{
      conn: conn,
      project: project,
      secret: secret
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Take payments"}, :system)
      [job] = Jobs.for_ticket(ticket.id)

      for payload <- [
            %{
              "held" => [%{"secret_id" => secret.id, "name" => "STRIPE_TEST_KEY", "version" => 1}],
              "gone" => []
            },
            %{
              "held" => [
                %{"secret_id" => secret.id, "name" => "STRIPE_TEST_KEY", "version" => 2},
                %{"secret_id" => Ecto.UUID.generate(), "name" => "SENTRY_TOKEN", "version" => 1}
              ],
              "gone" => []
            }
          ] do
        {:ok, _} =
          Events.append("job.secrets", :system, %{
            ticket_id: ticket.id,
            job_id: job.id,
            payload: payload
          })
      end

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      lines = view |> element(".job-secrets") |> render()
      assert lines =~ "STRIPE_TEST_KEY v1"
      assert lines =~ "STRIPE_TEST_KEY v2, SENTRY_TOKEN v1"
    end
  end

  describe "a command's page" do
    # A command's run records what it held as an agent's does, and its page draws it the same way.
    test "names the secrets and versions its run held", %{conn: conn, project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Publish"}, :system)

      {:ok, command} =
        Forge.Jobs.Commands.insert(Forge.Repo, ticket, Tickets.workflow(ticket), %{
          command: "publish",
          args: [],
          at: ticket.base_commit,
          state: "refining",
          parent: nil,
          batch: "batch-1",
          concurrent: nil
        })

      {:ok, _} =
        Events.append("job.secrets", :system, %{
          ticket_id: ticket.id,
          job_id: command.id,
          payload: %{
            "held" => [
              %{"secret_id" => Ecto.UUID.generate(), "name" => "STRIPE_TEST_KEY", "version" => 3}
            ],
            "gone" => []
          }
        })

      {:ok, view, _html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{command.id}")

      assert view |> element(".job-secrets") |> render() =~ "STRIPE_TEST_KEY v3"
    end
  end

  describe "a conversation's page" do
    test "says what it holds, and what was deleted since it was opened", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, gone} = Operator.set_secret(project, user, "GONE_KEY", "sk_test_deleted-soon")
      {:ok, chat} = Conversations.open(project, "hi", secrets: ["STRIPE_TEST_KEY", "GONE_KEY"])
      {:ok, _} = Operator.delete_secret(project, user, gone.id)

      # Its first run held both; its latest, after the deletion, says what is gone.
      for gone <- [[], ["GONE_KEY"]] do
        {:ok, _} =
          Events.append("job.secrets", :system, %{
            job_id: chat.id,
            project_id: project.id,
            payload: %{"held" => [], "gone" => gone}
          })
      end

      # Something else happened since; the warning is the latest run's, not the latest event's.
      {:ok, _} =
        Events.append("chat.message", :system, %{
          job_id: chat.id,
          project_id: project.id,
          payload: %{"text" => "and then"}
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # What it holds now, and only that: the deleted one is not still listed as held.
      assert view |> element("#chat-secrets") |> render() =~ ~r/holds STRIPE_TEST_KEY\s*</

      assert view |> element(".chat-secret-gone") |> render() =~
               "GONE_KEY was deleted and this conversation no longer holds it"
    end

    test "one whose every secret is gone holds none, and says so", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, only} = Operator.set_secret(project, user, "ONLY_KEY", "sk_test_the-only-one")
      {:ok, chat} = Conversations.open(project, "hi", secrets: ["ONLY_KEY"])
      {:ok, _} = Operator.delete_secret(project, user, only.id)

      {:ok, _} =
        Events.append("job.secrets", :system, %{
          job_id: chat.id,
          project_id: project.id,
          payload: %{"held" => [], "gone" => ["ONLY_KEY"]}
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      refute has_element?(view, "#chat-secrets")
      assert has_element?(view, ".chat-secret-gone", "ONLY_KEY was deleted")
    end
  end
end
