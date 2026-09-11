defmodule Mix.Tasks.Forge.User.Add do
  @shortdoc "Creates the operator: mix forge.user.add EMAIL"
  @moduledoc "Creates a user. Tasks that record decisions act as this user."

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run([email]) do
    CLI.boot()

    case Accounts.register_user(%{email: email}) do
      {:ok, user} -> Mix.shell().info("created user #{user.email} (#{user.id})")
      {:error, changeset} -> CLI.fail(inspect(changeset.errors))
    end
  end

  def run(_), do: CLI.fail("usage: mix forge.user.add EMAIL")
end
