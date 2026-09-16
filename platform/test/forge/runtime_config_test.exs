defmodule Forge.RuntimeConfigTest do
  @moduledoc """
  What `config/runtime.exs` decides for a release, read the way a release reads it.

  The endpoint's address is a security property rather than a preference. `force_ssl` is
  configured with `rewrite_on: [:x_forwarded_proto]`, so the platform decides it is on TLS by
  believing a request header, and that header is only trustworthy while the proxy is the only
  thing that can send one. An address the proxy does not own is an address from which a session
  cookie can be accepted over cleartext.

  Nothing else could have caught what this caught. `config/prod.exs` says loopback and says why;
  `runtime.exs` is read afterwards and `Config` deep-merges keyword lists, so a single
  `ip: {0, 0, 0, 0, 0, 0, 0, 0}` left there by the Phoenix generator won — quietly, on every
  release, in a file that reads as though the first one decided it. So this reads both files in
  order, merges them as `Config` does, and asserts the address that actually comes out.
  """

  use ExUnit.Case, async: false

  @prod Path.expand("../../config/prod.exs", __DIR__)
  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  @required %{
    "SECRET_KEY_BASE" => String.duplicate("s", 64),
    "DATABASE_URL" => "ecto://forge:forge@localhost/forge"
  }

  # Cleared for the duration: each one would otherwise let whatever is in the shell that ran the
  # suite decide what this reads, and two of them are exactly what is under test.
  @cleared ~w(FORGE_HTTP_IP PORT PHX_HOST FORGE_VAPID_PUBLIC_KEY)

  setup do
    names = @cleared ++ Map.keys(@required)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    Enum.each(@cleared, &System.delete_env/1)
    System.put_env(@required)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp endpoint do
    @prod
    |> Config.Reader.read!(env: :prod)
    |> Config.Reader.merge(Config.Reader.read!(@runtime, env: :prod))
    |> get_in([:forge, ForgeWeb.Endpoint])
  end

  test "a release binds loopback, so only the proxy can claim the request was on TLS" do
    assert endpoint()[:http][:ip] == {127, 0, 0, 1}
    assert endpoint()[:http][:port] == 4000
  end

  test "FORGE_HTTP_IP is what widens it, and it survives the prod block" do
    System.put_env("FORGE_HTTP_IP", "10.0.2.2")

    assert endpoint()[:http][:ip] == {10, 0, 2, 2}

    # Widening the binding must not cost the port, which lives in the same keyword list.
    assert endpoint()[:http][:port] == 4000
  end

  test "an address that is not one is refused at boot rather than ignored" do
    System.put_env("FORGE_HTTP_IP", "0.0.0.0/0")

    assert_raise RuntimeError, ~r/FORGE_HTTP_IP must be an IP address/, &endpoint/0
  end

  # The host is what `check_origin` and every generated URL are built from, and it is the one
  # thing the proxy cannot supply for us.
  test "the public host comes from PHX_HOST" do
    System.put_env("PHX_HOST", "forge.example.org")

    assert endpoint()[:url][:host] == "forge.example.org"
    assert endpoint()[:url][:scheme] == "https"
  end
end
