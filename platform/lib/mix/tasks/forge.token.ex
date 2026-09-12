defmodule Mix.Tasks.Forge.Token do
  @shortdoc "Creates an API token: mix forge.token EMAIL --name NAME"
  @moduledoc "Prints a bearer token for the JSON API once. Requests with it act as the user."

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [name: :string])

    case positional do
      [email] ->
        CLI.boot()
        user = Accounts.get_user_by_email(email) || CLI.fail("unknown user #{email}")
        token = Accounts.create_api_token(user, Keyword.get(opts, :name, "cli"))
        Mix.shell().info(token)

      _ ->
        CLI.fail("usage: mix forge.token EMAIL --name NAME")
    end
  end
end
