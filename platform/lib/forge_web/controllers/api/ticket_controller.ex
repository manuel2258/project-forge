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

  def index(conn, %{"project" => name}) do
    case Projects.by_name(name) do
      nil ->
        {:error, :not_found}

      project ->
        json(conn, %{tickets: Enum.map(Tickets.list(project), &Render.ticket(&1, project.name))})
    end
  end

  def index(conn, _params) do
    json(conn, %{tickets: Enum.map(Tickets.list(), &Render.ticket(&1, project_name(&1)))})
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

  @doc """
  The merge decision as data: the diff, the documents the change was built from, the questions
  answered and the total cost. The same material the review page draws, because the API is the
  product surface and the page is one client of it.
  """
  def review(conn, _params) do
    %{ticket: ticket, project: project} = conn.assigns

    case Artifacts.latest(ticket.id, ForgeCore.Workflow.changeset_artifact()) do
      nil -> {:error, :not_found}
      changeset -> json(conn, Render.review(ticket, project, changeset))
    end
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

    with {:ok, version} <- requested_version(ticket.id, name, params["version"]) do
      json(conn, Render.version(version, name))
    end
  end

  defp requested_version(ticket_id, name, nil) do
    case Artifacts.latest(ticket_id, name) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  defp requested_version(ticket_id, name, requested) do
    case Integer.parse(requested) do
      {n, ""} when n > 0 ->
        case Enum.find(Artifacts.versions(ticket_id, name), &(&1.version == n)) do
          nil -> {:error, :not_found}
          version -> {:ok, version}
        end

      _ ->
        {:error, {:bad_request, "version must be a positive integer"}}
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
    case Tickets.fetch(name, number) do
      {:ok, ticket, project} ->
        conn |> assign(:project, project) |> assign(:ticket, ticket)

      :error ->
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
