defmodule Forge.Look.Gateway do
  @moduledoc """
  The plug of `Forge.Look.Device.listen/2`: the platform's endpoint, JavaScript of a test's own at
  the paths it names, or a 502 while its flag is
  set — what a proxy sends a browser when it cannot reach the platform behind it. Test support.
  """

  @behaviour Plug

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, {down, scripts}) do
    cond do
      :atomics.get(down, 1) == 1 ->
        conn |> Plug.Conn.send_resp(502, "Bad Gateway") |> Plug.Conn.halt()

      script = Map.get(scripts, conn.request_path) ->
        # Past the guard, like everything else the browser fetches (`Forge.Look.Guard`).
        if Forge.Look.Guard.allowed?(conn) do
          conn
          |> Plug.Conn.put_resp_content_type("text/javascript")
          |> Plug.Conn.send_resp(200, script)
          |> Plug.Conn.halt()
        else
          Forge.Look.Guard.refuse(conn)
        end

      true ->
        ForgeWeb.Endpoint.call(conn, ForgeWeb.Endpoint.init([]))
    end
  end
end
