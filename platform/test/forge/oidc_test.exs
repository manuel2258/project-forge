defmodule Forge.OidcTest do
  @moduledoc """
  The OIDC flow, end to end, against an issuer the test signs itself (`Forge.FakeIssuer`).

  `Forge.Accounts.Oidc` owns the provider list and the shape of what comes out; `assent` owns the
  protocol. So what is asserted here is both halves of that seam: that a good login yields the
  `(issuer, subject, email)` this platform keys on, and that the refusals a wrapper can silently
  swallow — a wrong signature, a replayed nonce, a token for another client, an expired one —
  still come back as errors after passing through it.

  A wrapper that returned `{:ok, _}` for any of those would be worse than no wrapper, because
  every caller above it is written as though a success means the issuer vouched for the user.
  """

  # **Not `async: true`.** `Forge.FakeIssuer.install/1` puts the provider list and the HTTP
  # adapter in `Application.put_env`, which is node-global: two modules installing at once
  # restore each other's state on exit, and a provider configured here leaks into any async
  # test that renders the login page. That was a real flake — two of five full-suite runs
  # failed, and `ForgeWeb.UserLive.LoginTest`, which predates OIDC, failed with it.
  use ExUnit.Case, async: false

  alias Forge.Accounts.Oidc
  alias Forge.FakeIssuer

  @redirect_uri "http://localhost:4002/auth/oidc/test/callback"

  setup do
    FakeIssuer.install()
  end

  defp start(provider) do
    {:ok, url, session} = Oidc.authorize_url(provider, @redirect_uri)
    %{url: url, session: session}
  end

  defp finish(provider, session, opts) do
    FakeIssuer.will_issue(Keyword.put_new(opts, :nonce, session.nonce))
    state = Keyword.get(opts, :state, session.state)

    Oidc.callback(provider, @redirect_uri, %{"code" => "the-code", "state" => state}, session)
  end

  describe "providers" do
    test "a configured provider is found by the id that appears in its URL", %{provider: provider} do
      assert [^provider] = Oidc.providers()
      assert Oidc.provider("test") == provider
      assert Oidc.provider("nope") == nil
    end

    test "a node with none configured offers none" do
      Application.put_env(:forge, Forge.Accounts.Oidc, [])
      assert Oidc.providers() == []
      assert Oidc.provider("test") == nil
    end
  end

  describe "authorize_url/2" do
    # Length is not unguessability: a hard-coded constant satisfies `byte_size(_) > 16` forever.
    # A nonce that does not change per login is what lets an ID token captured from one login be
    # replayed into another, which is the entire reason this value exists.
    test "a nonce is new every login, not merely long", %{provider: provider} do
      %{session: first} = start(provider)
      %{session: second} = start(provider)

      refute first.nonce == second.nonce
      refute first.state == second.state
      refute first.code_verifier == second.code_verifier
    end

    test "sends the browser to the issuer's authorization endpoint", %{provider: provider} do
      %{url: url} = start(provider)

      assert url =~ "https://issuer.example.test/authorize"
      assert url =~ "client_id=forge-test-client"
      assert url =~ "scope=openid+email+profile"
      assert url =~ URI.encode_www_form(@redirect_uri)
    end

    # All three are what makes the callback verifiable at all: without them a callback URL is a
    # login anyone who can make the browser follow one can complete.
    test "and keeps a state, a nonce and a PKCE challenge for the way back", %{
      provider: provider
    } do
      %{url: url, session: session} = start(provider)

      assert is_binary(session.state) and byte_size(session.state) > 16
      assert is_binary(session.nonce) and byte_size(session.nonce) > 16
      assert is_binary(session.code_verifier) and byte_size(session.code_verifier) > 16

      assert url =~ "code_challenge_method=S256"
      assert url =~ "state=#{session.state}"
      assert url =~ "nonce=#{session.nonce}"
      # The verifier is the secret half and must never be the half that travels.
      refute url =~ session.code_verifier
    end
  end

  describe "callback/4" do
    test "yields the identity the issuer vouched for", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:ok, claims} =
               finish(provider, session, sub: "abc-123", email: "person@example.org")

      assert claims == %{
               issuer: "https://issuer.example.test",
               subject: "abc-123",
               email: "person@example.org"
             }
    end

    # The signature is the whole of why any of this can be believed.
    test "refuses a token signed by something that is not the issuer", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, wrong_key: true)
    end

    # The nonce binds the token to *this* login. Without the check, a token captured from
    # another one replays.
    test "refuses a token whose nonce is not the one this login sent", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, nonce: "some-other-nonce")
    end

    # The state binds the callback to this browser.
    test "refuses a callback whose state is not the one this login sent", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, state: "not-the-state")
    end

    test "refuses a token addressed to a different client", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, aud: "somebody-elses-client")
    end

    test "refuses a token from a different issuer", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, iss: "https://evil.example.test")
    end

    test "refuses an expired token", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, _reason} = finish(provider, session, expires_in: -30)
    end

    # Its own answer rather than a generic failure: this one is a provider an operator has to go
    # and reconfigure, and `ForgeWeb.OidcController` says so instead of "could not be completed".
    test "a provider that yields no email address says which problem that is", %{
      provider: provider
    } do
      %{session: session} = start(provider)

      assert {:error, :no_email} = finish(provider, session, email: nil)
    end

    # An issuer where anybody may type any address into their own profile is an issuer that can
    # otherwise park a colleague's address on this node permanently: the pending row still holds
    # it, and refusing an account suspends it rather than freeing the address.
    test "an address the issuer says it has not verified is refused", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:error, :email_unverified} =
               finish(provider, session, extra: %{"email_verified" => false})
    end

    # `false` is the only unambiguous case. Issuers that take the address from a directory, where
    # it cannot be self-asserted, omit the claim entirely, and reading "did not say" as "said no"
    # would lock those out.
    test "an issuer that does not mention verification is still allowed", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:ok, %{email: "a@example.org"}} = finish(provider, session, [])
    end

    test "an address the issuer says it has verified is allowed", %{provider: provider} do
      %{session: session} = start(provider)

      assert {:ok, %{email: "a@example.org"}} =
               finish(provider, session, extra: %{"email_verified" => true})
    end
  end

  describe "the ID token's signing algorithm" do
    # The fake issuer signs RS256. A provider that says it expects ES256 must therefore refuse
    # this token — which is what proves the configured value reaches `assent` at all, rather
    # than the default quietly applying and the setting doing nothing.
    test "a token signed with an algorithm the provider does not expect is refused", %{
      provider: provider
    } do
      elsewhere = %{provider | id_token_alg: "ES256"}
      %{session: session} = start(elsewhere)

      assert {:error, reason} = finish(elsewhere, session, [])
      assert Oidc.describe_error(reason) =~ "Expected `alg` in ID Token to be \"ES256\""
    end

    test "the default expects what almost every issuer signs with", %{provider: provider} do
      assert provider.id_token_alg == "RS256"
      %{session: session} = start(provider)

      assert {:ok, _claims} = finish(provider, session, [])
    end
  end

  describe "describe_error/1" do
    # The reachable leak: `client_secret_basic` puts the secret in a request header, and assent
    # 0.3.1's Req adapter hands those request headers back inside the `%HTTPResponse{}` that its
    # errors carry. An expired authorization code is enough to get here.
    test "a failed token exchange never describes itself with the client secret", %{
      provider: provider
    } do
      %{session: session} = start(provider)
      FakeIssuer.will_issue(nonce: session.nonce, token_status: 401)

      {:error, reason} =
        Oidc.callback(
          provider,
          @redirect_uri,
          %{"code" => "the-code", "state" => session.state},
          session
        )

      described = Oidc.describe_error(reason)

      refute described =~ "shh"
      refute described =~ Base.encode64("forge-test-client:shh")
      refute described =~ "authorization"
      refute described =~ "Basic"

      # Still worth logging: it says what failed and where, which is the whole point of keeping
      # a line at all.
      assert described =~ "Assent.InvalidResponseError"
      assert described =~ "status=401"
    end

    # `inspect/1` is what this replaced, and `Exception.message/1` is not an alternative:
    # `HTTPResponse.format/1` prints every header too. Both are checked here so that a future
    # "simplification" back to either one fails.
    test "the secret is in the error it is given, so the redaction is doing the work", %{
      provider: provider
    } do
      %{session: session} = start(provider)
      FakeIssuer.will_issue(nonce: session.nonce, token_status: 401)

      {:error, reason} =
        Oidc.callback(
          provider,
          @redirect_uri,
          %{"code" => "the-code", "state" => session.state},
          session
        )

      # The secret travels base64-encoded inside the Basic credential, which is exactly why a
      # `refute ... =~ "shh"` on its own would be a test that cannot fail.
      credential = Base.encode64("forge-test-client:shh")

      assert inspect(reason) =~ credential
      assert Exception.message(reason) =~ credential
    end

    test "a query string is stripped, because it carries state and a code" do
      error = %Assent.InvalidResponseError{
        response: %Assent.HTTPAdapter.HTTPResponse{
          status: 400,
          request_url: "https://issuer.example.test/token?code=secret-code&state=s",
          headers: [{"authorization", "Basic c2hoOnNoaA=="}],
          body: "{}"
        }
      }

      described = Oidc.describe_error(error)

      assert described =~ "url=https://issuer.example.test/token"
      refute described =~ "secret-code"
      refute described =~ "Basic"
    end

    # `Assent.MissingParamError` is `defexception [:key, :params]`, and `:params` is the whole
    # callback query — the authorization code included.
    test "a missing parameter is named without printing the parameters it came with" do
      error = %Assent.MissingParamError{
        key: "code",
        params: %{"code" => "secret-code", "state" => "s"}
      }

      described = Oidc.describe_error(error)

      assert described =~ "key=code"
      refute described =~ "secret-code"
    end

    test "an unrecognised reason is named rather than printed" do
      refute Oidc.describe_error({:raw, "a-token-that-should-not-be-logged"}) =~ "a-token"
    end

    # These are what an operator actually sees when an issuer is misconfigured, so they have to
    # survive the redaction rather than be flattened into "an unrecognised error".
    test "assent's own validation sentences survive, because they are the useful part" do
      assert Oidc.describe_error("The ID Token has expired") == "The ID Token has expired"
    end

    test "a sentence from the far end cannot flood the log" do
      described = Oidc.describe_error(String.duplicate("a", 5_000))

      assert String.length(described) == 200
    end

    test "a plain atom reason stays readable" do
      assert Oidc.describe_error(:no_email) == ":no_email"
    end
  end
end
