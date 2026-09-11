defmodule Mix.Tasks.Forge.Project.Add do
  @shortdoc "Registers a project: mix forge.project.add NAME REPO_PATH [--default-branch main]"
  @moduledoc "Registers a project. The bare repository is created at REPO_PATH if missing."

  use Mix.Task

  alias Forge.{CLI, Projects}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [default_branch: :string])

    case positional do
      [name, repo_path] ->
        CLI.boot()

        attrs = %{
          name: name,
          repo_path: repo_path,
          default_branch: Keyword.get(opts, :default_branch, "main")
        }

        case Projects.register(attrs) do
          {:ok, project} ->
            Mix.shell().info("registered #{project.name} at #{Projects.repo_path(project)}")

          {:error, %Ecto.Changeset{} = changeset} ->
            CLI.fail(inspect(changeset.errors))

          {:error, reason} ->
            CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.project.add NAME REPO_PATH [--default-branch main]")
    end
  end
end
