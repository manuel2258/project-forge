defmodule ForgeWeb.Plugs.McpOrigin do
  @moduledoc """
  Refuses a request to the MCP endpoint whose `Origin` is not the platform's own (403): a page in a
  browser must not be able to drive forge with a visitor's token, and the way MCP's transport asks
  servers to defend against it. A client that is not a browser sends no `Origin`, which passes.

  The platform's own is **the endpoint's configured URL, never the request's `Host`**: an attacker's
  name that resolves to the platform's address sends `Host: attacker` and `Origin: attacker`, and a
  comparison with the first would let it in.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] -> conn
      [origin] -> if own?(origin), do: conn, else: refuse(conn)
      _several -> refuse(conn)
    end
  end

  defp own?(origin), do: parts(origin) != nil and parts(origin) == parts(ForgeWeb.Endpoint.url())

  # An origin is a scheme, a host and a port and nothing else, read **strictly**: `URI.parse/1` is
  # lenient and reads `http://localhost:4000.evil.example` as host `localhost`, port 4000, which
  # would let a name that merely starts like the platform's own in. What does not match this
  # shape is no origin of ours, whatever it parses to. The default port of the scheme is filled in
  # on both sides, so `http://host` and `http://host:80` are one.
  defp parts(origin) when is_binary(origin) do
    case Regex.run(~r/\A(https?):\/\/([A-Za-z0-9.\-]+)(?::([0-9]{1,5}))?\z/, origin) do
      [_all, scheme, host] -> {scheme, String.downcase(host), default_port(scheme)}
      [_all, scheme, host, port] -> {scheme, String.downcase(host), String.to_integer(port)}
      nil -> nil
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80

  defp refuse(conn) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{
      error: %{reason: "forbidden", detail: "this origin may not use the MCP endpoint"}
    })
    |> halt()
  end
end
