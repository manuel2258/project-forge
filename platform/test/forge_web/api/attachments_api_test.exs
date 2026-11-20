defmodule ForgeWeb.Api.AttachmentsApiTest do
  @moduledoc """
  Files on the JSON API (`docs/design/attachments.md` § The API): a `multipart/form-data` write
  attaches `files[]` wherever the same write exists today, kept whole or refused whole; the token's
  limits are the write's; and withdrawing a file is a person's.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{
    Accounts,
    Artifacts,
    Attachments,
    Events,
    FakeWorker,
    Jobs,
    Projects,
    Repo,
    Tickets
  }

  alias Forge.Attachments.{Attachment, Upload}
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job

  @workflow "../../../../core/test/fixtures/workflow_example.yml"
            |> Path.expand(__DIR__)
            |> File.read!()
            |> String.replace(
              "    produces: [plan.md]\n",
              "    produces: [plan.md]\n    outcomes: [done, redo]\n"
            )
            |> String.replace(
              "  - { from: planning,      to: implementing }\n",
              "  - { from: planning,      to: implementing }\n" <>
                "  - { from: planning,      to: refining,      when: redo }\n"
            )

  setup %{conn: conn} do
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, tmp_dir("data")))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    limits = Application.get_env(:forge, Forge.Attachments, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
      Application.put_env(:forge, Forge.Attachments, limits)
    end)

    owner = user_fixture()

    {:ok, project} =
      Projects.register(
        %{
          name: "att-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
        },
        owner
      )

    funded!(project)
    member = member_fixture(project, :member)
    {:ok, ticket} = Tickets.admit(project, %{title: "Scores"}, {:user, owner.id})

    %{
      conn: conn,
      owner: owner,
      owner_conn: as(conn, Accounts.create_api_token(owner, "owner")),
      member: member,
      member_conn: as(conn, Accounts.create_api_token(member, "member")),
      project: project,
      ticket: ticket
    }
  end

  defp as(conn, secret), do: put_req_header(conn, "authorization", "Bearer " <> secret)

  defp token_conn(conn, project, opts) do
    {:ok, secret, row} = Tokens.issue(project, Keyword.merge([name: "ci", git: :reader], opts))
    {as(conn, secret), row}
  end

  defp tpath(project, ticket, tail),
    do: "/api/v1/tickets/#{project.name}/#{ticket.number}#{tail}"

  # A real `multipart/form-data` body, which is what a client sends and what the endpoint now
  # leaves for `ForgeWeb.Plugs.ApiFiles` to read: a test adapter given a map skips the parser.
  defp multipart(conn, url, fields, files, method \\ :post) do
    boundary = "forgeboundary#{System.unique_integer([:positive])}"

    parts =
      Enum.map(fields, fn {name, value} ->
        "--#{boundary}\r\ncontent-disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
      end) ++
        Enum.map(files, fn {filename, bytes} ->
          "--#{boundary}\r\ncontent-disposition: form-data; name=\"files[]\"; " <>
            "filename=\"#{filename}\"\r\ncontent-type: application/octet-stream\r\n\r\n#{bytes}\r\n"
        end)

    body = IO.iodata_to_binary(parts) <> "--#{boundary}--\r\n"

    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> dispatch(@endpoint, method, url, body)
  end

  defp staged, do: Repo.aggregate(Upload, :count)
  defp attached(ticket), do: Attachments.pool({:ticket, ticket.id})

  describe "every write takes files" do
    test "admitting a ticket", %{owner_conn: conn, project: project} do
      response =
        conn
        |> multipart(
          "/api/v1/projects/#{project.name}/tickets",
          [title: "Bug", body: "See it.", on_hold: "false"],
          [
            {"bug report.png", "PNG"}
          ]
        )
        |> json_response(201)

      ticket = Tickets.get_by_number!(project, response["number"])
      assert [%{file: "bug-report.png", size: 3, attachment: row}] = attached(ticket)
      assert row.to_kind == :ticket
      assert row.to_version_id == Artifacts.latest(ticket.id, "ticket").id
      assert row.original_name == "bug report.png"
      assert row.user_id
    end

    test "a new version of a document", %{owner_conn: conn, project: project, ticket: ticket} do
      assert %{"version" => 1} =
               conn
               |> multipart(
                 tpath(project, ticket, "/artifacts/feedback.md"),
                 [content: "Look."],
                 [
                   {"a.png", "x"}
                 ]
               )
               |> json_response(200)

      assert [%{attachment: %{to_kind: :document, to_version_id: id}}] = attached(ticket)
      assert id == Artifacts.latest(ticket.id, "feedback.md").id
    end

    test "an answer", %{owner_conn: conn, owner: owner, project: project, ticket: ticket} do
      doc = """
      Which?

      ```question
      key: naming
      anchor: "Which?"
      text: "Which?"
      options:
        - label: "a"
          detail: "one"
        - label: "b"
          detail: "two"
      blocking: false
      assumption: "a"
      ```
      """

      {:ok, _} = Forge.Operator.edit(ticket, owner, "notes.md", doc, "0")

      assert conn
             |> multipart(tpath(project, ticket, "/answers"), [key: "naming", choice: "b"], [
               {"a.png", "x"}
             ])
             |> json_response(200)

      assert [%{attachment: %{to_kind: :answer}}] = attached(ticket)
    end

    test "a proposal accepted", %{owner_conn: conn, project: project} do
      job = job_fixture(%{ticket: ticket_fixture(%{project: project})})
      version = proposal_fixture(%{job: job})

      response =
        conn
        |> multipart("/api/v1/proposals/#{version.id}/accept", [on_hold: "false"], [
          {"p.png", "x"}
        ])
        |> json_response(200)

      ticket = Tickets.get_by_number!(project, response["number"])
      assert [%{attachment: %{to_kind: :ticket}}] = attached(ticket)
    end
  end

  describe "a ticket that has run" do
    setup %{project: project, ticket: ticket} do
      worker = FakeWorker.connect()
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
      {:ok, _} = FakeWorker.run(%Job{} = job, worker, "success", doc: "refinement.md")
      :ok = if project, do: :ok
      %{ticket: Tickets.get!(ticket.id)}
    end

    test "an approval's note, a transition's comment and a note to run again", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      assert conn
             |> multipart(
               tpath(project, ticket, "/approve"),
               [decision: "rejected", comment: "No."],
               [{"a.png", "x"}]
             )
             |> json_response(200)

      assert conn
             |> multipart(
               tpath(project, ticket, "/transition"),
               [to: "planning", comment: "Go."],
               [{"b.png", "x"}]
             )
             |> json_response(200)

      kinds = ticket |> attached() |> Enum.map(& &1.attachment.to_kind)
      assert kinds == [:note, :note]

      words =
        Attachments.all({:ticket, ticket.id})
        |> Attachments.describe()
        |> Map.values()
        |> Enum.map(& &1.to)

      assert Enum.sort(words) == ["a rejection note", "a transition's comment"]
    end

    test "a note to run the state again", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      assert conn
             |> multipart(tpath(project, ticket, "/retry"), [note: "again"], [{"a.png", "x"}])
             |> json_response(200)

      assert [%{attachment: %{to_kind: :note}}] = attached(ticket)
    end
  end

  describe "who may send files" do
    test "a read token is refused 403 and nothing is staged", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {conn, _row} = token_conn(conn, project, api: :read)

      assert %{"error" => %{"reason" => "forbidden"}} =
               conn
               |> multipart(tpath(project, ticket, "/retry"), [], [{"a.png", "x"}])
               |> json_response(403)

      assert staged() == 0
    end

    test "a read token is refused 403 whatever and however much it sends", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {conn, _row} = token_conn(conn, project, api: :read)
      files = for n <- 1..11, do: {"f#{n}.png", "x"}

      assert %{"error" => %{"reason" => "forbidden"}} =
               conn
               |> multipart(tpath(project, ticket, "/retry"), [], files)
               |> json_response(403)

      assert staged() == 0
    end

    test "a write token may, and is named as who attached it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {conn, row} = token_conn(conn, project, api: :write)

      assert conn
             |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [
               {"a.png", "x"}
             ])
             |> json_response(200)

      assert [%{attachment: attachment}] = attached(ticket)
      assert attachment.token_id == row.id
      assert attachment.user_id == nil
      assert %{"kind" => "api", "name" => "ci"} = attachment.author
    end

    test "someone who is not a member is refused as for any ticket, and nothing is staged", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      stranger = as(conn, Accounts.create_api_token(user_fixture(), "stranger"))

      assert stranger
             |> multipart(tpath(project, ticket, "/retry"), [], [{"a.png", "x"}])
             |> json_response(404)

      assert stranger
             |> multipart(
               "/api/v1/projects/#{project.name}/tickets",
               [title: "x", on_hold: "false"],
               [{"a.png", "x"}]
             )
             |> json_response(404)

      assert staged() == 0
      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "a token of another project is refused", %{conn: conn, ticket: ticket, project: project} do
      other = project_fixture()
      {conn, _row} = token_conn(conn, other, api: :write)

      assert conn
             |> multipart(tpath(project, ticket, "/retry"), [], [{"a.png", "x"}])
             |> json_response(404)

      assert staged() == 0
    end
  end

  # A multipart body from whole parts: what a hostile client sends and the helper above cannot.
  defp raw(conn, url, parts) do
    boundary = "rawboundary#{System.unique_integer([:positive])}"

    body =
      Enum.map_join(parts, fn part -> "--#{boundary}\r\n#{part}\r\n" end) <>
        "--#{boundary}--\r\n"

    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> dispatch(@endpoint, :post, url, body)
  end

  defp part(name, body, extra \\ ""),
    do: ~s(content-disposition: form-data; name="#{name}"#{extra}\r\n\r\n#{body})

  describe "what the body may hold, in every part of it" do
    setup do
      # max = 2 × 4 bytes + a megabyte.
      Application.put_env(:forge, Forge.Attachments, per_act: 2, file_bytes: 4)
      :ok
    end

    test "the headers of all the parts are counted: a megabyte in all, to the byte", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      # `content-disposition` (19 bytes) and `form-data; name="…"` (18 and the name): two parts whose
      # headers come to exactly a megabyte are read, one byte more is 413.
      name = fn bytes -> String.duplicate("n", bytes) end
      each = div(1024 * 1024, 2) - 37
      at_the_limit = [part(name.(each), ""), part(name.(each), "")]
      one_over = [part(name.(each), ""), part(name.(each + 1), "")]
      url = tpath(project, ticket, "/retry")

      assert conn |> raw(url, at_the_limit) |> Map.get(:status) != 413
      assert conn |> raw(url, one_over) |> Map.get(:status) == 413
    end

    test "the number of parts is bounded: a hundred and one empty ones are 413", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      parts = for n <- 1..101, do: part("x[#{n}]", "")

      assert %{"error" => %{"reason" => "too_large"}} =
               conn |> raw(tpath(project, ticket, "/retry"), parts) |> json_response(413)

      # And a hundred are read: the retry is refused by the ticket (a job is live), not by the body.
      parts = for n <- 1..100, do: part("x[#{n}]", "")
      assert conn |> raw(tpath(project, ticket, "/retry"), parts) |> Map.get(:status) != 413
    end

    test "a file that fills the body's room to the byte is read", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      # Four bytes of room left (a megabyte and eight in all), and a file of four: within both.
      skipped = String.duplicate("x", 1024 * 1024 + 4)

      conn =
        raw(conn, tpath(project, ticket, "/retry"), [
          part("other", skipped, ~s(; filename="o.bin")),
          part("files[]", "1234", ~s(; filename="f.png"))
        ])

      assert conn.status != 413
      assert conn.status != 422
    end

    test "a part that is not ours is counted by its last chunk as well", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      # A megabyte and nine bytes: one full chunk, then a short last chunk that passes the body.
      skipped = String.duplicate("x", 1024 * 1024 + 9)

      assert conn
             |> raw(tpath(project, ticket, "/retry"), [
               part("other", skipped, ~s(; filename="o.bin"))
             ])
             |> Map.get(:status) == 413
    end

    test "a request an exception cuts short leaves no staged file", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      # No `to`: the action has no clause for it, which Phoenix answers 400 by raising.
      assert_error_sent 400, fn ->
        multipart(conn, tpath(project, ticket, "/transition"), [comment: "x"], [{"a.png", "x"}])
      end

      assert staged() == 0
    end

    test "a file that arrives after the room is used is 413, though it is within its own limit",
         ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      # Two bytes of room left in the body (a megabyte and eight bytes in all), and a file of four.
      skipped = String.duplicate("x", 1024 * 1024 + 6)

      assert conn
             |> raw(tpath(project, ticket, "/retry"), [
               part("other", skipped, ~s(; filename="o.bin")),
               part("files[]", "1234", ~s(; filename="f.png"))
             ])
             |> Map.get(:status) == 413

      assert staged() == 0
    end

    test "a file many times its limit is 413 as it is read past, and kept nowhere", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      # A megabyte-sized limit, so that the first chunk is within the body and the file is drained.
      Application.put_env(:forge, Forge.Attachments, per_act: 1, file_bytes: 1_000_000)
      huge = String.duplicate("x", 3 * 1024 * 1024)

      assert conn
             |> raw(tpath(project, ticket, "/retry"), [
               part("files[]", huge, ~s(; filename="huge.bin"))
             ])
             |> Map.get(:status) == 413

      assert staged() == 0
    end

    test "the last chunk of a file past its limit is counted as the others are", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      # 2 MiB and a hundred bytes: the chunks before the last fit the body, the whole does not.
      Application.put_env(:forge, Forge.Attachments, per_act: 1, file_bytes: 1_048_577)
      huge = String.duplicate("x", 2 * 1024 * 1024 + 100)

      assert conn
             |> raw(tpath(project, ticket, "/retry"), [
               part("files[]", huge, ~s(; filename="huge.bin"))
             ])
             |> Map.get(:status) == 413
    end
  end

  describe "what the body may hold" do
    test "a text field is bounded: a comment of megabytes is 413, and nothing is read on", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      comment = String.duplicate("x", 1024 * 1024 + 1)

      assert %{"error" => %{"reason" => "too_large"}} =
               conn
               |> multipart(tpath(project, ticket, "/retry"), [note: comment], [{"a.png", "x"}])
               |> json_response(413)

      assert staged() == 0
    end

    test "a media type is not case sensitive", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      conn =
        conn
        |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [{"a.png", "x"}])

      assert conn.status == 200

      # The same body with the type spelled as a client may spell it.
      boundary = "b#{System.unique_integer([:positive])}"

      body =
        Enum.join(
          [
            "--#{boundary}",
            ~s(content-disposition: form-data; name="content"),
            "",
            "hi2",
            "--#{boundary}",
            ~s(content-disposition: form-data; name="files[]"; filename="b.png"),
            "",
            "x",
            "--#{boundary}--",
            ""
          ],
          "\r\n"
        )

      conn =
        ctx.owner_conn
        |> put_req_header("content-type", "Multipart/Form-Data; boundary=#{boundary}")
        |> dispatch(@endpoint, :post, tpath(project, ticket, "/artifacts/m.md"), body)

      assert conn.status == 200

      assert [_, %{original_name: "b.png"}] =
               Enum.sort_by(Repo.all(Attachment), & &1.original_name)
    end

    test "the temporary copies of the files are gone when the request is", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      dir = Path.join(System.tmp_dir!(), "forge-upload")
      before = if File.dir?(dir), do: File.ls!(dir), else: []

      conn
      |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [{"a.png", "x"}])
      |> json_response(200)

      Application.put_env(:forge, Forge.Attachments, file_bytes: 1)

      conn
      |> multipart(tpath(project, ticket, "/artifacts/o.md"), [content: "hi"], [{"b.png", "xx"}])
      |> json_response(422)

      assert if(File.dir?(dir), do: File.ls!(dir), else: []) -- before == []
    end
  end

  describe "whole or not at all" do
    test "a refused request does not run the act: an approval is not given, a merge not pushed",
         ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      Application.put_env(:forge, Forge.Attachments, pool_bytes: 3)
      events = length(Events.for_ticket(ticket.id))

      assert %{"error" => %{"detail" => [%{"limit" => "pool_bytes"}]}} =
               conn
               |> multipart(tpath(project, ticket, "/transition"), [to: "planning"], [
                 {"big.png", "12345"}
               ])
               |> json_response(422)

      # Checked before the act, not after it: nothing was done to roll back.
      assert length(Events.for_ticket(ticket.id)) == events
      assert Tickets.get!(ticket.id).state == ticket.state
    end

    test "a file past a limit refuses the request, naming it, and writes nothing", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      Application.put_env(:forge, Forge.Attachments, per_act: 2, file_bytes: 4)
      events = length(Events.for_ticket(ticket.id))

      assert %{"error" => %{"reason" => "attachments_refused", "detail" => [refused]}} =
               conn
               |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [
                 {"fits.png", "1234"},
                 {"big.mov", "12345"}
               ])
               |> json_response(422)

      assert %{"file" => "big.mov", "limit" => "file_bytes", "detail" => detail} = refused
      assert detail =~ "MiB" or detail =~ "file"
      assert staged() == 0
      assert Artifacts.latest(ticket.id, "n.md") == nil
      assert attached(ticket) == []
      assert length(Events.for_ticket(ticket.id)) == events
    end

    test "too many files are refused before any is staged past the first ten", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      Application.put_env(:forge, Forge.Attachments, per_act: 1)

      assert %{"error" => %{"detail" => [%{"file" => "b.png", "limit" => "per_act"}]}} =
               conn
               |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [
                 {"a.png", "x"},
                 {"b.png", "x"}
               ])
               |> json_response(422)

      assert staged() == 0
      assert Artifacts.latest(ticket.id, "n.md") == nil
    end

    test "a pool limit found at the claim refuses the request whole and unstages", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      Application.put_env(:forge, Forge.Attachments, pool_files: 1)

      assert %{
               "error" => %{
                 "reason" => "attachments_refused",
                 "detail" => [%{"limit" => "pool_files"}]
               }
             } =
               conn
               |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [
                 {"a.png", "x"},
                 {"b.png", "x"}
               ])
               |> json_response(422)

      assert staged() == 0
      assert Artifacts.latest(ticket.id, "n.md") == nil
      assert attached(ticket) == []
    end

    test "a write the operation refuses leaves no staged file behind", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx

      assert %{"error" => %{"reason" => "nothing_pending"}} =
               conn
               |> multipart(tpath(project, ticket, "/approve"), [decision: "approved"], [
                 {"a.png", "x"}
               ])
               |> json_response(409)

      assert staged() == 0
      assert attached(ticket) == []
    end

    test "a body past the limit is 413 in the API's shape", ctx do
      %{owner_conn: conn, project: project, ticket: ticket} = ctx
      Application.put_env(:forge, Forge.Attachments, per_act: 1, file_bytes: 1)
      big = String.duplicate("x", 2 * 1024 * 1024)

      assert %{"error" => %{"reason" => "too_large"}} =
               conn
               |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [
                 {"big.bin", big}
               ])
               |> json_response(413)

      assert staged() == 0
      assert Artifacts.latest(ticket.id, "n.md") == nil
    end
  end

  test "a field of the body cannot take the place of the address's", ctx do
    %{owner_conn: conn, project: project, ticket: ticket} = ctx

    assert %{"artifact" => "n.md"} =
             conn
             |> multipart(
               tpath(project, ticket, "/artifacts/n.md"),
               [content: "hi", name: "evil.md"],
               [
                 {"a.png", "x"}
               ]
             )
             |> json_response(200)

    assert Artifacts.latest(ticket.id, "evil.md") == nil
  end

  test "a JSON write is as it was, and attaches nothing", %{
    owner_conn: conn,
    project: project,
    ticket: ticket
  } do
    assert %{"version" => 1} =
             conn
             |> post(tpath(project, ticket, "/artifacts/n.md"), %{"content" => "hi"})
             |> json_response(200)

    assert Repo.aggregate(Attachment, :count) == 0
  end

  describe "withdrawing" do
    setup %{member_conn: member_conn, project: project, ticket: ticket} do
      member_conn
      |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [{"a.png", "one"}])
      |> json_response(200)

      member_conn
      |> multipart(tpath(project, ticket, "/artifacts/n.md"), [content: "hi"], [{"a.png", "two"}])
      |> json_response(200)

      :ok
    end

    test "the attacher withdraws one version, with a reason", ctx do
      %{member_conn: conn, project: project, ticket: ticket} = ctx

      assert %{"withdrawn" => [%{"name" => "attachments/a.png", "reason" => "oops", "size" => 3}]} =
               conn
               |> delete(tpath(project, ticket, "/attachments/a.png/2"), %{"reason" => "oops"})
               |> json_response(200)

      assert [%{file: "a.png", version: 1}] = attached(ticket)
    end

    test "or every version", ctx do
      %{member_conn: conn, project: project, ticket: ticket} = ctx

      assert %{"withdrawn" => [_, _]} =
               conn |> delete(tpath(project, ticket, "/attachments/a.png")) |> json_response(200)

      assert attached(ticket) == []
    end

    test "an admin may, another member may not", ctx do
      %{owner_conn: admin, project: project, ticket: ticket} = ctx
      other = as(ctx.conn, Accounts.create_api_token(member_fixture(project, :member), "other"))

      assert %{"error" => %{"reason" => "forbidden"}} =
               other |> delete(tpath(project, ticket, "/attachments/a.png")) |> json_response(403)

      assert length(attached(ticket)) == 2
      assert admin |> delete(tpath(project, ticket, "/attachments/a.png")) |> json_response(200)
      assert attached(ticket) == []
    end

    test "a project token may not, write or read, whoever attached it", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx

      for access <- [:write, :read] do
        {conn, _row} = token_conn(conn, project, api: access)

        assert %{"error" => %{"reason" => "forbidden"}} =
                 conn
                 |> delete(tpath(project, ticket, "/attachments/a.png"))
                 |> json_response(403)
      end

      assert length(attached(ticket)) == 2
    end

    test "a file that is not there is 404, and a version that is not a number is 400", ctx do
      %{member_conn: conn, project: project, ticket: ticket} = ctx

      assert conn |> delete(tpath(project, ticket, "/attachments/none.png")) |> json_response(404)

      assert conn
             |> delete(tpath(project, ticket, "/attachments/a.png/two"))
             |> json_response(400)

      assert conn |> delete(tpath(project, ticket, "/attachments/a.png/9")) |> json_response(404)
    end

    test "a non-member sees a ticket that is not there", ctx do
      %{project: project, ticket: ticket} = ctx
      stranger = as(ctx.conn, Accounts.create_api_token(user_fixture(), "stranger"))

      assert stranger
             |> delete(tpath(project, ticket, "/attachments/a.png"))
             |> json_response(404)

      assert length(attached(ticket)) == 2
    end

    test "a token-attached file is an admin's only", ctx do
      %{conn: conn, project: project, ticket: ticket, member_conn: member, owner_conn: admin} =
        ctx

      {conn, _row} = token_conn(conn, project, api: :write)

      conn
      |> multipart(tpath(project, ticket, "/artifacts/t.md"), [content: "hi"], [{"t.png", "x"}])
      |> json_response(200)

      assert member |> delete(tpath(project, ticket, "/attachments/t.png")) |> json_response(403)
      assert admin |> delete(tpath(project, ticket, "/attachments/t.png")) |> json_response(200)

      assert from(a in Attachment, where: not is_nil(a.withdrawn_at), select: count())
             |> Repo.one() == 1
    end
  end
end
