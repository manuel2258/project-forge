defmodule ForgeWeb.UserLive.ConfirmationTest do
  use ForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Forge.AccountsFixtures

  alias Forge.Accounts

  setup do
    %{unconfirmed_user: unconfirmed_user_fixture(), confirmed_user: user_fixture()}
  end

  describe "Confirm user" do
    test "renders confirmation page for unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")
      assert html =~ "Is this your own device?"

      # The common answer is the filled one, and it is the one that remembers the session.
      assert has_element?(
               lv,
               ~s(#confirmation_form button.ui-btn--primary[name="user[remember_me]"][value="true"]),
               "Yes, keep me signed in"
             )

      refute has_element?(
               lv,
               ~s(#confirmation_form button[name="user[remember_me]"]),
               "No, just this once"
             )

      assert html =~ "turn them on in your settings"

      # The same head as every sign-in screen, and no button opens focused: the focus ring on
      # *Yes* read as already chosen (UX pass, A29).
      assert has_element?(lv, "#sign-in-link .signin-brand img.signin-logo")
      refute has_element?(lv, "#confirmation_form[phx-mounted]")
    end

    test "renders login page for confirmed user", %{conn: conn, confirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute has_element?(lv, "#confirmation_form")
      assert has_element?(lv, ~s(#login_form button[name="user[remember_me]"]), "Yes, keep me")
      assert has_element?(lv, "#login_form button", "No, just this once")
      refute html =~ "turn them on in your settings"
    end

    test "renders login page for already logged in user", %{conn: conn, confirmed_user: user} do
      conn = log_in_user(conn, user)

      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, html} = live(conn, ~p"/users/log-in/#{token}")
      refute html =~ "Is this your own device?"
      assert has_element?(lv, "#login_form button", "Sign in")
      refute has_element?(lv, ~s(#login_form button[name="user[remember_me]"]))
    end

    test "confirms the given token once", %{conn: conn, unconfirmed_user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#confirmation_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "User confirmed successfully"

      assert Accounts.get_user!(user.id).confirmed_at
      # we are logged in now
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in?way=link")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "logs confirmed user in without changing confirmed_at", %{
      conn: conn,
      confirmed_user: user
    } do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~
               "Welcome back!"

      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in?way=link")

      assert html =~ "Magic link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in?way=link")

      # Under the address field of the link's own screen, not in a floating flash.
      doc = Floki.parse_document!(html)

      assert doc |> Floki.find("#login_form_magic_email-error") |> Floki.text() =~
               "Magic link is invalid or it has expired"

      assert Floki.attribute(doc, "#login_form_magic_email", "aria-invalid") == ["true"]

      # Drawn once, where it belongs: not a second time anywhere else on the page, toast included.
      refute doc |> Floki.find("#toast") |> Floki.text() =~ "Magic link is invalid"

      assert doc
             |> Floki.find("body")
             |> Floki.text()
             |> String.split("Magic link is invalid")
             |> length() == 2
    end
  end
end
