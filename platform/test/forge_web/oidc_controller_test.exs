defmodule ForgeWeb.OidcControllerTest do
  @moduledoc """
  An OIDC login as a browser performs it: two requests, and a session in between.

  `Forge.OidcTest` proves the protocol wrapper; this proves the part that only exists in the
  controller — that the `state`, `nonce` and PKCE verifier survive the redirect out and are gone
  after the redirect back, that a first login lands on the holding page rather than in the
  product, and that nothing a failed login says names an issuer, a claim or a reason.
  """

  # Not `async: true`, for the reason given in `Forge.OidcTest`: the fake issuer is installed
  # through node-global application config.
  use ForgeWeb.ConnCase, async: false

  alias Forge.Accounts
  alias Forge.FakeIssuer

  @session_key :oidc_session_params

  setup %{conn: conn} do
    context = FakeIssuer.install()
    Map.put(context, :conn, Plug.Test.init_test_session(conn, %{}))
  end

  # The first leg, kept so the second has something to verify against.
  defp begin(conn) do
    conn = get(conn, ~p"/auth/oidc/test")
    %{conn: conn, session: get_session(conn, @session_key)}
  end

  defp come_back(conn, session, opts) do
    FakeIssuer.will_issue(Keyword.put_new(opts, :nonce, session.nonce))
    state = Keyword.get(opts, :state, session.state)

    get(conn, ~p"/auth/oidc/test/callback?#{[code: "the-code", state: state]}")
  end

  describe "request" do
    test "sends the browser to the issuer", %{conn: conn} do
      %{conn: conn} = begin(conn)

      assert redirected_to(conn) =~ "https://issuer.example.test/authorize"
    end

    test "and keeps what the callback will need in the session", %{conn: conn} do
      %{session: session} = begin(conn)

      assert is_binary(session.state)
      assert is_binary(session.nonce)
      assert is_binary(session.code_verifier)
    end

    test "an unknown provider is refused without saying which exist", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/not-a-provider")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "No such login provider."
    end
  end

  describe "callback" do
    test "logs in the account the issuer vouched for", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, sub: "abc", email: "person@example.org")

      assert get_session(conn, :user_token)
      assert user = Accounts.get_user_by_identity("https://issuer.example.test", "abc")
      assert user.email == "person@example.org"
    end

    # The account is new, so it is pending, so the one page it may see is the holding page.
    # `UserAuth.require_approved_user/2` is what does this, and it must not have an exception
    # for accounts that arrived through an issuer.
    test "a first login lands on the holding page, not in the product", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)
      conn = come_back(conn, session, sub: "abc", email: "person@example.org")

      assert redirected_to(conn) == ~p"/"
      assert get(recycle(conn), ~p"/") |> redirected_to() == ~p"/users/pending"
    end

    test "an approved account goes where it was going", %{conn: conn} do
      %{conn: first, session: session} = begin(conn)
      first = come_back(first, session, sub: "abc", email: "person@example.org")
      user = Accounts.get_user_by_identity("https://issuer.example.test", "abc")
      {:ok, _} = Accounts.approve_user(user, :host)

      assert get(recycle(first), ~p"/") |> html_response(200)
    end

    # Single use: the params are deleted when read, so the same callback URL replayed from a
    # history or a proxy log has nothing left to verify against.
    #
    # **Asserted on a callback that failed, and that is the whole point.** After a successful one
    # the session is empty whatever this controller does, because `UserAuth.log_in_user/3` renews
    # it against fixation — so a success-path assertion here passes with the `delete_session/2`
    # taken out, and proves nothing. A failure leaves the session alone, which makes it the only
    # place the deletion is visible, and also the case that matters: a login that did not work is
    # exactly when somebody retries the URL.
    test "the session params are spent even when the callback fails", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, wrong_key: true)

      assert get_session(conn, @session_key) == nil

      # And so the same URL a second time is a callback nobody started.
      replay = come_back(recycle(conn), session, sub: "abc", email: "person@example.org")

      assert Phoenix.Flash.get(replay.assigns.flash, :error) =~
               "already finished or was never started"

      refute get_session(replay, :user_token)
    end

    test "a callback nobody started is refused", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/test/callback?#{[code: "c", state: "s"]}")

      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "already finished or was never started"

      refute get_session(conn, :user_token)
    end

    test "a token signed by something else logs nobody in", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, wrong_key: true)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      assert Forge.Repo.aggregate(Forge.Accounts.Identity, :count) == 0
    end

    # What the browser is told must not depend on what was wrong: a login page that explains
    # itself is a login page that enumerates.
    test "and says no more than that it failed", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)
      conn = come_back(conn, session, wrong_key: true)

      message = Phoenix.Flash.get(conn.assigns.flash, :error)

      assert message == "That login could not be completed."
      refute message =~ "issuer.example.test"
      refute message =~ "signature"
    end

    test "an address another account holds is refused and says so", %{conn: conn} do
      existing = Forge.AccountsFixtures.user_fixture()
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, sub: "abc", email: existing.email)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "An account already exists for that address"
    end

    # **`docs/design/identity.md` § The IdP is not the authority**: "Forge does not read
    # `groups`, `roles` or any other claim to decide access. Ever." The reason it is *ever* is in
    # that section — membership derived from a claim is revoked only at the next login, and a
    # role changed at the issuer is a change to who can spend money here that leaves no event
    # behind. So an issuer is given every claim it might hope means something, and the account it
    # gets is a pending one in no project, the same as if it had claimed nothing.
    test "no claim an issuer sends grants anything", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      conn =
        come_back(conn, session,
          sub: "abc",
          email: "person@example.org",
          extra: %{
            "groups" => ["admins", "forge-admins"],
            "roles" => ["node_admin", "owner"],
            "node_admin" => true,
            "approved_at" => "2020-01-01T00:00:00Z",
            "email_verified" => true
          }
        )

      assert redirected_to(conn) == ~p"/"
      user = Accounts.get_user_by_identity("https://issuer.example.test", "abc")

      refute user.node_admin
      assert user.approved_at == nil
      refute Forge.Accounts.User.active?(user)
      assert Forge.Projects.list(user) == []
    end

    test "a provider that returns no address is a configuration problem and says so", %{
      conn: conn
    } do
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, email: nil)

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no email address"
      refute get_session(conn, :user_token)
    end

    test "an address the issuer has not verified is refused and says so", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      conn = come_back(conn, session, extra: %{"email_verified" => false})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "has not verified"
      refute get_session(conn, :user_token)
      assert Accounts.list_users() == []
    end

    # The whole point of keeping a log line at all is that an operator can tell a wrong client
    # secret from an unreachable issuer. The whole point of this test is that doing so does not
    # put the client secret in the log — which is what `inspect/1` on an `assent` error did.
    test "a token endpoint that refuses logs the failure without the client secret", %{conn: conn} do
      %{conn: conn, session: session} = begin(conn)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = come_back(conn, session, token_status: 401)

          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "could not be completed"
          refute get_session(conn, :user_token)
        end)

      assert log =~ "oidc login via test failed"
      assert log =~ "Assent.InvalidResponseError"
      assert log =~ "status=401"

      refute log =~ Base.encode64("forge-test-client:shh")
      refute log =~ "Basic"
      refute log =~ "authorization"
    end
  end
end
