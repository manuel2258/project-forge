defmodule Mix.Tasks.Forge.Project.Add do
  @shortdoc "Registers a project: mix forge.project.add NAME REPO_PATH [--owner EMAIL]"
  @moduledoc """
  Registers a project. The bare repository is created at REPO_PATH if missing.

  `--owner` names the account that administers it. Omitted, it resolves to the node's only
  admin and refuses when there is more than one: a project with no members is invisible to
  everyone, including a node admin, and the only repair is SQL. See
  `docs/design/identity.md` § Projects and members.
  """

  use Mix.Task

  alias Forge.{Accounts, CLI, Projects}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [default_branch: :string, owner: :string])

    case positional do
      [name, repo_path] -> add(name, repo_path, opts)
      _ -> CLI.fail("usage: mix forge.project.add NAME REPO_PATH [--owner EMAIL]")
    end
  end

  defp add(name, repo_path, opts) do
    CLI.boot()

    attrs = %{
      name: name,
      repo_path: repo_path,
      default_branch: Keyword.get(opts, :default_branch, "main")
    }

    with {:ok, owner} <- Accounts.owner_for(Keyword.get(opts, :owner)),
         {:ok, project} <- Projects.register(attrs, owner) do
      Mix.shell().info(
        "registered #{project.name} at #{Projects.repo_path(project)}, owned by #{owner.email}"
      )
    else
      {:error, :ambiguous_owner} -> CLI.fail("more than one node admin: pass --owner EMAIL")
      {:error, :no_owner} -> CLI.fail("no node admin: mix forge.user.add EMAIL PASS --node-admin")
      {:error, :unknown_user} -> CLI.fail("unknown user #{Keyword.get(opts, :owner)}")
      {:error, %Ecto.Changeset{} = changeset} -> CLI.fail(inspect(changeset.errors))
      {:error, reason} -> CLI.fail(inspect(reason))
    end
  end
end
