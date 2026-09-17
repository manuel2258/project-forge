defmodule ForgeWeb.ApprovalGateTest do
  @moduledoc """
  The perimeter as an operator meets it: a pending account reaches the holding page and nothing
  else, a suspended one is logged out, and `node_admin` unlocks exactly one page.

  These assert through the surfaces that would show the defect, because a context test on
  `User.active?/1` says nothing about whether any route consults it.
  """

  use ForgeWeb.ConnCase, async: true

  import Forge.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Forge.Accounts

  describe "a pending account" do
    setup do
      %{user: pending_user_fixture()}
    end

    test "is sent to the holding page from the queue", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/")
      assert redirected_to(conn) == ~p"/users/pending"
    end

    test "is sent to the holding page from a project page", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/projects/new")
      assert redirected_to(conn) == ~p"/users/pending"
    end

    test "is sent to the holding page from its own settings", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> get(~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/pending"
    end

    test "is stopped by the plug on a route that is not a LiveView", %{conn: conn, user: user} do
      # The operator scope has two guards: `on_mount(:require_approved)` for the live routes and
      # the `require_approved_user` plug for the pipeline. The LiveView ones above cannot fail
      # when only the plug breaks, so this reaches the one plain controller in that scope. A
      # mutation sweep found this exact hole: the plug let everyone through and nothing noticed.
      conn = conn |> log_in_user(user) |> get(~p"/tickets/demo/1/artifacts/plan.md/1")
      assert redirected_to(conn) == ~p"/users/pending"
    end

    test "reaches the holding page itself", %{conn: conn, user: user} do
      {:ok, view, html} = conn |> log_in_user(user) |> live(~p"/users/pending")

      # Not `html =~ user.email`: the layout header renders the address on every authenticated
      # page, so that assertion passes against an empty body. Assert the page's own heading and
      # that the nav is off, which is what this page is.
      assert has_element?(view, "h1", "Waiting for approval")
      refute has_element?(view, "nav a[href='/board']")
      assert html =~ user.email
    end

    test "is refused on the API", %{conn: conn, user: user} do
      token = Accounts.create_api_token(user, "test")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401)
    end
  end

  describe "an approved account" do
    setup do
      %{user: user_fixture()}
    end

    test "reaches the queue", %{conn: conn, user: user} do
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/")

      # The nav is the thing a pending account does not get, and the layout header's copy of the
      # address is not evidence of reaching anything.
      assert has_element?(view, "nav a[href='/board']")
      assert user
    end

    test "is sent away from the holding page's opposite — the accounts page", %{
      conn: conn,
      user: user
    } do
      # Approved is not node admin. The mutation this catches is dropping the node_admin check
      # in on_mount(:require_node_admin), which would hand account governance to everyone who
      # got past the door.
      assert {:error, {:redirect, %{to: "/"}}} = conn |> log_in_user(user) |> live(~p"/accounts")
    end
  end

  describe "a suspended account" do
    test "loses its session outright rather than reaching the holding page", %{conn: conn} do
      admin = node_admin_fixture()
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, _user} = Accounts.suspend_user(user, admin)

      # Not /users/pending: a suspended account has nowhere to wait. Its session stops
      # resolving, so it is an anonymous visitor again.
      assert redirected_to(get(conn, ~p"/")) == ~p"/users/log-in"
    end

    test "is refused on the API", %{conn: conn} do
      admin = node_admin_fixture()
      user = user_fixture()
      token = Accounts.create_api_token(user, "test")

      {:ok, _user} = Accounts.suspend_user(user, admin)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401)
    end
  end

  describe "the accounts page" do
    test "lets a node admin approve a waiting account", %{conn: conn} do
      admin = node_admin_fixture()
      pending = pending_user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      assert has_element?(view, "button[phx-value-id='#{pending.id}'][phx-click='approve']")

      view
      |> element("button[phx-value-id='#{pending.id}'][phx-click='approve']")
      |> render_click()

      assert Accounts.get_user!(pending.id).approved_at
    end

    test "demoting an administrator actually demotes it", %{conn: conn} do
      admin = node_admin_fixture()
      other = node_admin_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      view
      |> element("button[phx-value-id='#{other.id}'][phx-click='demote']")
      |> render_click()

      # The button and the call are different things: a demote wired to `set_node_admin(.., true)`
      # renders identically and leaves a second administrator standing.
      refute Accounts.get_user!(other.id).node_admin
    end

    test "a decided account is not offered again as waiting", %{conn: conn} do
      admin = node_admin_fixture()
      approved = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      # Only pending rows get the approve button. If `pending?/1` answered true for everyone,
      # the page would keep asking about accounts that were decided long ago.
      refute has_element?(view, "button[phx-value-id='#{approved.id}'][phx-click='approve']")
    end

    test "is reachable from the layout, and only by a node admin", %{conn: conn} do
      admin = node_admin_fixture()
      plain = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/")
      assert has_element?(view, "a[href='/accounts']")

      {:ok, plain_view, _html} = conn |> log_in_user(plain) |> live(~p"/")
      refute has_element?(plain_view, "a[href='/accounts']")
    end

    test "suspending actually suspends, and reinstating lifts it", %{conn: conn} do
      admin = node_admin_fixture()
      victim = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      # Suspend is the button that cuts off a session outright; nothing checked that it did.
      view
      |> element("button[phx-value-id='#{victim.id}'][phx-click='suspend']")
      |> render_click()

      refute Forge.Accounts.User.active?(Accounts.get_user!(victim.id))

      view
      |> element("button[phx-value-id='#{victim.id}'][phx-click='reinstate']")
      |> render_click()

      assert Forge.Accounts.User.active?(Accounts.get_user!(victim.id))
    end

    test "promoting grants the flag rather than removing it", %{conn: conn} do
      admin = node_admin_fixture()
      plain = user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")
      view |> element("button[phx-value-id='#{plain.id}'][phx-click='promote']") |> render_click()

      assert Accounts.get_user!(plain.id).node_admin
    end

    test "a refused account does not return to the waiting list", %{conn: conn} do
      admin = node_admin_fixture()
      refused = pending_user_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      view
      |> element("button[phx-value-id='#{refused.id}'][phx-click='suspend']")
      |> render_click()

      # Pending *and* suspended: `is_nil(approved_at)` alone still calls this waiting, so the
      # suspension half of the filter is the only thing that can drop it.
      user = Accounts.get_user!(refused.id)
      assert is_nil(user.approved_at) and not is_nil(user.suspended_at)
      refute user.id in Enum.map(Accounts.list_pending_users(), & &1.id)

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")
      refute has_element?(view, "button[phx-value-id='#{refused.id}'][phx-click='approve']")
    end

    test "offers no way to demote the only administrator", %{conn: conn} do
      admin = node_admin_fixture()

      {:ok, view, _html} = conn |> log_in_user(admin) |> live(~p"/accounts")

      refute has_element?(view, "button[phx-value-id='#{admin.id}'][phx-click='demote']")
    end
  end
end
