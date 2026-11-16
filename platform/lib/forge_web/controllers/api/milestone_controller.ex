defmodule ForgeWeb.Api.MilestoneController do
  @moduledoc """
  A project's milestones over the API (`docs/design/ui.md` § Milestones): everything the
  Milestones view does, as data. Nested under the project, so every route is scoped to it by
  construction: a project the caller is not a member of is a 404, as a ticket in one is, and a
  milestone id of another project answers `not_found` too (`Forge.Milestones.get/2` resolves it
  inside the project).
  """

  use ForgeWeb, :controller

  alias Forge.{Milestones, Operator, Projects}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  plug ForgeWeb.Plugs.ApiAccess,
       :writable when action in [:create, :update, :current, :close, :reopen, :move]

  # The caller's project by name, or a 404 that is the same for one that is not there. Runs before
  # the action reads anything of the project.
  plug :load_project

  def index(conn, _params) do
    overview = Milestones.overview(conn.assigns.project.id)

    json(conn, %{
      milestones: Enum.map(overview.milestones ++ overview.closed, &Render.milestone_entry/1),
      unplaced: Enum.map(overview.unplaced, & &1.number)
    })
  end

  def create(conn, params) do
    with {:ok, milestone} <-
           Operator.create_milestone(conn.assigns.project, actor(conn), text(params)) do
      conn |> put_status(:created) |> json(%{milestone: shown(conn, milestone.id)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, milestone} <-
           Operator.update_milestone(conn.assigns.project, actor(conn), id, text(params)) do
      json(conn, %{milestone: shown(conn, milestone.id)})
    end
  end

  # Marks the milestone current. `current: false` unmarks it, when it is the one marked: a project
  # may have none current, and a milestone that is not current is left as it is. The milestone is
  # looked up first, in this project, because unmarking another one writes nothing and so would
  # never meet a milestone that is not there.
  def current(conn, %{"id" => id} = params) do
    with {:ok, milestone} <- find(conn, id),
         {:ok, _marked} <- mark(conn, milestone, params["current"] in [false, "false"]) do
      json(conn, %{milestone: shown(conn, milestone.id)})
    end
  end

  defp mark(conn, milestone, true) do
    project = conn.assigns.project

    case Milestones.current(project.id) do
      %{id: id} when id == milestone.id ->
        Operator.set_current_milestone(project, actor(conn), nil)

      _another_or_none ->
        {:ok, nil}
    end
  end

  defp mark(conn, milestone, false),
    do: Operator.set_current_milestone(conn.assigns.project, actor(conn), milestone.id)

  def close(conn, %{"id" => id}) do
    with {:ok, milestone} <- find(conn, id),
         {:ok, _closed} <-
           Operator.close_milestone(conn.assigns.project, actor(conn), milestone.id) do
      json(conn, %{milestone: shown(conn, milestone.id)})
    end
  end

  def reopen(conn, %{"id" => id}) do
    with {:ok, milestone} <- find(conn, id),
         {:ok, _reopened} <-
           Operator.reopen_milestone(conn.assigns.project, actor(conn), milestone.id) do
      json(conn, %{milestone: shown(conn, milestone.id)})
    end
  end

  def move(conn, %{"id" => id} = params) do
    with {:ok, milestone} <- find(conn, id),
         {:ok, to} <- target(params, conn.assigns.project),
         {:ok, _moved} <-
           Operator.move_milestone(conn.assigns.project, actor(conn), milestone.id, to) do
      json(conn, %{milestone: shown(conn, milestone.id)})
    end
  end

  # The project's own milestone `id`, open or closed. Another project's is not found, as one that
  # does not exist is, and so is an id that is no id.
  defp find(conn, id) do
    case Milestones.get(conn.assigns.project.id, id) do
      nil -> {:error, :not_found}
      milestone -> {:ok, milestone}
    end
  end

  defp target(%{"to" => to}, _project) when to in ~w(top up down bottom),
    do: {:ok, String.to_existing_atom(to)}

  defp target(%{"before" => before}, project) when is_binary(before) do
    case Milestones.get(project.id, before) do
      nil -> {:error, :not_in_order}
      milestone -> {:ok, {:before, milestone.id}}
    end
  end

  defp target(_params, _project),
    do: {:error, {:bad_request, "to is top, up, down or bottom, or before is a milestone id"}}

  # Only what a milestone is made of, whatever else arrived.
  defp text(params), do: %{name: params["name"], description: params["description"]}

  defp shown(conn, id) do
    overview = Milestones.overview(conn.assigns.project.id)

    (overview.milestones ++ overview.closed)
    |> Enum.find(&(&1.milestone.id == id))
    |> Render.milestone_entry()
  end

  defp load_project(%{params: %{"project" => name}} = conn, _opts) do
    case find_project(conn, name) do
      %{} = project ->
        assign(conn, :project, project)

      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{reason: "not_found", detail: nil}})
        |> halt()
    end
  end

  # The caller's own projects, never the node's.
  defp find_project(%{assigns: %{current_scope: %{token: %{} = token, project: project}}}, name),
    do: if(project.name == name and project.id == token.project_id, do: project)

  defp find_project(conn, name) do
    conn.assigns.current_scope.user |> Projects.list() |> Enum.find(&(&1.name == name))
  end

  defp actor(%{assigns: %{current_scope: %{token: %{} = token}}}), do: token
  defp actor(conn), do: conn.assigns.current_scope.user
end
