defmodule Forge.Accounts.UserNotifier do
  @moduledoc "Composes and delivers account emails: login links, confirmation, email change."
  import Swoosh.Email

  alias Forge.Accounts.User
  alias Forge.Mailer

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(from_address())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  # Configuration rather than a literal, because the generated literal is `contact@example.com`
  # and a relay refuses an address the node does not own. `config/config.exs` keeps the
  # placeholder so development is unchanged; `FORGE_MAIL_FROM` replaces it on a release.
  #
  # `fetch_env!` and not `get_env/3` with the placeholder repeated as a default: `config.exs`
  # always sets the key, so a default here is a second copy of the address that can never be
  # reached and can silently disagree with the first.
  defp from_address, do: Application.fetch_env!(:forge, :mail_from)

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
