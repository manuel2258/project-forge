defmodule ForgeWeb.Api.ProjectController do
  use ForgeWeb, :controller

  alias Forge.Projects
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  def index(conn, _params) do
    projects = Projects.list(conn.assigns.current_scope.user)
    json(conn, %{projects: Enum.map(projects, &Render.project/1)})
  end

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
