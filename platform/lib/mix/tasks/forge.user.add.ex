defmodule Mix.Tasks.Forge.User.Add do
  @shortdoc "Creates an operator: mix forge.user.add EMAIL PASSWORD"
  @moduledoc "Creates a confirmed user who can log in with a password. Browser registration is off."

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run([email, password]) do
    CLI.boot()

    case Accounts.create_operator(email, password) do
      {:ok, user} -> Mix.shell().info("created user #{user.email} (#{user.id})")
      {:error, changeset} -> CLI.fail(inspect(changeset.errors))
    end
  end

  def run(_), do: CLI.fail("usage: mix forge.user.add EMAIL PASSWORD")
end
