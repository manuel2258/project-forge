defmodule Forge.Look.GuardTest do
  # Sync: the token is application environment, which the whole endpoint reads.
  use ExUnit.Case, async: false

  alias Forge.Look.Guard

  @base "http://127.0.0.1:4002"

  setup do
    token = Guard.generate()
    Guard.put_token(token)
    on_exit(fn -> Guard.put_token(nil) end)
    %{token: token}
  end

  defp get(path, cookie \\ nil, headers \\ []) do
    headers = if cookie, do: [{"cookie", "#{Guard.cookie()}=#{cookie}"} | headers], else: headers
    # A fresh connection each time: a pooled one the server closed after a refusal is reused and
    # reads as a transport error that says nothing about the guard.
    headers =
      if List.keymember?(headers, "connection", 0),
        do: headers,
        else: [{"connection", "close"} | headers]

    Req.get!(@base <> path, headers: headers, retry: false, redirect: false)
  end

  @upgrade [
    {"connection", "Upgrade"},
    {"upgrade", "websocket"},
    {"sec-websocket-version", "13"},
    {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
  ]

  test "a page, a live socket, the worker socket and git are refused without the cookie", _ do
    for {path, headers} <- [
          {"/", []},
          {"/users/log-in", []},
          {"/live/websocket?vsn=2.0.0", @upgrade},
          {"/worker/websocket?vsn=2.0.0", @upgrade},
          {"/git/anything.git/info/refs?service=git-upload-pack", []}
        ] do
      response = get(path, nil, headers)
      assert response.status == 403, "#{path} was served: #{response.status}"
      assert response.body == "forbidden"
    end
  end

  test "a wrong cookie is refused as a missing one is, an empty or a partial one included", %{
    token: token
  } do
    assert get("/users/log-in", "not-the-token").status == 403
    assert get("/users/log-in", "").status == 403
    assert get("/users/log-in", String.slice(token, 0, 10)).status == 403
    assert get("/users/log-in", token <> "x").status == 403
    assert get("/live/websocket?vsn=2.0.0", "not-the-token", @upgrade).status == 403
  end

  test "with the cookie the app answers as itself", %{token: token} do
    assert get("/users/log-in", token).status == 200
    refute get("/live/websocket?vsn=2.0.0", token, @upgrade).status == 403

    # The worker socket drops a connection that does not authenticate as a worker, which is the
    # app answering as itself: reaching it at all is what the cookie buys.
    worker =
      try do
        get("/worker/websocket?vsn=2.0.0", token, @upgrade).status
      rescue
        Req.TransportError -> :closed_by_the_app
      end

    refute worker == 403
    refute get("/git/anything.git/info/refs?service=git-upload-pack", token).status == 403
  end

  test "a token is 256 bits and never the same twice" do
    token = Guard.generate()
    assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    refute token == Guard.generate()
  end

  test "with no token configured everything passes" do
    Guard.put_token(nil)
    assert get("/users/log-in").status == 200
  end
end
