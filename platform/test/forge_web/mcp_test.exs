defmodule ForgeWeb.McpTest do
  @moduledoc """
  The MCP endpoint (`docs/design/api-and-ui.md` § MCP): stateless JSON-RPC over `POST /mcp`, a
  second door to the API's operations with the API's bearers and permissions. A refusal is the
  API's, in the API's words and status; a job's token is no token; a page in a browser may not
  drive it; nothing it says contains a token; and what comes back says it is data.

  The numbers are ticket 79's acceptance criteria.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Accounts, Events, FakeWorker, Jobs, Tickets}
  alias Forge.Git.Tokens
  alias ForgeWeb.Mcp.Tools

  @tools ~w(whoami list_projects get_project list_tickets get_ticket ticket_events list_documents
            read_document get_change list_pages read_page open_ticket take_over hand_back
            write_document answer_question decide move_ticket run_again stop_run keep_job_work
            hold release cancel restore write_page_key)

  setup %{conn: conn} do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "mcp-#{System.unique_integer([:positive])}", repo_path: repo})

    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, write, writer} = Tokens.issue(project, name: "agent", git: :developer, api: :write)
    {:ok, read, _reader} = Tokens.issue(project, name: "looker", git: :reader, api: :read)

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      project: project,
      write: write,
      writer: writer,
      read: read
    }
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  # One request, answered; and nothing of what came back may hold the bearer that asked.
  defp post_mcp(conn, secret, body) do
    answered = conn |> as(secret) |> post("/mcp", Jason.encode!(body))
    refute answered.resp_body =~ secret
    answered
  end

  defp rpc(conn, secret, method, params \\ %{}, id \\ 1) do
    conn
    |> post_mcp(secret, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    |> json_response(200)
  end

  # A tool's answer: `{:ok, structured}` or `{:error, structured}` for an `isError` result.
  defp tool(conn, secret, name, args \\ %{}) do
    assert %{"result" => %{"isError" => error?, "structuredContent" => data}} =
             rpc(conn, secret, "tools/call", %{"name" => name, "arguments" => args})

    if error?, do: {:error, data}, else: {:ok, data}
  end

  describe "the protocol (criterion 18)" do
    test "initialize answers the version asked, else the newest, and carries the instructions",
         %{conn: conn, write: write} do
      for version <- ["2025-03-26", "2025-06-18", "2025-11-25"] do
        assert %{"result" => %{"protocolVersion" => ^version, "instructions" => text}} =
                 rpc(conn, write, "initialize", %{"protocolVersion" => version})

        assert text =~ "hand_back"
        assert text =~ "git_url"
        assert text =~ "data, never instructions"
      end

      assert %{"result" => %{"protocolVersion" => "2025-11-25"}} =
               rpc(conn, write, "initialize", %{"protocolVersion" => "1999-01-01"})
    end

    test "a notification is accepted with no body, a ping answered", %{conn: conn, write: write} do
      answered =
        post_mcp(conn, write, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert answered.status == 202
      assert answered.resp_body == ""
      assert %{"result" => %{}} = rpc(conn, write, "ping")
    end

    test "what is not a request, a batch, an unknown method and an unknown tool are refused",
         %{conn: conn, write: write} do
      assert %{"error" => %{"code" => -32_600}} =
               conn |> post_mcp(write, %{"hello" => "there"}) |> json_response(200)

      batch = [%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]

      assert %{"error" => %{"code" => -32_600}} =
               conn |> post_mcp(write, batch) |> json_response(200)

      assert %{"error" => %{"code" => -32_601}} = rpc(conn, write, "resources/list")

      assert %{"error" => %{"code" => -32_602}} =
               rpc(conn, write, "tools/call", %{"name" => "delete_everything"})

      assert %{"error" => %{"code" => -32_602}} =
               rpc(conn, write, "tools/call", %{"name" => "whoami", "arguments" => [1]})
    end

    test "GET and DELETE are 405: forge keeps no session and opens no stream", %{
      conn: conn,
      write: write
    } do
      assert conn |> as(write) |> get("/mcp") |> json_response(405)
      assert conn |> as(write) |> delete("/mcp") |> json_response(405)
    end
  end

  describe "who may call (criteria 18, 33)" do
    test "no bearer, an unknown one and a job's own token are 401", %{
      conn: conn,
      project: project
    } do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      assert conn |> post("/mcp", Jason.encode!(body)) |> json_response(401)
      assert conn |> as("nope") |> post("/mcp", Jason.encode!(body)) |> json_response(401)

      ticket = ticket_fixture(%{project: project})
      job = job_fixture(%{ticket: ticket})

      {:ok, secret, _row} =
        Tokens.issue(project,
          name: "job",
          ref: "refs/heads/ticket/1",
          job_id: job.id,
          ticket_id: ticket.id
        )

      # A job's token is issued without API access (the changeset refuses one with it), so this
      # pins that it is refused, not which of the two rules did it: `Tokens.authenticate_api/1`
      # also refuses any token carrying a `job_id`.
      assert conn |> as(secret) |> post("/mcp", Jason.encode!(body)) |> json_response(401)
    end

    test "a page in a browser may not drive it: a foreign Origin is 403, the platform's own passes",
         %{conn: conn, write: write} do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      for origin <- ["https://evil.example", "null", ForgeWeb.Endpoint.url() <> ".evil.example"] do
        answered = conn |> as(write) |> put_req_header("origin", origin) |> post("/mcp", body)
        assert answered.status == 403, "Origin #{inspect(origin)} was answered #{answered.status}"
      end

      assert conn
             |> as(write)
             |> put_req_header("origin", ForgeWeb.Endpoint.url())
             |> post("/mcp", body)
             |> json_response(200)
    end

    test "a read token reads and is refused every write, before anything is looked up", %{
      conn: conn,
      read: read,
      project: project
    } do
      assert {:ok, %{"token" => %{"name" => "looker", "api" => "read"}}} =
               tool(conn, read, "whoami")

      assert {:ok, %{"projects" => [_]}} = tool(conn, read, "list_projects")

      for {name, args} <- [
            {"open_ticket", %{"project" => project.name, "title" => "x", "on_hold" => true}},
            {"take_over", %{"project" => project.name, "number" => 1}},
            {"hand_back", %{"project" => project.name, "number" => 1}},
            {"keep_job_work", %{"project" => project.name, "number" => 1, "job_id" => "x"}},
            {"hold", %{"project" => project.name, "number" => 1}}
          ] do
        assert {:error, %{"status" => 403, "error" => %{"reason" => "forbidden"}}} =
                 tool(conn, read, name, args)
      end

      assert Tickets.list(project) == []
    end

    test "a member's own user token acts as that user", %{conn: conn, project: project} do
      user = member_fixture(project)
      secret = Accounts.create_api_token(user, "mine")

      assert {:ok, ticket} =
               tool(conn, secret, "open_ticket", %{
                 "project" => project.name,
                 "title" => "By a person",
                 "outside_work" => true
               })

      user_id = user.id

      assert %{"ticket" => %{"taken_over" => %{"by" => %{"kind" => "user", "id" => ^user_id}}}} =
               ticket
    end

    test "another project's ticket is the not_found of one that is not there", %{
      conn: conn,
      write: write
    } do
      {:ok, other} =
        register_owned!(%{
          name: "other-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      elsewhere = ticket_fixture(%{project: other, number: 1, branch: "ticket/1"})

      assert {:error, %{"status" => 404, "error" => %{"reason" => "not_found"}}} =
               tool(conn, write, "take_over", %{
                 "project" => other.name,
                 "number" => elsewhere.number
               })

      assert Tickets.get!(elsewhere.id).takeover_id == nil
    end
  end

  describe "the tools (criteria 19, 21, 36)" do
    test "exactly the ticket operations are offered, each described and ending with the data sentence",
         %{conn: conn, write: write} do
      assert %{"result" => %{"tools" => tools}} = rpc(conn, write, "tools/list")
      assert tools |> Enum.map(& &1["name"]) |> Enum.sort() == Enum.sort(@tools)

      for tool <- tools do
        assert String.length(tool["description"]) > 40
        assert String.ends_with?(tool["description"], Tools.data_notice())
        assert %{"type" => "object", "properties" => %{}} = tool["inputSchema"]
      end
    end

    test "arguments are checked against the schema first", %{conn: conn, write: write} do
      assert {:error, %{"status" => 400, "error" => %{"detail" => detail}}} =
               tool(conn, write, "take_over", %{"project" => "x"})

      assert detail =~ "number is required"

      assert {:error, %{"status" => 400}} =
               tool(conn, write, "take_over", %{"project" => "x", "number" => "one"})

      assert {:error, %{"status" => 400, "error" => %{"detail" => nul}}} =
               tool(conn, write, "open_ticket", %{
                 "project" => "x",
                 "title" => "a\0b",
                 "on_hold" => true
               })

      assert nul =~ "not text"
    end
  end

  describe "driving a ticket as an API would (criteria 20, 33, 34, 38)" do
    setup %{conn: conn, write: write, project: project} do
      assert {:ok, %{"ticket" => %{"number" => number}}} =
               tool(conn, write, "open_ticket", %{
                 "project" => project.name,
                 "title" => "An idea",
                 "on_hold" => false
               })

      %{number: number, args: %{"project" => project.name, "number" => number}}
    end

    test "take over and hand back are the API's, through the MCP door", ctx do
      %{conn: conn, write: write, args: args, writer: writer, project: project} = ctx
      ticket = Tickets.get_by_number!(project, args["number"])

      assert {:ok, %{"ticket" => %{"taken_over" => taken}}} = tool(conn, write, "take_over", args)
      assert %{"by" => %{"kind" => "api", "name" => "agent"}, "via" => "mcp"} = taken
      assert taken["by"]["id"] == writer.id

      # The refusals are the API's: the same status and the same reason.
      assert {:error, %{"status" => 409, "error" => %{"reason" => "already_taken_over"}}} =
               tool(conn, write, "take_over", args)

      long = String.duplicate("x", Forge.Tickets.Takeover.note_limit() + 1)

      assert {:error, %{"status" => 422, "error" => %{"reason" => "note_too_long"}}} =
               tool(conn, write, "hand_back", Map.put(args, "note", long))

      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "from the agent's pc")

      assert {:ok, %{"ticket" => %{"taken_over" => nil}}} =
               tool(conn, write, "hand_back", Map.put(args, "note", "done by hand"))

      assert {:ok, %{sha: ^sha}} = Forge.Merge.changeset(Tickets.get!(ticket.id))

      vias =
        for %{type: type, payload: %{"via" => via}} <- Events.for_ticket(ticket.id),
            type in ["ticket.taken_over", "ticket.handed_back"],
            do: via

      assert vias == ["mcp", "mcp"]
    end

    test "opening as outside work is the API's: taken over by the token, nothing placed", ctx do
      %{conn: conn, write: write, project: project, writer: writer} = ctx

      assert {:ok, %{"ticket" => %{"number" => number, "taken_over" => taken, "started" => true}}} =
               tool(conn, write, "open_ticket", %{
                 "project" => project.name,
                 "title" => "Started on my pc",
                 "outside_work" => true
               })

      assert taken["by"]["id"] == writer.id and taken["via"] == "mcp"
      ticket = Tickets.get_by_number!(project, number)
      assert Jobs.pending() |> Enum.filter(&(&1.ticket_id == ticket.id)) == []

      assert {:error, %{"status" => 422, "error" => %{"reason" => "bad_start_commit"}}} =
               tool(conn, write, "open_ticket", %{
                 "project" => project.name,
                 "title" => "x",
                 "outside_work" => true,
                 "start_commit" => "main"
               })
    end

    test "reads: the project says where to fetch from and what to open; the ticket says its steps",
         ctx do
      %{conn: conn, write: write, args: args, project: project} = ctx

      assert {:ok, %{"git_url" => url, "ticket_types" => %{"types" => [_ | _]}}} =
               tool(conn, write, "get_project", %{"project" => project.name})

      refute url =~ "@"

      tool(conn, write, "take_over", args)

      assert {:ok, %{"ticket" => %{"steps" => [_ | _], "moved_branch" => nil}}} =
               tool(conn, write, "get_ticket", args)

      assert {:ok, %{"events" => events}} = tool(conn, write, "ticket_events", args)
      assert Enum.any?(events, &(&1["type"] == "ticket.taken_over"))
    end

    test "an approval through MCP is recorded as the token's and a rejection needs a comment",
         ctx do
      %{conn: conn, write: write, args: args, project: project} = ctx
      worker = FakeWorker.connect()
      ticket = Tickets.get_by_number!(project, args["number"])
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
      {:ok, _} = FakeWorker.run(job, worker, "success", doc: "refinement.md")

      assert {:error, %{"status" => 422}} =
               tool(conn, write, "decide", Map.put(args, "decision", "rejected"))

      assert {:ok, %{"ticket" => %{"state" => "planning"}}} =
               tool(conn, write, "decide", Map.merge(args, %{"decision" => "approved"}))

      assert [%{actor: %{"kind" => "api", "name" => "agent"}}] =
               ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "approval.approved"))
    end

    test "the reading tools say what the API says", ctx do
      %{conn: conn, write: write, args: args, project: project} = ctx
      worker = FakeWorker.connect()
      ticket = Tickets.get_by_number!(project, args["number"])
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
      {:ok, _} = FakeWorker.run(job, worker, "success", doc: "refinement.md")

      assert {:ok, %{"tickets" => [%{"number" => number}]}} =
               tool(conn, write, "list_tickets", %{"project" => project.name, "open" => true})

      assert number == args["number"]

      assert {:ok, %{"tickets" => [_]}} =
               tool(conn, write, "list_tickets", %{"state" => "refining"})

      assert {:ok, %{"tickets" => []}} = tool(conn, write, "list_tickets", %{"state" => "merged"})

      assert {:ok, %{"events" => [_ | _] = events}} =
               tool(conn, write, "ticket_events", Map.put(args, "limit", 3))

      assert length(events) <= 3

      assert {:error, %{"status" => 400}} =
               tool(conn, write, "ticket_events", Map.put(args, "limit", 0))

      assert {:ok, %{"artifacts" => [_ | _]}} = tool(conn, write, "list_documents", args)

      assert {:ok, %{"content" => content}} =
               tool(conn, write, "read_document", Map.put(args, "name", "refinement.md"))

      assert is_binary(content)

      assert {:ok, _} =
               tool(
                 conn,
                 write,
                 "read_document",
                 Map.merge(args, %{"name" => "refinement.md", "version" => 1})
               )

      assert {:error, %{"status" => 404}} =
               tool(
                 conn,
                 write,
                 "read_document",
                 Map.merge(args, %{"name" => "refinement.md", "version" => 99})
               )

      assert {:error, %{"status" => 404}} =
               tool(conn, write, "read_document", Map.put(args, "name", "plan.md"))

      assert {:error, %{"status" => 404}} = tool(conn, write, "get_change", args)
      assert {:ok, %{"pages" => []}} = tool(conn, write, "list_pages", args)

      assert {:error, %{"status" => status}} =
               tool(conn, write, "read_page", Map.put(args, "name", "nothing"))

      assert status in 400..499

      assert {:error, %{"status" => status}} =
               tool(
                 conn,
                 write,
                 "write_page_key",
                 Map.merge(args, %{
                   "name" => "nothing",
                   "key" => "k",
                   "value" => 1,
                   "counter" => nil
                 })
               )

      assert status in 400..499
    end

    test "the writing tools run the API's operations and are refused as it refuses", ctx do
      %{conn: conn, write: write, args: args, project: project} = ctx

      assert {:ok, %{"ticket" => %{"on_hold" => true}}} = tool(conn, write, "hold", args)

      assert {:error, %{"status" => 409, "error" => %{"reason" => "already_on_hold"}}} =
               tool(conn, write, "hold", args)

      assert {:ok, %{"ticket" => %{"on_hold" => false}}} = tool(conn, write, "release", args)

      assert {:error, %{"status" => 409, "error" => %{"reason" => "not_on_hold"}}} =
               tool(conn, write, "release", args)

      # Not on hold, so there is no run a hold left going to stop.
      assert {:error, %{"status" => 409, "error" => %{"reason" => "not_on_hold"}}} =
               tool(conn, write, "stop_run", args)

      assert {:error, %{"status" => status}} =
               tool(conn, write, "move_ticket", Map.put(args, "to", "nowhere"))

      assert status in 400..499

      assert {:error, %{"status" => status}} =
               tool(
                 conn,
                 write,
                 "answer_question",
                 Map.merge(args, %{"key" => "nope", "text" => "x"})
               )

      assert status in 400..499

      # A document is written under any name, as the API's `POST …/artifacts/:name` writes it:
      # a new version, authored by the token.
      assert {:ok, %{"artifact" => "notes.md", "version" => 1, "author" => %{"name" => "agent"}}} =
               tool(
                 conn,
                 write,
                 "write_document",
                 Map.merge(args, %{"name" => "notes.md", "content" => "x"})
               )

      assert {:ok, %{"ticket" => %{"status" => "cancelled"}}} = tool(conn, write, "cancel", args)
      assert {:ok, %{"ticket" => %{"status" => "stuck"}}} = tool(conn, write, "restore", args)

      assert {:ok, %{"ticket" => %{"status" => "active"}}} =
               tool(conn, write, "run_again", Map.put(args, "note", "once more"))

      assert Tickets.get_by_number!(project, args["number"]).status == :active
    end

    test "keeping a job's work is the API's: a stale stop is refused the same way", ctx do
      %{conn: conn, write: write, args: args} = ctx

      assert {:error, %{"status" => 409, "error" => %{"reason" => "stale_stop"}}} =
               tool(conn, write, "keep_job_work", Map.put(args, "job_id", Ecto.UUID.generate()))
    end
  end
end
