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

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    Process.put(:worker, Forge.FakeWorker.connect())

    %{conn: conn, user: user, project: project}
  end

  # The worker is a machine on the far end of a channel now, and in these tests it is this
  # process: it takes assignments out of its own mailbox and answers them. Its handle and the
  # scenario it is to play live in the process dictionary because they belong to this process
  # in exactly the same way. See Forge.FakeWorker.
  defp scenario(name, doc), do: Process.put(:scenario, {name, doc})

  defp run_pending(ticket_id) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {name, doc} = Process.get(:scenario, {"success", "plan.md"})
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), name, doc: doc)
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

  # The same admission call, one branch along: a repository that was pushed but carries no
  # `.forge/workflow.yml` is the client's next step, not a platform fault.
  test "admitting against a repository with no workflow file is a client error", %{conn: conn} do
    {:ok, %{name: name}} =
      Projects.register(%{
        name: "bare-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(%{".forge/workflow.yml" => nil})
      })

    response =
      conn
      |> post(~p"/api/v1/projects/#{name}/tickets", %{title: "No workflow here"})
      |> json_response(422)

    assert %{"error" => %{"reason" => "no_workflow_file"}} = response
    assert response["error"]["detail"] =~ ".forge/workflow.yml"
  end

  test "editing a document artifact without string content is a client error", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Edit me"}, {:user, user.id})

    for content <- [123, nil, [1, 2, 3]] do
      assert %{"error" => %{"reason" => "document_requires_content"}} =
               conn
               |> post(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/artifacts/notes.md", %{
                 content: content
               })
               |> json_response(422)
    end
  end

  # `repo_path` is derived from the name for API-created projects and is not a field of the
  # request, so an error must not name it.
  test "a project rejected for its name does not report derived fields", %{conn: conn} do
    response = conn |> post(~p"/api/v1/projects", %{}) |> json_response(422)

    assert %{"error" => %{"reason" => "invalid", "detail" => detail}} = response
    assert Map.has_key?(detail, "name")
    refute Map.has_key?(detail, "repo_path")
  end

  # A project registered but not yet pushed to is a client mistake, not a platform fault:
  # docs/design/api-and-ui.md lists 400/401/404/409/422 as the error statuses.
  test "admitting against a repository with no commits is a client error", %{conn: conn} do
    {:ok, %{name: name}} =
      Projects.register(%{
        name: "empty-#{System.unique_integer([:positive])}",
        repo_path: Path.join(tmp_dir("empty"), "project.git")
      })

    response =
      conn
      |> post(~p"/api/v1/projects/#{name}/tickets", %{title: "Nowhere to run"})
      |> json_response(422)

    # The detail names the ref that could not be resolved, rather than assuming which one it
    # was: `Git.resolve/2` is also called with a ticket's own branch.
    assert %{"error" => %{"reason" => "unknown_ref"}} = response
    assert response["error"]["detail"] =~ "main"
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

    # By state, not by position: `for_ticket/1` orders by `inserted_at`, which is
    # second-granular, so two jobs created in the same second tie and come back in
    # whichever order Postgres chose.
    job = Enum.find(Jobs.for_ticket(ticket.id), &(&1.state == "refined"))

    assert %{"job" => %{"spec" => %{"state" => "refined"}}, "events" => job_events} =
             conn |> get(~p"/api/v1/tickets/#{name}/1/jobs/#{job.id}") |> json_response(200)

    assert Enum.any?(job_events, &(&1["type"] == "job.harness.started"))

    assert %{"tickets" => [%{"ref" => ^ref}]} =
             conn |> get(~p"/api/v1/tickets?project=#{name}") |> json_response(200)
  end
end
