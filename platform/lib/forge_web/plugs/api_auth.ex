defmodule ForgeWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates API requests by bearer token and assigns the current scope."

  import Plug.Conn

  alias Forge.Accounts
  alias Forge.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         %{} = user <- Accounts.get_user_by_api_token(String.trim(token)) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{
          error: %{reason: "unauthorized", detail: "a valid bearer token is required"}
        })
        |> halt()
    end
  end
end
