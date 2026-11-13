defmodule ForgeWeb.UserLive.LoginTest do
  @moduledoc """
  The login page on a node with no provider: *Other ways* (`21p`) is the whole page, opening on
  the password or the link. `ForgeWeb.UserLive.LoginOidcTest` covers a node with one.
  """

  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures

  alias ForgeWeb.SignIn

  describe "login page" do
    test "opens on the password, with no way back to a provider", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password")
      refute has_element?(lv, "#sign-in-provider")
      refute has_element?(lv, "#sign-in-back")
      assert has_element?(lv, ~s(#sign-in-way input[name=way][value=password][checked]))
      refute has_element?(lv, ~s(#sign-in-way input[name=way][value=link][checked]))
      assert html =~ "A new account waits for an administrator to approve it."
    end

    # There is no provider screen to open, whatever is asked for.
    test "a provider asked for on a node with none is the password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=provider")

      assert has_element?(lv, "#login_form_password")
      refute has_element?(lv, "#sign-in-provider")
    end

    test "a device that last used a link opens on the link", %{conn: conn} do
      conn = put_req_cookie(conn, SignIn.cookie(), "magic")

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "#login_form_password")
    end

    test "the switch moves between the password and the link", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      lv |> form("#sign-in-way", way: "link") |> render_change()
      assert_patch(lv, ~p"/users/log-in?way=link")
      assert has_element?(lv, "#login_form_magic")
      assert has_element?(lv, ~s(#sign-in-way input[value=link][checked]))

      lv |> form("#sign-in-way", way: "password") |> render_change()
      assert_patch(lv, ~p"/users/log-in?way=password")
      assert has_element?(lv, "#login_form_password")
    end
  end

  describe "user login - magic link" do
    test "sends a link when the user exists, and says so in place", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=link")

      html = lv |> form("#login_form_magic", user: %{email: user.email}) |> render_submit()

      assert has_element?(lv, "#sign-in-sent", "Check #{user.email}.")
      assert html =~ "works once"

      assert Forge.Repo.get_by!(Forge.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    # The same screen for an address with no account: it says the link comes only if there is
    # one, which is true either way and tells nobody which.
    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=link")

      lv
      |> form("#login_form_magic", user: %{email: "idonotexist@example.com"})
      |> render_submit()

      assert has_element?(lv, "#sign-in-sent", "Check idonotexist@example.com.")
      assert has_element?(lv, "#sign-in-sent", "only if the address has an account here")
    end

    # The address is what the visitor typed, drawn back to them: as text.
    test "draws the address it was sent to as text", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=link")

      html =
        lv
        |> form("#login_form_magic", user: %{email: "<b>x</b>@example.com"})
        |> render_submit()

      refute html =~ "<b>x</b>"
      assert html =~ "&lt;b&gt;x&lt;/b&gt;@example.com"
    end

    test "another address goes back to the field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=link")
      lv |> form("#login_form_magic", user: %{email: "a@example.com"}) |> render_submit()

      lv |> element("#sign-in-sent button", "Use another address") |> render_click()

      refute has_element?(lv, "#sign-in-sent")
      assert has_element?(lv, "#login_form_magic")
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: true}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["_forge_web_user_remember_me"]
    end

    # The common answer is ticked; unticking it signs in without a remembered session.
    test "keeps the session on this device unless told not to", %{conn: conn} do
      user = user_fixture() |> set_password()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password_remember[checked]")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: false}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      refute conn.resp_cookies["_forge_web_user_remember_me"]
    end

    # The refusal is the pair's — the page cannot say which half was wrong — so its line is under
    # Sign in, a whole sentence, and neither field is marked (UX pass, A30).
    test "a wrong password comes back with the line under Sign in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      line = "That email and password don't match an account here."
      assert Phoenix.Flash.get(conn.assigns.flash, :sign_in_error) == line
      assert redirected_to(conn) == ~p"/users/log-in?way=password"

      {:ok, lv, html} = live(recycle(conn), ~p"/users/log-in?way=password")

      assert has_element?(lv, "#login_form_password button + #sign-in-password-error", line)
      refute has_element?(lv, "#login_form_password_password-error")
      refute has_element?(lv, ~s(#login_form_password_password[aria-invalid="true"]))
      # The email comes back filled; the line is drawn once, in place, not in a flash as well.
      assert has_element?(lv, ~s(#login_form_password input[value="test@email.com"]))

      doc = Floki.parse_document!(html)

      # Drawn once, where it belongs: not a second time anywhere else on the page, toast included.
      refute doc |> Floki.find("#toast") |> Floki.text() =~ line

      assert doc
             |> Floki.find("body")
             |> Floki.text()
             |> String.split(line)
             |> length() == 2
    end

    # A line belongs to the screen it came back to.
    test "the line is left behind when the screen changes", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> Phoenix.Controller.fetch_flash()
        |> Phoenix.Controller.put_flash(:sign_in_error, "Invalid email or password")

      {:ok, lv, _html} = live(conn, ~p"/users/log-in?way=password")
      assert has_element?(lv, "#sign-in-password-error")

      lv |> form("#sign-in-way", way: "link") |> render_change()

      assert has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "#login_form_magic_email-error")
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/users/log-in?way=link")

      assert html =~ "Sign in again to change your account."
      assert has_element?(lv, ~s(#login_form_magic_email[readonly][value="#{user.email}"]))
    end
  end
end
