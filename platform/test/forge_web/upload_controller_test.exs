defmodule ForgeWeb.UploadControllerTest do
  @moduledoc """
  The page's way of sending a file (`docs/design/attachments.md` § Staging, claiming and the sweep):
  a member's session and a CSRF header, the bytes counted as they arrive, and a miss for anyone
  else. What it keeps is staged and counts for nothing until an act claims it.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.GitFixtures

  alias Forge.Attachments.Upload
  alias Forge.{Projects, Repo, Storage}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "up-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    limits = Application.get_env(:forge, Forge.Attachments, [])

    on_exit(fn ->
      Application.put_env(:forge, Forge.Storage, store)
      Application.put_env(:forge, Forge.Attachments, limits)
    end)

    %{project: project}
  end

  defp upload(conn, project, body, name \\ "shot.png", encoded \\ nil) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
    |> Plug.Conn.put_req_header(
      "x-file-name",
      encoded || URI.encode(name, &URI.char_unreserved?/1)
    )
    |> post(~p"/projects/#{project.name}/uploads", body)
  end

  test "keeps the bytes as a staged upload and says what it kept", %{
    conn: conn,
    project: project,
    user: user
  } do
    conn = upload(conn, project, "pixels", "Screen Shot é.png")

    assert %{"id" => id, "name" => "Screen Shot é.png", "size" => 6} = json_response(conn, 200)

    assert %Upload{size: 6, key: key, user_id: user_id, project_id: project_id} =
             Repo.get!(Upload, id)

    assert {:ok, "pixels"} = Storage.get(key)
    assert user_id == user.id
    assert project_id == project.id
  end

  test "past the limit it is 413 and nothing is kept",
       %{conn: conn, project: project} do
    Application.put_env(:forge, Forge.Attachments, file_bytes: 10)

    conn = upload(conn, project, String.duplicate("x", 11))

    assert %{"error" => %{"reason" => "too_large", "limit" => limit}} = json_response(conn, 413)
    assert limit =~ "for one file"
    assert Repo.aggregate(Upload, :count) == 0

    dir = Application.get_env(:forge, Forge.Storage)[:dir]
    assert not File.dir?(Path.join(dir, "upload")) or File.ls!(Path.join(dir, "upload")) == []
  end

  test "exactly the limit is kept", %{conn: conn, project: project} do
    Application.put_env(:forge, Forge.Attachments, file_bytes: 10)

    assert %{"size" => 10} =
             conn |> upload(project, String.duplicate("x", 10)) |> json_response(200)
  end

  test "a body over a chunk is read whole", %{conn: conn, project: project} do
    body = :crypto.strong_rand_bytes(2_500_000)

    assert %{"size" => 2_500_000, "id" => id} =
             conn |> upload(project, body) |> json_response(200)

    {:ok, stored} = Storage.get(Repo.get!(Upload, id).key)
    assert stored == body
  end

  test "a name that is not valid text is a file", %{conn: conn, project: project} do
    assert %{"name" => "file"} =
             conn |> upload(project, "x", "bad", "%FF%FE") |> json_response(200)
  end

  test "a non-member gets a miss and nothing is kept", %{project: project} do
    stranger = Forge.AccountsFixtures.user_fixture()
    conn = build_conn() |> log_in_user(stranger)

    assert_error_sent 404, fn -> upload(conn, project, "x") end
    assert Repo.aggregate(Upload, :count) == 0
  end

  test "a visitor with no session is sent to log in", %{project: project} do
    conn = build_conn() |> upload(project, "x")
    assert redirected_to(conn) =~ "/users/log-in"
    assert Repo.aggregate(Upload, :count) == 0
  end

  test "a request without the CSRF token is refused", %{conn: conn, project: project} do
    conn = conn |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> Plug.Conn.put_req_header("content-type", "application/octet-stream")
      |> post(~p"/projects/#{project.name}/uploads", "x")
    end
  end

  describe "taking one back" do
    test "deletes the person's own and its bytes", %{conn: conn, project: project, user: user} do
      %{"id" => id} = conn |> upload(project, "x") |> json_response(200)
      key = Repo.get!(Upload, id).key

      assert build_conn()
             |> log_in_user(user)
             |> delete(~p"/projects/#{project.name}/uploads/#{id}")
             |> response(204)

      assert Repo.get(Upload, id) == nil
      assert {:error, :not_found} = Storage.stat(key)
    end

    test "leaves another member's alone", %{conn: conn, project: project} do
      %{"id" => id} = conn |> upload(project, "x") |> json_response(200)
      other = Forge.AccountsFixtures.user_fixture()
      Forge.ForgeFixtures.join!(project, other, :member)
      other_conn = build_conn() |> log_in_user(other)

      assert other_conn |> delete(~p"/projects/#{project.name}/uploads/#{id}") |> response(204)
      assert Repo.get(Upload, id)
    end
  end
end
