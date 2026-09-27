defmodule ForgeWeb.StoreControllerTest do
  # Not async: the store's directory and token lifetime are application environment, which
  # is global, and these tests move both.
  use ForgeWeb.ConnCase, async: false

  alias Forge.Storage
  alias Forge.Storage.Token

  # In a header, never the query string: a URL reaches every proxy log between the worker and
  # the platform. See docs/design/storage.md § The token is a header.
  defp with_token(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-store-http-#{System.unique_integer([:positive])}"
      )

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

      conn = get(with_token(conn, Token.sign(:get, key)), ~p"/store/#{key}")

      assert response(conn, 200) == "{\"type\":\"started\"}"
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    end

    test "refuses a token minted for another key", %{conn: conn} do
      {:ok, _info} = Storage.put("job/j1/secret.jsonl", "not yours")
      {:ok, _info} = Storage.put("job/j2/own.jsonl", "mine")

      conn =
        get(
          with_token(conn, Token.sign(:get, "job/j2/own.jsonl")),
          ~p"/store/job/j1/secret.jsonl"
        )

      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)
    end

    test "refuses a put token used to read", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      conn = get(with_token(conn, Token.sign(:put, key)), ~p"/store/#{key}")

      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)
    end

    test "refuses a missing or malformed token", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      # No header at all, a header that is not a Bearer, and a Bearer that is not a token.
      assert %{"error" => %{"reason" => "missing_token"}} =
               conn |> get(~p"/store/#{key}") |> json_response(401)

      assert %{"error" => %{"reason" => "missing_token"}} =
               conn
               |> put_req_header("authorization", Token.sign(:get, key))
               |> get(~p"/store/#{key}")
               |> json_response(401)

      assert %{"error" => %{"reason" => "invalid_token"}} =
               conn |> with_token("nonsense") |> get(~p"/store/#{key}") |> json_response(401)
    end

    # The shape this replaced. A token in the URL is a token in every proxy log on the path, so
    # it is not merely deprecated — it does not authenticate. docs/design/storage.md.
    test "a token in the query string does not authenticate", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      assert %{"error" => %{"reason" => "missing_token"}} =
               conn |> get(~p"/store/#{key}?token=#{Token.sign(:get, key)}") |> json_response(401)
    end

    test "refuses an expired token", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")
      # The lifetime is signed into the token, so it is the configuration at signing that counts.
      previous = Application.get_env(:forge, Storage, [])
      Application.put_env(:forge, Storage, Keyword.put(previous, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Storage, previous) end)

      token = Token.sign(:get, key)
      conn = get(with_token(conn, token), ~p"/store/#{key}")

      assert %{"error" => %{"reason" => "expired_token"}} = json_response(conn, 401)
    end

    # A transcript is uploaded when its job stops, which can be the job's whole wall clock after
    # the token was minted. The lifetime is signed in, so a token that outlasts the configured
    # one is still good once the configured one is gone — here, zero.
    test "a token minted to outlast something is good past the ordinary lifetime", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      previous = Application.get_env(:forge, Storage, [])
      Application.put_env(:forge, Storage, Keyword.put(previous, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Storage, previous) end)

      token = Token.sign(:get, key, outlasting_ms: 60_000)
      assert conn |> with_token(token) |> get(~p"/store/#{key}") |> response(200) == "x"
    end

    # Milliseconds, like every other duration in the platform's config: 999 of them is no whole
    # second, so with no ordinary lifetime this token is born expired. Read as seconds it would
    # last a quarter of an hour.
    test "outlasting is counted in milliseconds", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"
      {:ok, _info} = Storage.put(key, "x")

      previous = Application.get_env(:forge, Storage, [])
      Application.put_env(:forge, Storage, Keyword.put(previous, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Storage, previous) end)

      token = Token.sign(:get, key, outlasting_ms: 999)
      conn = get(with_token(conn, token), ~p"/store/#{key}")

      assert %{"error" => %{"reason" => "expired_token"}} = json_response(conn, 401)
    end

    test "says not_found for a key the store does not have", %{conn: conn} do
      key = "job/j1/missing.jsonl"

      conn = get(with_token(conn, Token.sign(:get, key)), ~p"/store/#{key}")

      assert %{"error" => %{"reason" => "not_found"}} = json_response(conn, 404)
    end

    # Even a validly signed token does not make a malformed key readable: the store checks the
    # key itself, after the token says the caller may ask about it.
    test "refuses a key that is not a key", %{conn: conn} do
      conn = get(with_token(conn, Token.sign(:get, "job/J1/x")), ~p"/store/job/J1/x")

      assert %{"error" => %{"reason" => "invalid_key"}} = json_response(conn, 400)
    end
  end

  describe "PUT /store/*key" do
    test "stores the body and reports what it wrote", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> with_token(Token.sign(:put, key))
        |> put(~p"/store/#{key}", "written by the worker")

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
        |> with_token(Token.sign(:put, key))
        |> put(~p"/store/#{key}", "second")

      assert %{"error" => %{"reason" => "exists"}} = json_response(conn, 409)
      assert {:ok, "first"} = Storage.get(key)
    end

    # `docs/design/storage.md` § Serving: a job's groups of files go under one prefix of its own,
    # whose member keys are not known when the token is minted.
    test "a prefix token writes any key under its prefix, and nothing else", %{conn: conn} do
      token = Token.sign_prefix("job/j1/out-abc/")

      put_with = fn key ->
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> with_token(token)
        |> put("/store/" <> key, "bytes")
      end

      assert %{"key" => "job/j1/out-abc/1"} = json_response(put_with.("job/j1/out-abc/1"), 200)

      assert %{"key" => "job/j1/out-abc/2/x"} =
               json_response(put_with.("job/j1/out-abc/2/x"), 200)

      for outside <- [
            "job/j1/out-abc",
            "job/j1/out-abcd/1",
            "job/j1/transcript-1.jsonl",
            "seed/p/s"
          ] do
        assert %{"error" => %{"reason" => "wrong_key"}} = json_response(put_with.(outside), 403),
               "wrote #{outside}"
      end

      # It reads nothing, not even what it wrote.
      conn = get(with_token(conn, token), ~p"/store/job/j1/out-abc/1")
      assert %{"error" => %{"reason" => "wrong_key"}} = json_response(conn, 403)

      # And overwrites nothing: the store refuses an existing key whatever the token.
      assert %{"error" => %{"reason" => "exists"}} =
               json_response(put_with.("job/j1/out-abc/1"), 409)
    end

    # The key is checked as the store checks it before it is compared, so a traversal that starts
    # with the prefix as a string is not under it.
    test "a prefix token refuses a key that only looks as if it is under the prefix" do
      assert Token.verify(
               Token.sign_prefix("job/j1/out-abc/"),
               :put,
               "job/j1/out-abc/../../seed/p/s"
             ) ==
               {:error, :wrong_key}

      assert_raise ArgumentError, fn -> Token.sign_prefix("job/j1/out-abc") end
    end

    test "refuses a get token used to write", %{conn: conn} do
      key = "job/j1/transcript-1.jsonl"

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> with_token(Token.sign(:get, key))
        |> put(~p"/store/#{key}", "nope")

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
        |> with_token(Token.sign(:put, key))
        |> put(~p"/store/#{key}", String.duplicate("x", 64))

      assert %{"error" => %{"reason" => "too_large"}} = json_response(conn, 413)
      assert {:error, :not_found} = Storage.get(key)
    end
  end
end
