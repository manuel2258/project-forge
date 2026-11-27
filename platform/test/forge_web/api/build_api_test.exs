defmodule ForgeWeb.Api.BuildApiTest do
  @moduledoc """
  A ticket's kept command copies over the JSON API, the stream door a download passes through, a
  command's log with its times, and the same over MCP (`docs/design/worker-tier.md` § Looking into a
  copy; `docs/design/api-and-ui.md`). The machine is the test process: it is registered as the
  worker's connection, receives the `explore` the platform sends, and answers it.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [ticket_fixture: 0]
  import Forge.WarmFixtures, only: [kept!: 3, ticket_in_checking!: 0]

  alias Forge.{Accounts, FakeWorker, Workers}
  alias Forge.Git.Tokens

  setup %{conn: conn} do
    %{project: project, user: user, ticket: ticket, commands: [build | _] = commands} =
      ticket_in_checking!()

    token = Accounts.create_api_token(user, "test")
    worker = FakeWorker.connect(project: project)
    kept = kept!(ticket, worker, command: "test", args: ["--all"])

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      project: project,
      ticket: ticket,
      worker: worker,
      kept: kept,
      build: build,
      commands: commands,
      url: "/api/v1/tickets/#{project.name}/#{ticket.number}"
    }
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  # Makes the request in a process of its own and answers what the machine is asked, in order.
  defp asking(request, answers) do
    task = Task.async(request)

    for answer <- answers do
      assert_receive {:explore, ref, asker, payload}, 2_000
      send(asker, {:explored, ref, answer})
      payload
    end
    |> then(&{Task.await(task), &1})
  end

  describe "the list" do
    test "has one row per machine and what a page draws, and no file of any", ctx do
      assert %{"builds" => [build]} = ctx.conn |> get(ctx.url <> "/builds") |> json_response(200)

      assert %{
               "job_id" => id,
               "command" => "test",
               "args" => ["--all"],
               "next" => true,
               "cleared" => false,
               "machine" => %{"id" => machine, "protocol" => protocol}
             } = build

      assert id == ctx.kept.id
      assert machine == ctx.worker.id
      assert protocol == ForgeCore.WorkerProtocol.current()
    end

    test "is empty when nothing was kept", %{conn: conn} do
      other = ticket_fixture()
      project = Forge.Projects.get!(other.project_id)
      user = user_fixture()
      Forge.ForgeFixtures.join!(project, user, :admin)
      token = Accounts.create_api_token(user, "o")

      assert %{"builds" => []} =
               conn
               |> as(token)
               |> get("/api/v1/tickets/#{project.name}/#{other.number}/builds")
               |> json_response(200)
    end
  end

  describe "a folder" do
    test "is one page of the machine's answer, with a name that is not text carried as bytes",
         ctx do
      entries = [
        %{"name_b64" => Base.encode64("src"), "kind" => "dir", "entries" => 4, "mtime" => 7},
        %{"name_b64" => Base.encode64(<<"a", 255>>), "kind" => "file", "size" => 3, "mtime" => 8},
        %{
          "name_b64" => Base.encode64("ln"),
          "kind" => "link",
          "target_b64" => Base.encode64("/etc/shadow")
        }
      ]

      {conn, [payload]} =
        asking(
          fn -> get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/folder?path=sub&offset=0") end,
          [%{"ok" => %{"entries" => entries, "total" => 3, "offset" => 0}}]
        )

      assert payload["op"] == "list" and payload["path_b64"] == Base.encode64("sub")

      assert %{"entries" => [dir, file, link], "total" => 3, "next_offset" => nil} =
               json_response(conn, 200)

      assert %{"name" => "src", "kind" => "dir", "entries" => 4} = dir
      assert %{"name" => nil, "name_b64" => b64, "size" => 3} = file
      assert Base.url_decode64!(b64, padding: false) == <<"a", 255>>
      assert %{"kind" => "link", "target" => "/etc/shadow"} = link
    end

    test "says where the next page starts", ctx do
      entry = %{"name_b64" => Base.encode64("a"), "kind" => "file", "size" => 1, "mtime" => 1}

      {conn, _} =
        asking(
          fn -> get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/folder") end,
          [%{"ok" => %{"entries" => [entry], "total" => 250, "offset" => 0}}]
        )

      assert %{"next_offset" => 1, "total" => 250} = json_response(conn, 200)
    end
  end

  describe "a file" do
    test "has its facts, its hash and its text when they are asked for", ctx do
      facts = %{
        "kind" => "file",
        "size" => 5,
        "mtime" => 3,
        "text" => true,
        "content_b64" => Base.encode64("hello"),
        "truncated" => false
      }

      sha = String.duplicate("b", 64)

      {conn, [first, second]} =
        asking(
          fn ->
            get(
              ctx.conn,
              ctx.url <> "/builds/#{ctx.kept.id}/file?path=a.txt&hash=true&content=true"
            )
          end,
          [%{"ok" => facts}, %{"ok" => %{"sha256" => sha, "size" => 5}}]
        )

      assert first["op"] == "file" and second["op"] == "hash"

      assert %{
               "kind" => "file",
               "size" => 5,
               "sha256" => ^sha,
               "content" => "hello",
               "text" => true
             } =
               json_response(conn, 200)
    end

    test "is not text when it is not, and the content asked of it is refused with 422", ctx do
      facts = %{"kind" => "file", "size" => 5, "mtime" => 3, "text" => false}

      {conn, _} =
        asking(
          fn ->
            get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/file?path=a.bin&content=true")
          end,
          [%{"ok" => facts}]
        )

      assert %{"error" => %{"reason" => "not_text"}} = json_response(conn, 422)
    end

    test "a link is its target as text and is not followed", ctx do
      facts = %{"kind" => "link", "target_b64" => Base.encode64("/etc/shadow")}

      {conn, _} =
        asking(fn -> get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/file?path=ln") end, [
          %{"ok" => facts}
        ])

      assert %{"kind" => "link", "target" => "/etc/shadow", "content" => nil} =
               json_response(conn, 200)
    end
  end

  describe "when the machine cannot answer" do
    test "it did not answer in time: 504", ctx do
      previous = Application.get_env(:forge, :explore_answer_ms)
      Application.put_env(:forge, :explore_answer_ms, 30)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:forge, :explore_answer_ms, previous),
          else: Application.delete_env(:forge, :explore_answer_ms)
      end)

      assert %{"error" => %{"reason" => "machine_not_answering"}} =
               ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder") |> json_response(504)
    end

    test "it is not connected: 503 with when its copy can be explored until", ctx do
      Registry.unregister(Forge.Workers.Registry, ctx.worker.id)

      assert %{"error" => %{"reason" => "machine_not_connected", "explorable_until" => until}} =
               ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder") |> json_response(503)

      assert {:ok, _time, 0} = DateTime.from_iso8601(until)
    end

    test "it runs a release that cannot be asked: 409", ctx do
      {:ok, _} = Workers.update(ctx.worker, %{protocol: 17})

      assert %{"error" => %{"reason" => "machine_outdated"}} =
               ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder") |> json_response(409)
    end

    test "the copy is not on it: 404 copy_gone, replaced by the command that replaced it", ctx do
      later = kept!(ctx.ticket, ctx.worker, ago: 5)

      {conn, _} =
        asking(
          fn -> get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/folder") end,
          [%{"error" => "no_copy"}]
        )

      assert %{"error" => %{"reason" => "copy_gone", "why" => "replaced", "replaced_by" => by}} =
               json_response(conn, 404)

      assert by == later.id
    end

    test "a path that is not inside the copy is 400 and never reaches the machine", ctx do
      for path <- ["..", "a/../b", "/etc/passwd"] do
        assert %{"error" => %{"reason" => "path_refused"}} =
                 ctx.conn
                 |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder", %{"path" => path})
                 |> json_response(400)
      end

      refute_received {:explore, _, _, _}
    end

    test "path_b64 that is not base64 is a bad request", ctx do
      assert %{"error" => %{"reason" => "bad_request"}} =
               ctx.conn
               |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder", %{"path_b64" => "!!"})
               |> json_response(400)
    end
  end

  describe "a copy is reached only through its own ticket" do
    test "another ticket's copy and a made-up one are 404 and the same 404", ctx do
      theirs = kept!(ticket_fixture(), ctx.worker, [])

      answers =
        for id <- [theirs.id, Ecto.UUID.generate(), "nope"] do
          ctx.conn |> get(ctx.url <> "/builds/#{id}/folder") |> json_response(404)
        end

      assert [%{"error" => %{"reason" => "not_found"}}] = Enum.uniq(answers)
      refute_received {:explore, _, _, _}
    end

    test "someone outside the project finds no ticket", ctx do
      stranger = Accounts.create_api_token(user_fixture(), "stranger")

      for path <- ["/builds", "/builds/#{ctx.kept.id}/folder", "/builds/#{ctx.kept.id}/download"] do
        assert %{"error" => %{"reason" => "not_found"}} =
                 ctx.conn |> as(stranger) |> get(ctx.url <> path) |> json_response(404)
      end

      refute_received {:explore, _, _, _}
    end
  end

  describe "who may look" do
    test "a project token of read or write access may do all of it", ctx do
      for api <- [:read, :write] do
        {:ok, secret, _row} = Tokens.issue(ctx.project, name: "t-#{api}", git: :none, api: api)

        assert %{"builds" => [_]} =
                 ctx.conn |> as(secret) |> get(ctx.url <> "/builds") |> json_response(200)

        {conn, _} =
          asking(
            fn -> ctx.conn |> as(secret) |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder") end,
            [%{"ok" => %{"entries" => [], "total" => 0, "offset" => 0}}]
          )

        assert %{"entries" => []} = json_response(conn, 200)
      end
    end

    test "a running job's token is refused", ctx do
      [agent | _] = Forge.Jobs.for_ticket(ctx.ticket.id)
      {:ok, secret, _row} = Tokens.issue(ctx.project, job_id: agent.id)

      assert ctx.conn |> as(secret) |> get(ctx.url <> "/builds") |> json_response(401)

      assert ctx.conn
             |> as(secret)
             |> get(ctx.url <> "/builds/#{ctx.kept.id}/folder")
             |> json_response(401)
    end

    test "looking leaves no event", ctx do
      before = ctx.ticket.id |> Forge.Events.for_ticket() |> length()
      ctx.conn |> get(ctx.url <> "/builds") |> json_response(200)

      {_conn, _} =
        asking(
          fn -> get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/folder") end,
          [%{"ok" => %{"entries" => [], "total" => 0, "offset" => 0}}]
        )

      assert ctx.ticket.id |> Forge.Events.for_ticket() |> length() == before
    end
  end

  describe "a download" do
    # The machine's half: reads the `explore`, then POSTs the bytes to the door with the secret.
    defp serve(ctx, body, opts \\ []) do
      task =
        Task.async(fn ->
          get(
            ctx.conn,
            ctx.url <> "/builds/#{ctx.kept.id}/download?path=" <> Keyword.get(opts, :path, "")
          )
        end)

      assert_receive {:explore, ref, owner,
                      %{"op" => "download", "stream" => id, "secret" => secret}},
                     2_000

      door = fn secret ->
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer " <> secret)
        |> put_req_header("x-forge-kind", Keyword.get(opts, :kind, "tar"))
        |> put_req_header("x-forge-name-b64", Base.encode64(Keyword.get(opts, :name, "copy.tar")))
        |> put_req_header("content-type", "application/octet-stream")
        |> post("/worker-streams/#{id}", body)
      end

      {task, ref, owner, id, secret, door}
    end

    test "passes the machine's bytes through to the client, stored nowhere", ctx do
      body = :crypto.strong_rand_bytes(2_600_000)
      {task, ref, owner, _id, secret, door} = serve(ctx, body)

      assert %{status: 200} = door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => byte_size(body)}}})

      conn = Task.await(task)
      assert conn.status == 200
      assert conn.resp_body == body
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/x-tar"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ ~s(filename="copy.tar")
      assert get_resp_header(conn, "x-accel-buffering") == ["no"]
    end

    test "a file is sent as itself", ctx do
      {task, ref, owner, _id, secret, door} = serve(ctx, "hello", kind: "file", name: "a b.txt")
      door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 5}}})

      conn = Task.await(task)
      assert conn.resp_body == "hello"
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/octet-stream"
      assert get_resp_header(conn, "content-disposition") |> hd() =~ "a b.txt"
    end

    test "a name with a path or a quote in it cannot escape the header", ctx do
      {task, ref, owner, _id, secret, door} = serve(ctx, "x", name: ~s(../../a"b\r\nx: y))
      door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 1}}})

      [disposition] = Task.await(task) |> get_resp_header("content-disposition")
      refute disposition =~ "/"
      refute disposition =~ "\n"
      refute disposition =~ "\r"
      assert String.split(disposition, "\"") |> length() == 3
    end

    test "a wrong secret is 403 and the stream is still waiting for the right one", ctx do
      {task, ref, owner, _id, secret, door} = serve(ctx, "abc")

      assert %{status: 403} = door.("wrong-" <> secret)
      assert %{status: 200} = door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 3}}})
      assert Task.await(task).resp_body == "abc"
    end

    test "a stream is used once, and an unknown one is not there", ctx do
      {task, ref, owner, id, secret, door} = serve(ctx, "abc")
      assert %{status: 200} = door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 3}}})
      Task.await(task)

      assert %{status: 404} = door.(secret)

      assert %{status: 404} =
               Phoenix.ConnTest.build_conn()
               |> put_req_header("authorization", "Bearer " <> secret)
               |> put_req_header("content-type", "application/octet-stream")
               |> post("/worker-streams/#{id}x", "abc")
    end

    test "a stream is forgotten when its download ends, not when the process that served it does",
         ctx do
      # A connection serves one request after another, so the process outlives the download; an id
      # left registered until it dies would stay open to whoever holds the secret.
      me = self()
      url = ctx.url <> "/builds/#{ctx.kept.id}/download"

      server =
        spawn_link(fn ->
          send(me, {:served, get(ctx.conn, url)})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:explore, ref, owner,
                      %{"op" => "download", "stream" => id, "secret" => secret}},
                     2_000

      assert owner == server
      assert [_registered] = Registry.lookup(Forge.Explore.streams(), id)

      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> secret)
      |> put_req_header("x-forge-kind", "file")
      |> put_req_header("content-type", "application/octet-stream")
      |> post("/worker-streams/#{id}", "abc")

      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 3}}})
      assert_receive {:served, %{status: 200}}, 2_000

      assert Process.alive?(server)
      assert Registry.lookup(Forge.Explore.streams(), id) == []
      send(server, :stop)
    end

    test "with no bearer at all it is 403", ctx do
      {task, ref, owner, id, secret, door} = serve(ctx, "abc")

      assert %{status: 403} =
               Phoenix.ConnTest.build_conn()
               |> put_req_header("content-type", "application/octet-stream")
               |> post("/worker-streams/#{id}", "abc")

      door.(secret)
      send(owner, {:explored, ref, %{"ok" => %{"bytes" => 3}}})
      Task.await(task)
    end

    test "a machine that cannot start is the API's refusal, with the copy untouched", ctx do
      task =
        Task.async(fn ->
          get(ctx.conn, ctx.url <> "/builds/#{ctx.kept.id}/download?path=gone")
        end)

      assert_receive {:explore, ref, owner, %{"op" => "download"}}, 2_000
      send(owner, {:explored, ref, %{"error" => "path_not_found"}})

      assert %{"error" => %{"reason" => "path_not_found"}} =
               task |> Task.await() |> json_response(404)
    end

    test "a download the machine never answers is 504, whatever the bytes did", ctx do
      previous = Application.get_env(:forge, :explore_answer_ms)
      Application.put_env(:forge, :explore_answer_ms, 30)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:forge, :explore_answer_ms, previous),
          else: Application.delete_env(:forge, :explore_answer_ms)
      end)

      assert %{"error" => %{"reason" => "machine_not_answering"}} =
               ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/download") |> json_response(504)
    end

    test "not connected, outdated and silent give their codes", ctx do
      {:ok, outdated} = Workers.update(ctx.worker, %{protocol: 17})
      assert ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/download") |> json_response(409)

      {:ok, _} = Workers.update(outdated, %{protocol: ForgeCore.WorkerProtocol.current()})
      Registry.unregister(Forge.Workers.Registry, ctx.worker.id)
      assert ctx.conn |> get(ctx.url <> "/builds/#{ctx.kept.id}/download") |> json_response(503)
    end

    test "a path with .. is refused before the machine is asked", ctx do
      assert %{"error" => %{"reason" => "path_refused"}} =
               ctx.conn
               |> get(ctx.url <> "/builds/#{ctx.kept.id}/download?path=../x")
               |> json_response(400)

      refute_received {:explore, _, _, _}
    end
  end

  describe "a command's log with its times" do
    setup ctx do
      assignment = FakeWorker.assign(ctx.build, ctx.worker)

      {:ok, _job} =
        FakeWorker.finish_command(assignment, 0,
          log: "one\ntwo\nthree\n",
          times: "0\n1500\n42000\n"
        )

      %{log_url: ctx.url <> "/jobs/#{ctx.build.id}/log"}
    end

    test "is the log exactly as it is, without times", ctx do
      conn = get(ctx.conn, ctx.log_url)
      assert response(conn, 200) == "one\ntwo\nthree\n"
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end

    test "with times has each line behind its milliseconds and a tab", ctx do
      assert ctx.conn |> get(ctx.log_url <> "?times=true") |> response(200) ==
               "0\tone\n1500\ttwo\n42000\tthree\n"
    end

    test "a command that kept no times shows the lines with the time left empty", ctx do
      other = FakeWorker.assign(Enum.at(ctx.commands, 1), ctx.worker)
      {:ok, _} = FakeWorker.finish_command(other, 0, log: "a\n")

      assert ctx.conn
             |> get(ctx.url <> "/jobs/#{other["job_id"]}/log?times=true")
             |> response(200) == "\ta\n"
    end

    test "is only for a command of this ticket", ctx do
      assert ctx.conn |> get(ctx.url <> "/jobs/#{Ecto.UUID.generate()}/log") |> json_response(404)
    end

    test "carries its steps in the command", ctx do
      assert %{"commands" => commands} = ctx.conn |> get(ctx.url) |> json_response(200)
      command = Enum.find(commands, &(&1["id"] == ctx.build.id))
      assert Map.has_key?(command, "steps") and Map.has_key?(command, "steps_unrecorded")
      assert command["steps_unrecorded"] == "before"
    end
  end

  describe "over MCP" do
    setup ctx do
      {:ok, secret, _row} = Tokens.issue(ctx.project, name: "agent", git: :none, api: :read)
      %{secret: secret}
    end

    defp mcp(conn, secret, name, args) do
      conn
      |> put_req_header("content-type", "application/json")
      |> as(secret)
      |> post("/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      })
      |> json_response(200)
      |> get_in(["result"])
    end

    test "a read token lists the builds and reads a folder", ctx do
      args = %{"project" => ctx.project.name, "number" => ctx.ticket.number}

      assert %{"isError" => false, "structuredContent" => %{"builds" => [%{"job_id" => id}]}} =
               mcp(ctx.conn, ctx.secret, "list_builds", args)

      assert id == ctx.kept.id

      folder = Map.put(args, "job_id", ctx.kept.id)

      {result, _} =
        asking(
          fn -> mcp(ctx.conn, ctx.secret, "list_build_folder", folder) end,
          [%{"ok" => %{"entries" => [], "total" => 0, "offset" => 0}}]
        )

      assert %{"isError" => false, "structuredContent" => %{"entries" => []}} = result
    end

    test "a file's facts, hash and text come in one answer, and a binary one has no text", ctx do
      args = %{
        "project" => ctx.project.name,
        "number" => ctx.ticket.number,
        "job_id" => ctx.kept.id,
        "path" => "a"
      }

      facts = %{
        "kind" => "file",
        "size" => 2,
        "text" => true,
        "content_b64" => Base.encode64("hi"),
        "truncated" => false
      }

      {result, _} =
        asking(
          fn -> mcp(ctx.conn, ctx.secret, "read_build_file", args) end,
          [%{"ok" => facts}, %{"ok" => %{"sha256" => String.duplicate("c", 64), "size" => 2}}]
        )

      assert %{"isError" => false, "structuredContent" => %{"content" => "hi", "sha256" => sha}} =
               result

      assert sha == String.duplicate("c", 64)

      {binary, _} =
        asking(
          fn -> mcp(ctx.conn, ctx.secret, "read_build_file", args) end,
          [
            %{"ok" => %{"kind" => "file", "size" => 2, "text" => false}},
            %{"ok" => %{"sha256" => String.duplicate("d", 64)}}
          ]
        )

      assert %{"isError" => false, "structuredContent" => %{"content" => nil}} = binary
    end

    test "a download is an address to fetch and not a stream", ctx do
      args = %{
        "project" => ctx.project.name,
        "number" => ctx.ticket.number,
        "job_id" => ctx.kept.id
      }

      assert %{"isError" => false, "structuredContent" => %{"url" => url, "note" => note}} =
               mcp(ctx.conn, ctx.secret, "download_build", args)

      assert url =~
               "/api/v1/tickets/#{ctx.project.name}/#{ctx.ticket.number}/builds/#{ctx.kept.id}/download"

      assert note =~ "your own token"
    end

    test "a copy of another ticket is the not found of a ticket that is not there", ctx do
      theirs = kept!(ticket_fixture(), ctx.worker, [])

      args = %{
        "project" => ctx.project.name,
        "number" => ctx.ticket.number,
        "job_id" => theirs.id
      }

      assert %{"isError" => true, "structuredContent" => %{"error" => %{"reason" => "not_found"}}} =
               mcp(ctx.conn, ctx.secret, "list_build_folder", args)
    end

    test "a command's steps", ctx do
      Forge.BuildFixtures.record_steps(ctx.build, [%{"name" => "script", "at" => 1, "ms" => 5}])

      args = %{
        "project" => ctx.project.name,
        "number" => ctx.ticket.number,
        "job_id" => ctx.build.id
      }

      assert %{
               "isError" => false,
               "structuredContent" => %{"steps" => [%{"name" => "script", "ms" => 5}]}
             } =
               mcp(ctx.conn, ctx.secret, "get_command_steps", args)
    end
  end
end
