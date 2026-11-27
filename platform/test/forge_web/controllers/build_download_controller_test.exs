defmodule ForgeWeb.BuildDownloadControllerTest do
  @moduledoc """
  The browser's download out of a kept command copy (`docs/design/ui.md` § The explorer,
  criteria 16, 31 and 34): who may ask, which copy is reachable, which paths are refused before the
  machine is asked, and the status each way of not answering has. The bytes' passage from a real
  machine is `Forge.Explore`'s own test; the machine here is `Forge.FakeExplore`.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.BuildFixtures
  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Forge.{FakeExplore, FakeWorker}

  setup :register_and_log_in_user

  setup %{user: user} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    worker = FakeWorker.connect()
    {project, ticket} = ticket_on(user)
    [command] = invoke_builds(ticket, worker, [[]])
    job = keep(command, worker)
    FakeExplore.install(%{"src/main.rs" => {:file, "fn main() {}\n"}})
    %{worker: worker, project: project, ticket: ticket, job: job}
  end

  defp download(ctx, query \\ "") do
    "/tickets/#{ctx.project.name}/#{ctx.ticket.number}/builds/#{ctx.job.id}/download" <> query
  end

  test "asks the machine for the whole copy, a folder or a file, and passes its answer on", ctx do
    conn = get(ctx.conn, download(ctx))
    assert response(conn, 200) == "archive of "
    assert_received {:explored, :download, ""}

    conn = get(ctx.conn, download(ctx, "?path=src%2Fmain.rs"))
    assert response(conn, 200) == "archive of src/main.rs"
    assert_received {:explored, :download, "src/main.rs"}
  end

  test "reads a path that is not text from `path64`", ctx do
    encoded = Base.url_encode64(<<0xFF, 0xFE>>, padding: false)
    conn = get(ctx.conn, download(ctx, "?path64=#{encoded}"))
    assert response(conn, 200)
    assert_received {:explored, :download, <<0xFF, 0xFE>>}
  end

  test "refuses a path outside the copy before the machine is asked", ctx do
    for path <- ["..%2Fetc", "%2Fetc%2Fshadow", "a%2F..%2Fb", "a%2F%2Fb"] do
      conn = get(ctx.conn, download(ctx, "?path=#{path}"))
      assert response(conn, 400) =~ "That path is not one inside the copy"
    end

    conn = get(ctx.conn, download(ctx, "?path64=!!"))
    assert response(conn, 400)
    refute_received {:explored, _op, _path}
  end

  test "says why when the machine cannot answer, with the status the API gives it", ctx do
    for {code, status, words} <- [
          {:machine_not_answering, 504, "did not answer in 15 seconds"},
          {:machine_not_connected, 503, "is not connected"},
          {:machine_outdated, 409, "older release"},
          {:copy_gone, 404, "no longer there"}
        ] do
      FakeExplore.fail(code)
      conn = get(ctx.conn, download(ctx))
      assert response(conn, status) =~ words
    end
  end

  test "answers as a ticket that does not exist to a person who is not a member", ctx do
    conn = log_in_user(build_conn(), Forge.AccountsFixtures.user_fixture())

    assert_error_sent 404, fn -> get(conn, download(ctx)) end
    refute_received {:explored, _op, _path}
  end

  test "answers as one that does not exist for another ticket's copy and for no id at all", ctx do
    worker = FakeWorker.connect()
    {_project, other_ticket} = ticket_on(ctx.user)
    [command] = invoke_builds(other_ticket, worker, [[]])
    other = keep(command, worker)

    assert_error_sent 404, fn ->
      get(ctx.conn, download(%{ctx | job: other}))
    end

    assert_error_sent 404, fn -> get(ctx.conn, download(%{ctx | job: %{id: "nope"}})) end
    refute_received {:explored, _op, _path}
  end

  test "needs somebody signed in", ctx do
    conn = get(build_conn(), download(ctx))
    assert redirected_to(conn) =~ "/users/log-in"
    refute_received {:explored, _op, _path}
  end
end
