defmodule ForgeWeb.Api.ApiPagesTest do
  @moduledoc """
  A ticket's pages and their stores over the JSON API (`docs/design/pages.md` § How a running job reaches the store): a
  person's token and a project's, who may read and who may write, the counter a token must name, and
  every way into another project's pages that is a 404.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import ForgeWeb.PageDoorFixtures

  alias Forge.{Accounts, Pages, Repo}
  alias Forge.Git.Tokens
  alias Forge.Tickets.Ticket

  setup do
    original = Application.get_env(:forge, Forge.Storage, [])

    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-pages-api-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:forge, Forge.Storage, Keyword.put(original, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, original)
      File.rm_rf!(dir)
    end)

    project = project_fixture()
    ticket = ticket_fixture(%{project: project, number: 1})
    member = member_fixture(project, :member)
    {page, _version} = published!({:ticket, ticket.id}, "form")

    %{project: project, ticket: ticket, member: member, page: page}
  end

  defp as_user(conn, user),
    do: put_req_header(conn, "authorization", "Bearer " <> Accounts.create_api_token(user, "t"))

  defp as_token(conn, project, api) do
    {:ok, secret, row} = Tokens.issue(project, name: "ci", git: :reader, api: api)
    {put_req_header(conn, "authorization", "Bearer " <> secret), row}
  end

  defp base(project, ticket), do: "/api/v1/tickets/#{project.name}/#{ticket.number}/pages"

  describe "reading" do
    test "a member lists the pages that have a version", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member} = ctx
      published!({:ticket, ticket.id}, "second", %{"index.html" => "x", "app.js" => "y"})

      assert %{"pages" => [first, second]} =
               conn |> as_user(member) |> get(base(project, ticket)) |> json_response(200)

      assert %{"name" => "form", "version" => 1, "files" => ["index.html"], "read_only" => false} =
               first

      assert %{"name" => "second", "files" => ["app.js", "index.html"]} = second
    end

    test "a store with no version is not listed, but is read by name", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member} = ctx
      {:ok, page} = Pages.ensure({:ticket, ticket.id}, "seeded")
      {:ok, _} = Pages.put(page, "k", [1], {:user, member.id})

      assert %{"pages" => [%{"name" => "form"}]} =
               conn |> as_user(member) |> get(base(project, ticket)) |> json_response(200)

      assert %{"entries" => [%{"key" => "k", "value" => [1]}]} =
               conn
               |> as_user(member)
               |> get(base(project, ticket) <> "/seeded/data")
               |> json_response(200)
    end

    test "one key, and a 404 for a missing key or page", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member, page: page} = ctx
      {:ok, _} = Pages.put(page, "k", "v", {:user, member.id})

      assert %{"key" => "k", "value" => "v"} =
               conn
               |> as_user(member)
               |> get(base(project, ticket) <> "/form/data/k")
               |> json_response(200)

      assert conn
             |> as_user(member)
             |> get(base(project, ticket) <> "/form/data/none")
             |> json_response(404)

      assert conn
             |> as_user(member)
             |> get(base(project, ticket) <> "/nope/data")
             |> json_response(404)
    end

    test "a read token reads", ctx do
      %{conn: conn, project: project, ticket: ticket, page: page, member: member} = ctx
      {:ok, _} = Pages.put(page, "k", "v", {:user, member.id})
      {conn, _row} = as_token(conn, project, :read)

      assert %{"entries" => [%{"key" => "k"}]} =
               conn |> get(base(project, ticket) <> "/form/data") |> json_response(200)
    end

    test "nobody outside the project, whatever they ask for", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      stranger = user_fixture()
      other = project_fixture()
      {other_token, _row} = as_token(conn, other, :write)

      for conn <- [as_user(conn, stranger), other_token] do
        assert conn |> get(base(project, ticket)) |> json_response(404)
        assert conn |> get(base(project, ticket) <> "/form/data") |> json_response(404)
        assert conn |> get(base(project, ticket) <> "/form/data/k") |> json_response(404)

        assert conn
               |> put(base(project, ticket) <> "/form/data/k", %{"value" => 1, "counter" => nil})
               |> json_response(404)
      end

      assert Pages.entry(ctx.page, "k") == nil
    end

    test "no token at all is a 401", %{conn: conn, project: project, ticket: ticket} do
      assert conn |> get(base(project, ticket)) |> json_response(401)
    end

    test "a page of another ticket of the project is not this ticket's", ctx do
      %{conn: conn, project: project, member: member} = ctx
      other = ticket_fixture(%{project: project, number: 2})
      {_page, _} = published!({:ticket, other.id}, "theirs")

      assert conn
             |> as_user(member)
             |> get(base(project, other) <> "/form/data")
             |> json_response(404)

      assert [%{"name" => "theirs"}] =
               conn
               |> as_user(member)
               |> get(base(project, other))
               |> json_response(200)
               |> Map.fetch!("pages")
    end
  end

  describe "writing" do
    test "a person's write is last-write-wins and recorded as them", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member, page: page} = ctx
      {:ok, _} = Pages.put(page, "k", "theirs", {:user, Ecto.UUID.generate()})

      assert %{"value" => "mine"} =
               conn
               |> as_user(member)
               |> put(base(project, ticket) <> "/form/data/k", %{"value" => "mine"})
               |> json_response(200)

      assert %{user_id: user_id, value: "mine"} = Pages.entry(page, "k")
      assert user_id == member.id
    end

    test "a person who names a stale counter is refused, as a job is", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member, page: page} = ctx
      {:ok, entry} = Pages.put(page, "k", "theirs", {:user, Ecto.UUID.generate()})

      assert %{"error" => %{"reason" => "changed"}} =
               conn
               |> as_user(member)
               |> put(base(project, ticket) <> "/form/data/k", %{
                 "value" => "mine",
                 "counter" => entry.counter + 1
               })
               |> json_response(409)
    end

    test "a write token names the counter it expects, and is recorded as the token", ctx do
      %{conn: conn, project: project, ticket: ticket, page: page} = ctx
      {conn, row} = as_token(conn, project, :write)
      path = base(project, ticket) <> "/form/data/k"

      assert %{"error" => %{"reason" => "counter_required"}} =
               conn |> put(path, %{"value" => 1}) |> json_response(400)

      assert %{"counter" => counter} =
               conn |> put(path, %{"value" => 1, "counter" => nil}) |> json_response(200)

      assert %{token_id: token_id} = Pages.entry(page, "k")
      assert token_id == row.id

      assert %{"error" => %{"reason" => "changed", "current" => %{"value" => 1}}} =
               conn |> put(path, %{"value" => 2, "counter" => nil}) |> json_response(409)

      assert conn |> delete(path) |> json_response(400)
      assert conn |> delete(path, %{"counter" => counter}) |> json_response(200)
      assert Pages.entry(page, "k") == nil
    end

    test "a read token cannot write, and is told before anything is looked up", ctx do
      %{conn: conn, project: project, ticket: ticket, page: page} = ctx
      {conn, _row} = as_token(conn, project, :read)
      path = base(project, ticket) <> "/form/data/k"

      assert conn |> put(path, %{"value" => 1, "counter" => nil}) |> json_response(403)
      assert conn |> delete(path, %{"counter" => nil}) |> json_response(403)

      assert conn
             |> put(base(project, ticket) <> "/nope/data/k", %{"value" => 1, "counter" => nil})
             |> json_response(403)

      assert Pages.entry(page, "k") == nil
    end

    test "a done ticket refuses a person's and a token's write", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member, page: page} = ctx

      Repo.update_all(from(t in Ticket, where: t.id == ^ticket.id),
        set: [status: :done]
      )

      path = base(project, ticket) <> "/form/data/k"
      {token_conn, _row} = as_token(conn, project, :write)

      assert %{"error" => %{"reason" => "read_only", "why" => "done"}} =
               conn |> as_user(member) |> put(path, %{"value" => 1}) |> json_response(409)

      assert token_conn |> put(path, %{"value" => 1, "counter" => nil}) |> json_response(409)
      assert Pages.entry(page, "k") == nil

      assert %{"read_only" => "done"} =
               conn
               |> as_user(member)
               |> get(base(project, ticket) <> "/form/data")
               |> json_response(200)
    end

    test "a page with no row is a 404 to write: only a job starts a store", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member} = ctx

      assert conn
             |> as_user(member)
             |> put(base(project, ticket) <> "/new/data/k", %{"value" => 1})
             |> json_response(404)

      assert Pages.get({:ticket, ticket.id}, "new") == nil
    end

    test "a limit is a 413 naming it", ctx do
      %{conn: conn, project: project, ticket: ticket, member: member} = ctx
      original = Application.get_env(:forge, Forge.Pages, [])
      Application.put_env(:forge, Forge.Pages, value_bytes: 8)
      on_exit(fn -> Application.put_env(:forge, Forge.Pages, original) end)

      assert %{"error" => %{"reason" => "limit", "max" => 8}} =
               conn
               |> as_user(member)
               |> put(base(project, ticket) <> "/form/data/k", %{
                 "value" => String.duplicate("x", 40)
               })
               |> json_response(413)
    end
  end
end
