defmodule Mix.Tasks.Forge.Token.List do
  @shortdoc "Lists a user's API tokens: mix forge.token.list EMAIL"
  @moduledoc "Prints name, creation time and id of each API token. The tokens themselves are not stored."

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run(args) do
    case args do
      [email] ->
        CLI.boot()
        user = Accounts.get_user_by_email(email) || CLI.fail("unknown user #{email}")

        for token <- Accounts.list_api_tokens(user),
            do: Mix.shell().info("#{token.name}\t#{token.inserted_at}\t#{token.id}")

      _ ->
        CLI.fail("usage: mix forge.token.list EMAIL")
    end
  end
end
