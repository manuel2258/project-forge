defmodule ForgeWeb.ArchiveControllerTest do
  @moduledoc """
  The worker's door to the project's archive (`docs/design/archive.md` § The door and its grant).

  Every guard has the test that fails without it: the project the token was minted for is the only
  one asked about, the grant ends with the job, an operator's token is not a job's, and nothing
  but a `GET` is routed.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Artifacts, Events, Repo, Storage}
  alias Forge.Git.{Token, Tokens}

  setup do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-archive-door-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      File.rm_rf!(dir)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 1})
    job = job_fixture(%{ticket: ticket})
    {:ok, secret, row} = Tokens.issue_for_job(job, ticket, project)

    %{project: project, ticket: ticket, job: job, secret: secret, row: row}
  end

  defp document!(ticket, name, content) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :document, {:user, Ecto.UUID.generate()}, %{
        content: content,
        parse: false
      })

    version
  end

  defp blob!(ticket, name, bytes) do
    key = "archive-door/#{System.unique_integer([:positive])}"
    {:ok, %{hash: hash}} = Storage.put(key, bytes)

    {:ok, version} =
      Artifacts.record_version(ticket.id, name, :blob, {:user, Ecto.UUID.generate()}, %{
        blob_uri: Storage.uri(key),
        content_hash: hash
      })

    version
  end

  # How many files the download folder holds; there is no folder until the first large download.
  defp leftovers(dir) do
    case File.ls(dir) do
      {:ok, names} -> length(names)
      {:error, :enoent} -> 0
    end
  end

  defp door(conn, secret, path) do
    conn
    |> put_req_header("authorization", "Bearer " <> secret)
    |> get(path)
  end

  describe "who may ask" do
    test "a job with its own token may", %{conn: conn, secret: secret} do
      assert %{"tickets" => [1]} = conn |> door(secret, "/archive") |> json_response(200)
    end

    test "nobody without one, whatever they send", %{conn: conn, secret: secret} do
      for conn <- [
            conn,
            put_req_header(conn, "authorization", "Bearer"),
            put_req_header(conn, "authorization", "Bearer "),
            put_req_header(conn, "authorization", "Bearer not-a-token"),
            put_req_header(conn, "authorization", "Bearer " <> String.duplicate("A", 43)),
            put_req_header(conn, "authorization", "Basic " <> secret),
            put_req_header(conn, "authorization", secret)
          ] do
        assert conn |> get("/archive") |> json_response(401)
      end
    end

    test "the token is a header and never the query string", %{conn: conn, secret: secret} do
      assert conn |> get("/archive?token=#{secret}") |> json_response(401)
    end

    test "not once the job has ended", %{conn: conn, job: job, secret: secret} do
      assert conn |> door(secret, "/archive") |> json_response(200)

      Tokens.revoke_for_job(job.id)

      assert conn |> door(secret, "/archive") |> json_response(401)
      assert conn |> door(secret, "/archive/tickets/1") |> json_response(401)
    end

    test "not once the grant has expired", %{conn: conn, row: row, secret: secret} do
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)
      Repo.update!(Ecto.Changeset.change(row, expires_at: past))

      assert conn |> door(secret, "/archive") |> json_response(401)
    end

    test "not with a token that holds no job, which is an operator's", %{
      conn: conn,
      project: project
    } do
      {:ok, secret, %Token{job_id: nil}} = Tokens.issue(project, name: "operator")

      assert conn |> door(secret, "/archive") |> json_response(401)
    end

    test "each job's token is for its own project's tickets and no other's", %{
      conn: conn,
      secret: secret
    } do
      other = project_fixture()
      other_ticket = ticket_fixture(%{project: other, number: 5})
      other_job = job_fixture(%{ticket: other_ticket})
      {:ok, other_secret, _row} = Tokens.issue_for_job(other_job, other_ticket, other)

      assert %{"tickets" => [1]} = conn |> door(secret, "/archive") |> json_response(200)
      assert %{"tickets" => [5]} = conn |> door(other_secret, "/archive") |> json_response(200)
      assert conn |> door(secret, "/archive/tickets/5") |> json_response(404)
      assert conn |> door(other_secret, "/archive/tickets/1") |> json_response(404)
    end
  end

  describe "what is listed and served" do
    test "a ticket's listing, and a version's bytes exactly as stored", %{
      conn: conn,
      ticket: ticket,
      secret: secret
    } do
      binary = <<0, 255, 254, "text", 0, 128>>
      document!(ticket, "plan.md", "# Plan\n")
      blob = blob!(ticket, "reports/out.bin", binary)

      assert %{"files" => files} =
               conn |> door(secret, "/archive/tickets/1") |> json_response(200)

      assert Enum.any?(files, &(&1["path"] == "plan.md"))

      conn = door(conn, secret, "/archive/tickets/1/#{blob.id}")
      assert response(conn, 200) == binary
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "a file too large to hold in a response is sent from disk, and the copy goes",
         %{conn: conn, ticket: ticket, secret: secret} do
      big = :binary.copy("0123456789", div(ForgeCore.Document.max_bytes(), 10) + 10)
      blob = blob!(ticket, "big.log", big)

      downloads = Path.join(System.tmp_dir!(), "forge-download")
      before = leftovers(downloads)

      conn = door(conn, secret, "/archive/tickets/1/#{blob.id}")
      assert byte_size(response(conn, 200)) == byte_size(big)
      assert response(conn, 200) == big

      # The copy fetched for this response is gone once it is sent.
      assert leftovers(downloads) == before
    end

    test "a document is bytes too, with no markup added", %{
      conn: conn,
      ticket: ticket,
      secret: secret
    } do
      version = document!(ticket, "plan.md", "<script>alert(1)</script>")

      conn = door(conn, secret, "/archive/tickets/1/#{version.id}")
      assert response(conn, 200) == "<script>alert(1)</script>"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end
  end

  describe "what is another project's" do
    setup %{conn: conn} do
      other = project_fixture()
      other_ticket = ticket_fixture(%{project: other, number: 9})
      theirs = document!(other_ticket, "secret.md", "B's secret")
      %{conn: conn, theirs: theirs}
    end

    test "is not found by its ticket number or its version id, and says what a missing one does",
         %{conn: conn, secret: secret, theirs: theirs, ticket: ticket} do
      mine = document!(ticket, "plan.md", "mine")
      missing = Ecto.UUID.generate()

      foreign = conn |> door(secret, "/archive/tickets/9") |> json_response(404)
      nothing = conn |> door(secret, "/archive/tickets/77") |> json_response(404)
      assert foreign == nothing

      for path <- [
            "/archive/tickets/9/#{theirs.id}",
            "/archive/tickets/1/#{theirs.id}",
            "/archive/tickets/1/#{missing}"
          ] do
        assert conn |> door(secret, path) |> json_response(404) == foreign
      end

      # The same call for a version that is the job's own works, so the 404 is the scope and not
      # the shape of the path.
      assert conn |> door(secret, "/archive/tickets/1/#{mine.id}") |> response(200) == "mine"
    end

    test "is not found by any path trick", %{conn: conn, secret: secret, theirs: theirs} do
      for path <- [
            "/archive/tickets/..",
            "/archive/tickets/1/..",
            "/archive/tickets/1/%2E%2E",
            "/archive/tickets/9%2F#{theirs.id}",
            "/archive/tickets/1/x%2F..%2F#{theirs.id}",
            "/archive/tickets/abc",
            "/archive/tickets/1/not-a-uuid",
            "/archive/tickets/0"
          ] do
        conn = door(conn, secret, path)
        assert conn.status in [400, 404], path
        refute conn.resp_body =~ "B's secret"
      end
    end
  end

  describe "what is recorded" do
    test "a content read is one event per version, and a listing none",
         %{conn: conn, job: job, ticket: ticket, secret: secret} do
      version = document!(ticket, "plan.md", "p")

      conn |> door(secret, "/archive") |> json_response(200)
      conn |> door(secret, "/archive/tickets/1") |> json_response(200)
      assert Forge.Archive.reads(job.id) == 0

      conn |> door(secret, "/archive/tickets/1/#{version.id}") |> response(200)
      conn |> door(secret, "/archive/tickets/1/#{version.id}") |> response(200)

      assert [%{payload: %{"ticket" => 1, "artifact" => "plan.md", "version" => 1}}] =
               Events.archive_reads(job.id)
    end

    test "a read that found nothing records nothing", %{conn: conn, job: job, secret: secret} do
      conn |> door(secret, "/archive/tickets/1/#{Ecto.UUID.generate()}") |> json_response(404)
      assert Forge.Archive.reads(job.id) == 0
    end

    test "a version whose bytes are gone is not found, and is not recorded as opened",
         %{conn: conn, job: job, ticket: ticket, secret: secret} do
      artifact = artifact_fixture(%{ticket: ticket, name: "gone.log", kind: :blob})

      version =
        version_fixture(%{artifact: artifact, content: nil, blob_uri: "store:nothing/here"})

      conn |> door(secret, "/archive/tickets/1/#{version.id}") |> json_response(404)
      assert Forge.Archive.reads(job.id) == 0
    end
  end

  describe "what cannot be done" do
    test "nothing under /archive is routed but a GET" do
      routes =
        Enum.filter(ForgeWeb.Router.__routes__(), &String.starts_with?(&1.path, "/archive"))

      assert length(routes) == 3
      assert Enum.all?(routes, &(&1.verb == :get))
    end

    test "a write is not a route", %{conn: conn, secret: secret} do
      for method <- [:post, :put, :patch, :delete] do
        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> secret)
          |> dispatch(@endpoint, method, "/archive/tickets/1")

        assert conn.status == 404
      end
    end
  end
end
