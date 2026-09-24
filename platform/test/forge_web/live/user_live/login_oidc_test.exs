defmodule ForgeWeb.UserLive.LoginOidcTest do
  @moduledoc """
  The login page with an issuer configured.

  `ForgeWeb.UserLive.LoginTest` covers the page a node without OIDC serves, and it must keep
  covering exactly that — so the provider buttons get their own module rather than a `describe`
  block there, because installing a provider is a node-global write and this module is therefore
  `async: false`.
  """

  # Not `async: true`: `Forge.FakeIssuer.install/1` writes application config, which every other
  # test shares. See `Forge.OidcTest`.
  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Forge.Accounts.Oidc
  alias Forge.FakeIssuer

  setup do
    FakeIssuer.install()
  end

  test "a configured issuer gets a button that starts its login", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    assert html =~ "Log in with Test Provider"
    assert html =~ ~s|href="/auth/oidc/test"|
  end

  # Asserted against the provider's own name and href, not against "Log in with" or "divider":
  # the page carries "Log in with email" and a divider of its own regardless, so the looser
  # assertion passes whatever the OIDC block does.
  test "a node with no issuer configured shows no provider button", %{conn: conn} do
    Application.put_env(:forge, Oidc, [])

    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    refute html =~ "Log in with Test Provider"
    refute html =~ "/auth/oidc/test"
  end

  # The page needs an id and a name. A client secret in the socket would be inspected into any
  # crash report naming this LiveView's process state.
  test "the client secret does not travel into the socket", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    assigns = :sys.get_state(lv.pid).socket.assigns

    # `assert [%{id: _, name: _}]` would not do: a `%Provider{}` matches that pattern too, so the
    # assertion has to be that the secret's key is not there at all.
    assert [button] = assigns.providers
    assert Map.keys(button) == [:id, :name]
    assert button == %{id: "test", name: "Test Provider"}

    refute inspect(assigns) =~ "shh"
  end

  # Defence in depth for every other `inspect/1` that might reach one.
  test "a provider does not print its client secret", %{provider: provider} do
    assert provider.client_secret == "shh"
    refute inspect(provider) =~ "shh"
  end
end
