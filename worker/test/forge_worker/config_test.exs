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
  # The platform schedules a job only when its slice fits what this figure says is left, so a
  # machine that overstates it is one that lets a build kill its neighbours. Three ways to
  # arrive at it, and the arithmetic in the third is the part with a trap in it.
  describe "the memory budget" do
    # `config/config.exs` configures a budget for every environment, so these restore what was
    # there rather than deleting it: a test that leaves the key gone changes what every test
    # after it reads, which is a failure that depends on the seed and looks like a flake.
    setup do
      previous = Application.get_env(:forge_worker, :memory_budget)
      reserve = Application.get_env(:forge_worker, :memory_reserve)

      on_exit(fn ->
        restore(:memory_budget, previous)
        restore(:memory_reserve, reserve)
        System.delete_env("FORGE_MEMORY_BUDGET")
      end)

      # Each test here is about one source speaking; the others are silenced first so that what
      # answers is the one the test named.
      Application.delete_env(:forge_worker, :memory_budget)
      Application.delete_env(:forge_worker, :memory_reserve)
      System.delete_env("FORGE_MEMORY_BUDGET")
      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:forge_worker, key)
    defp restore(key, value), do: Application.put_env(:forge_worker, key, value)

    test "is what the operator configured, in bytes" do
      Application.put_env(:forge_worker, :memory_budget, 3_221_225_472)
      assert Config.memory_budget() == 3_221_225_472
    end

    # The environment carries strings and the scheduler compares numbers, so a machine
    # configured this way would otherwise offer "2048" and be compared against an integer.
    test "read from the environment is a number, not the string it arrived as" do
      System.put_env("FORGE_MEMORY_BUDGET", "2048")

      assert Config.memory_budget() == 2048
    end

    test "with nobody saying, it is what the machine has less the reserve" do
      Application.put_env(:forge_worker, :memory_reserve, 1_000_000)

      assert Config.memory_budget() == total_memory() - 1_000_000
    end

    # A reserve larger than the machine is a machine that offers nothing, which the platform
    # reads as "assign it nothing". Without the floor it would offer a negative figure, and
    # `slice_bytes <= budget` is a comparison that a negative number passes on the wrong side.
    test "never offers less than nothing" do
      Application.put_env(:forge_worker, :memory_reserve, 1_000_000_000_000_000)

      assert Config.memory_budget() == 0
    end

    defp total_memory do
      [_line, kb] = Regex.run(~r/MemTotal:\s+(\d+) kB/, File.read!("/proc/meminfo"))
      String.to_integer(kb) * 1024
    end
  end

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
  describe "cores" do
    setup do
      previous = Application.get_env(:forge_worker, :cores)

      on_exit(fn ->
        restore(:cores, previous)
        System.delete_env("FORGE_CORES")
      end)

      Application.delete_env(:forge_worker, :cores)
      System.delete_env("FORGE_CORES")
      :ok
    end

    test "is what the operator configured" do
      Application.put_env(:forge_worker, :cores, 4)
      assert Config.cores() == 4
    end

    # Same trap as the budget: the environment carries strings and the gate compares numbers,
    # so a machine configured this way would offer "4" and be compared against an integer.
    test "read from the environment is a number, not the string it arrived as" do
      System.put_env("FORGE_CORES", "4")
      assert Config.cores() == 4
    end

    test "with nobody saying, it is what the VM was actually given" do
      assert Config.cores() == :erlang.system_info(:logical_processors_online)
      assert Config.cores() > 0
    end
  end

  describe "the kinds a worker accepts" do
    setup do
      previous = Application.get_env(:forge_worker, :accepts)

      on_exit(fn ->
        restore(:accepts, previous)
        System.delete_env("FORGE_ACCEPTS")
      end)

      Application.delete_env(:forge_worker, :accepts)
      System.delete_env("FORGE_ACCEPTS")
      :ok
    end

    # Nil and not a list of everything: the platform reads "said nothing" as "takes anything",
    # and a worker that enumerated the kinds it knew would refuse one added in a migration it
    # has not been rebuilt for.
    test "with nobody saying, it is nothing rather than a list" do
      assert Config.accepts() == nil
    end

    test "is a comma-separated list, because the config disk has no room for structure" do
      System.put_env("FORGE_ACCEPTS", "command")
      assert Config.accepts() == ["command"]

      System.put_env("FORGE_ACCEPTS", "workflow,chat")
      assert Config.accepts() == ["workflow", "chat"]
    end

    test "tolerates the spacing a person types" do
      System.put_env("FORGE_ACCEPTS", " workflow , chat ")
      assert Config.accepts() == ["workflow", "chat"]
    end

    # An empty or comma-only value is somebody who meant to say nothing, and reading it as a
    # list of no kinds would be a machine that takes no work at all — silently, and only on the
    # machine that was misconfigured.
    test "a value with nothing in it is nobody saying" do
      for written <- ["", "   ", ",", " , , "] do
        System.put_env("FORGE_ACCEPTS", written)
        assert Config.accepts() == nil, "#{inspect(written)} should be nobody saying"
      end
    end
  end

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
