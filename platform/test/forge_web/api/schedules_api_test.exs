defmodule ForgeWeb.Api.SchedulesApiTest do
  @moduledoc """
  Schedules over the JSON API (`docs/design/schedules.md` § The door): readable by a project's
  members and its project tokens with API read, switched by a project admin's own session or user
  token and by no project token whatever its access, and dismissed by any member or a token with
  write. Each refusal is checked to have changed nothing.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Projects, Schedules}
  alias Forge.Git.Tokens
  alias Forge.Schedules.Schedule

  @workflow Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  @schedules """
  schedules:
    - name: weekly-cleanup
      cron: "0 6 * * MON"
      title: Weekly cleanup
      body: Tidy up.
  """

  setup %{conn: conn} do
    admin = user_fixture()
    member = user_fixture()
    stranger = user_fixture()

    repo = seeded_repo(%{".forge/workflow.yml" => File.read!(@workflow) <> "\n" <> @schedules})

    {:ok, project} =
      Projects.register(
        %{name: "sapi-#{System.unique_integer([:positive])}", repo_path: repo},
        admin
      )

    join!(project, member, :member)

    %{
      conn: conn,
      admin: admin,
      member: member,
      stranger: stranger,
      project: project,
      admin_token: Accounts.create_api_token(admin, "admin"),
      member_token: Accounts.create_api_token(member, "member"),
      stranger_token: Accounts.create_api_token(stranger, "stranger")
    }
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)
  defp sched_path(project, tail), do: "/api/v1/projects/#{project.name}/schedules#{tail}"

  defp project_token!(project, api) do
    {:ok, secret, _row} = Tokens.issue(project, name: "ci", git: :reader, api: api)
    secret
  end

  defp row(project), do: Schedules.get(project, nil, "weekly-cleanup")

  defp alert!(project, admin) do
    {:ok, _} = Schedules.switch_on(project, admin, nil, "weekly-cleanup")
    row = row(project)
    now = DateTime.utc_now(:second)

    Forge.Repo.update_all(
      from(s in Schedule, where: s.id == ^row.id),
      set: [
        problem: "its workflow does not parse",
        problem_kind: :failed,
        problem_at: now,
        alerted_at: now
      ]
    )
  end

  describe "reading" do
    test "a member sees what the file declares and what is kept", ctx do
      %{conn: conn, project: project, admin: admin, member_token: token} = ctx
      {:ok, _} = Schedules.switch_on(project, admin, nil, "weekly-cleanup")

      assert %{"schedules" => [schedule]} =
               conn |> as(token) |> get(sched_path(project, "")) |> json_response(200)

      assert %{
               "name" => "weekly-cleanup",
               "type" => nil,
               "cron" => "0 6 * * MON",
               "title" => "Weekly cleanup",
               "body" => "Tidy up.",
               "on" => true,
               "enabled_by" => email,
               "next_at" => next_at,
               "problem" => nil,
               "alert_open" => false
             } = schedule

      assert email == admin.email
      assert is_binary(next_at)
    end

    test "with no workflow to read, what is on is still listed, by name, with why", ctx do
      %{conn: conn, project: project, admin: admin, member_token: token} = ctx
      {:ok, _} = Schedules.switch_on(project, admin, nil, "weekly-cleanup")
      commit_to_default(project, %{".forge/workflows/chore.yml" => File.read!(@workflow)})

      body = conn |> as(token) |> get(sched_path(project, "")) |> json_response(200)
      assert %{"schedules" => [schedule]} = body
      refute Map.has_key?(body, "error")

      assert %{"name" => "weekly-cleanup", "on" => true, "title" => nil} = schedule
      assert schedule["file_error"] =~ ".forge/workflow.yml"
    end

    test "an off schedule is listed off", ctx do
      %{conn: conn, project: project, member_token: token} = ctx

      assert %{"schedules" => [%{"on" => false, "enabled_by" => nil}]} =
               conn |> as(token) |> get(sched_path(project, "")) |> json_response(200)
    end

    test "a project token with read, and nobody else", ctx do
      %{conn: conn, project: project, stranger_token: stranger} = ctx

      assert %{"schedules" => [_]} =
               conn
               |> as(project_token!(project, :read))
               |> get(sched_path(project, ""))
               |> json_response(200)

      assert conn |> as(stranger) |> get(sched_path(project, "")) |> json_response(404)
      assert conn |> get(sched_path(project, "")) |> json_response(401)

      other_owner = user_fixture()

      {:ok, other} =
        Projects.register(
          %{name: "oth-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          other_owner
        )

      assert conn
             |> as(project_token!(other, :write))
             |> get(sched_path(project, ""))
             |> json_response(404)
    end
  end

  describe "switching on and off" do
    test "an admin's user token does both", ctx do
      %{conn: conn, project: project, admin_token: token, admin: admin} = ctx

      assert %{"schedule" => %{"on" => true, "enabled_by" => email}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup"})
               |> json_response(200)

      assert email == admin.email
      assert Schedule.on?(row(project))

      assert %{"schedule" => %{"on" => false}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/off"), %{"name" => "weekly-cleanup"})
               |> json_response(200)

      refute Schedule.on?(row(project))
    end

    test "a member's user token is refused, and nothing changes", ctx do
      %{conn: conn, project: project, member_token: token} = ctx

      assert %{"error" => %{"reason" => "forbidden"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup"})
               |> json_response(403)

      assert row(project) == nil
    end

    test "a member cannot switch an admin's schedule off", ctx do
      %{conn: conn, project: project, member_token: token, admin: admin} = ctx
      {:ok, _} = Schedules.switch_on(project, admin, nil, "weekly-cleanup")

      assert conn
             |> as(token)
             |> post(sched_path(project, "/off"), %{"name" => "weekly-cleanup"})
             |> json_response(403)

      assert Schedule.on?(row(project))
    end

    test "no project token, whatever its access, and nothing changes", ctx do
      %{conn: conn, project: project, admin: admin} = ctx
      {:ok, _} = Schedules.switch_on(project, admin, nil, "weekly-cleanup")

      for api <- [:read, :write], act <- ["on", "off"] do
        assert conn
               |> as(project_token!(project, api))
               |> post(sched_path(project, "/" <> act), %{"name" => "weekly-cleanup"})
               |> json_response(403)
      end

      assert Schedule.on?(row(project))
      assert row(project).enabled_by_id == admin.id
    end

    test "a stranger finds no project", ctx do
      %{conn: conn, project: project, stranger_token: token} = ctx

      assert conn
             |> as(token)
             |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup"})
             |> json_response(404)

      assert row(project) == nil
    end

    test "says why it was refused: gone, on already, off already, no name", ctx do
      %{conn: conn, project: project, admin_token: token} = ctx

      assert %{"error" => %{"reason" => "schedule_gone"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/on"), %{"name" => "nope"})
               |> json_response(409)

      assert %{"error" => %{"reason" => "already_off"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/off"), %{"name" => "weekly-cleanup"})
               |> json_response(409)

      conn
      |> as(token)
      |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup"})
      |> json_response(200)

      assert %{"error" => %{"reason" => "already_on"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup"})
               |> json_response(409)

      assert %{"error" => %{"reason" => "bad_request"}} =
               conn |> as(token) |> post(sched_path(project, "/on"), %{}) |> json_response(400)

      assert %{"error" => %{"reason" => "bad_request"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/on"), %{"name" => "weekly-cleanup", "type" => 5})
               |> json_response(400)
    end
  end

  describe "dismissing" do
    test "a member, a user token, and a project token with write may", ctx do
      %{conn: conn, project: project, admin: admin, member_token: member_token} = ctx

      for secret <- [member_token, project_token!(project, :write)] do
        alert!(project, admin)
        assert row(project).alerted_at

        assert %{
                 "schedule" => %{
                   "alert_open" => false,
                   "problem" => "its workflow does not parse"
                 }
               } =
                 conn
                 |> as(secret)
                 |> post(sched_path(project, "/dismiss"), %{"name" => "weekly-cleanup"})
                 |> json_response(200)

        assert row(project).alerted_at == nil
        Schedules.switch_off(project, admin, nil, "weekly-cleanup")
      end
    end

    test "is recorded with who, and a project token as the token", ctx do
      %{conn: conn, project: project, admin: admin} = ctx
      alert!(project, admin)

      conn
      |> as(project_token!(project, :write))
      |> post(sched_path(project, "/dismiss"), %{"name" => "weekly-cleanup"})
      |> json_response(200)

      assert [%{actor: %{"kind" => "api"}}] =
               Forge.Repo.all(from e in Forge.Events.Event, where: e.type == "schedule.dismissed")
    end

    test "a read token is refused, a stranger finds nothing, and the item stays", ctx do
      %{conn: conn, project: project, admin: admin, stranger_token: stranger} = ctx
      alert!(project, admin)

      assert conn
             |> as(project_token!(project, :read))
             |> post(sched_path(project, "/dismiss"), %{"name" => "weekly-cleanup"})
             |> json_response(403)

      assert conn
             |> as(stranger)
             |> post(sched_path(project, "/dismiss"), %{"name" => "weekly-cleanup"})
             |> json_response(404)

      assert row(project).alerted_at
    end

    test "a read token is refused before the project is looked up: another project's too", ctx do
      %{conn: conn, project: project} = ctx

      {:ok, other} =
        Projects.register(
          %{name: "oth-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user_fixture()
        )

      # With the plug it is 403 whichever project is named; without it, 404 for another's.
      assert conn
             |> as(project_token!(project, :read))
             |> post(sched_path(other, "/dismiss"), %{"name" => "weekly-cleanup"})
             |> json_response(403)
    end

    test "with nothing to dismiss, says so", ctx do
      %{conn: conn, project: project, member_token: token} = ctx

      assert %{"error" => %{"reason" => "no_alert"}} =
               conn
               |> as(token)
               |> post(sched_path(project, "/dismiss"), %{"name" => "weekly-cleanup"})
               |> json_response(409)
    end
  end

  describe "the queue" do
    test "carries the alert as an item with no ticket", ctx do
      %{conn: conn, project: project, admin: admin, member_token: token} = ctx
      alert!(project, admin)

      assert %{"items" => [item]} =
               conn |> as(token) |> get("/api/v1/queue") |> json_response(200)

      assert item["kind"] == "schedule"
      assert item["ticket"] == nil and item["project"] == project.name
      assert %{"name" => "weekly-cleanup", "problem_kind" => "failed"} = item["detail"]
    end
  end
end
