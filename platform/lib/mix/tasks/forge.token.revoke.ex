defmodule Mix.Tasks.Forge.Token.Revoke do
  @shortdoc "Revokes a user's API tokens by name: mix forge.token.revoke EMAIL NAME"
  @moduledoc "Deletes every API token of the user with that name. Requests with them stop working at once."

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run(args) do
    case args do
      [email, name] ->
        CLI.boot()
        user = Accounts.get_user_by_email(email) || CLI.fail("unknown user #{email}")
        Mix.shell().info("revoked #{Accounts.revoke_api_tokens(user, name)} token(s)")

      _ ->
        CLI.fail("usage: mix forge.token.revoke EMAIL NAME")
    end
  end
end
