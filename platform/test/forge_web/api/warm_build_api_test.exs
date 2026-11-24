defmodule ForgeWeb.Api.WarmBuildApiTest do
  @moduledoc """
  A ticket's warm build over the JSON API (`docs/design/api-and-ui.md`, `docs/design/worker-tier.md`
  § The command copy): the ticket shows it, its commands show what each reported, and clearing it
  is a member's, a write token's, and no job's.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.WarmFixtures, only: [kept!: 3, ticket_in_checking!: 0]

  alias Forge.{Accounts, Events, FakeWorker, Repo, Tickets}
  alias Forge.Git.Tokens

  setup %{conn: conn} do
    %{project: project, user: user, ticket: ticket, commands: commands} = ticket_in_checking!()
    token = Accounts.create_api_token(user, "test")
    worker = FakeWorker.connect(project: project)

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      project: project,
      ticket: ticket,
      commands: commands,
      worker: worker,
      url: "/api/v1/tickets/#{project.name}/#{ticket.number}"
    }
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  test "the ticket says there is no copy until a command keeps one", %{conn: conn, url: url} do
    assert %{"ticket" => %{"warm_build" => %{"copy" => nil}}} =
             conn |> get(url) |> json_response(200)
  end

  test "the ticket shows the copy its next command goes to, and nothing of its files", ctx do
    kept = kept!(ctx.ticket, ctx.worker, size: 2048, args: ["--all", "<b>x</b>"])
    commit = String.duplicate("c", 40)

    assert %{"ticket" => %{"warm_build" => %{"copy" => copy}}} =
             ctx.conn |> get(ctx.url) |> json_response(200)

    assert copy == %{
             "size" => 2048,
             "machine" => ctx.worker.id,
             "command" => "test",
             "args" => ["--all", "<b>x</b>"],
             "commit" => commit,
             "job_id" => kept.id,
             "kept_at" => DateTime.to_iso8601(kept.finished_at)
           }
  end

  test "a ticket whose workflow keeps nothing has no warm build at all", %{conn: conn} do
    other = Forge.ForgeFixtures.ticket_fixture()
    project = Forge.Projects.get!(other.project_id)
    user = user_fixture()
    Forge.ForgeFixtures.join!(project, user, :admin)
    token = Accounts.create_api_token(user, "other")

    assert %{"ticket" => %{"warm_build" => nil}} =
             conn
             |> as(token)
             |> get("/api/v1/tickets/#{project.name}/#{other.number}")
             |> json_response(200)
  end

  test "a command shows what its worker reported, and one that reported nothing shows null",
       ctx do
    [_build, first, second | _] = ctx.commands

    {:ok, _job} =
      first
      |> FakeWorker.assign(ctx.worker)
      |> FakeWorker.finish_command(0, warm: %{"source" => "seed", "kept" => true, "size" => 77})

    {:ok, _job} = second |> FakeWorker.assign(ctx.worker) |> FakeWorker.finish_command(0)

    assert %{"commands" => commands} = ctx.conn |> get(ctx.url) |> json_response(200)
    by_id = Map.new(commands, &{&1["id"], &1})

    assert %{
             "kind" => "command",
             "command" => "test",
             "exit_status" => 0,
             "warm" => %{
               "source" => "seed",
               "kept" => true,
               "unkept" => nil,
               "size" => 77,
               "from_job_id" => nil
             }
           } = by_id[first.id]

    assert by_id[second.id]["warm"] == nil

    assert %{"job" => %{"warm" => %{"source" => "seed"}}} =
             ctx.conn |> get(ctx.url <> "/jobs/#{first.id}") |> json_response(200)
  end

  describe "clearing" do
    test "a member's token does, and the next command is told the new epoch", ctx do
      kept!(ctx.ticket, ctx.worker, [])

      assert %{"warm_build" => %{"copy" => nil}} =
               ctx.conn |> post(ctx.url <> "/clear-warm-build") |> json_response(200)

      assert Tickets.get!(ctx.ticket.id).warm_epoch == 1

      assert [%{actor: %{"kind" => "user"}}] =
               ctx.ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "ticket.warm_cleared"))
    end

    test "a project token that may write does, as the token", ctx do
      {:ok, write, _row} = Tokens.issue(ctx.project, name: "bot", git: :none, api: :write)

      assert %{"warm_build" => _} =
               ctx.conn |> as(write) |> post(ctx.url <> "/clear-warm-build") |> json_response(200)

      assert [%{actor: %{"kind" => "api", "name" => "bot"}}] =
               ctx.ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "ticket.warm_cleared"))
    end

    test "a read-only project token is refused, and nothing changes", ctx do
      {:ok, read, _row} = Tokens.issue(ctx.project, name: "ro", git: :none, api: :read)

      assert %{"error" => %{"reason" => "forbidden"}} =
               ctx.conn |> as(read) |> post(ctx.url <> "/clear-warm-build") |> json_response(403)

      assert Tickets.get!(ctx.ticket.id).warm_epoch == 0
    end

    test "a job's own token is no token", ctx do
      [agent | _] = Forge.Jobs.for_ticket(ctx.ticket.id)
      {:ok, secret, _row} = Tokens.issue(ctx.project, job_id: agent.id)

      assert ctx.conn |> as(secret) |> post(ctx.url <> "/clear-warm-build") |> json_response(401)
      assert Tickets.get!(ctx.ticket.id).warm_epoch == 0
    end

    test "someone outside the project finds no ticket", ctx do
      stranger = Accounts.create_api_token(user_fixture(), "stranger")

      assert %{"error" => %{"reason" => "not_found"}} =
               ctx.conn
               |> as(stranger)
               |> post(ctx.url <> "/clear-warm-build")
               |> json_response(404)

      assert Repo.reload!(ctx.ticket).warm_epoch == 0
    end
  end
end
