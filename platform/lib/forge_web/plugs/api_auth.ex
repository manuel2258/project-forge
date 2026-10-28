defmodule ForgeWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates API requests by bearer token and assigns the current scope.

  Two kinds of bearer: a user's API token, then a project token (`Forge.Git.Tokens`). Every
  failure — unknown, expired, revoked, a job's, git-only — is the same 401, so the response says
  nothing about which.
  """

  import Plug.Conn

  alias Forge.Accounts
  alias Forge.Accounts.Scope
  alias Forge.Git.Tokens

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, token} <- bearer(header),
         {:ok, scope} <- scope(token) do
      assign(conn, :current_scope, scope)
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

  defp scope(secret) do
    case Accounts.get_user_by_api_token(secret) do
      %{} = user ->
        {:ok, Scope.for_user(user)}

      nil ->
        with {:ok, token} <- Tokens.authenticate_api(secret),
             do: {:ok, Scope.for_token(token, Forge.Projects.get!(token.project_id))}
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
