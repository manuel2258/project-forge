defmodule ForgeWeb.Api.TicketController do
  use ForgeWeb, :controller

  alias Forge.{Artifacts, Events, Jobs, Operator, Projects, Proposals, Queue, Tickets}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  plug :load_ticket
       when action not in [
              :index,
              :create,
              :queue,
              :me,
              :proposals,
              :accept_proposal,
              :decline_proposal
            ]

  def me(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{id: user.id, email: user.email, node_admin: user.node_admin})
  end

  defp project_name(ticket), do: Projects.get!(ticket.project_id).name

  def queue(conn, _params) do
    items =
      conn.assigns.current_scope.user
      |> Queue.items()
      |> Enum.map(&Render.queue_item(&1, &1.project.name))

    json(conn, %{items: items})
  end

  def index(conn, %{"project" => name}) do
    with %{} = project <- find_project(conn, name) do
      json(conn, %{tickets: Enum.map(Tickets.list(project), &Render.ticket(&1, project.name))})
    end
  end

  def index(conn, _params) do
    tickets =
      conn
      |> scoped_projects()
      |> Enum.flat_map(fn project ->
        Enum.map(Tickets.list(project), &Render.ticket(&1, project.name))
      end)

    json(conn, %{tickets: tickets})
  end

  # **`Operator.admit/3` is the guard, and the only one.** This used to find the project among
  # the caller's own and then call `Tickets.admit/3` — a second check with its own idea of who
  # may admit (any membership row, where `Operator` asks `:use`), and an admission the Operator
  # never saw. The project is resolved by name alone here so that nothing but `admit/3` decides,
  # and its refusal is the same 404 as a project that does not exist: not a member and does not
  # exist are the same answer (`docs/design/identity.md` § Projects and members). It runs before
  # the ticket is validated, so a malformed request into somebody else's project is not a 422
  # that says the project is there. `docs/design/api-and-ui.md` § Operations.
  def create(conn, %{"project" => name} = params) do
    attrs = %{
      title: params["title"] || "",
      body: params["body"] || "",
      ticket_type: params["ticket_type"]
    }

    with %{} = project <- Projects.by_name(name) || {:error, :not_found},
         {:ok, ticket} <- admit(project, user(conn), attrs) do
      conn |> put_status(:created) |> json(Render.ticket(ticket, project.name))
    end
  end

  defp admit(project, user, attrs) do
    case Operator.admit(project, user, attrs) do
      {:error, :forbidden} -> {:error, :not_found}
      other -> other
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

  # Runs the state the ticket rests in again (`Forge.Engine.retry/2`). The queue serves `retry`
  # on a stuck item, and a client that can read it can act on it.
  def retry(conn, _params) do
    with {:ok, ticket} <- Operator.retry(conn.assigns.ticket, user(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def cancel(conn, _params) do
    with {:ok, ticket} <- Operator.cancel(conn.assigns.ticket, user(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def restore(conn, _params) do
    with {:ok, ticket} <- Operator.restore(conn.assigns.ticket, user(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  # Open proposals are per project, not per ticket: a project chat's proposal has no ticket, and
  # the operator's question is "what has been suggested here", not "what did ticket 12 suggest".
  def proposals(conn, %{"project" => name}) do
    with %{} = project <- find_project(conn, name) do
      json(conn, %{proposals: Enum.map(Proposals.open(project.id), &Render.proposal/1)})
    end
  end

  def accept_proposal(conn, %{"version_id" => version_id} = params) do
    with {:ok, ticket} <-
           Operator.accept_proposal(
             version_id,
             user(conn),
             params["comment"],
             params["ticket_type"]
           ) do
      json(conn, Render.ticket(ticket, project_name(ticket)))
    end
  end

  def decline_proposal(conn, %{"version_id" => version_id} = params) do
    with {:ok, decision} <- Operator.decline_proposal(version_id, user(conn), params["comment"]) do
      json(conn, %{version_id: decision.artifact_version_id, decision: "declined"})
    end
  end

  defp load_ticket(%{params: %{"project" => name, "number" => number}} = conn, _opts) do
    # A ticket in a project the caller is not a member of answers 404, not 403. Not a member and
    # does not exist are the same answer — `docs/design/identity.md` § Projects and members.
    case Tickets.fetch(name, number) do
      {:ok, ticket, project} ->
        if member?(conn, project),
          do: conn |> assign(:project, project) |> assign(:ticket, ticket),
          else: missing(conn, name, number)

      :error ->
        missing(conn, name, number)
    end
  end

  defp missing(conn, name, number) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{reason: "not_found", detail: "no ticket #{name}##{number}"}})
    |> halt()
  end

  defp member?(conn, project),
    do: Projects.member?(project, conn.assigns.current_scope.user)

  # The caller's own projects, never the node's. Every list below goes through one of these.
  defp scoped_projects(conn), do: Projects.list(conn.assigns.current_scope.user)

  defp find_project(conn, name) do
    case Enum.find(scoped_projects(conn), &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> project
    end
  end

  defp user(conn), do: conn.assigns.current_scope.user
end
