defmodule ForgeWeb.Api.ProjectTokenTest do
  @moduledoc """
  A project token on the JSON API: what it reads, what it may write and as whom, and every way it
  is refused. `docs/design/api-and-ui.md` § JSON API, `docs/design/git-hosting.md` § One project
  token, two doors.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Events, Projects, Repo, Storage, Tickets}
  alias Forge.Git.{Token, Tokens}

  setup %{conn: conn} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    owner = user_fixture()
    {:ok, project} = Projects.register(%{name: "tok-#{n()}", repo_path: seeded_repo()}, owner)
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, owner.id})

    %{conn: conn, owner: owner, project: project, ticket: ticket}
  end

  # As the worker's results are recorded: the hash is the store's own (`Forge.Jobs.Blobs`), and
  # it is `sha256:` of the bytes, which is what makes the listing checkable by a client.
  defp stored_hash(key, bytes) do
    {:ok, %{hash: hash}} = Storage.stat(key)
    assert hash == Storage.hash(bytes)
    hash
  end

  defp n, do: System.unique_integer([:positive])

  defp token!(project, opts \\ []) do
    {:ok, secret, row} =
      Tokens.issue(project, Keyword.merge([name: "ci", git: :reader, api: :read], opts))

    {secret, row}
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp ticket_path(project, ticket, tail),
    do: "/api/v1/tickets/#{project.name}/#{ticket.number}#{tail}"

  describe "who gets in" do
    test "a read token lists its project's tickets with no project argument", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _row} = token!(project)

      assert %{"tickets" => [%{"number" => number}]} =
               conn |> as(secret) |> get("/api/v1/tickets") |> json_response(200)

      assert number == ticket.number
    end

    test "every way of not being let in is the same 401", %{conn: conn, project: project} do
      {none, _} = token!(project, api: :none)
      {revoked, row} = token!(project)
      {expired, expired_row} = token!(project)
      {:ok, _} = Tokens.revoke(row.id)
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)
      Repo.update!(Ecto.Changeset.change(expired_row, expires_at: past))

      bodies =
        for secret <- [none, revoked, expired, "nonsense", Base.url_encode64("x", padding: false)] do
          conn |> as(secret) |> get("/api/v1/tickets") |> json_response(401)
        end

      assert [one] = Enum.uniq(bodies)
      assert one["error"]["reason"] == "unauthorized"
    end

    # The mutation that matters: drop `nil <- token.job_id` from `authenticate_api/1` and force
    # the row past the changeset, which refuses the same thing for its own reason.
    test "a job's token never reaches the API, whatever it is made to hold", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      [job | _] = Forge.Jobs.for_ticket(ticket.id)

      {:ok, secret, row} =
        Tokens.issue(project, job_id: job.id, ref: "refs/heads/" <> ticket.branch)

      Repo.update!(Ecto.Changeset.change(row, api_access: :write))

      assert conn |> as(secret) |> get("/api/v1/tickets") |> json_response(401)
      assert conn |> as(secret) |> get("/api/v1/me") |> json_response(401)
    end

    test "the changeset refuses a job's token that opens the API", %{project: project, ticket: t} do
      [job | _] = Forge.Jobs.for_ticket(t.id)

      assert {:error, changeset} =
               Tokens.issue(project, job_id: job.id, ref: "refs/heads/ticket/1", api: :read)

      assert [_] = Keyword.get_values(changeset.errors, :api_access)
    end

    test "a git use marks it used via git", ctx do
      %{project: project} = ctx
      {secret, row} = token!(project)
      assert {:ok, _} = Tokens.authorise(secret, project, :read)
      flush_touch()

      assert %Token{last_used_via: :git, last_used_at: %DateTime{}} = Repo.get!(Token, row.id)
    end

    test "using the token marks it used, and by which door", ctx do
      %{conn: conn, project: project} = ctx
      {secret, row} = token!(project)
      conn |> as(secret) |> get("/api/v1/tickets") |> json_response(200)
      flush_touch()

      assert %Token{last_used_via: :api, last_used_at: %DateTime{}} = Repo.get!(Token, row.id)
    end

    # The archive is a third door on a job's token (`docs/design/archive.md`), and the row says so
    # rather than passing an archive read off as a fetch.
    test "an archive read marks a job's token used via the archive", ctx do
      %{project: project, ticket: ticket} = ctx
      [job | _] = Forge.Jobs.for_ticket(ticket.id)
      {:ok, secret, row} = Tokens.issue(project, job_id: job.id)
      assert {:ok, _} = Tokens.authorise_job(secret)
      flush_touch()

      assert %Token{last_used_via: :archive, last_used_at: %DateTime{}} =
               Repo.get!(Token, row.id)
    end

    test "/me describes the token and not a person", %{conn: conn, project: project} do
      {secret, row} = token!(project, name: "dashboard")

      assert %{
               "token" => %{"id" => id, "name" => "dashboard", "git" => "reader", "api" => "read"}
             } =
               conn |> as(secret) |> get("/api/v1/me") |> json_response(200)

      assert id == row.id
    end
  end

  describe "one project and no other" do
    test "another project answers exactly as one that does not exist", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _} = token!(project, api: :write)
      other_owner = user_fixture()

      {:ok, other} =
        Projects.register(%{name: "oth-#{n()}", repo_path: seeded_repo()}, other_owner)

      {:ok, theirs} = Tickets.admit(other, %{title: "Theirs"}, {:user, other_owner.id})

      missing = conn |> as(secret) |> get("/api/v1/tickets/nowhere/1") |> json_response(404)

      for url <- [
            "/api/v1/tickets/#{other.name}/#{theirs.number}",
            "/api/v1/tickets/#{other.name}/#{theirs.number}/artifacts",
            "/api/v1/tickets/#{other.name}/#{theirs.number}/artifacts/ticket/1/raw",
            "/api/v1/tickets/#{other.name}/#{theirs.number}/events"
          ] do
        assert conn |> as(secret) |> get(url) |> json_response(404) |> Map.put("error", nil) ==
                 Map.put(missing, "error", nil)
      end

      assert %{"error" => %{"reason" => "not_found"}} =
               conn
               |> as(secret)
               |> get("/api/v1/tickets?project=#{other.name}")
               |> json_response(404)

      # A write into the other project is refused as a missing project, not as forbidden.
      assert conn
             |> as(secret)
             |> post("/api/v1/projects/#{other.name}/tickets", %{"title" => "Sneak"})
             |> json_response(404)

      assert Tickets.list(other) |> length() == 1
      assert ticket.project_id == project.id
    end
  end

  describe "tickets by state and openness" do
    test "state and open filters combine, cancelled stay hidden", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {:ok, second} = Tickets.admit(project, %{title: "Second"}, {:user, owner.id})
      {:ok, third} = Tickets.admit(project, %{title: "Third"}, {:user, owner.id})
      Repo.update!(Ecto.Changeset.change(second, status: :done, state: "elsewhere"))
      Repo.update!(Ecto.Changeset.change(third, status: :cancelled))
      {secret, _} = token!(project)

      numbers = fn query ->
        %{"tickets" => tickets} =
          conn |> as(secret) |> get("/api/v1/tickets" <> query) |> json_response(200)

        tickets |> Enum.map(& &1["number"]) |> Enum.sort()
      end

      assert numbers.("") == [ticket.number, second.number]
      assert numbers.("?open=true") == [ticket.number]
      assert numbers.("?state=elsewhere") == [second.number]
      assert numbers.("?state=elsewhere&open=true") == []
      assert numbers.("?state=#{ticket.state}&open=true") == [ticket.number]
      assert numbers.("?state=no-such-state") == []
    end
  end

  describe "a filter that is not a state name" do
    test "lists nothing, never everything and never a 500", ctx do
      %{conn: conn, project: project} = ctx
      {secret, _} = token!(project)

      for query <- ["?state=%00", "?state[]=x", "?state[a]=b"] do
        assert %{"tickets" => []} =
                 conn |> as(secret) |> get("/api/v1/tickets" <> query) |> json_response(200),
               query
      end

      # `open` is true or it is no filter, so a false asks for everything.
      {:ok, done} = Tickets.admit(project, %{title: "Done"}, :system)
      Repo.update!(Ecto.Changeset.change(done, status: :done))

      assert %{"tickets" => [_, _]} =
               conn |> as(secret) |> get("/api/v1/tickets?open=false") |> json_response(200)

      assert %{"tickets" => [_]} =
               conn |> as(secret) |> get("/api/v1/tickets?open=true") |> json_response(200)
    end
  end

  describe "the address of a version" do
    test "bytes that are not UTF-8 in a name, and a ticket number past an integer, are 404",
         ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _} = token!(project)

      assert conn
             |> as(secret)
             |> get(ticket_path(project, ticket, "/artifacts/doc%FF.md/1/raw"))
             |> json_response(404)

      assert conn
             |> as(secret)
             |> get("/api/v1/tickets/#{project.name}/2147483648")
             |> json_response(404)

      assert conn
             |> as(secret)
             |> get("/api/v1/tickets/#{project.name}/99999999999999999999")
             |> json_response(404)
    end
  end

  describe "artifacts and their versions" do
    test "every version of every artifact is listed, with how to fetch it", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      author = {:user, owner.id}
      write = &Artifacts.record_version(ticket.id, "notes.md", :document, author, %{content: &1})
      for i <- 1..120, do: {:ok, _} = write.("note #{i}")

      key = "job/#{Ecto.UUID.generate()}/out-a/pkg"
      {:ok, _} = Storage.put(key, "bytes")

      {:ok, _} =
        Artifacts.record_version(ticket.id, "pkg", :blob, author, %{blob_uri: Storage.uri(key)})

      {:ok, _} =
        Artifacts.record_version(ticket.id, "changeset", :blob, author, %{
          blob_uri: "git:" <> String.duplicate("a", 40)
        })

      {secret, _} = token!(project)

      %{"artifacts" => artifacts} =
        conn
        |> as(secret)
        |> get(ticket_path(project, ticket, "/artifacts"))
        |> json_response(200)

      by_name = Map.new(artifacts, &{&1["name"], &1})
      notes = by_name["notes.md"]
      assert length(notes["versions"]) == 120
      assert Enum.map(notes["versions"], & &1["number"]) == Enum.to_list(1..120)
      assert Enum.all?(notes["versions"], &(&1["form"] == "text"))
      assert hd(notes["versions"])["author"] == %{"kind" => "user", "id" => owner.id}

      assert %{"content_hash" => "sha256:" <> _, "id" => _, "inserted_at" => _} =
               hd(notes["versions"])

      assert [%{"form" => "file"}] = by_name["pkg"]["versions"]
      assert [%{"form" => "commit"}] = by_name["changeset"]["versions"]
    end

    test "the bytes received are the bytes the listed hash names", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      author = {:user, owner.id}
      {secret, _} = token!(project)
      leftovers = Path.wildcard(Path.join(System.tmp_dir!(), "plug-*/forge-download-*"))

      big = String.duplicate("a", ForgeCore.Document.max_bytes() + 1)
      small_bin = <<137, 80, 78, 71, 0, 1, 2>>

      blobs = %{"big" => big, "small.bin" => small_bin, "group/inner.bin" => small_bin <> "x"}

      for {name, bytes} <- blobs do
        key = "job/#{Ecto.UUID.generate()}/out-a/#{Path.basename(name)}"
        {:ok, _} = Storage.put(key, bytes)

        {:ok, _} =
          Artifacts.record_version(ticket.id, name, :blob, author, %{
            blob_uri: Storage.uri(key),
            content_hash: stored_hash(key, bytes)
          })
      end

      {:ok, _} =
        Artifacts.record_version(ticket.id, "doc.md", :document, author, %{content: "# hi\n"})

      %{"artifacts" => artifacts} =
        conn
        |> as(secret)
        |> get(ticket_path(project, ticket, "/artifacts"))
        |> json_response(200)

      expected = Map.put(blobs, "doc.md", "# hi\n")

      for %{"name" => name, "versions" => [version]} <- artifacts, bytes = expected[name] do
        url = ticket_path(project, ticket, "/artifacts/#{URI.encode_www_form(name)}/1/raw")
        response = conn |> as(secret) |> get(url)

        assert response(response, 200) == bytes
        assert version["content_hash"] == Storage.hash(bytes)
        assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
      end

      assert Path.wildcard(Path.join(System.tmp_dir!(), "plug-*/forge-download-*")) -- leftovers ==
               []
    end

    test "a blob whose bytes are gone is a 404 and leaves no temporary file behind", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, _} = token!(project)
      leftovers = Path.wildcard(Path.join(System.tmp_dir!(), "plug-*/forge-download-*"))

      {:ok, _} =
        Artifacts.record_version(ticket.id, "lost", :blob, {:user, owner.id}, %{
          blob_uri: Storage.uri("job/#{Ecto.UUID.generate()}/out-a/lost")
        })

      assert conn
             |> as(secret)
             |> get(ticket_path(project, ticket, "/artifacts/lost/1/raw"))
             |> json_response(404)

      assert Path.wildcard(Path.join(System.tmp_dir!(), "plug-*/forge-download-*")) -- leftovers ==
               []
    end

    test "text is inline and a file is an attachment of a type nothing executes", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, _} = token!(project)
      author = {:user, owner.id}

      {:ok, _} =
        Artifacts.record_version(ticket.id, "page.html", :document, author, %{
          content: "<script>alert(1)</script>"
        })

      response =
        conn |> as(secret) |> get(ticket_path(project, ticket, "/artifacts/page.html/1/raw"))

      assert ["text/plain; charset=utf-8"] = get_resp_header(response, "content-type")

      assert [~s(inline; filename="page-v1.html")] =
               get_resp_header(response, "content-disposition")
    end

    test "a commit is 422 and says where the diff is", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, _} = token!(project)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "changeset", :blob, {:user, owner.id}, %{
          blob_uri: "git:" <> String.duplicate("a", 40)
        })

      assert %{"error" => %{"reason" => "not_a_file", "detail" => detail}} =
               conn
               |> as(secret)
               |> get(ticket_path(project, ticket, "/artifacts/changeset/1/raw"))
               |> json_response(422)

      assert detail =~ "/review"
    end

    test "a version that is not there is one 404, however it is not there", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, _} = token!(project)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "doc.md", :document, {:user, owner.id}, %{
          content: "x"
        })

      bodies =
        for tail <- [
              "/artifacts/doc.md/2/raw",
              "/artifacts/doc.md/0/raw",
              "/artifacts/doc.md/-1/raw",
              "/artifacts/doc.md/one/raw",
              "/artifacts/doc.md/1abc/raw",
              "/artifacts/nothing/1/raw",
              "/artifacts/..%2F..%2Fetc%2Fpasswd/1/raw",
              "/artifacts/#{String.duplicate("a", 5000)}/1/raw",
              "/artifacts/doc%00.md/1/raw"
            ] do
          conn |> as(secret) |> get(ticket_path(project, ticket, tail)) |> json_response(404)
        end

      assert Enum.uniq(bodies) |> length() == 1
    end
  end

  describe "every route, by its class" do
    # Drives `ForgeWeb.TokenRoutes.all/0`, so a route added with the wrong
    # class, or a plug dropped from one, is a failing request rather than a line in a table.
    defp fill(path, project, ticket) do
      path
      |> String.replace(":project", project.name)
      |> String.replace(":number", to_string(ticket.number))
      |> String.replace(":name", "doc.md")
      |> String.replace(":version_id", Ecto.UUID.generate())
      |> String.replace(":version", "1")
      |> String.replace(":job_id", Ecto.UUID.generate())
    end

    defp call(conn, verb, url),
      do: Phoenix.ConnTest.dispatch(conn, ForgeWeb.Endpoint, verb, url, %{})

    test "a read token is refused every write with 403, ticket or no ticket", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _} = token!(project, api: :read)

      for {{verb, path}, :token_write} <- ForgeWeb.TokenRoutes.all() do
        for target <- [ticket, %{number: 424_242}] do
          assert %{"error" => %{"reason" => "forbidden"}} =
                   conn
                   |> as(secret)
                   |> call(verb, fill(path, project, target))
                   |> json_response(403)
        end
      end
    end

    test "no token, even a write one, gets what is a person's", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _} = token!(project, api: :write)

      for {{verb, path}, :token_never} <- ForgeWeb.TokenRoutes.all() do
        assert conn |> as(secret) |> call(verb, fill(path, project, ticket)) |> json_response(403)
      end
    end

    test "another project's write token finds nothing, with a missing ticket's body", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      other_owner = user_fixture()

      {:ok, other} =
        Projects.register(%{name: "oth-#{n()}", repo_path: seeded_repo()}, other_owner)

      {secret, _} = token!(other, api: :write)

      missing =
        conn |> as(secret) |> get("/api/v1/tickets/#{other.name}/99999") |> json_response(404)

      for {{verb, path}, class} <- ForgeWeb.TokenRoutes.all(),
          class in [:token_read, :token_write],
          String.contains?(path, ":number") do
        response = conn |> as(secret) |> call(verb, fill(path, project, ticket))

        assert json_response(response, 404)["error"]["reason"] == missing["error"]["reason"],
               "#{verb} #{path}"
      end
    end
  end

  describe "writing" do
    test "a read token is refused before the ticket is looked up", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {secret, _} = token!(project, api: :read)

      for {url, body} <- [
            {ticket_path(project, ticket, "/artifacts/doc.md"), %{"content" => "x"}},
            {ticket_path(project, ticket, "/cancel"), %{}},
            {ticket_path(project, %{number: 9999}, "/cancel"), %{}},
            {"/api/v1/projects/#{project.name}/tickets", %{"title" => "x"}},
            {"/api/v1/proposals/#{Ecto.UUID.generate()}/accept", %{}}
          ] do
        assert %{"error" => %{"reason" => "forbidden"}} =
                 conn |> as(secret) |> post(url, body) |> json_response(403)
      end

      assert Tickets.list(project) |> length() == 1
    end

    test "a write token does what a member can, authored by API and never by its issuer", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, token} = token!(project, api: :write, name: "release-bot", issued_by_id: owner.id)

      assert %{"ref" => ref} =
               conn
               |> as(secret)
               |> post("/api/v1/projects/#{project.name}/tickets", %{"title" => "By API"})
               |> json_response(201)

      [_, number] = String.split(ref, "#")
      admitted = Tickets.get_by_number!(project, String.to_integer(number))

      assert conn
             |> as(secret)
             |> post(ticket_path(project, ticket, "/artifacts/ticket"), %{"content" => "# New\n"})
             |> json_response(200)

      assert conn
             |> as(secret)
             |> post(ticket_path(project, ticket, "/cancel"), %{})
             |> json_response(200)

      assert conn
             |> as(secret)
             |> post(ticket_path(project, ticket, "/restore"), %{})
             |> json_response(200)

      api = %{"kind" => "api", "id" => token.id, "name" => "release-bot"}
      assert Artifacts.latest(ticket.id, "ticket").author == api
      assert Artifacts.latest(admitted.id, "ticket").author == api

      actors = ticket.id |> Events.for_ticket() |> Enum.map(&{&1.type, &1.actor})
      assert {"ticket.cancelled", api} in actors
      assert {"ticket.restored", api} in actors
      assert {"artifact.version_written", api} in actors

      refute Enum.any?(actors, fn {_type, actor} ->
               actor["id"] == owner.id and actor["kind"] == "api"
             end)

      # Revoked since, it reads the same: the name travelled with the event.
      {:ok, _} = Tokens.revoke(token.id)
      assert Enum.any?(Events.for_ticket(ticket.id), &(&1.actor == api))
    end

    test "answers, approvals and proposal decisions carry the token and not a user", ctx do
      %{conn: conn, project: project, ticket: ticket, owner: owner} = ctx
      {secret, token} = token!(project, api: :write, name: "answerer")

      {:ok, version} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content: """
          # Plan

          ```question
          key: naming
          text: What is the table called?
          options: [{label: scores, detail: About scores}]
          blocking: false
          assumption: scores
          ```
          """
        })

      assert conn
             |> as(secret)
             |> post(ticket_path(project, ticket, "/answers"), %{
               "key" => "naming",
               "choice" => "scores"
             })
             |> json_response(200)

      assert [%{answer: answer, token_name: "answerer"}] = Artifacts.answered(ticket.id)
      assert answer.token_id == token.id
      assert answer.user_id == nil

      {:ok, approval} =
        Artifacts.put_approval(
          Ecto.Multi.new(),
          :a,
          version,
          {:api, token.id, "answerer"},
          :approved,
          %{"from" => "a", "to" => "b"},
          nil
        )
        |> Repo.transaction()
        |> then(fn {:ok, %{a: a}} -> {:ok, a} end)

      assert approval.token_id == token.id and approval.user_id == nil
      refute owner.id in [answer.user_id, approval.user_id]
    end

    test "a person's tokens-only routes are never a token's", %{conn: conn, project: project} do
      {secret, _} = token!(project, api: :write)

      for {verb, url} <- [{:post, "/api/v1/projects"}, {:get, "/api/v1/queue"}] do
        assert %{"error" => %{"reason" => "forbidden"}} =
                 conn |> as(secret) |> dispatch_to(verb, url) |> json_response(403)
      end
    end
  end

  defp dispatch_to(conn, :get, url), do: get(conn, url)
  defp dispatch_to(conn, :post, url), do: post(conn, url, %{"name" => "grab"})

  # Last-used is stamped off the request path, so wait for it rather than sleep.
  defp flush_touch do
    Task.Supervisor.children(Forge.TaskSupervisor)
    |> Enum.each(fn pid ->
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        2000 -> :ok
      end
    end)
  end
end
