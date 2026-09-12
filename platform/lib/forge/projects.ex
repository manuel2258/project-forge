defmodule Forge.Projects do
  @moduledoc "Projects: a name, a bare repository the platform owns, and a default branch."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Events, Git, Repo}
  alias Forge.Projects.Project

  @doc """
  Registers a project. The bare repository at `repo_path` is created if it does not exist;
  an existing one is used as is, so a repository can be imported by pushing to it first.
  """
  @spec register(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def register(attrs) do
    changeset = Project.changeset(%Project{}, attrs)

    with {:ok, project} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- Git.init_bare(Path.expand(project.repo_path)) do
      Multi.new()
      |> Multi.insert(:project, changeset)
      |> Events.log(:event, "project.registered", :system, fn %{project: project} ->
        %{payload: %{"project_id" => project.id, "name" => project.name}}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{project: project}} -> {:ok, project}
        {:error, :project, changeset, _} -> {:error, changeset}
      end
    end
  end

  @spec get!(String.t()) :: Project.t()
  def get!(id), do: Repo.get!(Project, id)

  @spec by_name(String.t()) :: Project.t() | nil
  def by_name(name), do: Repo.one(from p in Project, where: p.name == ^name)

  @spec list() :: [Project.t()]
  def list, do: Repo.all(from p in Project, order_by: p.name)

  @doc "Absolute path of the project's bare repository."
  @spec repo_path(Project.t()) :: String.t()
  def repo_path(%Project{repo_path: path}), do: Path.expand(path)
end
