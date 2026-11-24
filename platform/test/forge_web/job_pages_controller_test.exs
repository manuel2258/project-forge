defmodule ForgeWeb.JobPagesControllerTest do
  @moduledoc """
  A running job's door to the live store of its ticket's pages (`docs/design/pages.md` § How a
  running job reaches the store).

  Each guard has the test that fails without it: the job's own token and nothing else opens it, the
  pages are the token's job row's (never the path's, never another ticket's), a command reaches
  none, a write names the counter it expects, and a done ticket and an ended chat refuse writes.
  """

  use ForgeWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import ForgeWeb.PageDoorFixtures

  alias Forge.{Events, Pages, Repo}
  alias Forge.Git.Tokens
  alias Forge.Tickets.Ticket

  setup do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-pages-door-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    limits = Application.get_env(:forge, Forge.Pages, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      Application.put_env(:forge, Forge.Pages, limits)
      File.rm_rf!(dir)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 1})
    job = job_fixture(%{ticket: ticket})
    {:ok, secret, _row} = Tokens.issue_for_job(job, ticket, project)
    {page, _version} = published!({:ticket, ticket.id}, "form")

    %{project: project, ticket: ticket, job: job, secret: secret, page: page}
  end

  defp door(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp put_key(conn, secret, name, key, body),
    do:
      conn
      |> door(secret)
      |> put("/job/pages/#{name}/data/#{URI.encode(key, &URI.char_unreserved?/1)}", body)

  describe "who may ask" do
    test "a job with its own token may", %{conn: conn, secret: secret} do
      assert %{"pages" => [%{"name" => "form", "version" => 1, "files" => ["index.html"]}]} =
               conn |> door(secret) |> get("/job/pages") |> json_response(200)
    end

    test "nobody without one, on any route", %{conn: conn, secret: secret} do
      for conn <- [
            conn,
            put_req_header(conn, "authorization", "Bearer not-a-token"),
            put_req_header(conn, "authorization", "Basic " <> secret)
          ] do
        assert conn |> get("/job/pages") |> json_response(401)
        assert conn |> get("/job/pages/form/data") |> json_response(401)
        assert conn |> get("/job/pages/form/data/a") |> json_response(401)

        assert conn
               |> put("/job/pages/form/data/a", %{"value" => 1, "counter" => nil})
               |> json_response(401)

        assert conn |> delete("/job/pages/form/data/a", %{"counter" => nil}) |> json_response(401)
      end
    end

    test "the token is a header and never the query string", %{conn: conn, secret: secret} do
      assert conn |> get("/job/pages?token=#{secret}") |> json_response(401)
    end

    test "not once the job has ended", %{conn: conn, job: job, secret: secret} do
      assert conn |> door(secret) |> get("/job/pages") |> json_response(200)
      Tokens.revoke_for_job(job.id)
      assert conn |> door(secret) |> get("/job/pages") |> json_response(401)
      assert conn |> door(secret) |> get("/job/pages/form/data") |> json_response(401)

      assert put_key(conn, secret, "form", "a", %{"value" => 1, "counter" => nil})
             |> json_response(401)
    end

    test "not with an operator's token, which holds no job", %{conn: conn, project: project} do
      {:ok, secret, _row} = Tokens.issue(project, name: "operator")
      assert conn |> door(secret) |> get("/job/pages") |> json_response(401)
    end

    test "a command reaches no page", %{conn: conn, project: project, ticket: ticket} do
      command = job_fixture(%{ticket: ticket, kind: :command, state: "checking"})
      {:ok, secret, _row} = Tokens.issue_for_job(command, ticket, project)

      assert conn |> door(secret) |> get("/job/pages") |> json_response(403)
      assert conn |> door(secret) |> get("/job/pages/form/data") |> json_response(403)

      assert put_key(conn, secret, "form", "a", %{"value" => 1, "counter" => nil})
             |> json_response(403)
    end
  end

  describe "which pages" do
    test "only its own ticket's: the same name on another ticket is another page", ctx do
      %{conn: conn, project: project, secret: secret, page: page} = ctx
      other = ticket_fixture(%{project: project, number: 2})
      {other_page, _} = published!({:ticket, other.id}, "form")
      {:ok, _} = Pages.put(other_page, "theirs", "x", {:user, Ecto.UUID.generate()})
      {:ok, _} = Pages.put(page, "ours", "y", {:user, Ecto.UUID.generate()})

      assert %{"entries" => [%{"key" => "ours"}]} =
               conn |> door(secret) |> get("/job/pages/form/data") |> json_response(200)

      assert conn |> door(secret) |> get("/job/pages/form/data/theirs") |> json_response(404)
    end

    test "a page of another ticket's that this one has no row for is not found", ctx do
      %{conn: conn, project: project, secret: secret} = ctx
      other = ticket_fixture(%{project: project, number: 2})
      {_page, _} = published!({:ticket, other.id}, "elsewhere")

      assert conn |> door(secret) |> get("/job/pages/elsewhere/data") |> json_response(404)

      assert [%{"name" => "form"}] =
               conn
               |> door(secret)
               |> get("/job/pages")
               |> json_response(200)
               |> Map.fetch!("pages")
    end

    test "a project chat reaches its own pages and not a ticket's", ctx do
      %{conn: conn, project: project, page: _ticket_page} = ctx
      chat = chat_fixture(%{project: project})
      {:ok, secret, _row} = Tokens.issue_for_job(chat, nil, project)
      {_page, _} = published!({:chat, chat.id}, "notes")

      assert [%{"name" => "notes"}] =
               conn
               |> door(secret)
               |> get("/job/pages")
               |> json_response(200)
               |> Map.fetch!("pages")

      assert conn |> door(secret) |> get("/job/pages/form/data") |> json_response(404)
    end

    test "a page with no row is not found to read", %{conn: conn, secret: secret} do
      assert conn |> door(secret) |> get("/job/pages/nothing/data") |> json_response(404)
    end
  end

  describe "reading" do
    test "a key comes with its value and counter, and a missing one is a 404", ctx do
      %{conn: conn, secret: secret, page: page} = ctx
      {:ok, entry} = Pages.put(page, "name", %{"first" => "Ada"}, {:user, Ecto.UUID.generate()})

      assert %{"key" => "name", "value" => %{"first" => "Ada"}, "counter" => counter} =
               conn |> door(secret) |> get("/job/pages/form/data/name") |> json_response(200)

      assert counter == entry.counter
      assert conn |> door(secret) |> get("/job/pages/form/data/other") |> json_response(404)
    end

    test "a key is one encoded segment", %{conn: conn, secret: secret, page: page} do
      {:ok, _} = Pages.put(page, "a/b c", 1, {:user, Ecto.UUID.generate()})

      assert %{"value" => 1} =
               conn |> door(secret) |> get("/job/pages/form/data/a%2Fb%20c") |> json_response(200)
    end

    test "the store says whether it can be written", %{conn: conn, secret: secret} do
      assert %{"read_only" => false} =
               conn |> door(secret) |> get("/job/pages/form/data") |> json_response(200)
    end
  end

  describe "writing" do
    test "a write that expects the key absent makes it, with the next counter", ctx do
      %{conn: conn, secret: secret, page: page} = ctx

      assert %{"value" => [1, 2], "counter" => first} =
               put_key(conn, secret, "form", "rows", %{"value" => [1, 2], "counter" => nil})
               |> json_response(200)

      assert Pages.entry(page, "rows").value == [1, 2]

      assert %{"counter" => second} =
               put_key(conn, secret, "form", "rows", %{"value" => "x", "counter" => first})
               |> json_response(200)

      assert second > first
    end

    test "it is recorded as the job's, not a person's", %{
      conn: conn,
      secret: secret,
      job: job,
      page: page
    } do
      put_key(conn, secret, "form", "k", %{"value" => 1, "counter" => nil}) |> json_response(200)
      assert Pages.entry(page, "k").job_id == job.id
    end

    test "a write that names no counter is a 400 and writes nothing", ctx do
      %{conn: conn, secret: secret, page: page} = ctx

      assert %{"error" => %{"reason" => "counter_required"}} =
               put_key(conn, secret, "form", "k", %{"value" => 1}) |> json_response(400)

      assert %{"error" => %{"reason" => "counter_required"}} =
               conn |> door(secret) |> delete("/job/pages/form/data/k") |> json_response(400)

      assert Pages.entry(page, "k") == nil
    end

    test "a counter that is not one is a 400", %{conn: conn, secret: secret} do
      for bad <- ["x", -1, 1.5, [1]] do
        assert %{"error" => %{"reason" => "bad_counter"}} =
                 put_key(conn, secret, "form", "k", %{"value" => 1, "counter" => bad})
                 |> json_response(400)
      end
    end

    test "a body with no value is a 400", %{conn: conn, secret: secret} do
      assert %{"error" => %{"reason" => "bad_request"}} =
               put_key(conn, secret, "form", "k", %{"counter" => nil}) |> json_response(400)
    end

    test "a stale counter is a 409 carrying the key as it is now", ctx do
      %{conn: conn, secret: secret, page: page} = ctx
      {:ok, entry} = Pages.put(page, "k", "theirs", {:user, Ecto.UUID.generate()})

      assert %{"error" => %{"reason" => "changed", "current" => current}} =
               put_key(conn, secret, "form", "k", %{
                 "value" => "mine",
                 "counter" => entry.counter - 1
               })
               |> json_response(409)

      assert current == %{"value" => "theirs", "counter" => entry.counter}
      assert Pages.entry(page, "k").value == "theirs"
    end

    test "null against a key that is there is a 409, and a counter against one that is not too",
         ctx do
      %{conn: conn, secret: secret, page: page} = ctx
      {:ok, entry} = Pages.put(page, "k", 1, {:user, Ecto.UUID.generate()})

      assert %{"error" => %{"current" => %{"counter" => counter}}} =
               put_key(conn, secret, "form", "k", %{"value" => 2, "counter" => nil})
               |> json_response(409)

      assert counter == entry.counter

      assert %{"error" => %{"reason" => "changed", "current" => nil}} =
               put_key(conn, secret, "form", "gone", %{"value" => 2, "counter" => 5})
               |> json_response(409)
    end

    test "a delete with the right counter removes the key, and a counter never comes back", ctx do
      %{conn: conn, secret: secret, page: page} = ctx
      {:ok, entry} = Pages.put(page, "k", 1, {:user, Ecto.UUID.generate()})

      assert %{"deleted" => true} =
               conn
               |> door(secret)
               |> delete("/job/pages/form/data/k", %{"counter" => entry.counter})
               |> json_response(200)

      assert Pages.entry(page, "k") == nil

      # The deleted key's old counter is gone for good: writing the key again takes a new one.
      assert %{"counter" => again} =
               put_key(conn, secret, "form", "k", %{"value" => 1, "counter" => nil})
               |> json_response(200)

      assert again > entry.counter
    end

    test "a delete may name its counter in the query string", %{
      conn: conn,
      secret: secret,
      page: page
    } do
      {:ok, entry} = Pages.put(page, "k", 1, {:user, Ecto.UUID.generate()})

      assert %{"deleted" => true} =
               conn
               |> door(secret)
               |> delete("/job/pages/form/data/k?counter=#{entry.counter}")
               |> json_response(200)

      assert %{"deleted" => false} =
               conn
               |> door(secret)
               |> delete("/job/pages/form/data/k?counter=null")
               |> json_response(200)
    end

    test "a stale delete is a 409 and removes nothing", %{conn: conn, secret: secret, page: page} do
      {:ok, entry} = Pages.put(page, "k", 1, {:user, Ecto.UUID.generate()})

      assert conn
             |> door(secret)
             |> delete("/job/pages/form/data/k", %{"counter" => entry.counter + 1})
             |> json_response(409)

      assert Pages.entry(page, "k")
    end

    test "any JSON value is a value", %{conn: conn, secret: secret, page: page} do
      for {value, n} <-
            Enum.with_index([nil, 0, "text", [1, %{"a" => []}], %{"deep" => %{"x" => true}}]) do
        put_key(conn, secret, "form", "k#{n}", %{"value" => value, "counter" => nil})
        |> json_response(200)

        assert Pages.entry(page, "k#{n}").value == value
      end
    end

    test "a limit is a 413 naming it and its number", %{conn: conn, secret: secret} do
      Application.put_env(:forge, Forge.Pages, value_bytes: 10)

      assert %{"error" => %{"reason" => "limit", "limit" => limit, "max" => 10}} =
               put_key(conn, secret, "form", "k", %{
                 "value" => String.duplicate("x", 50),
                 "counter" => nil
               })
               |> json_response(413)

      assert limit =~ "value"
    end

    test "a value Postgres cannot hold is a 422 and stores nothing",
         %{conn: conn, secret: secret, page: page} do
      assert %{"error" => %{"reason" => "invalid_value"}} =
               put_key(conn, secret, "form", "k", %{"value" => "a\u0000b", "counter" => nil})
               |> json_response(422)

      assert Pages.entry(page, "k") == nil
    end

    test "a key that is not a key is a 422", %{conn: conn, secret: secret} do
      assert %{"error" => %{"reason" => "invalid_key"}} =
               put_key(conn, secret, "form", "bad\u0001key", %{"value" => 1, "counter" => nil})
               |> json_response(422)
    end
  end

  describe "a page with no row yet" do
    test "its job may start its store when its state declares it, and no other may", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx

      declaring =
        job_fixture(%{
          ticket: ticket,
          attempt: 2,
          spec: %{"prompt" => "p", "produces" => ["seed@"]}
        })

      {:ok, secret, _row} = Tokens.issue_for_job(declaring, ticket, project)

      assert put_key(conn, secret, "seed", "k", %{"value" => 1, "counter" => nil})
             |> json_response(200)

      assert Pages.get({:ticket, ticket.id}, "seed")

      assert put_key(conn, ctx.secret, "undeclared", "k", %{"value" => 1, "counter" => nil})
             |> json_response(404)

      assert Pages.get({:ticket, ticket.id}, "undeclared") == nil
    end

    test "a chat may write any valid page name", %{conn: conn, project: project} do
      chat = chat_fixture(%{project: project})
      {:ok, secret, _row} = Tokens.issue_for_job(chat, nil, project)

      assert put_key(conn, secret, "fresh", "k", %{"value" => 1, "counter" => nil})
             |> json_response(200)

      assert put_key(conn, secret, "not a name!", "k", %{"value" => 1, "counter" => nil})
             |> json_response(404)
    end
  end

  describe "read only" do
    test "a done ticket refuses every write and still reads", ctx do
      %{conn: conn, secret: secret, ticket: ticket, page: page} = ctx
      {:ok, entry} = Pages.put(page, "k", 1, {:user, Ecto.UUID.generate()})

      Repo.update_all(from(t in Ticket, where: t.id == ^ticket.id),
        set: [status: :done]
      )

      assert %{"error" => %{"reason" => "read_only", "why" => "done"}} =
               put_key(conn, secret, "form", "k", %{"value" => 2, "counter" => entry.counter})
               |> json_response(409)

      assert conn
             |> door(secret)
             |> delete("/job/pages/form/data/k", %{"counter" => entry.counter})
             |> json_response(409)

      assert %{"read_only" => "done", "entries" => [%{"value" => 1}]} =
               conn |> door(secret) |> get("/job/pages/form/data") |> json_response(200)
    end

    test "a ticket reopened can be written again", %{conn: conn, secret: secret, ticket: ticket} do
      Repo.update_all(from(t in Ticket, where: t.id == ^ticket.id),
        set: [status: :cancelled]
      )

      assert put_key(conn, secret, "form", "k", %{"value" => 2, "counter" => nil})
             |> json_response(409)

      Repo.update_all(from(t in Ticket, where: t.id == ^ticket.id),
        set: [status: :active]
      )

      assert put_key(conn, secret, "form", "k", %{"value" => 2, "counter" => nil})
             |> json_response(200)
    end

    test "an ended project chat refuses writes", %{conn: conn, project: project} do
      chat = chat_fixture(%{project: project})
      {:ok, secret, _row} = Tokens.issue_for_job(chat, nil, project)
      {_page, _} = published!({:chat, chat.id}, "notes")

      assert put_key(conn, secret, "notes", "k", %{"value" => 1, "counter" => nil})
             |> json_response(200)

      Repo.insert!(
        Events.Event.changeset(%Events.Event{}, %{
          type: "chat.ended",
          actor: Events.encode_actor({:user, Ecto.UUID.generate()}),
          job_id: chat.id,
          project_id: project.id,
          payload: %{"reason" => "closed"}
        })
      )

      assert %{"error" => %{"reason" => "read_only"}} =
               put_key(conn, secret, "notes", "k", %{"value" => 2, "counter" => 1})
               |> json_response(409)
    end
  end

  describe "what is logged" do
    test "never a value", %{conn: conn, secret: secret} do
      log =
        capture_log(fn ->
          put_key(conn, secret, "form", "k", %{
            "value" => "hunter2-secret-value",
            "counter" => nil
          })

          put_key(conn, secret, "form", "k", %{"value" => "hunter2-other-value", "counter" => 99})
        end)

      refute log =~ "hunter2"
    end
  end
end
