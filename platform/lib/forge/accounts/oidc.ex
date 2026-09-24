defmodule Forge.Accounts.Oidc do
  @moduledoc """
  The OIDC half of authentication: configured issuers in, a verified identity out.

  `docs/design/identity.md` § Authentication. This module owns the *provider list* and the shape
  of what a login yields; it owns none of the protocol. `Assent.Strategy.OIDC` does discovery,
  JWKS, signature verification and the claim rules, and that split is deliberate — the note's
  § What the first implementation settled says why a hand-rolled one was the wrong trade.

  Two calls, one per leg of the redirect:

      {:ok, url, session_params} = Oidc.authorize_url(provider, redirect_uri)
      {:ok, %{issuer: _, subject: _, email: _}} = Oidc.callback(provider, redirect_uri, params, session_params)

  `session_params` carries `state`, `nonce` and the PKCE verifier. It belongs in the caller's
  session cookie and must be deleted when the callback reads it; `ForgeWeb.OidcController` is
  the only caller and does both.

  **The issuer recorded on the identity is the configured one**, not a claim. `assent` has
  already checked the `iss` claim against it by the time this returns, so the two agree — but
  the one written down is the one an operator configured, because that is the half of the key
  that has to keep meaning the same thing when a provider is renamed.
  """

  alias Forge.Accounts.Oidc.Provider

  @type claims :: %{issuer: String.t(), subject: String.t(), email: String.t()}

  @doc """
  Every configured provider, in configuration order. Empty is the ordinary case: a node with no
  issuers configured shows no buttons and behaves exactly as it did before this existed.
  """
  @spec providers() :: [Provider.t()]
  def providers, do: Application.get_env(:forge, __MODULE__, [])[:providers] || []

  @doc "The provider with that id, or nil. The id is what appears in the URL."
  @spec provider(String.t()) :: Provider.t() | nil
  def provider(id) when is_binary(id), do: Enum.find(providers(), &(&1.id == id))

  @doc """
  Where to send the browser, and what to keep until it comes back.

  The returned `session_params` are `state`, `nonce` and the PKCE `code_verifier`. Losing them
  means the callback cannot be verified, which is the point of them.
  """
  @spec authorize_url(Provider.t(), String.t()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def authorize_url(%Provider{} = provider, redirect_uri) do
    config = Keyword.put(config(provider, redirect_uri), :nonce, nonce())

    case Assent.Strategy.OIDC.authorize_url(config) do
      {:ok, %{url: url, session_params: session_params}} -> {:ok, url, session_params}
      {:ok, other} -> {:error, {:no_session_params, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Exchanges the code and returns the identity the issuer vouched for.

  `{:error, :no_email}` is its own answer rather than a generic failure: it is a provider whose
  scope does not yield an address, which is a misconfiguration somebody has to go and fix, and
  the message an operator sees says so.
  """
  @spec callback(Provider.t(), String.t(), map(), map()) ::
          {:ok, claims()} | {:error, :no_email | :no_subject | term()}
  def callback(%Provider{} = provider, redirect_uri, params, session_params) do
    config =
      provider
      |> config(redirect_uri)
      |> Keyword.put(:session_params, session_params)

    with {:ok, %{user: user}} <- Assent.Strategy.OIDC.callback(config, params) do
      identify(provider, user)
    end
  end

  @doc """
  What may be written to the log about a failed login, and nothing else.

  **Never `inspect/1` an `assent` error.** `Assent.InvalidResponseError` and
  `Assent.UnexpectedResponseError` are `defexception [:response]`, and assent 0.3.1's Req adapter
  shadows its `headers` variable — it binds the *request* headers at
  `deps/assent/lib/assent/http_adapter/req.ex:18` and re-maps that same variable into the
  returned `%HTTPResponse{}` at lines 37-42. So the response struct comes back holding the
  request's headers, and for `client_secret_basic` — which `Assent.Strategy.OIDC` puts in force
  by default, `deps/assent/lib/assent/strategies/oidc.ex:275` — one of them is
  `authorization: Basic base64(client_id:client_secret)`. Nothing in assent derives `Inspect`.

  `Exception.message/1` is no safer: `HTTPResponse.format/1` prints `Response headers:` followed
  by every header (`deps/assent/lib/assent/http_adapter.ex:56-57`), which are those same request
  headers.

  An expired authorization code is enough to reach this — a consent tab left open past the
  issuer's code TTL — and a wrong client secret reaches it on every single attempt.

  So the reason is reduced to fields that diagnose a failure without carrying a credential: the
  error's module, the HTTP status, the request URL with its query stripped, and a missing
  parameter's name. `Assent.MissingParamError` is `defexception [:key, :params]` and `:params` is
  the whole callback query including `code`, so the key is taken and the params are not.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(reason) when is_atom(reason), do: inspect(reason)

  def describe_error(%_{} = error) do
    [inspect(error.__struct__) | safe_details(error)] |> Enum.join(" ")
  end

  # **A binary is assent's own sentence, and it is the most useful thing in this whole function.**
  # Every ID-token validation failure comes back as one: "Invalid JWT signature for ID Token",
  # "Invalid `nonce` included in ID Token", "The ID Token has expired". They interpolate claim
  # values — an audience, an issuer — which come out of the token, never out of the config, so
  # no credential of this platform's can reach one. Discarding them would leave an operator
  # debugging a failing issuer with nothing at all.
  #
  # Capped, because a claim value is whatever the far end put in it.
  def describe_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)

  # Anything else — a bare tuple, a map — could be carrying a token, so it is named, not printed.
  def describe_error(_other), do: "an unrecognised error"

  defp safe_details(error) do
    Enum.flat_map(
      [
        {:status, Map.get(error, :response) |> field(:status)},
        {:url, Map.get(error, :response) |> field(:request_url) |> strip_query()},
        {:key, Map.get(error, :key)},
        {:error, Map.get(error, :error)}
      ],
      fn
        {_name, nil} -> []
        {name, value} -> ["#{name}=#{value}"]
      end
    )
  end

  defp field(%_{} = struct, key), do: Map.get(struct, key)
  defp field(_other, _key), do: nil

  defp strip_query(nil), do: nil
  defp strip_query(url) when is_binary(url), do: url |> String.split("?", parts: 2) |> hd()
  defp strip_query(_other), do: nil

  # `sub` is checked as well as `email`, though a token without one cannot pass validation: this
  # is the value that becomes half of a primary key, and a nil here would be a row that every
  # future login for that issuer collides with.
  defp identify(%Provider{} = provider, user) do
    case {user["sub"], user["email"]} do
      {sub, email} when is_binary(sub) and is_binary(email) and sub != "" and email != "" ->
        if verified?(user["email_verified"]) do
          {:ok, %{issuer: provider.issuer, subject: sub, email: email}}
        else
          {:error, :email_unverified}
        end

      {sub, _email} when is_binary(sub) and sub != "" ->
        {:error, :no_email}

      _other ->
        {:error, :no_subject}
    end
  end

  # **An explicit `false` is refused; an absent claim is not.**
  #
  # `docs/design/identity.md` § What the first implementation settled argues that an address
  # already in use is refused rather than adopted, which is what stops a takeover. This is the
  # other half, and it is about a *free* address: an issuer where anyone may type any address
  # into their profile can otherwise park `colleague@corp.com` on this node forever, because a
  # pending row still holds the address and "Refuse" only suspends it.
  #
  # The absent case stays permitted deliberately. Plenty of issuers — including private ones
  # where the address comes from a directory and cannot be self-asserted — omit the claim
  # entirely, and treating "did not say" as "said no" would lock those out. `false` is not
  # ambiguous, and it is the only case this refuses.
  defp verified?(false), do: false
  defp verified?("false"), do: false
  defp verified?(_other), do: true

  defp config(%Provider{} = provider, redirect_uri) do
    [
      client_id: provider.client_id,
      client_secret: provider.client_secret,
      base_url: provider.issuer,
      redirect_uri: redirect_uri,
      authorization_params: [scope: provider.scope],
      id_token_signed_response_alg: provider.id_token_alg,
      # PKCE. `true` because assent does generate this one, and hands the verifier back in
      # `session_params` where it belongs.
      code_verifier: true
    ] ++ http_opts()
  end

  # **Generated here, and not by assent.** `Assent.Strategy.OIDC`'s moduledoc says it will make
  # one when `:nonce` is `true`; in 0.3.1 it does not — it sends the atom, stores the atom, and
  # compares the atom with itself on the way back, which is a nonce check that passes for every
  # token. The library's own `## Nonce` section shows this instead, and it is what the tests
  # assert: a value long enough to be unguessable, and one the callback actually compares.
  defp nonce, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # The HTTP client assent talks to the issuer with. `Req` is already a dependency and is the
  # default it would pick anyway; naming it here is what gives the tests somewhere to put an
  # issuer of their own.
  defp http_opts do
    case Application.get_env(:forge, __MODULE__, [])[:http_adapter] do
      nil -> []
      adapter -> [http_adapter: adapter]
    end
  end

  # There is no `:strategy` override here on purpose. There was one, justified as "swappable so
  # the tests can put an issuer of their own" — but nothing sets it: `Forge.FakeIssuer` injects
  # at `:http_adapter`, and `grep -rn "strategy:" config test` finds nothing. An indirection
  # whose only stated reason is false is a claim nothing checks, so the strategy is named.
end
