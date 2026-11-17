defmodule Forge.TestEndpoint do
  @moduledoc """
  The test endpoint's address, as this run has it.

  **The suite serves on a port the kernel picks** (`port: 0` in `config/test.exs`), because it
  used to serve on 4002 and every platform suite on a machine claimed that one name on the
  loopback all of its jobs share: the second suite — a gate beside another ticket's gate, or a
  `mix test` by hand beside either — died at boot with `:eaddrinuse` before it ran a test, on a
  commit nothing was wrong with (17 of the 51 failed gates between 2026-11-07 and 2026-11-16).

  A port nobody chose is a port nobody knows until the listener is up, and the config says `0`.
  `publish/0`, run once from `test_helper.exs`, tells everything that reads the address what it
  is: the application environment (`Forge.Git.Url` reads it there) and the running endpoint
  (`ForgeWeb.Endpoint.url/0` reads that). `port/0` and `base_url/1` are for the tests that dial
  the endpoint themselves.

  A `PORT` in the environment still wins (`config/runtime.exs`), and is published like any other.
  """

  @endpoint ForgeWeb.Endpoint

  @doc "The port the endpoint is listening on."
  @spec port() :: :inet.port_number()
  def port do
    {:ok, {_ip, port}} = @endpoint.server_info(:http)
    port
  end

  @doc """
  A URL for the endpoint. `host` is `localhost` unless asked: that is the host the endpoint is
  configured with, and LiveView refuses a socket whose origin is another.
  """
  @spec base_url(String.t()) :: String.t()
  def base_url(host \\ "localhost"), do: "http://#{host}:#{port()}"

  @doc """
  Makes the bound port the configured one, in the application environment and in the running
  endpoint. Returns the port.
  """
  @spec publish() :: :inet.port_number()
  def publish do
    port = port()

    env = Application.get_env(:forge, @endpoint, [])
    http = Keyword.put(Keyword.get(env, :http, []), :port, port)
    Application.put_env(:forge, @endpoint, Keyword.put(env, :http, http))

    # The endpoint's whole configuration, because `Phoenix.Config` deletes every key a change
    # leaves out, but its own handle and the keys it sets itself (`deps/phoenix/lib/phoenix/
    # config.ex`, `update/3`): the table holds the config the endpoint was started with plus what
    # it derived.
    config =
      @endpoint
      |> :ets.tab2list()
      |> Enum.reject(&match?({:__config__, _pid}, &1))
      |> Keyword.put(:http, Keyword.put(@endpoint.config(:http), :port, port))

    :ok = @endpoint.config_change([{@endpoint, config}], [])
    port
  end
end
