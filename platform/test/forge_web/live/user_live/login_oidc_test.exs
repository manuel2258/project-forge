defmodule ForgeWeb.UserLive.LoginOidcTest do
  @moduledoc """
  The login page with an issuer configured: the provider first (`21o`), *Other ways* (`21p`) for
  a device that last used a password or a link, and a provider's refusal in place (`21n`).

  `ForgeWeb.UserLive.LoginTest` covers the page a node without OIDC serves, and it must keep
  covering exactly that — so the provider screens get their own module rather than a `describe`
  block there, because installing a provider is a node-global write and this module is therefore
  `async: false`.
  """

  # Not `async: true`: `Forge.FakeIssuer.install/1` writes application config, which every other
  # test shares. See `Forge.OidcTest`.
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Accounts.Oidc
  alias Forge.FakeIssuer
  alias ForgeWeb.SignIn

  setup do
    FakeIssuer.install()
  end

  defp remembering(conn, value), do: put_req_cookie(conn, SignIn.cookie(), value)

  defp with_flash(conn, key, value) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
    |> Phoenix.Controller.put_flash(key, value)
  end

  test "a configured issuer is the page: one button that starts its login", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    assert has_element?(
             lv,
             ~s(#sign-in-provider a[href="/auth/oidc/test"]),
             "Continue with Test Provider"
           )

    assert has_element?(lv, "#sign-in-with-test", "issuer.example.test")
    # The tile is the initials of the provider's first two words.
    assert has_element?(lv, "#sign-in-with-test .signin-provider-mark", "tp")
    assert has_element?(lv, ~s(#sign-in-other[href="/users/log-in?way=password"]))
    refute has_element?(lv, "#login_form_password")
    refute has_element?(lv, "#login_form_magic")
  end

  # Asserted against the provider's own name and href, not against "Continue with": the other
  # screens carry the word "Continue" nowhere, but a looser assertion would pass whatever the
  # provider block did.
  test "a node with no issuer configured shows no provider button", %{conn: conn} do
    Application.put_env(:forge, Oidc, [])

    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    refute html =~ "Test Provider"
    refute html =~ "/auth/oidc/test"
  end

  describe "the device remembers how it last signed in" do
    test "a password opens on the password, with the way back", %{conn: conn} do
      {:ok, lv, _html} = live(remembering(conn, "password"), ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password")
      refute has_element?(lv, "#sign-in-provider")

      assert has_element?(
               lv,
               ~s(#sign-in-back[href="/users/log-in?way=provider"]),
               "Test Provider"
             )
    end

    test "a link opens on the link", %{conn: conn} do
      {:ok, lv, _html} = live(remembering(conn, "magic"), ~p"/users/log-in")

      assert has_element?(lv, "#login_form_magic")
    end

    test "the provider opens on the provider", %{conn: conn} do
      {:ok, lv, _html} = live(remembering(conn, "oidc:test"), ~p"/users/log-in")

      assert has_element?(lv, "#sign-in-provider")
    end

    # The way back is a link, and wins over the cookie.
    test "the provider asked for opens whatever was remembered", %{conn: conn} do
      {:ok, lv, _html} = live(remembering(conn, "password"), ~p"/users/log-in?way=provider")

      assert has_element?(lv, "#sign-in-provider")
    end

    test "the provider it last used comes first", %{conn: conn} do
      [test] = Oidc.providers()
      other = %{test | id: "other", name: "Other Provider", issuer: "https://other.example.test"}

      Application.put_env(
        :forge,
        Oidc,
        Keyword.put(Application.get_env(:forge, Oidc), :providers, [test, other])
      )

      {:ok, _lv, html} = live(remembering(conn, "oidc:other"), ~p"/users/log-in")
      ids = html |> Floki.parse_document!() |> Floki.attribute(".signin-provider", "id")
      assert ids == ["sign-in-with-other", "sign-in-with-test"]

      {:ok, _lv, html} = live(build_conn(), ~p"/users/log-in")
      ids = html |> Floki.parse_document!() |> Floki.attribute(".signin-provider", "id")
      assert ids == ["sign-in-with-test", "sign-in-with-other"]

      # With two, the way back names neither.
      {:ok, lv, _html} = live(remembering(build_conn(), "password"), ~p"/users/log-in")
      assert has_element?(lv, "#sign-in-back", "Back")
      refute has_element?(lv, "#sign-in-back", "Test Provider")
    end

    # A value the platform never wrote is ignored — the page opens as if there were none — and
    # nothing of it is drawn: the cookie decides a screen and is never content.
    test "a value it never wrote is ignored and never drawn", %{conn: conn} do
      for value <- ["<b>passwordz</b>", "oidc:gone-provider", "Password", "oidc:"] do
        {:ok, lv, html} = live(remembering(conn, value), ~p"/users/log-in")

        assert has_element?(lv, "#sign-in-provider"), value
        refute html =~ "passwordz"
        refute html =~ "gone-provider"
      end
    end
  end

  describe "a provider's refusal (21n)" do
    test "sits above the button in the provider's code, with a plain reading", %{conn: conn} do
      conn = with_flash(conn, :oidc_refusal, "access_denied:test")

      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=provider")

      assert has_element?(lv, "#sign-in-refusal", "Test Provider didn't sign you in")
      # The shared notice in danger, as every notice is drawn (UX re-check #6).
      assert has_element?(lv, "#sign-in-refusal.ui-notice--danger[role=alert]")
      assert has_element?(lv, "#sign-in-refusal code", "access_denied")
      assert has_element?(lv, "#sign-in-refusal", "You cancelled")
      # The button to try again is still there.
      assert has_element?(lv, "#sign-in-with-test")
    end

    # Checked where it is drawn and not only where it was written: an unregistered code, or a
    # provider the node does not have, draws nothing at all.
    test "draws nothing for a code that is not registered or a provider that is not configured",
         %{conn: conn} do
      for value <- ["<b>owned</b>:test", "made_up:test", "access_denied:nobody", "access_denied"] do
        {:ok, lv, html} =
          conn |> with_flash(:oidc_refusal, value) |> live(~p"/users/log-in?way=provider")

        refute has_element?(lv, "#sign-in-refusal"), value
        refute html =~ "owned"
        refute html =~ "made_up"
      end
    end

    test "the whole round trip: refused at the provider, quoted on the page", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{})
      conn = get(conn, ~p"/auth/oidc/test")
      session = get_session(conn, :oidc_session_params)

      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          get(
            recycle(conn),
            ~p"/auth/oidc/test/callback?#{[error: "temporarily_unavailable", state: session.state]}"
          )

        {:ok, lv, _html} = live(recycle(conn), redirected_to(conn))

        assert has_element?(lv, "#sign-in-refusal code", "temporarily_unavailable")
        assert has_element?(lv, "#sign-in-refusal", "busy or down")
      end)
    end

    test "a failure that is not a refusal sits in the same place", %{conn: conn} do
      conn = with_flash(conn, :sign_in_error, "No such login provider.")

      {:ok, lv, html} = live(conn, ~p"/users/log-in?way=provider")

      assert has_element?(lv, "#sign-in-error", "No such login provider.")

      doc = Floki.parse_document!(html)

      # Drawn once, where it belongs: not a second time anywhere else on the page, toast included.
      refute doc |> Floki.find("#toast") |> Floki.text() =~ "No such login provider."

      assert doc
             |> Floki.find("body")
             |> Floki.text()
             |> String.split("No such login provider.")
             |> length() == 2
    end
  end

  # The page needs an id, a name and a host. A client secret in the socket would be inspected
  # into any crash report naming this LiveView's process state.
  test "the client secret does not travel into the socket", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    assigns = :sys.get_state(lv.pid).socket.assigns

    # `assert [%{id: _, name: _}]` would not do: a `%Provider{}` matches that pattern too, so the
    # assertion has to be that the secret's key is not there at all.
    assert [button] = assigns.providers
    assert Map.keys(button) |> Enum.sort() == [:host, :id, :name]
    assert button == %{id: "test", name: "Test Provider", host: "issuer.example.test"}

    refute inspect(assigns) =~ "shh"
  end

  # Defence in depth for every other `inspect/1` that might reach one.
  test "a provider does not print its client secret", %{provider: provider} do
    assert provider.client_secret == "shh"
    refute inspect(provider) =~ "shh"
  end
end
