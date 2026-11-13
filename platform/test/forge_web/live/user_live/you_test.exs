defmodule ForgeWeb.UserLive.YouTest do
  @moduledoc """
  You (`12j`, `docs/design/ui.md` § You): what is about this browser — push and the theme — then
  what is about the account — how it signs in, Accounts for a node admin, usage — and signing out.
  The forms and the credentials are `SettingsTest` and `SettingsCredentialsTest`.
  """

  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures

  alias Forge.Accounts

  defp open(conn, user) do
    {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/users/settings")
    {view, html}
  end

  test "is titled You, with the address under it", %{conn: conn} do
    user = user_fixture()
    {view, _html} = open(conn, user)

    assert has_element?(view, "#top-bar .ui-top-name", "You")
    assert has_element?(view, "#top-bar .ui-top-sub", user.email)
    refute has_element?(view, "#top-bar .ui-top-sub", "admin")
  end

  test "a node admin's says so", %{conn: conn} do
    admin = node_admin_fixture()
    {view, _html} = open(conn, admin)

    assert has_element?(view, "#top-bar .ui-top-sub", "#{admin.email} · admin")
  end

  # The theme moved here from the title menu: three options, each dispatching the root template's
  # `phx:set-theme` with its own name, the selected one drawn by the browser.
  test "this browser's theme is switched here", %{conn: conn} do
    {view, _html} = open(conn, user_fixture())

    for theme <- ~w(system dark light) do
      assert view
             |> element(~s(#you-theme button[data-phx-theme="#{theme}"]), theme)
             |> render() =~ "phx:set-theme"
    end
  end

  describe "notifications" do
    test "subscribe this browser for the person signed in, and unsubscribe it", %{conn: conn} do
      user = user_fixture()
      {view, _html} = open(conn, user)

      assert has_element?(
               view,
               ~s(#push-switch[role=switch][phx-hook=PushSubscribe][data-vapid-key="test-public"])
             )

      render_hook(view, "push:subscribe", %{
        "endpoint" => "https://push.example/you",
        "keys" => %{
          "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      })

      assert [%{user_id: user_id}] = Forge.Push.subscriptions()
      assert user_id == user.id

      render_hook(view, "push:unsubscribe", %{"endpoint" => "https://push.example/you"})
      assert Forge.Push.subscriptions() == []
    end

    # The switch's state is the browser's subscription, which the server does not know: it is
    # never re-rendered over what the hook set.
    test "the switch is the browser's to set", %{conn: conn} do
      {view, _html} = open(conn, user_fixture())

      assert has_element?(view, ~s(#push-switch[phx-update=ignore]))
    end

    test "a refused subscription says so", %{conn: conn} do
      {view, _html} = open(conn, user_fixture())

      render_hook(view, "push:subscribe", %{"endpoint" => "https://push.example/you"})
      # Under the switch that was pressed, never a toast (`ui.md` § Errors stay where you acted).
      assert has_element?(view, "#push-switch + #push-error[role=alert]", "Could not save")
      refute has_element?(view, ".ui-toast")
      assert Forge.Push.subscriptions() == []

      render_hook(view, "push:error", %{"reason" => "permission was not granted"})

      assert has_element?(
               view,
               "#push-error",
               "Notifications unavailable: permission was not granted"
             )

      # Gone once the browser does subscribe.
      render_hook(view, "push:subscribe", %{
        "endpoint" => "https://push.example/you",
        "keys" => %{
          "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      })

      assert [_] = Forge.Push.subscriptions()
      refute has_element?(view, "#push-error")
    end
  end

  describe "signed in with" do
    test "each identity as its issuer and subject, and a password when there is one",
         %{conn: conn} do
      {:ok, user} =
        Accounts.log_in_with_identity(%{
          issuer: "https://id.acme.example",
          subject: "sub-1",
          email: "person@example.org"
        })

      {:ok, user} = Accounts.approve_user(user, :host)
      {view, _html} = open(conn, user)

      assert has_element?(view, "#you-signed-in", "id.acme.example · sub-1")
      refute has_element?(view, "#you-signed-in", "password")
      refute has_element?(view, "#you-signed-in", "email link")

      {view, _html} = open(build_conn(), set_password(user))
      assert has_element?(view, "#you-signed-in", "id.acme.example · sub-1")
      assert has_element?(view, "#you-signed-in", "password")
    end

    test "an account with neither signs in by link", %{conn: conn} do
      {view, _html} = open(conn, user_fixture())

      assert has_element?(view, "#you-signed-in .you-row-value", "email link")
    end
  end

  # Accounts hangs off You for a node admin, with the number waiting; for anybody else it is not
  # there — the page behind it refuses them anyway (`ApprovalGateTest`).
  test "a node admin gets Accounts with the number waiting, nobody else does", %{conn: conn} do
    pending_user_fixture()
    pending_user_fixture()

    {view, _html} = open(conn, node_admin_fixture())
    assert has_element?(view, ~s(#you-accounts[href="/accounts"]), "2 waiting")

    {view, _html} = open(build_conn(), user_fixture())
    refute has_element?(view, "#you-accounts")
  end

  test "usage leads to /usage", %{conn: conn} do
    {view, _html} = open(conn, user_fixture())

    assert has_element?(view, ~s(#you-usage[href="/usage"]), "5h — · week —")
  end

  # Accounts and Usage lead elsewhere, after what is yours to set: not between "Signed in with"
  # and the email field (UX pass, D20).
  test "Accounts and Usage come after the credentials", %{conn: conn} do
    {_view, html} = open(conn, node_admin_fixture())

    {credentials, _} = :binary.match(html, ~s(id="credentials"))
    {email, _} = :binary.match(html, ~s(id="email_form"))

    for id <- ~w(you-accounts you-usage) do
      {at, _} = :binary.match(html, ~s(id="#{id}"))
      assert at > credentials
      assert at > email
    end
  end

  test "signs out last", %{conn: conn} do
    {_view, html} = open(conn, user_fixture())

    assert html =~ ~s(id="you-sign-out")
    {at, _} = :binary.match(html, ~s(id="you-sign-out"))
    {credentials, _} = :binary.match(html, ~s(id="credentials"))
    assert at > credentials
  end
end
