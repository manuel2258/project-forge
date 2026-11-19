defmodule ForgeWeb.ExtendApiTest do
  @moduledoc """
  Extending a job that ran out of budget through the API (`docs/design/api-and-ui.md`): the page is
  a client of it, so everything the page does is here — the offer a ticket carries, the figures and
  the note, the refusals by reason, and who may.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, FakeWorker, Jobs, Projects, Repo, Tickets}
  alias Forge.Git.Tokens
  alias Forge.Jobs.Extensions

  @workflow """
  version: 1
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md]
      budget: { turns: 150, tokens: 12M }
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits:
    ticket_tokens: 100M
  """

  setup %{conn: conn} do
    user = user_fixture()
    bearer = Accounts.create_api_token(user, "test")

    {:ok, project} =
      Projects.register(
        %{
          name: "ext-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
        },
        user
      )

    funded!(project)
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    worker = FakeWorker.connect()
    [job] = Jobs.for_ticket(ticket.id)
    assignment = FakeWorker.assign(job, worker)

    {:ok, job} =
      FakeWorker.finish(assignment, "max_budget",
        written: %{},
        harness: %{
          "session_id" => "sess-42",
          "session_blob" => assignment["store"]["session_prefix"] <> "1.jsonl",
          "version" => "2.1.284",
          "usage" => 12_000_000
        }
      )

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> bearer),
      user: user,
      project: project,
      ticket: Tickets.get!(ticket.id),
      job: job,
      worker: worker
    }
  end

  defp api(project, ticket, tail \\ ""),
    do: "/api/v1/tickets/#{project.name}/#{ticket.number}#{tail}"

  defp extend_url(project, ticket, job), do: api(project, ticket, "/jobs/#{job.id}/extend")

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  test "a stuck ticket carries the offer, and the queue's item carries it too", ctx do
    %{conn: conn, project: project, ticket: ticket, job: job} = ctx

    assert %{
             "ticket" => %{
               "status" => "stuck",
               "retry" => true,
               "cap" => 100_000_000,
               "cap_raise" => 0,
               "extend" => %{
                 "job_id" => job_id,
                 "exhausted" => "tokens",
                 "default_tokens" => 6_000_000,
                 "default_turns" => 75,
                 "bounds_turns" => true
               }
             }
           } = conn |> get(api(project, ticket)) |> json_response(200)

    assert job_id == job.id

    assert %{"items" => [%{"kind" => "stuck", "detail" => %{"extend" => %{"job_id" => ^job_id}}}]} =
             conn |> get("/api/v1/queue") |> json_response(200)
  end

  test "extending reopens the job, and the job shows it", ctx do
    %{conn: conn, project: project, ticket: ticket, job: job, user: user} = ctx

    assert %{"status" => "active", "extend" => nil} =
             conn
             |> post(extend_url(project, ticket, job), %{
               "tokens" => "6M",
               "turns" => "75",
               "note" => "Finish the review."
             })
             |> json_response(200)

    assert %{"job" => %{"status" => "pending", "outcome" => nil} = shown} =
             conn |> get(api(project, ticket, "/jobs/#{job.id}")) |> json_response(200)

    assert [
             %{
               "tokens" => 6_000_000,
               "turns" => 75,
               "note" => "Finish the review.",
               "author" => %{"kind" => "user", "id" => id},
               "exhausted" => "tokens"
             }
           ] = shown["extensions"]

    assert id == user.id
    assert [%{"extension_id" => nil, "resumed" => nil}] = shown["runs"]
  end

  test "a run again carries a note and a raise, and the job it makes says who", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    # Nothing left of the cap: the state's budget is what the raise has to cover.
    ticket |> Ecto.Changeset.change(usage: 100_000_000) |> Repo.update!()

    assert %{"error" => %{"reason" => "raise_short"}} =
             conn
             |> post(api(project, ticket, "/retry"), %{"note" => "Smaller."})
             |> json_response(422)

    assert %{"status" => "active", "cap_raise" => 12_000_000, "cap" => 112_000_000} =
             conn
             |> post(api(project, ticket, "/retry"), %{"note" => "Smaller.", "raise" => "12M"})
             |> json_response(200)

    [_old, new] = Jobs.for_ticket(ticket.id)

    assert %{"job" => %{"restart" => %{"note" => "Smaller.", "author" => %{"kind" => "user"}}}} =
             conn |> get(api(project, ticket, "/jobs/#{new.id}")) |> json_response(200)
  end

  test "each refusal has its reason", ctx do
    %{conn: conn, project: project, ticket: ticket, job: job} = ctx
    path = extend_url(project, ticket, job)

    assert %{"error" => %{"reason" => "invalid_tokens", "detail" => detail}} =
             conn |> post(path, %{"tokens" => "lots"}) |> json_response(422)

    assert detail =~ "800k"

    assert %{"error" => %{"reason" => "invalid_turns"}} =
             conn |> post(path, %{"tokens" => "1M", "turns" => "1.5"}) |> json_response(422)

    assert %{"error" => %{"reason" => "note_too_long"}} =
             conn
             |> post(path, %{"tokens" => "1M", "note" => String.duplicate("n", 4_001)})
             |> json_response(422)

    # 4,000 graphemes of e and a combining accent are 8,000 codepoints, which the database's own
    # limit counts: refused here, not a 500 from a constraint.
    assert %{"error" => %{"reason" => "note_too_long"}} =
             conn
             |> post(path, %{"tokens" => "1M", "note" => String.duplicate("e\u0301", 4_000)})
             |> json_response(422)

    assert %{"error" => %{"reason" => "invalid_note"}} =
             conn |> post(path, %{"tokens" => "1M", "note" => ["a"]}) |> json_response(422)

    # A JSON \u0000 is a NUL byte the database would refuse: answered here, not a 500.
    assert %{"error" => %{"reason" => "invalid_note"}} =
             conn |> post(path, %{"tokens" => "1M", "note" => "a\u0000b"}) |> json_response(422)

    assert %{"error" => %{"reason" => "invalid_raise"}} =
             conn |> post(path, %{"tokens" => "1M", "raise" => "lots"}) |> json_response(422)

    assert %{"error" => %{"reason" => "raise_not_needed"}} =
             conn |> post(path, %{"tokens" => "1M", "raise" => "1M"}) |> json_response(422)

    assert %{"error" => %{"reason" => "not_found"}} =
             conn
             |> post(api(project, ticket, "/jobs/#{Ecto.UUID.generate()}/extend"), %{
               "tokens" => "1M"
             })
             |> json_response(404)

    short = Ecto.Changeset.change(ticket, usage: 98_000_000) |> Repo.update!()

    assert %{"error" => %{"reason" => "raise_short", "detail" => short_detail}} =
             conn |> post(path, %{"tokens" => "6M"}) |> json_response(422)

    assert short_detail =~ "raised by at least 4M"
    assert Extensions.all(job.id) == []
    assert %{cap_raise: 0} = Tickets.get!(short.id)

    assert %{"cap_raise" => 4_000_000, "cap" => 104_000_000} =
             conn |> post(path, %{"tokens" => "6M", "raise" => "4M"}) |> json_response(200)

    # Reopened: the same request again finds the job no longer stuck.
    assert %{"error" => %{"reason" => "not_extendable", "detail" => again}} =
             conn |> post(path, %{"tokens" => "1M"}) |> json_response(409)

    assert again =~ "not stuck"
  end

  test "a write token does it and is named; a read token and a job's token are refused", ctx do
    %{conn: conn, project: project, ticket: ticket, job: job} = ctx
    {:ok, read, _} = Tokens.issue(project, name: "ci", git: :reader, api: :read)
    {:ok, write, _} = Tokens.issue(project, name: "bot", git: :reader, api: :write)

    assert %{"error" => %{"reason" => "forbidden"}} =
             conn
             |> as(read)
             |> post(extend_url(project, ticket, job), %{"tokens" => "1M"})
             |> json_response(403)

    assert Extensions.all(job.id) == []

    assert %{"status" => "active"} =
             conn
             |> as(write)
             |> post(extend_url(project, ticket, job), %{"tokens" => "1M"})
             |> json_response(200)

    assert [%{token_id: token_id, user_id: nil}] = Extensions.all(job.id)
    assert is_binary(token_id)

    assert %{"job" => %{"extensions" => [%{"author" => %{"kind" => "api", "name" => "bot"}}]}} =
             conn |> get(api(project, ticket, "/jobs/#{job.id}")) |> json_response(200)
  end

  test "a person who is not a member finds nothing", ctx do
    %{project: project, ticket: ticket, job: job} = ctx
    stranger = Accounts.create_api_token(user_fixture(), "other")

    assert %{"error" => %{"reason" => "not_found"}} =
             build_conn()
             |> as(stranger)
             |> post(extend_url(project, ticket, job), %{"tokens" => "1M"})
             |> json_response(404)

    assert Extensions.all(job.id) == []
  end
end
