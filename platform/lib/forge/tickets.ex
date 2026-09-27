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
  validates `.forge/workflow.yml` at the head of the default branch, then in one transaction
  allocates the number under a lock on the project row, records the ticket and its body,
  creates the first pending job, and last creates the branch, so a failure leaves neither a
  row nor a branch behind. `actor` is `{:user, id}` or `:system`.
  """
  @spec admit(Project.t(), map(), Events.actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def admit(%Project{} = project, attrs, actor \\ :system) do
    with {:ok, prepared} <- prepare_admission(project) do
      Multi.new()
      |> put_admit(prepared, project, attrs, actor)
      |> Repo.transaction()
      |> case do
        {:ok, %{ticket: ticket}} ->
          Events.notify(ticket.id)
          {:ok, ticket}

        {:error, step, reason, _changes} ->
          {:error, {step, reason}}
      end
    end
  end

  @doc """
  Everything `put_admit/5` needs from the repository, read before any transaction opens.

  Split out so a caller that admits a ticket *as part of something else* can compose the
  admission into its own `Ecto.Multi` — `Forge.Proposals.accept/3` does, because accepting a
  proposal and recording the decision have to commit together or not at all. Kept outside the
  transaction so `admit/3`'s error shape is unchanged: a workflow that does not parse still
  comes back as `{:error, [%ForgeCore.Error{}]}` rather than as a failed Multi step.
  """
  @spec prepare_admission(Project.t()) :: {:ok, map()} | {:error, term()}
  def prepare_admission(%Project{} = project) do
    repo = Projects.repo_path(project)

    with {:ok, base} <- Git.resolve(repo, project.default_branch),
         {:ok, yaml} <- workflow_yaml(repo, base),
         {:ok, workflow} <-
           Parser.parse(yaml, at_commit(repo, base)),
         {:ok, yaml_map} <- YamlElixir.read_from_string(yaml) do
      {:ok, %{repo: repo, base: base, workflow: workflow, yaml_map: yaml_map}}
    end
  end

  @doc """
  Adds the steps that admit a ticket to `multi`, under `:number`, `:ticket`, `:admitted`,
  `{:ticket_doc, _}`, `{:first_job, _}` and `:branch`.

  The caller transacts. `admit/3` is the ordinary caller and does nothing else; a caller with
  more to do in the same transaction adds its own steps around these.
  """
  @spec put_admit(Multi.t(), map(), Project.t(), map(), Events.actor()) :: Multi.t()
  def put_admit(multi, prepared, %Project{} = project, attrs, actor) do
    %{repo: repo, base: base, workflow: workflow, yaml_map: yaml_map} = prepared

    multi
    |> Multi.run(:number, fn repo_, _ ->
      # Serialises admissions per project so two never take the same number.
      repo_.one!(from p in Project, where: p.id == ^project.id, lock: "FOR UPDATE")
      {:ok, next_number(repo_, project)}
    end)
    |> Multi.insert(:ticket, fn %{number: number} ->
      Ticket.admit_changeset(%Ticket{}, %{
        project_id: project.id,
        number: number,
        title: Map.fetch!(attrs, :title),
        body: Map.get(attrs, :body, ""),
        base_commit: base,
        branch: "ticket/#{number}",
        workflow: yaml_map,
        workflow_commit: base,
        state: workflow.initial
      })
    end)
    |> Events.log(:admitted, "ticket.admitted", actor, fn %{ticket: ticket} ->
      %{
        ticket_id: ticket.id,
        payload: %{"number" => ticket.number, "state" => workflow.initial, "base_commit" => base}
      }
    end)
    |> Multi.merge(fn %{ticket: ticket} ->
      body = "# #{ticket.title}\n\n#{ticket.body}"
      name = Workflow.ticket_artifact()

      Artifacts.put_version(Multi.new(), :ticket_doc, ticket.id, name, :document, actor, %{
        content: body,
        parse: false
      })
    end)
    |> Multi.merge(fn %{ticket: ticket} ->
      Jobs.put_create(Multi.new(), :first_job, ticket, workflow, workflow.initial)
    end)
    |> Multi.run(:branch, fn _repo, %{ticket: ticket} ->
      case Git.create_branch(repo, ticket.branch, base) do
        :ok -> {:ok, ticket.branch}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Whether `project` can take a ticket right now, and why not when it cannot.

  Exactly the checks `admit/3` makes before it writes anything, run on their own so the create
  form can say what is wrong before the operator types a title — `docs/design/ui.md` § Creating
  things. A new project always fails this: its repository is empty, so there is no workflow, and
  the fix is to push one.

  It is a moment, not a guarantee. The repository is a shared surface and `admit/3` checks again.

  The workflow comes back so a caller that has asked this question does not have to read and
  parse the same file a second time to say anything about it.
  """
  @spec admissible(Project.t()) :: {:ok, Workflow.t()} | {:error, term()}
  def admissible(%Project{} = project) do
    repo = Projects.repo_path(project)

    with {:ok, base} <- Git.resolve(repo, project.default_branch),
         {:ok, yaml} <- workflow_yaml(repo, base) do
      Parser.parse(yaml, at_commit(repo, base))
    end
  end

  # What the validator asks of the repository, answered at the commit the workflow is read at:
  # a prompt file under `.forge/`, and a command's script by its full path.
  defp at_commit(repo, base) do
    [
      prompt_exists: &Git.exists?(repo, base, ".forge/" <> &1),
      file_exists: &Git.exists?(repo, base, &1)
    ]
  end

  defp workflow_yaml(repo, base) do
    case Git.show(repo, base, @workflow_file) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, :not_found} -> {:error, {:no_workflow_file, @workflow_file}}
    end
  end

  defp next_number(repo, %Project{id: project_id}) do
    (repo.one(from t in Ticket, where: t.project_id == ^project_id, select: max(t.number)) || 0) +
      1
  end

  @doc "The pinned workflow of a ticket, as a validated struct. Raises if it no longer parses."
  @spec workflow(Ticket.t()) :: Workflow.t()
  def workflow(%Ticket{} = ticket) do
    {:ok, workflow} = parsed_workflow(ticket)
    workflow
  end

  @doc """
  The pinned workflow, or the validator's errors.

  A definition is validated when the ticket is admitted and pinned as it was then, while the
  validator's rules move between milestones, so a pinning can stop parsing long after it was
  written. Callers serving more than one ticket at a time use this, so that one such row
  cannot take the others down with it.
  """
  @spec parsed_workflow(Ticket.t()) :: {:ok, Workflow.t()} | {:error, [ForgeCore.Error.t()]}
  def parsed_workflow(%Ticket{workflow: map}), do: Parser.from_map(map)

  @spec get!(String.t()) :: Ticket.t()
  def get!(id), do: Repo.get!(Ticket, id)

  @doc """
  Looks a ticket up by project name and number given as strings, as URLs and refs carry
  them. `{:ok, ticket, project}` or `:error` for anything that is not a ticket.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, Ticket.t(), Project.t()} | :error
  def fetch(project_name, number) when is_binary(project_name) and is_binary(number) do
    with %Project{} = project <- Projects.by_name(project_name),
         {n, ""} when n > 0 <- Integer.parse(number),
         %Ticket{} = ticket <- Repo.get_by(Ticket, project_id: project.id, number: n) do
      {:ok, ticket, project}
    else
      _ -> :error
    end
  end

  @doc "Like `fetch/2` but raises `Ecto.NoResultsError`, which the web layer renders as 404."
  @spec fetch!(String.t(), String.t()) :: {Ticket.t(), Project.t()}
  def fetch!(project_name, number) do
    case fetch(project_name, number) do
      {:ok, ticket, project} -> {ticket, project}
      :error -> raise Ecto.NoResultsError, queryable: Ticket
    end
  end

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
