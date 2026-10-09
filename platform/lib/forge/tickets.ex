defmodule Forge.Tickets do
  @moduledoc """
  Tickets: admission pins the project's workflow at the base commit, creates the branch,
  records the ticket body as the `ticket` artifact, and creates the first job.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.{Artifacts, Events, Git, Jobs, Projects, Repo, TicketTypes}
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.Parser

  @doc """
  Admits a ticket to `project`. `attrs` needs `:title`; `:body` and `:ticket_type` are optional.
  Reads and validates the type's workflow at the head of the default branch — the single
  `.forge/workflow.yml`, or `.forge/workflows/<type>.yml` (`docs/design/ticket-types.md`) — then
  in one transaction allocates the number under a lock on the project row, records the ticket and
  its body, creates the first pending job, and last creates the branch, so a failure leaves
  neither a row nor a branch behind. `actor` is `{:user, id}` or `:system`.
  """
  @spec admit(Project.t(), map(), Events.actor()) :: {:ok, Ticket.t()} | {:error, term()}
  def admit(%Project{} = project, attrs, actor \\ :system) do
    with {:ok, prepared} <- prepare_admission(project, Map.get(attrs, :ticket_type)) do
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
  Everything `put_admit/5` needs from the repository, read before any transaction opens: the
  workflow of `ticket_type` — nil for the single file, or for the one type a directory holding
  one implies — with its imports resolved, and the type it was read as.

  Split out so a caller that admits a ticket *as part of something else* can compose the
  admission into its own `Ecto.Multi` — `Forge.Proposals.accept/4` does, because accepting a
  proposal and recording the decision have to commit together or not at all. Kept outside the
  transaction so `admit/3`'s error shape is unchanged: a workflow that does not parse still
  comes back as `{:error, [%ForgeCore.Error{}]}` rather than as a failed Multi step.
  """
  @spec prepare_admission(Project.t(), term()) :: {:ok, map()} | {:error, term()}
  def prepare_admission(project, ticket_type \\ nil)

  # A form sends an empty string for a select left alone; that is no type named, not a type
  # called "". Anything but a string is not a type's name at all — refused here, once, rather
  # than reaching a sentence that interpolates it.
  def prepare_admission(%Project{} = project, ""), do: prepare_admission(project, nil)

  def prepare_admission(%Project{} = project, ticket_type)
      when is_nil(ticket_type) or is_binary(ticket_type),
      do: prepare(project, &TicketTypes.for_admission(&1, ticket_type))

  def prepare_admission(%Project{}, _ticket_type),
    do: {:error, {:invalid_ticket_type, :not_a_name}}

  @doc """
  What `Forge.Engine.repin/2` pins: `ticket`'s own type, read at the default branch's head. A
  type whose file is gone refuses rather than guessing which type the ticket is now.
  """
  @spec prepare_repin(Project.t(), Ticket.t()) :: {:ok, map()} | {:error, term()}
  def prepare_repin(%Project{} = project, %Ticket{ticket_type: ticket_type}),
    do: prepare(project, &TicketTypes.for_repin(&1, ticket_type))

  # What is pinned is the definition with its imports resolved, not the file's own text: a
  # ticket's workflow is read back with no repository to read a library from
  # (`docs/design/ticket-types.md` § Imports).
  defp prepare(project, select) do
    repo = Projects.repo_path(project)

    with {:ok, base} <- Git.resolve(repo, project.default_branch),
         {:ok, layout} <- TicketTypes.layout(repo, base),
         {:ok, ticket_type, path} <- select.(layout),
         {:ok, workflow, flat} <- load(repo, base, path) do
      {:ok,
       %{repo: repo, base: base, workflow: workflow, yaml_map: flat, ticket_type: ticket_type}}
    end
  end

  defp entries(%{form: :single}, true), do: [%{name: nil, path: TicketTypes.single_path()}]
  defp entries(%{form: :single}, false), do: []
  defp entries(%{form: :types, types: types}, _single), do: types

  defp parsed_at(repo, base, path) do
    case load(repo, base, path) do
      {:ok, workflow, _flat} -> {:ok, workflow}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load(repo, base, path) do
    with {:ok, yaml} <- workflow_yaml(repo, base, path) do
      Parser.load(yaml, at_commit(repo, base))
    end
  end

  @doc """
  Every ticket type the project's default branch declares, each with its workflow or why it has
  none — what the ticket form offers and the project page shows: the checks `admit/3` makes
  before it writes anything, run for every type at once so the form can say what is wrong before
  the operator types a title (`docs/design/ui.md` § Creating things). A new project fails them:
  its repository is empty, so there is no workflow. It is a moment, not a guarantee — the
  repository is a shared surface, and `admit/3` checks again. `form` is `:single` for the one
  `.forge/workflow.yml`, whose only entry is named nil, or `:types` for the directory; `not_types`
  is what the directory holds that is not a type, and why.

  Each type is parsed, so a broken one is shown broken beside the others rather than taking them
  down with it: one stray file must not stop every other type admitting.

  `single: false` leaves the single file out, unparsed, for a caller that wants only types — the
  backlog, which every assignment composes and which says nothing about a project without types.
  """
  @spec types(Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def types(%Project{} = project, opts \\ []) do
    repo = Projects.repo_path(project)

    with {:ok, base} <- Git.resolve(repo, project.default_branch),
         {:ok, layout} <- TicketTypes.layout(repo, base) do
      entries = entries(layout, Keyword.get(opts, :single, true))

      types = Enum.map(entries, &Map.put(&1, :workflow, parsed_at(repo, base, &1.path)))
      {:ok, %{form: layout.form, types: types, not_types: layout.not_types}}
    end
  end

  @doc """
  What changed under `.forge/` on the project's default branch since `ticket` was pinned — the
  workflow, its prompts, its command scripts — as the head and the paths, or nil when nothing did.

  A ticket reads all of those at its pin for its whole life (`docs/design/workflow-grammar-v1.md`
  § Pinning), so a fix to `build.sh` that lands on the default branch never reaches a ticket
  already failing on the old one. The ticket page says so, beside the way to re-pin.
  """
  @spec drift(Ticket.t(), Project.t()) :: %{head: String.t(), paths: [String.t()]} | nil
  def drift(%Ticket{workflow_commit: pinned, ticket_type: ticket_type}, %Project{} = project) do
    repo = Projects.repo_path(project)
    own = TicketTypes.path(ticket_type)

    # `head != pinned` is an equivalent mutant: the diff of a commit against itself is empty, and
    # an empty diff is nil too. It spares the second git call on the common case.
    with {:ok, head} when head != pinned <- Git.resolve(repo, project.default_branch),
         {:ok, paths} <- Git.changed_paths(repo, pinned, head, [".forge"]),
         [_ | _] = paths <- Enum.reject(paths, &another_type?(&1, own)) do
      %{head: head, paths: paths}
    else
      _none -> nil
    end
  end

  # Another type's file changing is not this ticket's drift: a spike's lifecycle is not a bug's.
  # Libraries, prompts and scripts still count whoever uses them — knowing which this type imports
  # means reading it at the pin, and a false "something changed" costs a glance where a missed
  # one costs a ticket failing on a script that was fixed (`docs/design/ticket-types.md`).
  defp another_type?(path, own),
    do: String.starts_with?(path, TicketTypes.dir() <> "/") and path != own

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
        ticket_type: prepared.ticket_type,
        state: workflow.initial
      })
    end)
    |> Events.log(:admitted, "ticket.admitted", actor, fn %{ticket: ticket} ->
      %{
        ticket_id: ticket.id,
        payload: %{
          "number" => ticket.number,
          "state" => workflow.initial,
          "base_commit" => base,
          "ticket_type" => ticket.ticket_type
        }
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

  # What the validator asks of the repository, answered at the commit the workflow is read at:
  # a prompt file under `.forge/`, a command's script by its full path, and a library's text.
  defp at_commit(repo, base) do
    [
      prompt_exists: &Git.exists?(repo, base, ".forge/" <> &1),
      file_exists: &Git.exists?(repo, base, &1),
      read_library: &read_at(repo, base, ".forge/" <> &1)
    ]
  end

  defp read_at(repo, base, path) do
    case Git.show(repo, base, path) do
      {:ok, text} -> {:ok, text}
      {:error, _reason} -> :error
    end
  end

  defp workflow_yaml(repo, base, path) do
    case Git.show(repo, base, path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, :not_found} -> {:error, {:no_workflow_file, path}}
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

  @doc """
  The tickets of a project, or of every project, **leaving out cancelled ones**: a cancelled ticket
  is hidden everywhere a ticket is listed, and reached only by its own address
  (`docs/design/workflow-grammar-v1.md` § Cancelling a ticket).
  """
  @spec list(Project.t() | nil) :: [Ticket.t()]
  def list(project \\ nil)

  def list(nil),
    do: Repo.all(from t in visible(Ticket), order_by: [asc: t.inserted_at])

  def list(%Project{id: id}),
    do: Repo.all(from t in visible(Ticket), where: t.project_id == ^id, order_by: [asc: t.number])

  @doc """
  Every ticket of a project, cancelled ones included: for what a cancel must not change — money
  already spent, and which ticket a proposal came from. Anything that *lists* tickets uses
  `list/1`.
  """
  @spec all(Project.t()) :: [Ticket.t()]
  def all(%Project{id: id}),
    do: Repo.all(from t in Ticket, where: t.project_id == ^id, order_by: [asc: t.number])

  @doc "Narrows a ticket query to the tickets that are listed: every one but a cancelled one."
  @spec visible(Ecto.Queryable.t()) :: Ecto.Query.t()
  def visible(query), do: from(t in query, where: t.status != :cancelled)

  @doc "The project a ticket belongs to, by id, or nil — one indexed read, for filtering events."
  @spec project_id(String.t() | nil) :: String.t() | nil
  def project_id(nil), do: nil

  def project_id(ticket_id),
    do: Repo.one(from t in Ticket, where: t.id == ^ticket_id, select: t.project_id)

  @spec project_of(Ticket.t()) :: Project.t()
  def project_of(%Ticket{project_id: id}), do: Projects.get!(id)

  @doc "Adds a ticket update to a multi."
  @spec put_progress(Multi.t(), term(), Ticket.t(), map()) :: Multi.t()
  def put_progress(multi, key, %Ticket{} = ticket, attrs) do
    Multi.update(multi, key, Ticket.progress_changeset(ticket, attrs))
  end
end
