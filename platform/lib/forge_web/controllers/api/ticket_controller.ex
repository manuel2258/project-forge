defmodule ForgeWeb.Api.TicketController do
  use ForgeWeb, :controller

  alias Forge.{Artifacts, Events, Jobs, Operator, Projects, Proposals, Queue, Tickets}
  alias ForgeWeb.Api.Render

  action_fallback ForgeWeb.Api.FallbackController

  # Both run before `:load_ticket`: a refusal that waited for the lookup would be a 404 for a
  # ticket that is not there and a 403 for one that is.
  plug ForgeWeb.Plugs.ApiAccess,
       :writable
       when action in [
              :create,
              :edit,
              :answer,
              :approve,
              :transition,
              :retry,
              :cancel,
              :restore,
              :accept_proposal,
              :decline_proposal
            ]

  plug ForgeWeb.Plugs.ApiAccess, :person_only when action in [:queue]

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

  def me(%{assigns: %{current_scope: %{token: %{} = token, project: project}}} = conn, _params) do
    json(conn, %{
      token: %{
        id: token.id,
        name: token.name,
        project: project.name,
        git: token.git_access,
        api: token.api_access,
        expires_at: token.expires_at
      }
    })
  end

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

  # `?state=` is one state name and `?open=true` is status active or stuck; both are optional and
  # they combine. Any other `open` value is no filter, as an unknown query parameter is.
  def index(conn, %{"project" => name} = params) do
    with %{} = project <- find_project(conn, name) do
      json(conn, %{tickets: listed(project, params)})
    end
  end

  def index(conn, params) do
    tickets = conn |> scoped_projects() |> Enum.flat_map(&listed(&1, params))
    json(conn, %{tickets: tickets})
  end

  # A state is a name: anything else (`?state[]=x`, a NUL, bytes that are not UTF-8) names no
  # state, so it lists nothing rather than everything or a 500 from the database.
  defp listed(project, params) do
    case filters(params) do
      :none -> []
      filters -> project |> Tickets.list(filters) |> Enum.map(&Render.ticket(&1, project.name))
    end
  end

  defp filters(params) do
    open = if params["open"] == "true", do: [open: true], else: []

    case params["state"] do
      nil ->
        open

      state when is_binary(state) ->
        if valid_text?(state), do: [state: state] ++ open, else: :none

      _not_a_name ->
        :none
    end
  end

  # Postgres refuses a NUL, or bytes that are not UTF-8, in a text parameter. The `String.valid?`
  # half cannot be reached from a query string (Plug answers 400 for invalid UTF-8 there first),
  # only from a path segment, which the raw route's test does reach: an equivalent mutant for
  # `state`, live for `name`.
  defp valid_text?(text), do: String.valid?(text) and not String.contains?(text, <<0>>)

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
         {:ok, ticket} <- admit(project, actor(conn), attrs) do
      conn |> put_status(:created) |> json(Render.ticket(ticket, project.name))
    end
  end

  defp admit(project, actor, attrs) do
    case Operator.admit(project, actor, attrs) do
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
  The merge decision as data: the diff, the documents the change was built from, the presentations
  an agent wrote about it, the questions answered and the total cost. The same material the review
  page draws, because the API is the product surface and the page is one client of it.
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

  @doc """
  Every artifact of the ticket with every version of it, so a client chooses what to fetch. One
  call, no limit: a ticket with hundreds of versions answers with all of them.
  """
  def artifacts(conn, _params) do
    listing =
      for {artifact, versions} <- Artifacts.versions_for_ticket(conn.assigns.ticket.id),
          do: Render.artifact_listing(artifact, versions)

    json(conn, %{artifacts: listing})
  end

  @doc """
  The stored bytes of one version (`ForgeWeb.ArtifactBytes`). The `content_hash` the listing gives
  is `sha256:` of exactly these bytes, but for a blob recorded without a hash (`uri:…`). A changeset is a commit and not a file: 422 saying where
  the diff is. A version that is not a positive integer, or is not there, is a 404 like any
  other thing that is not yours.
  """
  def raw(conn, %{"name" => name, "version" => requested}) do
    ticket = conn.assigns.ticket

    # Postgres refuses a NUL, or bytes that are not UTF-8, in a text parameter, and that would be
    # a 500 for a name no artifact can have.
    # `n > 0` is an equivalent mutant: versions start at 1, so a zero or a negative finds nothing
    # below either way. It is kept so the address says what a version number is.
    with true <- valid_text?(name),
         {n, ""} when n > 0 <- Integer.parse(requested),
         %{} = version <- Enum.find(Artifacts.versions(ticket.id, name), &(&1.version == n)),
         nil <- Artifacts.commit(version),
         %Plug.Conn{} = sent <- ForgeWeb.ArtifactBytes.send_version(conn, name, version) do
      sent
    else
      sha when is_binary(sha) -> {:error, :not_a_file}
      _absent -> {:error, :not_found}
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
    with {:ok, ticket} <- Operator.edit(conn.assigns.ticket, actor(conn), name, content) do
      json(conn, Render.version(Artifacts.latest(ticket.id, name), name))
    end
  end

  def answer(conn, %{"key" => key} = params) do
    attrs = %{choice: params["choice"], text: params["text"]}

    with {:ok, ticket} <- Operator.answer(conn.assigns.ticket, actor(conn), key, attrs) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def approve(conn, params) do
    decision = if params["decision"] == "rejected", do: :rejected, else: :approved

    with {:ok, ticket} <-
           Operator.decide(conn.assigns.ticket, actor(conn), decision, params["comment"]) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def transition(conn, %{"to" => to} = params) do
    opts = [outcome: params["outcome"], comment: params["comment"]]

    with {:ok, ticket} <- Operator.transition(conn.assigns.ticket, actor(conn), to, opts) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  # Runs the state the ticket rests in again (`Forge.Engine.retry/2`). The queue serves `retry`
  # on a stuck item, and a client that can read it can act on it.
  def retry(conn, _params) do
    with {:ok, ticket} <- Operator.retry(conn.assigns.ticket, actor(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def cancel(conn, _params) do
    with {:ok, ticket} <- Operator.cancel(conn.assigns.ticket, actor(conn)) do
      json(conn, Render.ticket(ticket, conn.assigns.project.name))
    end
  end

  def restore(conn, _params) do
    with {:ok, ticket} <- Operator.restore(conn.assigns.ticket, actor(conn)) do
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
             actor(conn),
             params["comment"],
             params["ticket_type"]
           ) do
      json(conn, Render.ticket(ticket, project_name(ticket)))
    end
  end

  def decline_proposal(conn, %{"version_id" => version_id} = params) do
    with {:ok, decision} <- Operator.decline_proposal(version_id, actor(conn), params["comment"]) do
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

  # A project token is a member of exactly the project it was issued for. The comparison is on the
  # id, not the name: the scope carries the project row the token names.
  defp member?(%{assigns: %{current_scope: %{token: %{} = token}}}, project),
    do: token.project_id == project.id

  defp member?(conn, project),
    do: Projects.member?(project, conn.assigns.current_scope.user)

  # The caller's own projects, never the node's. Every list below goes through one of these.
  defp scoped_projects(%{assigns: %{current_scope: %{token: %{} = token, project: project}}}),
    do: Enum.filter([project], &(&1.id == token.project_id))

  defp scoped_projects(conn), do: Projects.list(conn.assigns.current_scope.user)

  defp find_project(conn, name) do
    case Enum.find(scoped_projects(conn), &(&1.name == name)) do
      nil -> {:error, :not_found}
      project -> project
    end
  end

  defp actor(%{assigns: %{current_scope: %{token: %{} = token}}}), do: token
  defp actor(conn), do: conn.assigns.current_scope.user
end
