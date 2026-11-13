defmodule Forge.Look.Setups.SigninProvider do
  @moduledoc """
  The sign-in screens with a provider configured (`21o`, `21p`, `21n`, `21g`).

  It puts one OIDC provider, *Example ID*, into the application's environment — the look's own
  VM, which ends with the run — with `Issuer` below as its HTTP client, so no request leaves the
  look's network namespace. `Issuer` answers only discovery, and names as the authorization
  endpoint **this app's own callback, carrying `error=access_denied`**: following
  *Continue with Example ID* is then a real round trip through `ForgeWeb.OidcController` — the
  session's `state` set, spent, and the refusal quoted on the page (`21n`) — without a provider.

  Users: `member` (an approved account, to log in and out as). Paths: `provider` (the provider
  screen asked for by name), `link` (an emailed link for an unconfirmed account, `21g`).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures

  alias Forge.Accounts.Oidc

  @impl true
  def build do
    provider = %Oidc.Provider{
      id: "look",
      name: "Example ID",
      issuer: "https://id.example.test",
      client_id: "look",
      client_secret: "look-not-a-secret"
    }

    Application.put_env(:forge, Oidc, providers: [provider], http_adapter: __MODULE__.Issuer)

    member = user_fixture()

    {token, _hashed} =
      generate_user_magic_link_token(unconfirmed_user_fixture(%{email: "pat@example.com"}))

    %{
      users: %{"member" => member},
      paths: %{"provider" => "/users/log-in?way=provider", "link" => "/users/log-in/#{token}"}
    }
  end

  defmodule Issuer do
    @moduledoc """
    Discovery for the look's provider: an authorization endpoint that is the app's own callback
    with the provider's refusal already in it. The rest of the query assent appends lands in
    `then`, which nothing reads, and `state` arrives as itself.
    """

    @behaviour Assent.HTTPAdapter

    alias Assent.HTTPAdapter.HTTPResponse

    @impl Assent.HTTPAdapter
    def request(_method, url, _body, _headers, _opts) do
      if String.ends_with?(url, "/.well-known/openid-configuration") do
        {:ok, {_ip, port}} = ForgeWeb.Endpoint.server_info(:http)
        app = "http://127.0.0.1:#{port}"

        body = %{
          "issuer" => "https://id.example.test",
          "authorization_endpoint" => app <> "/auth/oidc/look/callback?error=access_denied&then=",
          "token_endpoint" => "https://id.example.test/token",
          "jwks_uri" => "https://id.example.test/jwks"
        }

        {:ok,
         %HTTPResponse{
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: Jason.encode!(body)
         }}
      else
        {:ok, %HTTPResponse{status: 404, headers: [], body: "no such endpoint"}}
      end
    end
  end
end
