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

  @doc """
  Where repositories registered by name live: `repos_dir` from the `Forge.Jobs` config, or
  `repos/` next to the data directory. Only the command line may register a repository
  anywhere else.
  """
  @spec repos_dir() :: String.t()
  def repos_dir do
    case Application.get_env(:forge, Forge.Jobs, [])[:repos_dir] do
      nil -> Path.join(Path.dirname(Forge.Jobs.data_dir()), "repos")
      dir -> Path.expand(dir)
    end
  end

  @doc "Registers a project whose bare repository is `<repos_dir>/<name>.git`."
  @spec register_named(String.t() | nil, String.t()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def register_named(name, default_branch) do
    # The name is validated by the changeset before anything touches the filesystem, so a
    # path-like name never becomes a path.
    repo_path = if is_binary(name), do: Path.join(repos_dir(), name <> ".git")

    case register(%{name: name, repo_path: repo_path, default_branch: default_branch}) do
      # Here the path is derived from the name rather than given, so it is blank only because
      # the name was. Reporting it would name a field the caller never sent.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, update_in(changeset.errors, &Keyword.delete(&1, :repo_path))}

      result ->
        result
    end
  end
end
