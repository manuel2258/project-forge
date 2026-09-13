defmodule ForgeWeb.StoreControllerTest do
  # Not async: the store's directory and token lifetime are application environment, which
  # is global, and these tests move both.
  use ForgeWeb.ConnCase, async: false

  alias Forge.Storage
  alias Forge.Storage.Token

  setup do
    dir = Path.join(System.tmp_dir!(), "forge-store-http-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:forge, Storage, [])
    Application.put_env(:forge, Storage, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:forge, Storage, previous)
      File.rm_rf!(dir)
    end)

    :ok
  end

  describe "GET /store/*key" do
    test "serves the object to a token minted for it", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "{\"type\":\"started\"}")

      conn = get(conn, ~p"/store/#{key}?token=#{Token.sign(:get, key)}")

      assert response(conn, 200) == "{\"type\":\"started\"}"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "refuses a token minted for another key", %{conn: conn} do
      {:ok, _info} = Storage.put("job/j1/secret.jsonl", "not yours")
      {:ok, _info} = Storage.put("job/j2/own.jsonl", "mine")

      conn =
        get(conn, ~p"/store/job/j1/secret.jsonl?token=#{Token.sign(:get, "job/j2/own.jsonl")}")

      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)
    end

    test "refuses a put token used to read", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      conn = get(conn, ~p"/store/#{key}?token=#{Token.sign(:put, key)}")

      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)
    end

    test "refuses a missing or malformed token", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      assert %{"error" => %{"reason" => "invalid_token"}} =
               conn |> get(~p"/store/#{key}") |> json_response(401)

      assert %{"error" => %{"reason" => "invalid_token"}} =
               conn |> get(~p"/store/#{key}?token=nonsense") |> json_response(401)
    end

    test "refuses an expired token", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")
      token = Token.sign(:get, key)

      previous = Application.get_env(:forge, Storage, [])
      Application.put_env(:forge, Storage, Keyword.put(previous, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Storage, previous) end)

      conn = get(conn, ~p"/store/#{key}?token=#{token}")

      assert %{"error" => %{"reason" => "expired_token"}} = json_response(conn, 401)
    end

    test "says not_found for a key the store does not have", %{conn: conn} do
      key = "job/j1/missing.jsonl"

      conn = get(conn, ~p"/store/#{key}?token=#{Token.sign(:get, key)}")

      assert %{"error" => %{"reason" => "not_found"}} = json_response(conn, 404)
    end

    # Even a validly signed token does not make a malformed key readable: the store checks the
    # key itself, after the token says the caller may ask about it.
    test "refuses a key that is not a key", %{conn: conn} do
      conn = get(conn, ~p"/store/job/J1/x?token=#{Token.sign(:get, "job/J1/x")}")

      assert %{"error" => %{"reason" => "invalid_key"}} = json_response(conn, 400)
    end
  end

  describe "PUT /store/*key" do
    test "stores the body and reports what it wrote", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put(~p"/store/#{key}?token=#{Token.sign(:put, key)}", "written by the worker")

      assert %{"key" => ^key, "size" => 21, "hash" => hash} = json_response(conn, 200)
      assert hash == Storage.hash("written by the worker")
      assert {:ok, "written by the worker"} = Storage.get(key)
    end

    test "refuses to overwrite", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "first")

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put(~p"/store/#{key}?token=#{Token.sign(:put, key)}", "second")

      assert %{"error" => %{"reason" => "exists"}} = json_response(conn, 409)
      assert {:ok, "first"} = Storage.get(key)
    end

    test "refuses a get token used to write", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put(~p"/store/#{key}?token=#{Token.sign(:get, key)}", "nope")

      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)
      assert {:error, :not_found} = Storage.get(key)
    end

    test "refuses a body over the configured ceiling", %{conn: conn} do
      key = "seed/sample/s1"
      previous = Application.get_env(:forge, Storage, [])
      Application.put_env(:forge, Storage, Keyword.put(previous, :max_upload_bytes, 8))
      on_exit(fn -> Application.put_env(:forge, Storage, previous) end)

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> put(~p"/store/#{key}?token=#{Token.sign(:put, key)}", String.duplicate("x", 64))

      assert %{"error" => %{"reason" => "too_large"}} = json_response(conn, 413)
      assert {:error, :not_found} = Storage.get(key)
    end
  end
end
