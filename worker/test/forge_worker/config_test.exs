defmodule ForgeWorker.ConfigTest do
  @moduledoc """
  What cloud-init told the machine it is, as the worker reads it back.

  Most of this module is bookkeeping. One thing in it is not: where the credential goes.
  `docs/design/worker-channel.md` § Authentication is three paragraphs on the token being a
  header and never a query parameter — a URL is written down by every proxy, access log and
  tracing span between the worker and the platform, and this token grants the channel for the
  life of the machine. Nothing asserted that until this file existed.
  """

  use ExUnit.Case, async: false

  alias ForgeWorker.Config

  @token "a-long-lived-machine-secret"

  setup do
    Application.put_env(:forge_worker, :worker_id, "w-1")
    Application.put_env(:forge_worker, :token, @token)
    Application.put_env(:forge_worker, :platform_url, "https://forge.example:8443")

    on_exit(fn ->
      Enum.each([:worker_id, :token, :platform_url], &Application.delete_env(:forge_worker, &1))
    end)
  end

  # The whole point of § Authentication: the URI names the worker and carries nothing else. A
  # query parameter here would put the machine's identity into every access log on the path,
  # where anyone with read access to that log can replay it until the worker is destroyed.
  test "the socket URI names the worker and carries no credential" do
    uri = Config.socket_uri()

    assert uri == "wss://forge.example:8443/worker/websocket?worker_id=w-1"
    refute uri =~ @token

    # Not just "the token is absent from the string": the query has exactly one key, so a
    # credential smuggled in under any other name is caught too.
    assert uri |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.keys() ==
             ["worker_id"]
  end

  # `docs/deploy.md` puts a TLS proxy in front of the platform, which is when a plaintext dial
  # stops being a development convenience and becomes the token in the clear on the wire. The
  # scheme is derived from the platform's own URL rather than configured twice.
  test "a platform reached over TLS is dialled over TLS, and a plain one is not" do
    assert Config.socket_uri() =~ ~r{^wss://}

    Application.put_env(:forge_worker, :platform_url, "http://platform.test:4000")
    assert Config.socket_uri() == "ws://platform.test:4000/worker/websocket?worker_id=w-1"
  end

  # `x-forge-worker-token` rather than `authorization`, and that is not a matter of taste:
  # Phoenix's socket transport forwards only `x-` prefixed headers to `connect/3` — that is
  # what `:x_headers` in the endpoint's `connect_info` means — so a worker that sent this as
  # `authorization` would be refused by a platform that never saw the header.
  test "the credential rides the x- header the socket transport actually forwards" do
    assert Config.socket_headers() == [{"x-forge-worker-token", @token}]
  end

  # A machine with no credential yet must not present an empty one as if it were real, and it
  # must not crash the handshake either.
  test "a machine with no token sends an empty header rather than nothing at all" do
    without(:token, "FORGE_WORKER_TOKEN", fn ->
      assert Config.socket_headers() == [{"x-forge-worker-token", ""}]
    end)
  end

  # "Nothing starts until it has" is the moduledoc's claim, and `ForgeWorker.Application` acts
  # on it: a machine missing any one of the three is one that would dial nowhere, or dial the
  # platform anonymously, if this said yes.
  test "a machine is configured only when it knows all three of the things it needs" do
    assert Config.configured?()

    for {key, env} <- [
          {:worker_id, "FORGE_WORKER_ID"},
          {:token, "FORGE_WORKER_TOKEN"},
          {:platform_url, "FORGE_PLATFORM_URL"}
        ] do
      without(key, env, fn -> refute Config.configured?(), "#{key} missing yet configured" end)
    end
  end

  # The environment is the fallback, so a key has to be gone from both places to be gone. The
  # suite runs this module synchronously, which is what makes touching the OS environment safe.
  defp without(key, env, fun) do
    app_value = Application.get_env(:forge_worker, key)
    env_value = System.get_env(env)
    Application.delete_env(:forge_worker, key)
    System.delete_env(env)

    try do
      fun.()
    after
      if app_value, do: Application.put_env(:forge_worker, key, app_value)
      if env_value, do: System.put_env(env, env_value)
    end
  end
end
