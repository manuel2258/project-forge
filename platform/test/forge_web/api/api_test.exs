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
      Projects.register(
        %{
          name: "api-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

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

  # Admitting is a member's work, not an admin's: `Operator.admit/3` asks `:use`. And the
  # admission is the member's in the log, which is what says who asked for the work. Both were
  # held only by tests whose caller owned the project.
  test "a plain member admits a ticket, and the log says it was them", %{
    conn: conn,
    project: project
  } do
    member = Forge.ForgeFixtures.member_fixture(project, :member)
    assert Projects.role(project, member) == :member
    token = Accounts.create_api_token(member, "member")

    conn =
      conn
      |> delete_req_header("authorization")
      |> put_req_header("authorization", "Bearer " <> token)

    assert %{"number" => number} =
             conn
             |> post(~p"/api/v1/projects/#{project.name}/tickets", %{title: "Persist scores"})
             |> json_response(201)

    ticket = Tickets.get_by_number!(project, number)

    assert [%{actor: %{"kind" => "user", "id" => actor}}] =
             ticket.id
             |> Forge.Events.for_ticket()
             |> Enum.filter(&(&1.type == "ticket.admitted"))

    assert actor == member.id
  end

  # The queue serves `retry` on a stuck item; the API is where a client acts on it. A transition
  # with nothing to approve is refused by name, as on the page.
  test "a stuck ticket's state is run again, and a transition with nothing to approve says so", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    name = project.name

    assert %{"error" => %{"reason" => "job_live"}} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/retry") |> json_response(409)

    scenario("invalid_document", "refinement.md")
    run_pending(ticket.id)

    assert %{"items" => [%{"kind" => "stuck", "detail" => %{"retry" => true}}]} =
             conn |> get(~p"/api/v1/queue") |> json_response(200)

    assert %{"error" => %{"reason" => "no_version"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/transition", %{to: "planning"})
             |> json_response(409)

    assert %{"state" => "refining", "status" => "active"} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/retry") |> json_response(200)

    assert [%{attempt: 2}] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
  end

  test "a ticket is cancelled and restored, and leaves the ticket list meanwhile", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, _ticket} = Tickets.admit(project, %{title: "Never mind"}, {:user, user.id})
    name = project.name

    assert %{"status" => "cancelled"} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/cancel") |> json_response(200)

    assert %{"tickets" => []} =
             conn |> get(~p"/api/v1/tickets?project=#{name}") |> json_response(200)

    assert %{"error" => %{"reason" => "not_cancellable"}} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/cancel") |> json_response(409)

    assert %{"error" => %{"reason" => "cancelled"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/transition", %{to: "planning"})
             |> json_response(409)

    assert %{"status" => "stuck"} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/restore") |> json_response(200)

    assert %{"error" => %{"reason" => "not_cancelled"}} =
             conn |> post(~p"/api/v1/tickets/#{name}/1/restore") |> json_response(409)
  end

  # A client that reads the queue decides what is waiting from the kind. A non-blocking question
  # served as a `question` would read as a halted job to every client that was not told otherwise.
  test "the queue serves a non-blocking question as an assumption", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    {:ok, _version} =
      Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: naming
        text: What is the table called?
        options: [{label: scores, detail: About scores}, {label: highscores, detail: About highscores}]
        blocking: false
        assumption: scores
        ```
        """
      })

    assert %{
             "items" => [
               %{
                 "kind" => "assumption",
                 "question" => %{"key" => "naming", "blocking" => false},
                 "detail" => %{"assumption" => "scores"}
               }
             ]
           } = conn |> get(~p"/api/v1/queue") |> json_response(200)
  end

  # A chat's questions are parsed from its reply, not stored, so they are the core's structs —
  # which the JSON encoder refuses, and the whole queue with them. They are served in the shape a
  # stored question is.
  test "a conversation asking questions is served with them", %{conn: conn, project: project} do
    {:ok, chat} = Forge.Conversations.open(project, "which?")

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{
          text:
            "```question\nkey: backend\ntext: Which backend?\noptions:\n" <>
              "  - {label: Postgres, detail: Where the data is., recommended: true}\n```\n"
        }
      })

    {:ok, _chat} =
      Forge.Conversations.record_turn(chat, %{
        "turn" => 1,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })

    assert %{
             "items" => [
               %{
                 "kind" => "chat",
                 "detail" => %{
                   "questions" => [
                     %{
                       "key" => "backend",
                       "text" => "Which backend?",
                       "options" => [
                         %{
                           "label" => "Postgres",
                           "detail" => "Where the data is.",
                           "recommended" => true
                         }
                       ]
                     }
                   ]
                 }
               }
             ]
           } = conn |> get(~p"/api/v1/queue") |> json_response(200)
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
  test "admitting against a repository with no workflow file is a client error", %{
    conn: conn,
    user: user
  } do
    {:ok, %{name: name}} =
      Projects.register(
        %{
          name: "bare-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => nil})
        },
        user
      )

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
  #
  # It used to fail as `unknown_ref` naming `main`, because a fresh repository's default branch
  # was unborn. Registering now puts an empty commit there — everything starts from that branch
  # and nothing outside the platform may write it — so the ref resolves and the operator is told
  # the thing that is actually wrong: there is no workflow. A git-level ref error was a true
  # statement about the wrong layer.
  test "admitting against a repository with no workflow is a client error", %{
    conn: conn,
    user: user
  } do
    {:ok, %{name: name}} =
      Projects.register(
        %{
          name: "empty-#{System.unique_integer([:positive])}",
          repo_path: Path.join(tmp_dir("empty"), "project.git")
        },
        user
      )

    response =
      conn
      |> post(~p"/api/v1/projects/#{name}/tickets", %{title: "Nowhere to run"})
      |> json_response(422)

    assert %{"error" => %{"reason" => "no_workflow_file"}} = response
    assert response["error"]["detail"] =~ ".forge/workflow.yml"
  end

  test "identifies the user and lists projects", %{conn: conn, user: user, project: project} do
    assert %{"email" => email} = conn |> get(~p"/api/v1/me") |> json_response(200)
    assert email == user.email
    assert %{"projects" => projects} = conn |> get(~p"/api/v1/projects") |> json_response(200)
    assert project.name in Enum.map(projects, & &1["name"])
    # The absolute host path of the repository is never handed to a client.
    refute Enum.any?(projects, &Map.has_key?(&1, "repo_path"))
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

  # **The API is the product and the UI is a client of it** (`docs/design/api-and-ui.md`), so a
  # fact only the LiveViews carry is a fact no other client can read. Which ceiling stopped a
  # `budget_exhausted` job is the whole point of recording it — "ran out of money" and "ran out
  # of turns" want different responses — and it shipped on three LiveView rows and nowhere here.
  test "a job says which ceiling stopped it", %{conn: conn, project: project} do
    name = project.name
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, project_owner(project).id})

    scenario("max_turns", "refinement.md")
    run_pending(ticket.id)

    assert %{"jobs" => [%{"outcome" => "budget_exhausted", "exhausted" => "turns"}]} =
             conn |> get(~p"/api/v1/tickets/#{name}/#{ticket.number}") |> json_response(200)

    # And nothing for a job no ceiling stopped, rather than a guess at one of the three.
    {:ok, other} = Tickets.admit(project, %{title: "y"}, {:user, project_owner(project).id})
    scenario("success", "refinement.md")
    run_pending(other.id)

    assert %{"jobs" => [%{"outcome" => "converged", "exhausted" => nil}]} =
             conn |> get(~p"/api/v1/tickets/#{name}/#{other.number}") |> json_response(200)
  end

  defp project_owner(project) do
    [%{user_id: user_id} | _rest] = Projects.members(project)
    Forge.Repo.get!(Forge.Accounts.User, user_id)
  end

  test "admits, shows, approves, answers, transitions and reads artifacts and events", %{
    conn: conn,
    project: project
  } do
    name = project.name

    assert %{"ref" => ref, "state" => "refining", "number" => 1} =
             conn
             |> post(~p"/api/v1/projects/#{name}/tickets", %{
               title: "Persist scores",
               body: "gone"
             })
             |> json_response(201)

    assert ref == "#{name}#1"
    ticket = Tickets.get_by_number!(project, 1)

    assert %{
             "ticket" => %{"state" => "refining"},
             "jobs" => [%{"state" => "refining", "status" => "pending"}],
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

    assert %{"state" => "planning", "pending_transition" => nil} =
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
                 "options" => [
                   %{"label" => "a", "detail" => "About a", "recommended" => true},
                   %{"label" => "b", "detail" => "About b", "recommended" => false}
                 ],
                 "artifact" => "plan.md"
               } = question
             ]
           } =
             conn |> get(~p"/api/v1/tickets/#{name}/1") |> json_response(200)

    # The recommendation is the option's flag; `default` went with the bare labels.
    refute Map.has_key?(question, "default")

    assert %{"error" => %{"reason" => "job_live"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/transition", %{to: "implementing"})
             |> json_response(409)

    assert %{"error" => %{"reason" => "no_open_question"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "nope", choice: "a"})
             |> json_response(404)

    # A choice is one of the question's labels, whichever surface sends it: the pages only offer
    # those, and a client can send anything.
    assert %{
             "error" => %{
               "reason" => "not_an_option",
               "detail" => ~s("c" is not an option of backend)
             }
           } =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "backend", choice: "c"})
             |> json_response(422)

    assert %{"error" => %{"reason" => "empty_answer"}} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "backend", text: "  "})
             |> json_response(422)

    # JSON can put an object where text is meant; `answers.md` is text, and it used to be a 500.
    assert %{"error" => %{"reason" => "invalid_answer"}} =
             conn
             |> put_req_header("content-type", "application/json")
             |> post(
               ~p"/api/v1/tickets/#{name}/1/answers",
               Jason.encode!(%{key: "backend", text: %{"no" => "text"}})
             )
             |> json_response(422)

    assert %{"state" => "planning"} =
             conn
             |> post(~p"/api/v1/tickets/#{name}/1/answers", %{key: "backend", choice: "b"})
             |> json_response(200)

    assert [%{status: :pending}] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.state == "planning"))

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
    job = Enum.find(Jobs.for_ticket(ticket.id), &(&1.state == "refining"))

    assert %{"job" => %{"spec" => %{"state" => "refining"}}, "events" => job_events} =
             conn |> get(~p"/api/v1/tickets/#{name}/1/jobs/#{job.id}") |> json_response(200)

    assert Enum.any?(job_events, &(&1["type"] == "job.harness.started"))

    assert %{"tickets" => [%{"ref" => ^ref}]} =
             conn |> get(~p"/api/v1/tickets?project=#{name}") |> json_response(200)
  end

  describe "ticket proposals" do
    setup %{project: project} do
      ticket = Forge.ForgeFixtures.ticket_fixture(%{project: project, number: 1})
      job = Forge.ForgeFixtures.job_fixture(%{ticket: ticket})
      version = Forge.ForgeFixtures.proposal_fixture(%{job: job})

      %{version: version, job: job}
    end

    test "lists what is open on a project", %{conn: conn, project: project, version: version} do
      id = version.id

      assert %{"proposals" => [proposal]} =
               conn |> get(~p"/api/v1/projects/#{project.name}/proposals") |> json_response(200)

      assert %{
               "version_id" => ^id,
               "title" => "Extract the score table",
               "readable" => true,
               "file" => "proposal-score-table.md"
             } = proposal
    end

    test "accepting one answers with the ticket it made", %{
      conn: conn,
      project: project,
      version: version
    } do
      assert %{"number" => number, "title" => "Extract the score table"} =
               conn
               |> post(~p"/api/v1/proposals/#{version.id}/accept", %{comment: "yes"})
               |> json_response(200)

      assert %{"ticket" => %{"number" => ^number, "title" => "Extract the score table"}} =
               conn |> get(~p"/api/v1/tickets/#{project.name}/#{number}") |> json_response(200)
    end

    test "declining one records it and stops listing it", %{
      conn: conn,
      project: project,
      version: version
    } do
      assert %{"decision" => "declined"} =
               conn
               |> post(~p"/api/v1/proposals/#{version.id}/decline", %{comment: "out of scope"})
               |> json_response(200)

      assert %{"proposals" => []} =
               conn |> get(~p"/api/v1/projects/#{project.name}/proposals") |> json_response(200)
    end

    # Deciding twice is a client mistake with an answer, not a platform fault. Answering it with
    # 500 is the shape of failure `docs/open-questions.md` § Message reliability records.
    test "deciding twice is a conflict, not a 500", %{conn: conn, version: version} do
      conn |> post(~p"/api/v1/proposals/#{version.id}/decline", %{}) |> json_response(200)

      assert %{"error" => %{"reason" => "already_decided"}} =
               conn |> post(~p"/api/v1/proposals/#{version.id}/accept", %{}) |> json_response(409)
    end

    test "accepting one a person edited into nonsense is answerable, not a 500", %{
      conn: conn,
      job: job
    } do
      version = Forge.ForgeFixtures.proposal_fixture(%{job: job, file: "b.md", content: "no h1"})

      assert %{"error" => %{"reason" => "invalid_proposal", "detail" => detail}} =
               conn
               |> post(~p"/api/v1/proposals/#{version.id}/accept", %{})
               |> json_response(422)

      assert detail =~ "level-one heading"
    end

    test "a proposal that is not there is a 404", %{conn: conn} do
      assert %{"error" => %{"reason" => "not_found"}} =
               conn
               |> post(~p"/api/v1/proposals/#{Ecto.UUID.generate()}/accept", %{})
               |> json_response(404)
    end
  end
end
