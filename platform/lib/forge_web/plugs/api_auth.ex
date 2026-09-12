defmodule ForgeWeb.Plugs.ApiAuth do
  @moduledoc "Authenticates API requests by bearer token and assigns the current scope."

  import Plug.Conn

  alias Forge.Accounts
  alias Forge.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, token} <- bearer(header),
         %{} = user <- Accounts.get_user_by_api_token(token) do
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

  # The scheme is case-insensitive (RFC 9110); clients send both `Bearer` and `bearer`.
  defp bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme) == "bearer" and String.trim(token) != "",
          do: {:ok, String.trim(token)},
          else: :error

      _ ->
        :error
    end
  end
end
