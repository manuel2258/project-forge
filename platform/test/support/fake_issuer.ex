defmodule Forge.FakeIssuer do
  @moduledoc """
  An OpenID provider the test signs itself, plugged in where `assent` would reach the network.

  It implements `Assent.HTTPAdapter`, so the discovery document, the JWKS and the token endpoint
  are all answered from here and the flow under test is the real one: a real authorization URL, a
  real code exchange, a real RS256 ID token verified against a real JWKS. What is fake is the
  network, and nothing else.

  That matters because the thing worth testing is the *refusals* — a token signed with the wrong
  key, a `nonce` that does not match, an expired one, one addressed to another client. Each of
  those is one option here, and each has to be produced honestly or the test proves nothing.

      %{provider: provider} = FakeIssuer.install()
      {:ok, url, session} = Oidc.authorize_url(provider, "http://localhost/cb")
      FakeIssuer.will_issue(nonce: session.nonce, sub: "abc", email: "a@b.c")
      {:ok, claims} = Oidc.callback(provider, "http://localhost/cb", %{"code" => "c", "state" => session.state}, session)

  State lives in the process dictionary, which is enough because `assent` calls the adapter
  synchronously from whoever started the flow — the test process, or a controller running in it
  under `Plug.Test`.
  """

  @behaviour Assent.HTTPAdapter

  alias Assent.HTTPAdapter.HTTPResponse
  alias Forge.Accounts.Oidc.Provider

  @issuer "https://issuer.example.test"
  @client_id "forge-test-client"

  # Generated once, at compile time, because a 2048-bit key per test is seconds of the suite
  # spent proving RSA works. The second one exists for exactly one test: a token signed by
  # something that is not this issuer must not be accepted.
  @signing_key :public_key.generate_key({:rsa, 2048, 65_537})
  @other_key :public_key.generate_key({:rsa, 2048, 65_537})

  @doc "Points `Forge.Accounts.Oidc` at this module, and hands back the provider to drive."
  @spec install(keyword()) :: %{provider: Provider.t(), issuer: String.t()}
  def install(opts \\ []) do
    previous = Application.get_env(:forge, Forge.Accounts.Oidc, [])

    provider = %Provider{
      id: Keyword.get(opts, :id, "test"),
      name: "Test Provider",
      issuer: @issuer,
      client_id: @client_id,
      client_secret: "shh"
    }

    Application.put_env(
      :forge,
      Forge.Accounts.Oidc,
      Keyword.merge(previous, providers: [provider], http_adapter: __MODULE__)
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:forge, Forge.Accounts.Oidc, previous)
    end)

    Process.put(__MODULE__, %{})

    %{provider: provider, issuer: @issuer}
  end

  @doc """
  What the token endpoint will sign next.

  `:nonce` has to be the one from `session_params` for the token to validate — passing a
  different one is how the nonce check is shown to be doing something. `:extra` merges arbitrary
  claims into the token, which is how an issuer that tries to grant itself something is written.
  """
  @spec will_issue(keyword()) :: :ok
  def will_issue(opts) do
    Process.put(__MODULE__, Map.new(opts))
    :ok
  end

  @impl Assent.HTTPAdapter
  def request(_method, url, _body, headers, _opts) do
    cond do
      String.ends_with?(url, "/.well-known/openid-configuration") -> json(discovery(), headers)
      String.ends_with?(url, "/jwks") -> json(jwks(), headers)
      String.ends_with?(url, "/token") -> token_response(headers)
      true -> {:ok, %HTTPResponse{status: 404, headers: headers, body: "no such endpoint"}}
    end
  end

  # **The response carries the request's headers, because the real adapter does.**
  #
  # This looks wrong and is deliberate. `Assent.HTTPAdapter.Req` shadows its `headers` variable:
  # it binds the request headers at `deps/assent/lib/assent/http_adapter/req.ex:18` and then
  # re-maps that same variable into the `%HTTPResponse{}` it returns at lines 37-42. Every
  # response assent hands back in 0.3.1 therefore holds the *request* headers — including the
  # `authorization: Basic base64(client_id:client_secret)` that `client_secret_basic` puts there.
  #
  # Our own `content-type` goes first because `Assent.HTTPAdapter.decode_response/2` takes the
  # first match (`deps/assent/lib/assent/http_adapter.ex:163`), and the request's is
  # `application/x-www-form-urlencoded`. The real Req adapter does not hit this because Req has
  # already decoded the body by then.
  #
  # A fake that returned honest response headers would be a fake in which
  # `Forge.Accounts.Oidc.describe_error/1` has nothing to redact, so the test proving the client
  # secret stays out of the log would pass against code that leaks it. That is the one thing a
  # fixture must never do.
  defp json(body, headers) do
    {:ok,
     %HTTPResponse{
       status: 200,
       headers: [{"content-type", "application/json"} | headers],
       body: Jason.encode!(body)
     }}
  end

  # A token endpoint that refuses. `:token_status` is how a wrong client secret, an expired
  # authorization code and a failing issuer are all written: assent turns any 400..599 into an
  # `Assent.InvalidResponseError` carrying this whole struct.
  defp token_response(headers) do
    case Process.get(__MODULE__, %{}) do
      %{token_status: status} ->
        {:ok,
         %HTTPResponse{
           status: status,
           headers: [{"content-type", "application/json"} | headers],
           body: Jason.encode!(%{"error" => "invalid_client"})
         }}

      _ok ->
        json(token(), headers)
    end
  end

  defp discovery do
    %{
      "issuer" => @issuer,
      "authorization_endpoint" => @issuer <> "/authorize",
      "token_endpoint" => @issuer <> "/token",
      "jwks_uri" => @issuer <> "/jwks",
      "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
    }
  end

  # One key and no `kid`, which assent accepts: `find_key/2` takes the only key when the header
  # names none. Fewer moving parts than a key id nothing here rotates.
  defp jwks do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = @signing_key

    %{
      "keys" => [
        %{
          "kty" => "RSA",
          "use" => "sig",
          "alg" => "RS256",
          "n" => encode_int(modulus),
          "e" => encode_int(exponent)
        }
      ]
    }
  end

  defp encode_int(int), do: int |> :binary.encode_unsigned() |> Base.url_encode64(padding: false)

  defp token do
    opts = Process.get(__MODULE__, %{})
    now = System.system_time(:second)

    claims =
      %{
        "iss" => Map.get(opts, :iss, @issuer),
        "sub" => Map.get(opts, :sub, "subject-1"),
        "aud" => Map.get(opts, :aud, @client_id),
        "exp" => now + Map.get(opts, :expires_in, 600),
        "iat" => now,
        "nonce" => Map.get(opts, :nonce)
      }
      |> put_email(opts)
      |> Map.merge(Map.get(opts, :extra, %{}))

    key = if Map.get(opts, :wrong_key, false), do: @other_key, else: @signing_key

    {:ok, id_token} =
      Assent.JWTAdapter.AssentJWT.sign(claims, "RS256", pem(key), json_library: Jason)

    %{"access_token" => "at", "token_type" => "bearer", "id_token" => id_token}
  end

  # `:no_email` is a provider whose scope yields no address, which is a real misconfiguration and
  # therefore a real case: the claim is left out entirely rather than set to nil.
  defp put_email(claims, %{email: nil}), do: claims

  defp put_email(claims, opts),
    do: Map.put(claims, "email", Map.get(opts, :email, "a@example.org"))

  defp pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
end
