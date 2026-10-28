defmodule ForgeWeb.Plugs.ApiAccess do
  @moduledoc """
  The two refusals a project token meets before an API action looks anything up.

  - `:writable`: a project token whose API access is not *write* gets 403 on a write. It runs
    before the ticket is loaded, so the refusal says nothing about whether the ticket exists — a
    read token cannot use it to probe.
  - `:person_only`: any project token gets 403 here. These routes are a person's (registering a
    project, the queue of what *they* are waiting on), whatever the token may do elsewhere.

  A user's token passes both: its limits are its user's memberships, enforced where they always
  were. See `docs/design/api-and-ui.md` § JSON API.
  """

  import Plug.Conn

  alias Forge.Accounts.Scope

  def init(opts), do: opts

  def call(conn, :writable) do
    case conn.assigns.current_scope do
      %Scope{token: %{api_access: :write}} -> conn
      %Scope{token: nil} -> conn
      _read_only -> forbidden(conn, "this token may read but not change anything")
    end
  end

  def call(conn, :person_only) do
    case conn.assigns.current_scope do
      %Scope{token: nil} -> conn
      _token -> forbidden(conn, "a project token cannot do this; it is a person's")
    end
  end

  defp forbidden(conn, detail) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: %{reason: "forbidden", detail: detail}})
    |> halt()
  end
end
