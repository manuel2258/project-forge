defmodule ForgeWeb.UserSessionController do
  use ForgeWeb, :controller

  alias Forge.Accounts
  alias ForgeWeb.{SignIn, Toast, UserAuth}

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> Toast.put(info)
        |> SignIn.remember(:magic)
        |> UserAuth.log_in_user(user, user_params)

      # Back to the link's own screen, where the line sits under the address it went to.
      _ ->
        conn
        |> put_flash(:sign_in_error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in?way=link")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> Toast.put(info)
      |> SignIn.remember(:password)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:sign_in_error, "That email and password don't match an account here.")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in?way=password")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> Toast.put("Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
