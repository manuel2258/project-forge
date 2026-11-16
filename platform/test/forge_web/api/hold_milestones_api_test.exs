defmodule ForgeWeb.Api.HoldMilestonesApiTest do
  @moduledoc """
  The hold, titles and milestones over the JSON API (`docs/design/api-and-ui.md` § JSON API): the
  product surface, so what a person can do on a page is done here and the responses carry what the
  pages show. Start or hold is the caller's to say, a read token cannot write, a job's token is no
  token, and another project's milestone answers as one that does not exist.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Events, Projects, Repo, Tickets}
  alias Forge.Git.Tokens

  setup %{conn: conn} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    user = user_fixture()
    token = Accounts.create_api_token(user, "test")
    {:ok, project} = Projects.register(%{name: "hm-#{n()}", repo_path: seeded_repo()}, user)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      user: user,
      project: project
    }
  end

  defp n, do: System.unique_integer([:positive])
  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp admit(conn, project, params) do
    conn
    |> post(
      "/api/v1/projects/#{project.name}/tickets",
      Map.merge(%{"title" => "An idea"}, params)
    )
  end

  test "admitting needs start or hold said, and writes nothing without it", %{
    conn: conn,
    project: project
  } do
    assert %{"error" => %{"reason" => "start_or_hold"}} =
             admit(conn, project, %{}) |> json_response(422)

    assert %{"error" => %{"reason" => "start_or_hold"}} =
             admit(conn, project, %{"on_hold" => "maybe"}) |> json_response(422)

    assert Tickets.list(project) == []

    assert %{
             "on_hold" => true,
             "started" => false,
             "waiting_on_release" => %{"entry" => "refining"}
           } =
             admit(conn, project, %{"on_hold" => true}) |> json_response(201)

    assert %{"on_hold" => false} =
             admit(conn, project, %{"on_hold" => false}) |> json_response(201)
  end

  test "hold, release and stop, with the fields the page shows", %{conn: conn, project: project} do
    %{"number" => number} = admit(conn, project, %{"on_hold" => false}) |> json_response(201)
    url = "/api/v1/tickets/#{project.name}/#{number}"

    assert %{"on_hold" => true, "held_at" => held_at} =
             conn |> post(url <> "/hold") |> json_response(200)

    assert held_at

    assert %{"error" => %{"reason" => "already_on_hold"}} =
             conn |> post(url <> "/hold") |> json_response(409)

    assert %{"error" => %{"reason" => "nothing_running"}} =
             conn |> post(url <> "/stop") |> json_response(409)

    assert %{"ticket" => %{"on_hold" => true, "stoppable" => false}} =
             conn |> get(url) |> json_response(200)

    assert %{"on_hold" => false} = conn |> post(url <> "/release") |> json_response(200)

    assert %{"error" => %{"reason" => "not_on_hold"}} =
             conn |> post(url <> "/release") |> json_response(409)
  end

  test "a title, a milestone and an order", %{conn: conn, project: project} do
    %{"number" => one} = admit(conn, project, %{"on_hold" => true}) |> json_response(201)
    %{"number" => two} = admit(conn, project, %{"on_hold" => true}) |> json_response(201)

    assert %{"title" => "Better"} =
             conn
             |> post("/api/v1/tickets/#{project.name}/#{one}/title", %{"title" => " Better "})
             |> json_response(200)

    assert %{"milestone" => %{"id" => id, "name" => "0.4"}} =
             conn
             |> post("/api/v1/projects/#{project.name}/milestones", %{"name" => "0.4"})
             |> json_response(201)
             |> Map.fetch!("milestone")
             |> then(fn m ->
               conn
               |> post("/api/v1/tickets/#{project.name}/#{one}/milestone", %{
                 "milestone_id" => m["id"]
               })
               |> json_response(200)
             end)

    conn
    |> post("/api/v1/tickets/#{project.name}/#{two}/milestone", %{"milestone_id" => id})
    |> json_response(200)

    assert %{"milestones" => [%{"tickets" => [^one, ^two], "progress" => %{"on_hold" => 2}}]} =
             conn |> get("/api/v1/projects/#{project.name}/milestones") |> json_response(200)

    conn
    |> post("/api/v1/tickets/#{project.name}/#{two}/move", %{"to" => "top"})
    |> json_response(200)

    conn
    |> post("/api/v1/tickets/#{project.name}/#{one}/move", %{"before" => two})
    |> json_response(200)

    assert %{"milestones" => [%{"tickets" => [^one, ^two]}]} =
             conn |> get("/api/v1/projects/#{project.name}/milestones") |> json_response(200)

    assert %{"error" => %{"reason" => "bad_request"}} =
             conn
             |> post("/api/v1/tickets/#{project.name}/#{one}/move", %{})
             |> json_response(400)

    # `before` is a ticket number; anything else that is not text or a number is a bad request.
    for before <- [%{"a" => 1}, [1], true] do
      assert %{"error" => %{"reason" => "bad_request"}} =
               conn
               |> post("/api/v1/tickets/#{project.name}/#{one}/move", %{"before" => before})
               |> json_response(400)
    end
  end

  test "a milestone is made, described, marked, closed, reopened and ordered", %{
    conn: conn,
    project: project
  } do
    base = "/api/v1/projects/#{project.name}/milestones"
    %{"milestone" => %{"id" => a}} = conn |> post(base, %{"name" => "A"}) |> json_response(201)
    %{"milestone" => %{"id" => b}} = conn |> post(base, %{"name" => "B"}) |> json_response(201)

    assert %{"error" => %{"reason" => "invalid"}} =
             conn |> post(base, %{"name" => "A"}) |> json_response(422)

    assert %{"milestone" => %{"description" => "Why"}} =
             conn
             |> post(base <> "/#{a}", %{"name" => "A", "description" => "Why"})
             |> json_response(200)

    assert %{"milestone" => %{"current" => true}} =
             conn |> post(base <> "/#{a}/current") |> json_response(200)

    # Unmarking another milestone leaves the marked one; unmarking itself leaves none, which a
    # project may have.
    assert %{"milestone" => %{"current" => false}} =
             conn |> post(base <> "/#{b}/current", %{"current" => false}) |> json_response(200)

    assert Forge.Milestones.current(project.id).id == a

    assert %{"milestone" => %{"current" => false}} =
             conn |> post(base <> "/#{a}/current", %{"current" => false}) |> json_response(200)

    assert Forge.Milestones.current(project.id) == nil
    conn |> post(base <> "/#{a}/current") |> json_response(200)

    assert %{"milestone" => %{"closed_at" => closed}} =
             conn |> post(base <> "/#{a}/close") |> json_response(200)

    assert closed

    assert %{"error" => %{"reason" => "closed"}} =
             conn |> post(base <> "/#{a}/current") |> json_response(409)

    assert %{"milestone" => %{"closed_at" => nil}} =
             conn |> post(base <> "/#{a}/reopen") |> json_response(200)

    assert %{"milestone" => %{"position" => _}} =
             conn |> post(base <> "/#{b}/move", %{"to" => "top"}) |> json_response(200)

    assert %{"milestones" => [%{"name" => "B"}, %{"name" => "A"}]} =
             conn |> get(base) |> json_response(200)
  end

  test "another project's milestone and a stranger's project are not there", %{
    conn: conn,
    project: project
  } do
    other_owner = user_fixture()
    {:ok, other} = Projects.register(%{name: "oth-#{n()}", repo_path: seeded_repo()}, other_owner)
    {:ok, foreign} = Forge.Milestones.create(other, %{name: "Theirs"}, {:user, other_owner.id})

    base = "/api/v1/projects/#{project.name}/milestones"

    for path <- [
          "/#{foreign.id}",
          "/#{foreign.id}/current",
          "/#{foreign.id}/close",
          "/#{foreign.id}/reopen"
        ] do
      assert %{"error" => %{"reason" => "not_found"}} =
               conn |> post(base <> path) |> json_response(404)
    end

    # Unmarking writes nothing, so it must still look the milestone up: an id that is another
    # project's, or none at all, is not found and not a crash.
    for id <- [foreign.id, Ecto.UUID.generate(), "not-an-id"] do
      assert %{"error" => %{"reason" => "not_found"}} =
               conn
               |> post(base <> "/#{id}/current", %{"current" => false})
               |> json_response(404)
    end

    assert %{"error" => %{"reason" => "not_found"}} =
             conn |> get("/api/v1/projects/#{other.name}/milestones") |> json_response(404)

    %{"number" => number} = admit(conn, project, %{"on_hold" => true}) |> json_response(201)

    assert %{"error" => %{"reason" => "milestone"}} =
             conn
             |> post("/api/v1/tickets/#{project.name}/#{number}/milestone", %{
               "milestone_id" => foreign.id
             })
             |> json_response(422)

    assert %{"error" => %{"reason" => "milestone"}} =
             admit(conn, project, %{"on_hold" => true, "milestone_id" => foreign.id})
             |> json_response(422)

    assert Repo.get!(Forge.Milestones.Milestone, foreign.id).name == "Theirs"
  end

  test "a write token does it as the API, a read token is refused, a job's is no token", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "T"}, {:user, user.id})
    {:ok, write, _} = Tokens.issue(project, name: "bot", git: :none, api: :write)
    {:ok, read, _} = Tokens.issue(project, name: "ro", git: :none, api: :read)
    url = "/api/v1/tickets/#{project.name}/#{ticket.number}"

    assert %{"error" => %{"reason" => "forbidden"}} =
             conn |> as(read) |> post(url <> "/hold") |> json_response(403)

    assert %{"on_hold" => true} = conn |> as(write) |> post(url <> "/hold") |> json_response(200)

    assert %{actor: %{"kind" => "api", "name" => "bot"}} =
             ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.held"))

    job = Forge.ForgeFixtures.job_fixture(%{ticket: ticket, attempt: 2})
    {:ok, job_secret, _} = Tokens.issue(project, job_id: job.id)
    assert conn |> as(job_secret) |> post(url <> "/release") |> json_response(401)
    assert Tickets.get!(ticket.id).held_at
  end

  test "accepting a proposal says start or hold, and where it goes", %{
    conn: conn,
    project: project
  } do
    job =
      Forge.ForgeFixtures.job_fixture(%{
        ticket: Forge.ForgeFixtures.ticket_fixture(%{project: project})
      })

    version = Forge.ForgeFixtures.proposal_fixture(%{job: job, file: "a.md", title: "Accept me"})

    assert %{"error" => %{"reason" => "start_or_hold"}} =
             conn |> post("/api/v1/proposals/#{version.id}/accept") |> json_response(422)

    assert %{"on_hold" => true} =
             conn
             |> post("/api/v1/proposals/#{version.id}/accept", %{"on_hold" => true})
             |> json_response(200)
  end
end
