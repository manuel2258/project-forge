defmodule ForgeWeb.Api.TicketController do
  use ForgeWeb, :controller

  alias Forge.{Artifacts, Events, Jobs, Operator, Projects, Queue, Tickets}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  plug :load_ticket when action not in [:index, :create, :queue, :me]

  def me(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{id: user.id, email: user.email, role: user.role})
  end

  def queue(conn, _params) do
    items = Enum.map(Queue.items(), &Render.queue_item(&1, project_name(&1.ticket)))
    json(conn, %{items: items})
  end

  def index(conn, params) do
    project = params["project"] && Projects.by_name(params["project"])

    tickets =
      case {params["project"], project} do
        {nil, _} -> Enum.map(Tickets.list(), &Render.ticket(&1, project_name(&1)))
        {_, nil} -> []
        {_, project} -> Enum.map(Tickets.list(project), &Render.ticket(&1, project.name))
      end

    json(conn, %{tickets: tickets})
  end

  def create(conn, %{"project" => name} = params) do
    with %{} = project <- Projects.by_name(name) || {:error, :not_found},
         {:ok, ticket} <-
           Tickets.admit(
             project,
             %{title: params["title"] || "", body: params["body"] || ""},
             actor(conn)
           ) do
      conn |> put_status(:created) |> json(Render.ticket(ticket, project.name))
    end
  end

  def show(conn, _params) do
    %{ticket: ticket, project: project} = conn.assigns

    json(conn, %{
      ticket: Render.ticket(ticket, project.name),
      jobs: Enum.map(Jobs.for_ticket(ticket.id), &Render.job/1),
      artifacts:
        Enum.map(
          Artifacts.list(ticket.id),
          &Render.artifact(&1, Artifacts.latest(ticket.id, &1.name))
        ),
      open_questions: Enum.map(Artifacts.open_questions(ticket.id), &Render.question/1)
    })
  end

  def events(conn, _params) do
    json(conn, %{events: Enum.map(Events.for_ticket(conn.assigns.ticket.id), &Render.event/1)})
  end

  def job(conn, %{"job_id" => job_id}) do
    ticket = conn.assigns.ticket

    case Enum.find(Jobs.for_ticket(ticket.id), &(&1.id == job_id)) do
      nil ->
        {:error, :not_found}

      job ->
        json(conn, %{
          job: Render.job_with_spec(job),
          events: Enum.map(Events.for_job(job.id), &Render.event/1)
        })
    end
  end

  def artifact(conn, %{"name" => name} = params) do
    ticket = conn.assigns.ticket

    version =
      case params["version"] do
        nil -> Artifacts.latest(ticket.id, name)
        n -> Enum.find(Artifacts.versions(ticket.id, name), &(Integer.to_string(&1.version) == n))
      end

    case version do
      nil -> {:error, :not_found}
      version -> json(conn, Render.version(version, name))
    end
  end

  def edit(conn, %{"name" => name, "content" => content}) do
    with {:ok, ticket} <- Operator.edit(conn.assigns.ticket, user(conn), name, content) do
      json(conn, Render.version(Artifacts.latest(ticket.id, name), name))
    end
  end

  def answer(conn, %{"key" => key} = params) do
    attrs = %{choice: params["choice"], text: params["text"]}

    with {:ok, ticket} <- Operator.answer(conn.assigns.ticket, user(conn), key, attrs) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def approve(conn, params) do
    decision = if params["decision"] == "rejected", do: :rejected, else: :approved

    with {:ok, ticket} <-
           Operator.decide(conn.assigns.ticket, user(conn), decision, params["comment"]) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def transition(conn, %{"to" => to} = params) do
    opts = [outcome: params["outcome"], comment: params["comment"]]

    with {:ok, ticket} <- Operator.transition(conn.assigns.ticket, user(conn), to, opts) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  defp load_ticket(%{params: %{"project" => name, "number" => number}} = conn, _opts) do
    with %{} = project <- Projects.by_name(name),
         {n, ""} <- Integer.parse(number),
         %{} = ticket <- Forge.Repo.get_by(Tickets.Ticket, project_id: project.id, number: n) do
      conn |> assign(:project, project) |> assign(:ticket, ticket)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{reason: "not_found", detail: "no ticket #{name}##{number}"}})
        |> halt()
    end
  end

  defp user(conn), do: conn.assigns.current_scope.user
  defp actor(conn), do: {:user, user(conn).id}
  defp project_name(ticket), do: Projects.get!(ticket.project_id).name
end
