defmodule ForgeWeb.McpController do
  @moduledoc """
  `POST /mcp`, the MCP endpoint (`docs/design/api-and-ui.md` § MCP). The request is read and
  answered by `ForgeWeb.Mcp`; who is calling was decided by the pipeline before this runs. `GET`
  and `DELETE` are 405: forge keeps no session to end and opens no stream.
  """

  use ForgeWeb, :controller

  def post(conn, _params) do
    case ForgeWeb.Mcp.handle(conn.assigns.current_scope, conn.body_params) do
      :accepted -> send_resp(conn, 202, "")
      {:reply, reply} -> json(conn, reply)
    end
  end

  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(:method_not_allowed)
    |> json(%{error: %{reason: "method_not_allowed", detail: "POST a JSON-RPC request"}})
  end
end
