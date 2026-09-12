defmodule ForgeWeb.Api.ProjectController do
  use ForgeWeb, :controller

  alias Forge.Projects
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  def index(conn, _params),
    do: json(conn, %{projects: Enum.map(Projects.list(), &Render.project/1)})

  # The API names the project; the repository is created under the platform's repos
  # directory. Registering an arbitrary path is a command-line operation.
  def create(conn, params) do
    with {:ok, project} <-
           Projects.register_named(params["name"], params["default_branch"] || "main") do
      conn |> put_status(:created) |> json(Render.project(project))
    end
  end
end
