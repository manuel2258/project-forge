defmodule ForgeWeb.Api.ProjectController do
  use ForgeWeb, :controller

  alias Forge.Projects
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  def index(conn, _params),
    do: json(conn, %{projects: Enum.map(Projects.list(), &Render.project/1)})

  def create(conn, params) do
    attrs = %{
      name: params["name"],
      repo_path: params["repo_path"],
      default_branch: params["default_branch"] || "main"
    }

    with {:ok, project} <- Projects.register(attrs) do
      conn |> put_status(:created) |> json(Render.project(project))
    end
  end
end
