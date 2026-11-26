defmodule ForgeWeb.Api.ProjectController do
  use ForgeWeb, :controller

  alias Forge.Projects
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  # Registering a project is a person's: a project token is for one that already exists.
  plug ForgeWeb.Plugs.ApiAccess, :person_only when action in [:create]

  def index(%{assigns: %{current_scope: %{token: %{} = token, project: project}}} = conn, _params) do
    json(conn, %{projects: for(p <- [project], p.id == token.project_id, do: Render.project(p))})
  end

  def index(conn, _params) do
    projects = Projects.list(conn.assigns.current_scope.user)
    json(conn, %{projects: Enum.map(projects, &Render.project/1)})
  end

  # One project of the caller's own, with where its repository is and the ticket types it admits:
  # what an agent needs before it can open a ticket (`docs/design/outside-work.md`). Another
  # project's is the 404 of one that is not there; the types are read from the repository, so the
  # answer is a moment and not a guarantee, as the ticket form's is.
  def show(conn, %{"project" => name}) do
    case Enum.find(own_projects(conn), &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> json(conn, Render.project_detail(project, Forge.Tickets.types(project)))
    end
  end

  defp own_projects(%{assigns: %{current_scope: %{token: %{} = token, project: project}}}),
    do: for(p <- [project], p.id == token.project_id, do: p)

  defp own_projects(conn), do: Projects.list(conn.assigns.current_scope.user)

  # The API names the project; the repository is created under the platform's repos
  # directory. Registering an arbitrary path is a command-line operation.
  def create(conn, params) do
    with {:ok, project} <-
           Projects.register_named(
             params["name"],
             params["default_branch"] || "main",
             conn.assigns.current_scope.user
           ) do
      conn |> put_status(:created) |> json(Render.project(project))
    end
  end
end
