defmodule Mix.Tasks.Forge.User.Add do
  @shortdoc "Creates an operator: mix forge.user.add EMAIL PASSWORD [--node-admin]"
  @moduledoc """
  Creates a confirmed, approved user who can log in with a password.

  `--node-admin` seeds an account that may approve others. This is the bootstrap and the reason
  it lives on the command line: approval is the perimeter, the first node admin cannot be
  approved by anyone, and whoever has a shell here is past every gate there is. See
  `docs/design/identity.md` § Approval.
  """

  use Mix.Task

  alias Forge.{Accounts, CLI}

  @impl true
  def run(args) do
    {opts, positional} = OptionParser.parse!(args, strict: [node_admin: :boolean])

    case positional do
      [email, password] -> add(email, password, opts)
      _ -> CLI.fail("usage: mix forge.user.add EMAIL PASSWORD [--node-admin]")
    end
  end

  defp add(email, password, opts) do
    CLI.boot()

    case Accounts.create_operator(email, password, opts) do
      {:ok, user} -> Mix.shell().info("created user #{user.email} (#{user.id})#{admin(user)}")
      {:error, changeset} -> CLI.fail(inspect(changeset.errors))
    end
  end

  defp admin(%{node_admin: true}), do: ", node admin"
  defp admin(_user), do: ""
end
