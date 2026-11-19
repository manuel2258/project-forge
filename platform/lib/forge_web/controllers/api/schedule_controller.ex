defmodule ForgeWeb.Api.ScheduleController do
  @moduledoc """
  A project's schedules over the API (`docs/design/schedules.md`): what the project page's Workflow
  view draws, as data, and the three things a person does about one.

  - `GET /projects/:project/schedules` — every schedule its files declare, with whether it is on,
    who by, when it fires next, the ticket it last admitted and its problem. The project's members
    and its project tokens with API read, and nobody else: a project the caller is not in is a 404.
  - `POST …/schedules/on` and `…/schedules/off`, `{type, name}` — **a project admin's, by session
    or by their own user token, and no project token's whatever its access**: `:person_only` here,
    and `Forge.Operator` refuses a member in any case.
  - `POST …/schedules/dismiss` — any member, a project token with API write included, as answering a
    question is.

  `type` is the ticket type whose file declares the schedule, absent for the single
  `.forge/workflow.yml`.
  """

  use ForgeWeb, :controller

  alias Forge.{Operator, Projects, Schedules}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  plug ForgeWeb.Plugs.ApiAccess, :person_only when action in [:on, :off]

  # Refuses a read token before the project is looked up, so the refusal says nothing of whether the
  # project it names exists: the operation's own `:use` would refuse it too, but after a 404.
  plug ForgeWeb.Plugs.ApiAccess, :writable when action in [:dismiss]
  plug :load_project

  def index(conn, _params) do
    project = conn.assigns.project

    rows = Schedules.rows(project)

    declared =
      case Forge.Tickets.types(project) do
        {:ok, types} -> Schedules.declared(types, rows)
        # No workflow to read: what is on is still known, by name, with why.
        {:error, reason} -> Schedules.unreadable(rows, reason)
      end

    json(conn, %{schedules: Enum.flat_map(declared, &Render.schedules/1)})
  end

  def on(conn, params) do
    with {:ok, type, name} <- address(params),
         {:ok, row} <-
           Operator.switch_schedule_on(
             conn.assigns.project,
             conn.assigns.current_scope.user,
             type,
             name
           ) do
      json(conn, %{schedule: Render.schedule(type, nil, row)})
    end
  end

  def off(conn, params) do
    with {:ok, type, name} <- address(params),
         {:ok, row} <-
           Operator.switch_schedule_off(
             conn.assigns.project,
             conn.assigns.current_scope.user,
             type,
             name
           ) do
      json(conn, %{schedule: Render.schedule(type, nil, row)})
    end
  end

  def dismiss(conn, params) do
    with {:ok, type, name} <- address(params),
         {:ok, row} <-
           Operator.dismiss_schedule(conn.assigns.project, actor(conn), type, name) do
      json(conn, %{schedule: Render.schedule(type, nil, row)})
    end
  end

  # Which schedule a request is about: a name, and the type whose file declares it when it has one.
  defp address(%{"name" => name} = params) when is_binary(name) and name != "" do
    case params["type"] do
      nil -> {:ok, nil, name}
      type when is_binary(type) and type != "" -> {:ok, type, name}
      _ -> {:error, {:bad_request, "type is the name of a ticket type, or absent"}}
    end
  end

  defp address(_params), do: {:error, {:bad_request, "name is the schedule's name"}}

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
