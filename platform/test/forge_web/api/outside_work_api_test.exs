defmodule ForgeWeb.Api.OutsideWorkApiTest do
  @moduledoc """
  Outside work over the JSON API (`docs/design/outside-work.md`): opening a ticket already taken
  over, from a commit the repository holds; taking over and handing back; keeping the work of a
  job whose branch moved. A read token cannot write, a job's token is no token, another project's
  ticket answers as one that is not there, and every act says through which door it came.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Events, Git, Projects, Repo, Tickets}
  alias Forge.Git.Tokens
  alias Forge.Tickets.Takeover

  setup %{conn: conn} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    user = user_fixture()
    token = Accounts.create_api_token(user, "test")
    {:ok, project} = Projects.register(%{name: "ow-#{n()}", repo_path: seeded_repo()}, user)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      user: user,
      project: project
    }
  end

  defp n, do: System.unique_integer([:positive])
  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp admit(conn, project, params) do
    post(
      conn,
      "/api/v1/projects/#{project.name}/tickets",
      Map.merge(%{"title" => "An idea"}, params)
    )
  end

  defp ticket_path(project, number), do: "/api/v1/tickets/#{project.name}/#{number}"

  defp token!(project, api) do
    {:ok, secret, token} = Tokens.issue(project, name: "bot-#{n()}", git: :reader, api: api)
    {secret, token}
  end

  describe "opening as outside work (criteria 13, 14, 35)" do
    test "is admitted taken over by whoever opened it, running nothing", %{
      conn: conn,
      project: project,
      user: user
    } do
      assert %{
               "number" => number,
               "on_hold" => true,
               "started" => true,
               "taken_over" => %{"by" => %{"kind" => "user", "id" => id}, "via" => "api"}
             } = admit(conn, project, %{"outside_work" => true}) |> json_response(201)

      assert id == user.id
      ticket = Tickets.get_by_number!(project, number)
      assert Tickets.started?(ticket)
      assert Forge.Jobs.pending() |> Enum.filter(&(&1.ticket_id == ticket.id)) == []

      types = events(ticket)
      assert "ticket.admitted" in types
      assert "ticket.taken_over" in types
    end

    test "a token opens it as the holder", %{conn: conn, project: project} do
      {secret, token} = token!(project, :write)

      assert %{"taken_over" => %{"by" => %{"kind" => "api", "id" => id, "name" => name}}} =
               conn
               |> as(secret)
               |> admit(project, %{"outside_work" => true})
               |> json_response(201)

      assert id == token.id
      assert name == token.name
    end

    test "says what cannot go together, and writes nothing", %{conn: conn, project: project} do
      assert %{"error" => %{"reason" => "outside_work_starts"}} =
               admit(conn, project, %{"outside_work" => true, "on_hold" => false})
               |> json_response(422)

      assert %{"error" => %{"reason" => "start_commit_without_outside_work"}} =
               admit(conn, project, %{
                 "on_hold" => true,
                 "start_commit" => String.duplicate("a", 40)
               })
               |> json_response(422)

      assert Tickets.list(project) == []
    end

    test "a start commit is a full commit id the repository holds, and nothing else", %{
      conn: conn,
      project: project
    } do
      repo = Projects.repo_path(project)
      {:ok, head} = Git.resolve(repo, "refs/heads/" <> project.default_branch)

      for bad <- [
            project.default_branch,
            "refs/heads/" <> project.default_branch,
            String.slice(head, 0, 12),
            String.upcase(head),
            "--upload-pack=x",
            "-" <> String.slice(head, 1, 39),
            String.duplicate("0", 40),
            head <> "0"
          ] do
        assert %{"error" => %{"reason" => "bad_start_commit"}} =
                 admit(conn, project, %{"outside_work" => true, "start_commit" => bad})
                 |> json_response(422),
               "#{inspect(bad)} was accepted"
      end

      assert Tickets.list(project) == []
      assert {:ok, ^head} = Git.resolve(repo, "refs/heads/" <> project.default_branch)
    end

    test "starts from a commit on another ticket's unmerged branch, measured from where it meets the default branch",
         %{conn: conn, project: project} do
      repo = Projects.repo_path(project)
      {:ok, default} = Git.resolve(repo, "refs/heads/" <> project.default_branch)

      %{"number" => first} = admit(conn, project, %{"on_hold" => false}) |> json_response(201)
      first_ticket = Tickets.get_by_number!(project, first)
      under = commit_file_on_branch(project, first_ticket.branch, "under.txt", "unmerged")
      # The default branch moves on after the other ticket's branch was cut: where the work meets
      # it is the old head, which is neither the start nor the default branch's head now.
      moved_on = commit_to_default(project, %{"later.txt" => "later\n"})
      refute moved_on == default

      assert %{"number" => number, "state" => state} =
               admit(conn, project, %{"outside_work" => true, "start_commit" => under})
               |> json_response(201)

      ticket = Tickets.get_by_number!(project, number)
      assert state == ticket.state
      assert {:ok, ^under} = Git.resolve(repo, "refs/heads/" <> ticket.branch)
      assert ticket.workflow_commit == under
      # Not the start, which would hide the work under it from whoever approves: where it meets
      # the default branch.
      assert ticket.base_commit == default
      assert {:ok, diff} = Git.run(repo, ["diff", "--name-only", ticket.base_commit, under])
      assert String.contains?(diff, "under.txt")
    end

    test "a commit that is in the repository but on no ref is refused", %{
      conn: conn,
      project: project
    } do
      repo = Projects.repo_path(project)
      {:ok, head} = Git.resolve(repo, "refs/heads/" <> project.default_branch)
      dangling = commit_beside(repo, head, "dangling.txt", "on no branch")
      assert {:ok, ^dangling} = Git.resolve(repo, dangling)

      assert %{"error" => %{"reason" => "bad_start_commit"}} =
               admit(conn, project, %{"outside_work" => true, "start_commit" => dangling})
               |> json_response(422)

      assert Tickets.list(project) == []
    end

    test "a start on the default branch is its own base, as an ordinary admission is", %{
      conn: conn,
      project: project
    } do
      repo = Projects.repo_path(project)
      {:ok, head} = Git.resolve(repo, "refs/heads/" <> project.default_branch)

      assert %{"number" => number} =
               admit(conn, project, %{"outside_work" => true, "start_commit" => head})
               |> json_response(201)

      assert Tickets.get_by_number!(project, number).base_commit == head
    end

    test "a read token may not open anything", %{conn: conn, project: project} do
      {secret, _} = token!(project, :read)

      assert conn
             |> as(secret)
             |> admit(project, %{"outside_work" => true})
             |> json_response(403)

      assert Tickets.list(project) == []
    end
  end

  describe "the project, for an agent that has to open a ticket" do
    test "carries the address to fetch from, with no credential, and the ticket types", %{
      conn: conn,
      project: project
    } do
      assert %{"name" => name, "git_url" => git_url, "ticket_types" => types} =
               conn |> get("/api/v1/projects/#{project.name}") |> json_response(200)

      assert name == project.name
      assert git_url == Git.Url.for(project)
      refute git_url =~ "@"
      assert %{"types" => _, "form" => _} = types
    end

    test "another project's is not there", %{conn: conn} do
      assert conn |> get("/api/v1/projects/nobody-#{n()}") |> json_response(404)
    end
  end

  describe "taking over and handing back" do
    setup %{conn: conn, project: project} do
      %{"number" => number} = admit(conn, project, %{"on_hold" => false}) |> json_response(201)
      %{number: number}
    end

    test "take over names the holder and the door; a second is refused naming who", %{
      conn: conn,
      project: project,
      number: number,
      user: user
    } do
      assert %{"taken_over" => %{"by" => %{"id" => id}, "via" => "api", "state" => "refining"}} =
               conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)

      assert id == user.id

      assert %{"error" => %{"reason" => "already_taken_over", "detail" => detail}} =
               conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(409)

      assert detail =~ user.id
      ticket = Tickets.get_by_number!(project, number)
      assert [%Takeover{via: "api"}] = Repo.all(Takeover)
      assert ticket.takeover_id
    end

    test "hands back with a note, recording what was pushed", %{
      conn: conn,
      project: project,
      number: number
    } do
      conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)
      ticket = Tickets.get_by_number!(project, number)
      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "from my pc")

      assert %{"taken_over" => nil, "on_hold" => false} =
               conn
               |> post(ticket_path(project, number) <> "/hand-back", %{"note" => "polished"})
               |> json_response(200)

      assert {:ok, %{sha: ^sha}} = Forge.Merge.changeset(Tickets.get!(ticket.id))
      assert [%Takeover{note: "polished", back_via: "api"}] = Repo.all(Takeover)

      assert [%{payload: %{"via" => "api", "note" => "polished"}}] =
               ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "ticket.handed_back"))
    end

    test "a note over the limit is refused with the limit, and the ticket stays taken over", %{
      conn: conn,
      project: project,
      number: number
    } do
      conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)
      note = String.duplicate("é", Takeover.note_limit() + 1)

      assert %{"error" => %{"reason" => "note_too_long", "detail" => detail}} =
               conn
               |> post(ticket_path(project, number) <> "/hand-back", %{"note" => note})
               |> json_response(422)

      assert detail =~ Integer.to_string(Takeover.note_limit())

      assert %{"ticket" => %{"taken_over" => %{}}} =
               conn |> get(ticket_path(project, number)) |> json_response(200)
    end

    test "a step that is not a name is refused before anything is recorded", %{
      conn: conn,
      project: project,
      number: number
    } do
      conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)
      ticket = Tickets.get_by_number!(project, number)
      commit_file_on_branch(project, ticket.branch, "mine.txt", "pushed")

      for bad <- [["refining"], %{"a" => 1}, 7] do
        assert %{"error" => %{"reason" => "bad_step"}} =
                 conn
                 |> post(ticket_path(project, number) <> "/hand-back", %{"to" => bad})
                 |> json_response(422)
      end

      # Nothing was written by the refusals: no version of the change, and still taken over.
      assert Forge.Artifacts.latest(ticket.id, "changeset") == nil
      assert Tickets.get!(ticket.id).takeover_id
    end

    test "a ticket nobody took over cannot be handed back", %{
      conn: conn,
      project: project,
      number: number
    } do
      assert %{"error" => %{"reason" => "not_taken_over"}} =
               conn
               |> post(ticket_path(project, number) <> "/hand-back", %{})
               |> json_response(409)
    end

    test "the steps a hand-back may go to are on the ticket, with what each needs", %{
      conn: conn,
      project: project,
      number: number
    } do
      conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)

      assert %{"ticket" => %{"steps" => steps}} =
               conn |> get(ticket_path(project, number)) |> json_response(200)

      assert [%{"state" => "refining", "edge" => nil, "missing" => []} | _] = steps
      assert Enum.any?(steps, &(&1["state"] == "implementing" and &1["missing"] != []))
    end

    test "a step whose document is missing is refused and the ticket stays taken over", %{
      conn: conn,
      project: project,
      number: number
    } do
      conn |> post(ticket_path(project, number) <> "/take-over") |> json_response(200)

      assert %{"error" => %{"reason" => "missing_input"}} =
               conn
               |> post(ticket_path(project, number) <> "/hand-back", %{"to" => "implementing"})
               |> json_response(409)

      assert %{"ticket" => %{"taken_over" => %{}}} =
               conn |> get(ticket_path(project, number)) |> json_response(200)
    end

    test "a read token is refused each, a write token takes over and is named", %{
      conn: conn,
      project: project,
      number: number
    } do
      {read, _} = token!(project, :read)
      {write, token} = token!(project, :write)

      for path <- ["/take-over", "/hand-back", "/keep-work"] do
        assert conn
               |> as(read)
               |> post(ticket_path(project, number) <> path)
               |> json_response(403)
      end

      assert %{"taken_over" => %{"by" => %{"kind" => "api", "id" => id}}} =
               conn
               |> as(write)
               |> post(ticket_path(project, number) <> "/take-over")
               |> json_response(200)

      assert id == token.id
    end

    test "another project's ticket is the 404 of one that is not there", %{conn: conn} do
      other = user_fixture()
      secret = Accounts.create_api_token(other, "other")
      {:ok, mine} = Projects.register(%{name: "ow-o-#{n()}", repo_path: seeded_repo()}, other)

      %{"number" => theirs} =
        conn |> as(secret) |> admit(mine, %{"on_hold" => false}) |> json_response(201)

      for path <- ["/take-over", "/hand-back", "/keep-work"] do
        assert conn
               |> post(ticket_path(mine, theirs) <> path, %{"job_id" => "x"})
               |> json_response(404)
      end

      assert Tickets.get_by_number!(mine, theirs).takeover_id == nil
    end

    test "keeping a job's work needs the job named, and a stop that is not there is stale", %{
      conn: conn,
      project: project,
      number: number
    } do
      assert %{"error" => %{"reason" => "bad_request"}} =
               conn |> post(ticket_path(project, number) <> "/keep-work") |> json_response(400)

      assert %{"error" => %{"reason" => "stale_stop"}} =
               conn
               |> post(ticket_path(project, number) <> "/keep-work", %{
                 "job_id" => Ecto.UUID.generate()
               })
               |> json_response(409)
    end
  end

  describe "the words of keeping a job's work" do
    test "each refusal is a 409 with its own reason, and the page says it in words" do
      for {reason, code} <- [
            {:stale_stop, "stale_stop"},
            {:nothing_kept, "nothing_kept"},
            {:keep_push_failed, "keep_push_failed"},
            {{:kept_work_conflicts, ["a.txt", "b/c.txt"]}, "kept_work_conflicts"}
          ] do
        assert %{status: 409, body: %{"error" => %{"reason" => ^code, "detail" => detail}}} =
                 ForgeWeb.Api.Errors.of(reason)

        assert is_binary(detail) and detail != ""
        assert ForgeWeb.Operator.Actions.describe(reason) =~ ~r/\w/
      end

      assert ForgeWeb.Operator.Actions.describe({:kept_work_conflicts, ["a.txt", "b/c.txt"]}) =~
               "a.txt, b/c.txt"

      assert %{body: %{"error" => %{"detail" => detail}}} =
               ForgeWeb.Api.Errors.of({:kept_work_conflicts, ["x.txt"]})

      assert detail =~ "x.txt"
    end
  end

  defp events(ticket),
    do: ticket |> Map.fetch!(:id) |> Events.for_ticket() |> Enum.map(& &1.type)
end
