defmodule ForgeWeb.OidcController do
  @moduledoc """
  The two legs of an OIDC login: out to the issuer, and back.

  `docs/design/identity.md` § Authentication. Neither action carries a credential, which is what
  makes them `public` in `AuthorizationInventoryTest` — and why everything they decide has to be
  decided from what comes back rather than from who is asking.

  `state`, `nonce` and the PKCE verifier live in the session between the two, and the callback
  **deletes them before doing anything else**: a callback URL replayed from a browser history or
  a proxy log then has nothing left to match against.

  What a successful callback produces is a *pending* account on first login. It reaches
  `/users/pending` and stays there until a node admin approves it, exactly as a local first login
  does — an issuer authenticates, it does not admit.
  """

  use ForgeWeb, :controller

  require Logger

  alias Forge.Accounts
  alias Forge.Accounts.Oidc
  alias ForgeWeb.{SignIn, Toast, UserAuth}

  @session_key :oidc_session_params

  def request(conn, %{"provider" => id}) do
    with %Oidc.Provider{} = provider <- Oidc.provider(id),
         {:ok, url, session_params} <- Oidc.authorize_url(provider, redirect_uri(id)) do
      conn
      |> put_session(@session_key, session_params)
      |> redirect(external: url)
    else
      nil -> refuse(conn, "No such login provider.")
      {:error, reason} -> refuse(conn, "Could not reach the login provider.", id, reason)
    end
  end

  def callback(conn, %{"provider" => id} = params) do
    session_params = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    with %Oidc.Provider{} = provider <- Oidc.provider(id),
         :ok <- started(session_params),
         {:ok, claims} <- Oidc.callback(provider, redirect_uri(id), params, session_params),
         {:ok, user} <- Accounts.log_in_with_identity(claims) do
      conn
      |> Toast.put("Welcome!")
      |> SignIn.remember({:oidc, id})
      |> UserAuth.log_in_user(user, %{})
    else
      nil ->
        refuse(conn, "No such login provider.")

      {:error, :no_start} ->
        refuse(conn, "That login had already finished or was never started. Try again.")

      {:error, :email_taken} ->
        refuse(conn, "An account already exists for that address. Log in with it instead.")

      {:error, :no_email} ->
        refuse(conn, "The login provider returned no email address.", id, :no_email)

      # The provider said no, in a code of its own (`21n`). Quoted on the login page only when it
      # is a registered one; `SignIn.refusal/2` answers nil for anything else, which then reads as
      # any other failure. The code is logged either way, by `Oidc.describe_error/1`, which takes
      # the `error` field and never the description beside it.
      {:error, %Assent.CallbackError{error: code} = reason} ->
        case SignIn.refusal(id, code) do
          nil -> refuse(conn, "That login could not be completed.", id, reason)
          refusal -> refused(conn, refusal, id, reason)
        end

      {:error, :email_unverified} ->
        refuse(
          conn,
          "The login provider has not verified that address.",
          id,
          :email_unverified
        )

      {:error, reason} ->
        refuse(conn, "That login could not be completed.", id, reason)
    end
  end

  # An absent `state` is not an error the caller can be told apart from a wrong one: both are
  # "start again", and saying which would say whether a given callback URL had been used.
  defp started(nil), do: {:error, :no_start}
  defp started(_session_params), do: :ok

  # The issuer is told this at the start and checks it at the end, so it is derived from the
  # endpoint's own URL rather than configured: a second place to write it down is a second place
  # for it to be wrong, and being wrong here is a redirect that silently never works.
  defp redirect_uri(id), do: url(~p"/auth/oidc/#{id}/callback")

  # What went wrong reaches the log; what the browser is told does not name an issuer, a claim
  # or a reason. A login page that explains itself is a login page that enumerates. The one
  # exception is `refused/4`: a provider's own registered refusal code, which the browser carried
  # here in the URL itself and which says nothing about this node.
  defp refuse(conn, message, id \\ nil, reason \\ nil) do
    if reason, do: Logger.warning("oidc login via #{id} failed: #{Oidc.describe_error(reason)}")

    conn
    |> put_flash(:sign_in_error, message)
    |> redirect(to: ~p"/users/log-in?way=provider")
  end

  defp refused(conn, refusal, id, reason) do
    Logger.warning("oidc login via #{id} was refused: #{Oidc.describe_error(reason)}")

    conn
    |> put_flash(:oidc_refusal, refusal)
    |> redirect(to: ~p"/users/log-in?way=provider")
  end
end
