defmodule ForgeWeb.SignIn do
  @moduledoc """
  How a person signs in, as the sign-in screens draw it and as the device remembers it
  (`docs/design/ui.md` § Signing in).

  Three things live here because each is read in one place and written in another:

  - **The remembered method.** A successful sign-in sets `_forge_last_sign_in` to `password`,
    `magic` or `oidc:<provider>` (`remember/2`, from `ForgeWeb.UserSessionController` and
    `ForgeWeb.OidcController`); the login page's `live_session` reads it back through
    `session/1`. Anything else in the cookie — a value it never wrote, a provider the node no
    longer has — reads as nothing, and nothing the cookie holds is ever drawn: it only decides
    which screen opens first. It names a method and never a person, so it outlives a log-out.
  - **A provider's refusal** (`21n`). The callback hands the login page the provider and the
    OAuth error code it came back with; only the codes OAuth 2.0 and OpenID Connect register are
    quoted, each with its own plain reading (`refusal_reading/1`), because the code arrives on a
    URL anybody can write.
  - **An issuer's name**, for the accounts page and You: the configured provider's name, or the
    issuer's host when no provider names it any more.
  """

  import Plug.Conn

  alias Forge.Accounts.Oidc

  @cookie "_forge_last_sign_in"
  @cookie_options [max_age: 365 * 24 * 60 * 60, http_only: true, same_site: "Lax"]

  @typedoc "How a device last signed in, once read back and checked."
  @type method :: :password | :magic | {:oidc, String.t()}

  @doc "The cookie's name."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @doc """
  Remembers on this device how it signed in: `:password`, `:magic` or `{:oidc, provider_id}`.
  Called only after the sign-in succeeded, on the response that carries the session.
  """
  @spec remember(Plug.Conn.t(), method()) :: Plug.Conn.t()
  def remember(conn, method), do: put_resp_cookie(conn, @cookie, encode(method), @cookie_options)

  defp encode(:password), do: "password"
  defp encode(:magic), do: "magic"
  defp encode({:oidc, id}) when is_binary(id), do: "oidc:" <> id

  @doc """
  The login pages' `live_session` session: the remembered method, checked, under
  `"last_sign_in"` — `nil` for no cookie and for any value `remember/2` would not have written.
  """
  @spec session(Plug.Conn.t()) :: %{String.t() => method() | nil}
  def session(conn) do
    conn = fetch_cookies(conn)
    %{"last_sign_in" => remembered(conn.cookies[@cookie])}
  end

  @doc """
  What a cookie value means, or `nil`. A provider counts only while the node still has it, so a
  device that last used a provider since removed opens as if it had no cookie.
  """
  @spec remembered(term()) :: method() | nil
  def remembered("password"), do: :password
  def remembered("magic"), do: :magic

  def remembered("oidc:" <> id) do
    if Oidc.provider(id), do: {:oidc, id}
  end

  def remembered(_other), do: nil

  # The registered error codes of an authorization response — RFC 6749 § 4.1.2.1 and OpenID
  # Connect Core § 3.1.2.6 — each read as what the person can do about it. A code outside this
  # table is not quoted at all (`refusal_reading/1`).
  @readings %{
    "access_denied" => "You cancelled, or your account there isn't allowed to use forge.",
    "login_required" => "It wants you signed in there first. Try again.",
    "interaction_required" => "It wants you to do something there first. Try again.",
    "consent_required" => "It wants you to agree to share your address with forge. Try again.",
    "account_selection_required" => "It wants you to pick an account there. Try again.",
    "server_error" => "Something went wrong on its side. Try again.",
    "temporarily_unavailable" => "It is busy or down for a moment. Try again shortly.",
    "invalid_request" => "It refused what forge asked for. An administrator should check it.",
    "unauthorized_client" =>
      "forge is not allowed to sign people in there. An administrator should check it.",
    "unsupported_response_type" =>
      "It does not offer the sign-in forge asks for. An administrator should check it.",
    "invalid_scope" =>
      "It does not offer what forge asked to read. An administrator should check it.",
    "invalid_request_uri" => "It refused what forge asked for. An administrator should check it.",
    "invalid_request_object" =>
      "It refused what forge asked for. An administrator should check it.",
    "request_not_supported" =>
      "It refused what forge asked for. An administrator should check it.",
    "request_uri_not_supported" =>
      "It refused what forge asked for. An administrator should check it.",
    "registration_not_supported" =>
      "It refused what forge asked for. An administrator should check it."
  }

  @doc "The plain reading of a registered OAuth error code, or `nil` for any other string."
  @spec refusal_reading(term()) :: String.t() | nil
  def refusal_reading(code) when is_binary(code), do: Map.get(@readings, code)
  def refusal_reading(_code), do: nil

  @doc """
  The refusal to hand the login page through the flash: the provider and the code, or `nil` when
  the code is not one this module quotes.
  """
  @spec refusal(String.t(), term()) :: String.t() | nil
  def refusal(provider_id, code) do
    if refusal_reading(code), do: code <> ":" <> provider_id
  end

  @doc """
  A refusal as the login page draws it, from what `refusal/2` put in the flash: the provider's
  name and issuer, the code and its reading — or `nil` when the code is not registered or the
  provider is not configured. Checked again here and not only where it was written, because this
  is where it is drawn.
  """
  @spec read_refusal(term()) :: map() | nil
  def read_refusal(value) when is_binary(value) do
    with [code, id] <- String.split(value, ":", parts: 2),
         reading when is_binary(reading) <- refusal_reading(code),
         %Oidc.Provider{} = provider <- Oidc.provider(id) do
      %{id: id, name: provider.name, host: host(provider.issuer), code: code, reading: reading}
    else
      _other -> nil
    end
  end

  def read_refusal(_value), do: nil

  @doc """
  How an account signs in, in the words You and Accounts both use (UX pass, D20): each identity as
  its issuer's name and the subject it sent, then `password` when it has one — or, with neither,
  `email link`, since that is the way left. Accounts used to call the same account `local`.
  """
  @spec ways(%{hashed_password: String.t() | nil}, [{String.t(), String.t()}]) :: [String.t()]
  def ways(user, identities) do
    named = for {issuer, subject} <- identities, do: "#{issuer_label(issuer)} · #{subject}"
    password = if user.hashed_password, do: ["password"], else: []

    case named ++ password do
      [] -> ["email link"]
      ways -> ways
    end
  end

  @doc """
  How an issuer is named on a page: the configured provider's name, or its host when the node no
  longer has a provider for it.
  """
  @spec issuer_label(String.t()) :: String.t()
  def issuer_label(issuer) do
    case Enum.find(Oidc.providers(), &(&1.issuer == issuer)) do
      %Oidc.Provider{name: name} -> name
      nil -> host(issuer)
    end
  end

  @doc "An issuer URL's host, or the URL itself when it has none."
  @spec host(String.t()) :: String.t()
  def host(issuer) do
    case URI.parse(issuer) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> issuer
    end
  end
end
