defmodule Forge.Tickets do
  @moduledoc """
  Tickets: admission pins the project's workflow at the base commit, creates the branch,
  records the ticket body as the `ticket` artifact, and creates the first job.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Git, Jobs, Projects, Repo}
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.Parser

  @workflow_file ".forge/workflow.yml"

  @doc """
  Admits a ticket to `project`. `attrs` needs `:title`; `:body` is optional. Reads and
  validates `.forge/workflow.yml` at the head of the default branch, allocates the number
  and branch, and creates the first job as pending. `actor` is `{:user, id}` or `:system`.
  """
  @spec admit(Project.t(), map(), Events.actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def admit(%Project{} = project, attrs, actor \\ :system) do
    repo = Projects.repo_path(project)

    with {:ok, base} <- Git.resolve(repo, project.default_branch),
         {:ok, yaml} <- workflow_yaml(repo, base),
         {:ok, workflow} <-
           Parser.parse(yaml, prompt_exists: &Git.exists?(repo, base, ".forge/" <> &1)),
         {:ok, yaml_map} <- YamlElixir.read_from_string(yaml) do
      number = next_number(project)
      branch = "ticket/#{number}"

      with :ok <- Git.create_branch(repo, branch, base) do
        insert(
          project,
          workflow,
          yaml_map,
          %{number: number, branch: branch, base: base},
          attrs,
          actor
        )
      end
    end
  end

  defp insert(
         project,
         workflow,
         yaml_map,
         %{number: number, branch: branch, base: base},
         attrs,
         actor
       ) do
    Multi.new()
    |> Multi.insert(
      :ticket,
      Ticket.admit_changeset(%Ticket{}, %{
        project_id: project.id,
        number: number,
        title: Map.fetch!(attrs, :title),
        body: Map.get(attrs, :body, ""),
        base_commit: base,
        branch: branch,
        workflow: yaml_map,
        workflow_commit: base,
        state: workflow.initial
      })
    )
    |> Events.log(:admitted, "ticket.admitted", actor, fn %{ticket: ticket} ->
      %{
        ticket_id: ticket.id,
        payload: %{"number" => number, "state" => workflow.initial, "base_commit" => base}
      }
    end)
    |> Multi.merge(fn %{ticket: ticket} ->
      body = "# #{ticket.title}\n\n#{ticket.body}"
      name = Workflow.ticket_artifact()

      Artifacts.put_version(Multi.new(), :ticket_doc, ticket.id, name, :document, actor, %{
        content: body
      })
    end)
    |> Multi.merge(fn %{ticket: ticket} ->
      Jobs.put_create(Multi.new(), :first_job, ticket, workflow, workflow.initial)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: ticket}} -> {:ok, ticket}
      {:error, step, reason, _} -> {:error, {step, reason}}
    end
  end

  defp workflow_yaml(repo, base) do
    case Git.show(repo, base, @workflow_file) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, :not_found} -> {:error, {:no_workflow_file, @workflow_file}}
    end
  end

  defp next_number(%Project{id: project_id}) do
    (Repo.one(from t in Ticket, where: t.project_id == ^project_id, select: max(t.number)) || 0) +
      1
  end

  @doc "The pinned workflow of a ticket, as a validated struct."
  @spec workflow(Ticket.t()) :: Workflow.t()
  def workflow(%Ticket{workflow: map}) do
    {:ok, workflow} = Parser.from_map(map)
    workflow
  end

  @spec get!(String.t()) :: Ticket.t()
  def get!(id), do: Repo.get!(Ticket, id)

  @spec get_by_number!(Project.t(), pos_integer()) :: Ticket.t()
  def get_by_number!(%Project{id: project_id}, number) do
    Repo.one!(from t in Ticket, where: t.project_id == ^project_id and t.number == ^number)
  end

  @spec list(Project.t() | nil) :: [Ticket.t()]
  def list(project \\ nil)
  def list(nil), do: Repo.all(from t in Ticket, order_by: [asc: t.inserted_at])

  def list(%Project{id: id}),
    do: Repo.all(from t in Ticket, where: t.project_id == ^id, order_by: [asc: t.number])

  @spec project_of(Ticket.t()) :: Project.t()
  def project_of(%Ticket{project_id: id}), do: Projects.get!(id)

  @doc "Adds a ticket update to a multi."
  @spec put_progress(Multi.t(), term(), Ticket.t(), map()) :: Multi.t()
  def put_progress(multi, key, %Ticket{} = ticket, attrs) do
    Multi.update(multi, key, Ticket.progress_changeset(ticket, attrs))
  end
end
