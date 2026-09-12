defmodule ForgeWeb.ApiTest do
  @moduledoc "Drives the milestone 1 loop through the JSON API with a bearer token."

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Jobs, Projects, Tickets}

  setup %{conn: conn} do
    user = user_fixture()
    token = Accounts.create_api_token(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer " <> token)

    {:ok, project} =
      Projects.register(%{
        name: "api-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    %{conn: conn, user: user, project: project}
  end

  defp scenario(name, doc) do
    config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(config, :extra_env, [{"FAKE_SCENARIO", name}, {"FAKE_DOC", doc}])
    )
  end

  defp run_pending(ticket_id) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {:ok, job} = Jobs.run(job)
    job
  end

  test "rejects missing or bad tokens", %{conn: conn} do
    assert %{"error" => %{"reason" => "unauthorized"}} =
             conn
             |> delete_req_header("authorization")
             |> get(~p"/api/v1/me")
             |> json_response(401)

    assert conn
           |> put_req_header("authorization", "Bearer nope")
           |> get(~p"/api/v1/me")
           |> json_response(401)
  end

  test "identifies the user and lists projects", %{conn: conn, user: user, project: project} do
    assert %{"email" => email} = conn |> get(~p"/api/v1/me") |> json_response(200)
    assert email == user.email
    assert %{"projects" => projects} = conn |> get(~p"/api/v1/projects") |> json_response(200)
    assert project.name in Enum.map(projects, & &1["name"])
  end

  test "accepts the bearer scheme in any case", %{conn: conn, user: user} do
    token = Accounts.create_api_token(user, "lowercase")

    assert %{"email" => _} =
             conn
             |> put_req_header("authorization", "bearer " <> token)
             |> get(~p"/api/v1/me")
             |> json_response(200)
  end

  test "registers a project by name under the repos directory; a path is not accepted", %{
    conn: conn
  } do
    name = "new-#{System.unique_integer([:positive])}"

    assert %{"name" => ^name} =
             conn
             |> post(~p"/api/v1/projects", %{name: name, repo_path: "/etc"})
             |> json_response(201)

    project = Projects.by_name(name)
    assert Projects.repo_path(project) == Path.join(Projects.repos_dir(), name <> ".git")
    assert File.dir?(Projects.repo_path(project))

    assert %{"error" => %{"reason" => "invalid", "detail" => %{"name" => _}}} =
             conn |> post(~p"/api/v1/projects", %{name: "../escape"}) |> json_response(422)

    refute File.exists?(Path.join(Projects.repos_dir(), "../escape.git"))

    assert %{"error" => %{"reason" => "invalid", "detail" => %{"name" => _}}} =
             conn |> post(~p"/api/v1/projects", %{}) |> json_response(422)
  end

  test "unknown projects, tickets and bad versions are reported, not guessed", %{
    conn: conn,
    project: project
  } do
    assert %{"error" => %{"reason" => "not_found"}} =
             conn |> get(~p"/api/v1/tickets?project=nope") |> json_response(404)

    assert %{"error" => %{"reason" => "not_found"}} =
             conn |> get(~p"/api/v1/tickets/#{project.name}/1") |> json_response(404)

    assert %{"error" => %{"reason" => "not_found"}} =
             conn |> get(~p"/api/v1/tickets/#{project.name}/abc") |> json_response(404)

    {:ok, _ticket} = Tickets.admit(project, %{title: "t", body: "b"}, :system)

    assert %{"error" => %{"reason" => "bad_request"}} =
             conn
             |> get(~p"/api/v1/tickets/#{project.name}/1/artifacts/ticket?version=abc")
             |> json_response(400)

    assert %{"error" => %{"reason" => "not_found"}} =
             conn
             |> get(~p"/api/v1/tickets/#{project.name}/1/artifacts/ticket?version=9")
             |> json_response(404)
  end

  test "admits, shows, approves, answers, transitions and reads artifacts and events", %{
    conn: conn,
    project: project
  } do
    name = project.name

    assert %{"ref" => ref, "state" => "refined", "number" => 1} =
             conn
             |> post(~p"/api/v1/projects/#{name}/tickets", %{
               title: "Persist scores",
               body: "gone"
             })
             |> json_response(201)

    assert ref == "#{name}#1"
    ticket = Tickets.get_by_number!(project, 1)

    assert %{
             "ticket" => %{"state" => "refined"},
             "jobs" => [%{"state" => "refined", "status" => "pending"}],
             "artifacts" => [%{"name" => "ticket"}],
             "open_questions" => []
           } =
             conn |> get(~p"/api/v1/tickets/#{name}/1") |> json_response(200)

    assert %{"error" => %{"reason" => "not_found"}} =
             conn |> get(~p"/api/v1/tickets/#{name}/99") |> json_response(404)

    # nothing to approve yet
    assert %{"error" => %{"reason" => "nothing_pending"}} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/approve", %{}) |> json_response(409)

    scenario("success", "refinement.md")
    run_pending(ticket.id)

    assert %{"items" => [%{"kind" => "approval", "ticket" => ^ref}]} =
             conn |> get(~p"/api/v1/queue") |> json_response(200)

    assert %{"state" => "planned", "pending_transition" => nil} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/approve", %{comment: "ok"})
             |> json_response(200)

    scenario("blocking", "plan.md")
    run_pending(ticket.id)

    assert %{
             "open_questions" => [
               %{
                 "key" => "backend",
                 "blocking" => true,
                 "options" => ["a", "b"],
                 "artifact" => "plan.md"
               }
             ]
           } =
             conn |> get(~p"/api/v1/tickets/#{name}/1") |> json_response(200)

    assert %{"error" => %{"reason" => "job_live"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/transition", %{to: "implemented"})
             |> json_response(409)

    assert %{"error" => %{"reason" => "no_open_question"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "nope", choice: "a"})
             |> json_response(404)

    assert %{"state" => "planned"} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "backend", choice: "b"})
             |> json_response(200)

    assert [%{status: :pending}] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.state == "planned"))

    assert %{"artifact" => "answers.md", "content" => content, "version" => 1} =
             conn |> get(~p"/api/v1/tickets/#{name}/1/artifacts/answers.md") |> json_response(200)

    assert content =~ "A: b"

    assert %{"version" => 1, "content" => "---\noutcome: done\n---\n# Plan" <> _} =
             conn
             |> get(~p"/api/v1/tickets/#{name}/1/artifacts/plan.md?version=1")
             |> json_response(200)

    assert %{"version" => 2} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/artifacts/plan.md", %{
               content: "---\noutcome: done\n---\n# Better plan\n"
             })
             |> json_response(200)

    assert %{"error" => %{"reason" => "invalid_document"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/artifacts/plan.md", %{content: "---\nbroken"})
             |> json_response(422)

    assert %{"events" => events} =
             conn |> get(~p"/api/v1/tickets/#{name}/1/events") |> json_response(200)

    assert "question.answered" in Enum.map(events, & &1["type"])

    [job | _] = Jobs.for_ticket(ticket.id)

    assert %{"job" => %{"spec" => %{"state" => "refined"}}, "events" => job_events} =
             conn |> get(~p"/api/v1/tickets/#{name}/1/jobs/#{job.id}") |> json_response(200)

    assert Enum.any?(job_events, &(&1["type"] == "job.harness.started"))

    assert %{"tickets" => [%{"ref" => ^ref}]} =
             conn |> get(~p"/api/v1/tickets?project=#{name}") |> json_response(200)
  end
end
