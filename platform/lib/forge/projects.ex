defmodule Forge.Projects do
  @moduledoc "Projects: a name, a bare repository the platform owns, and a default branch."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.{Events, Git, Repo}
  alias Forge.Git.Credentials
  alias Forge.Git.Hooks
  alias Forge.Projects.{Member, Mirror, Project}

  require Logger

  @doc """
  Registers a project. The bare repository at `repo_path` is created if it does not exist;
  an existing one is used as is, so a repository can be imported by pushing to it first. The
  hooks that enforce the branch discipline are installed either way.

  **The name is reserved before the repository is touched.** Registering a name that already
  exists fails at the insert, before any git runs, so a registration can never rewrite another
  project's HEAD, hooks or default branch — the guard is the name and not the directory, which is
  what keeps the import-by-push path working. See `docs/design/git-hosting.md`.
  """
  @spec register(map(), User.t() | nil) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def register(attrs, owner \\ nil)

  # Refused rather than allowed to produce a project with no members: such a project is invisible
  # to every user including a node admin, and the only repair is SQL. The command line resolves
  # an owner with `Accounts.owner_for/1` before it gets here.
  def register(_attrs, nil), do: {:error, :no_owner}

  def register(attrs, %User{} = owner) do
    changeset = Project.changeset(%Project{}, attrs)

    Multi.new()
    # Reserve the name first: `unique_constraint(:name)` is the authority on who owns a repo
    # path, so a second registration of an existing name fails here and `initialize_repo/1`
    # below never runs against a repository that is not this row's own.
    |> Multi.insert(:project, changeset)
    |> own(owner)
    |> Events.log(:event, "project.registered", actor(owner), fn %{project: project} ->
      %{
        project_id: project.id,
        payload: %{"project_id" => project.id, "name" => project.name}
      }
    end)
    # Git runs last and inside the transaction: if it fails, the row, the membership and the
    # event all roll back, and `initialize_repo/1` removes any directory it created.
    |> Multi.run(:repo, fn _repo, %{project: project} -> initialize_repo(project) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{project: project}} -> {:ok, project}
      {:error, :project, changeset, _} -> {:error, changeset}
      {:error, :repo, reason, _} -> {:error, reason}
    end
  end

  # Creates the repository for a freshly reserved project. Called only after the name is this
  # row's, so it can never touch another project's repository.
  defp initialize_repo(%Project{} = project) do
    path = Path.expand(project.repo_path)
    we_made_it? = not File.exists?(path)

    with :ok <- Git.init_bare(path),
         :ok <- Hooks.install(path, project),
         # A bare repository `git init` made points HEAD at whatever git's default is, which a
         # worker's `clone --branch <default>` then cannot find. Harmless while the platform
         # cloned on its own disk; not harmless once the clone comes over the wire.
         :ok <- Git.ensure_head(path, project.default_branch),
         # And a commit on it. Everything the platform does starts from the default branch — a
         # ticket's base, a conversation's branch, a merge's destination — and `pre-receive`
         # lets nothing but the platform's own merge write it, so no push could create it.
         :ok <- Git.ensure_initial_commit(path, project.default_branch) do
      {:ok, path}
    else
      {:error, reason} ->
        # Remove only a directory this call created: an imported repository the caller pushed
        # first is theirs, and a rollback must not delete it.
        if we_made_it?, do: File.rm_rf(path)
        {:error, reason}
    end
  end

  # Whoever registers a project administers it — `docs/design/identity.md` § Projects and
  # members. There is no ownerless path any more: `register/2` refuses one.
  defp own(multi, %User{} = owner) do
    Multi.insert(multi, :member, fn %{project: project} ->
      Member.changeset(%Member{}, %{
        project_id: project.id,
        user_id: owner.id,
        role: :admin
      })
    end)
  end

  defp actor(%User{id: id}), do: {:user, id}

  # The platform acting on its own, and the only other thing `by` can be.
  defp actor(:system), do: :system

  @doc """
  Adds a member with no capability check, for the host.

  This is the repair path and deliberately not `put_member/4`: a project whose admins are all
  gone has nobody holding `:manage` to act through, so a function that required one could not
  fix the state it exists to fix. Reachable only from a shell, which is past every gate.
  """
  @spec grant_member(Project.t(), User.t(), Member.role()) :: {:ok, Member.t()} | {:error, term()}
  def grant_member(%Project{} = project, %User{} = user, role) when role in [:admin, :member] do
    %Member{}
    |> Member.changeset(%{project_id: project.id, user_id: user.id, role: role})
    |> Repo.insert(
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:project_id, :user_id]
    )
  end

  @spec get!(String.t()) :: Project.t()
  def get!(id), do: Repo.get!(Project, id)

  @spec by_name(String.t()) :: Project.t() | nil
  def by_name(name), do: Repo.one(from p in Project, where: p.name == ^name)

  @doc """
  Every project. Node-wide, so nothing an operator sees may call it — see `list/1`.
  """
  @spec list() :: [Project.t()]
  def list, do: Repo.all(from p in Project, order_by: p.name)

  @doc """
  The projects this user is a member of, which is the only list a person is ever shown.

  A non-member does not see a project: not its name, not its tickets, not that it exists
  (`docs/design/identity.md` § Projects and members).
  """
  @spec list(User.t()) :: [Project.t()]
  def list(%User{id: user_id}) do
    Repo.all(
      from p in Project,
        join: m in Member,
        on: m.project_id == p.id,
        where: m.user_id == ^user_id,
        order_by: p.name
    )
  end

  @doc """
  The viewer's projects with what waits on them and what runs, then what each has to run on:
  `waiting` (the items of the viewer's queue in that project, counted as the queue counts them),
  `running` (its jobs on a machine now), open tickets, assigned templates, permanent machines
  assigned to it, credentials in its pool that are not revoked, and the latest thing that
  happened — `latest`, its most recently changed open ticket, and `last_merge`, when a ticket of
  it last merged (`docs/design/ui.md` § The projects page).

  **Projects that wait on the viewer come first**, by name within each group.

  One read per figure over every project, never one per project: the page is a list, and a
  list that queries per row grows its cost with the thing it lists. The waiting counts are one
  read of the viewer's queue, which is scoped by membership as the queue page is.
  """
  @spec summaries(User.t()) :: [
          %{
            project: Project.t(),
            waiting: non_neg_integer(),
            first_waiting: Forge.Queue.item() | nil,
            running: non_neg_integer(),
            open_tickets: non_neg_integer(),
            templates: non_neg_integer(),
            machines: non_neg_integer(),
            credentials: non_neg_integer(),
            latest: Forge.Tickets.Ticket.t() | nil,
            last_merge: DateTime.t() | nil
          }
        ]
  def summaries(%User{} = user) do
    projects = list(user)
    ids = Enum.map(projects, & &1.id)

    # **Scoped twice, and the second is what holds.** The rows are `list(user)`'s and every figure
    # is looked up by a row's project, so a count for a project not on the page has nowhere to be
    # drawn: reading the node-wide `Queue.items/0` here, or dropping `in ^ids` from a query below,
    # is an equivalent mutant on the page — the narrowing is about what is read, not what is shown.
    by_project = user |> Forge.Queue.items() |> Enum.group_by(& &1.project.id)

    waiting =
      Map.new(by_project, fn {project_id, items} -> {project_id, Forge.Queue.tally(items)} end)

    # What has waited longest, which a row with a count names in place of its latest line: the
    # count says something waits, and this says what (`docs/design/ui.md` § The projects page).
    first_waiting =
      Map.new(by_project, fn {project_id, items} ->
        {project_id,
         items
         |> Enum.filter(&Forge.Queue.waiting?/1)
         |> Enum.min_by(& &1.since, DateTime, fn -> nil end)}
      end)

    running =
      counts(
        from(j in Forge.Jobs.Job,
          where: j.project_id in ^ids and j.status == :running,
          group_by: j.project_id,
          select: {j.project_id, count(j.id)}
        )
      )

    tickets =
      counts(
        from(t in Forge.Tickets.Ticket,
          where: t.project_id in ^ids and t.status in ^Forge.Tickets.Ticket.open_statuses(),
          group_by: t.project_id,
          select: {t.project_id, count(t.id)}
        )
      )

    templates =
      counts(
        from(a in Forge.Provisioning.ProjectTemplate,
          where: a.project_id in ^ids,
          group_by: a.project_id,
          select: {a.project_id, count(a.template_id)}
        )
      )

    # Permanent machines assigned to the project, which serve its jobs with no template at all
    # (`docs/design/identity.md` § Workers). A destroyed one serves nothing.
    machines =
      counts(
        from(a in Forge.Workers.ProjectWorker,
          join: w in Forge.Workers.Worker,
          on: w.id == a.worker_id,
          where: a.project_id in ^ids and w.status != :destroyed,
          group_by: a.project_id,
          select: {a.project_id, count(w.id)}
        )
      )

    credentials =
      counts(
        from(a in Forge.Credentials.ProjectCredential,
          join: c in Forge.Credentials.Credential,
          on: c.id == a.credential_id,
          where: a.project_id in ^ids and is_nil(c.revoked_at),
          group_by: a.project_id,
          select: {a.project_id, count(c.id)}
        )
      )

    # Each project's most recently changed open ticket, in one read: `DISTINCT ON` keeps the
    # first row per project in the order given.
    latest =
      Repo.all(
        from(t in Forge.Tickets.Ticket,
          where: t.project_id in ^ids and t.status in ^Forge.Tickets.Ticket.open_statuses(),
          distinct: [asc: t.project_id],
          order_by: [desc: t.updated_at, desc: t.number]
        )
      )
      |> Map.new(&{&1.project_id, &1})

    last_merge =
      counts(
        from(e in Forge.Events.Event,
          where: e.project_id in ^ids and e.type == "ticket.merged",
          group_by: e.project_id,
          select: {e.project_id, max(e.inserted_at)}
        )
      )

    rows =
      for project <- projects do
        %{
          project: project,
          waiting: Map.get(waiting, project.id, 0),
          first_waiting: Map.get(first_waiting, project.id),
          running: Map.get(running, project.id, 0),
          open_tickets: Map.get(tickets, project.id, 0),
          templates: Map.get(templates, project.id, 0),
          machines: Map.get(machines, project.id, 0),
          credentials: Map.get(credentials, project.id, 0),
          latest: Map.get(latest, project.id),
          last_merge: Map.get(last_merge, project.id)
        }
      end

    # Stable, so each group keeps `list/1`'s order by name.
    Enum.sort_by(rows, &(&1.waiting == 0))
  end

  defp counts(query), do: query |> Repo.all() |> Map.new()

  ## Membership

  @doc """
  The role this user holds on this project, or nil for a non-member — **and nil for an account
  that may not act**, pending or suspended, whatever its rows say.

  Read from the database at every call, the account's standing with the membership, because the
  `%User{}` a caller holds is the one its page mounted with. Every guard on a project asks this —
  `Forge.Operator`, membership here, assigning a machine, a template or a credential — so a
  member suspended while a page was open is refused at the next act, not only at the next mount
  (review fixes 7, H1). A suspended member keeps its row (§ Projects and members), which is why
  the row alone is not the answer.
  """
  @spec role(Project.t(), User.t()) :: Member.role() | nil
  def role(%Project{id: project_id}, %User{id: user_id}) do
    Repo.one(
      from m in Member,
        join: u in User,
        on: u.id == m.user_id,
        where: m.project_id == ^project_id and m.user_id == ^user_id,
        where: not is_nil(u.approved_at) and is_nil(u.suspended_at),
        select: m.role
    )
  end

  @doc """
  Whether this user may reach this project's work.

  Asks the capability rather than testing for any role at all. This is the JSON API's only read
  guard, so hard-coding "a membership row grants read" here is the capability seam failing at
  the one call site it was built for: splitting `:use` later would leave every ticket endpoint
  granting read to a role that no longer carries it.
  """
  @spec member?(Project.t(), User.t()) :: boolean()
  def member?(%Project{} = project, %User{} = user) do
    Forge.Access.can?(
      Forge.Accounts.Scope.for_project(Forge.Accounts.Scope.for_user(user), project),
      :use
    )
  end

  @doc "The memberships of a project, admins first then by when they joined."
  @spec members(Project.t()) :: [Member.t()]
  def members(%Project{id: project_id}) do
    Repo.all(
      from m in Member,
        where: m.project_id == ^project_id,
        order_by: [asc: m.inserted_at],
        preload: [:user]
    )
    |> Enum.sort_by(&{rank(&1.role), &1.inserted_at})
  end

  # Explicit, because `order_by: [asc: m.role]` sorted the stored strings and "admins first" was
  # true only because 'admin' < 'member' in the alphabet. A third role would reorder the page
  # silently.
  defp rank(:admin), do: 0
  defp rank(:member), do: 1

  @doc """
  Adds or changes a member.

  There are no invitations: the user already exists, because approval is what made them exist
  (`docs/design/identity.md` § Projects and members). `by` is the acting admin, recorded as the
  event's actor.

  **Only an account that may act is added**, which is `User.active?/1`: a pending account is
  refused with `:not_approved` and a suspended one with `:suspended`. Asked after the caller's
  own check, so a non-admin learns nothing about anybody's account from the answer.
  """
  @spec put_member(Project.t(), User.t(), Member.role(), User.t()) ::
          {:ok, Member.t()} | {:error, term()}
  def put_member(%Project{} = project, %User{} = user, role, %User{} = by)
      when role in [:admin, :member] do
    cond do
      manageable(project, by) != :ok ->
        {:error, :forbidden}

      # Approval is the perimeter, and a membership is inside it. A pending account in a project
      # could use nothing — its session and token are refused — but its row is one
      # `on_delete: :restrict` holds against `Accounts.delete_unapproved_user/2`, the one way a
      # squatted address is freed.
      not User.active?(user) ->
        {:error, User.standing(user)}

      true ->
        set_member(project, user, role, by)
    end
  end

  defp set_member(project, user, role, by) do
    changeset =
      Member.changeset(%Member{}, %{project_id: project.id, user_id: user.id, role: role})

    Multi.new()
    # Demotion is removal by another name: a project whose last admin becomes a member has
    # nobody who can make one again, and `remove_member/3` refuses exactly this.
    |> Multi.run(:last_admin, fn _repo, _changes ->
      if role == :admin, do: {:ok, nil}, else: not_last_admin(project, user)
    end)
    |> Multi.insert(:member, changeset,
      on_conflict: {:replace, [:role, :updated_at]},
      conflict_target: [:project_id, :user_id]
    )
    |> Events.log(:event, "project.member_set", {:user, by.id}, %{
      project_id: project.id,
      payload: %{"project_id" => project.id, "user_id" => user.id, "role" => to_string(role)}
    })
    |> Repo.transaction()
    |> case do
      {:ok, %{member: member}} -> {:ok, member}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Removes a member.

  Removing the last admin is refused: a project with none has no one who can add one, and the
  membership page would be the thing that locked itself.
  """
  @spec remove_member(Project.t(), User.t(), User.t()) :: :ok | {:error, term()}
  def remove_member(%Project{} = project, %User{} = user, %User{} = by) do
    if manageable(project, by) == :ok,
      do: delete_member(project, user, by),
      else: {:error, :forbidden}
  end

  defp delete_member(project, user, by) do
    Multi.new()
    |> Multi.run(:last_admin, fn _repo, _changes -> not_last_admin(project, user) end)
    |> Multi.delete_all(
      :member,
      from(m in Member, where: m.project_id == ^project.id and m.user_id == ^user.id)
    )
    |> put_withdrawn(project, user)
    |> Events.log(:event, "project.member_removed", {:user, by.id}, %{
      project_id: project.id,
      payload: %{"project_id" => project.id, "user_id" => user.id}
    })
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp not_last_admin(project, user),
    do: if(last_admin?(project, user), do: {:error, :last_admin}, else: {:ok, nil})

  # **A person who leaves a project stops funding it**, in the transaction that removes them: the
  # templates, machines and credentials they assigned to it are unassigned with the membership
  # (`docs/design/identity.md` § Workers). Assignment is only allowed to a member, and without
  # this the rule held on the way in and not afterwards — a template kept making machines billed
  # to someone who could no longer see the project they were made for.
  defp put_withdrawn(multi, %Project{id: project_id}, %User{id: user_id}) do
    multi
    |> Multi.delete_all(
      :withdrawn_templates,
      from(a in Forge.Provisioning.ProjectTemplate,
        join: t in assoc(a, :template),
        where: a.project_id == ^project_id and t.user_id == ^user_id
      )
    )
    |> Multi.delete_all(
      :withdrawn_workers,
      from(a in Forge.Workers.ProjectWorker,
        join: w in assoc(a, :worker),
        where: a.project_id == ^project_id and w.user_id == ^user_id
      )
    )
    |> Multi.delete_all(
      :withdrawn_credentials,
      from(a in Forge.Credentials.ProjectCredential,
        join: c in assoc(a, :credential),
        where: a.project_id == ^project_id and c.user_id == ^user_id
      )
    )
  end

  # Membership is what `:manage` means, so changing it is guarded the same way the settings are.
  # Here rather than only in the page: a LiveView that hides the form is cosmetics, and this is
  # the thing an event sent by hand still has to get past.
  defp manageable(%Project{} = project, %User{} = by) do
    scope = Forge.Accounts.Scope.for_project(Forge.Accounts.Scope.for_user(by), project)
    Forge.Access.ensure(scope, :manage)
  end

  # Asked inside the transaction that demotes or removes, with the project's admin rows locked:
  # two admins demoting each other at once each saw the other still there when this was asked
  # before the write, both writes committed, and the project had none. Locked, the second waits
  # for the first, and reads the rows as the first left them.
  #
  # The lock itself is an equivalent mutant under the test sandbox, which runs every process of a
  # test on one connection in one transaction, so two writers never wait on each other there;
  # the refusal it guards is what the tests can see.
  defp last_admin?(%Project{id: project_id}, %User{id: user_id}) do
    admins =
      Repo.all(
        from m in Member,
          where: m.project_id == ^project_id and m.role == :admin,
          lock: "FOR UPDATE",
          select: m.user_id
      )

    admins == [user_id]
  end

  @doc "Changes a registered project. `mix forge.seed.publish` uses it to move the seed on."
  @spec update(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update(%Project{} = project, attrs),
    do: project |> Project.changeset(attrs) |> Repo.update()

  @doc "Absolute path of the project's bare repository."
  @spec repo_path(Project.t()) :: String.t()
  def repo_path(%Project{repo_path: path}), do: Path.expand(path)

  @doc """
  Reinstalls the hooks in every registered repository, and gives any repository with an unborn
  default branch its first commit. Called at boot, so a change to a rule reaches repositories
  that already exist rather than new ones only.

  The second half is here for exactly the reason the first is. Registering a project writes an
  empty root commit, but a project registered *before* that existed still has nothing on its
  default branch — and everything starts from that branch, so a chat or a ticket on one fails
  with a ref error. Fixing it only on the way in would leave every project that already exists
  broken for ever, since nothing outside the platform may write that branch.
  """
  @spec ensure_hooks() :: non_neg_integer()
  def ensure_hooks do
    Enum.count(list(), fn project ->
      path = repo_path(project)

      with :ok <- install_hooks(project, path),
           :ok <- ensure_branch(project, path) do
        true
      else
        _error -> false
      end
    end)
  end

  defp install_hooks(project, path) do
    case Hooks.install(path, project) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("could not install hooks in #{project.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_branch(project, path) do
    case Git.ensure_initial_commit(path, project.default_branch) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("could not start #{project.name}'s default branch: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sets the project's default model, or clears it when given nothing.

  Cleared is not "no model": it is the machine's, which is the platform-wide setting. The value
  is not checked against a list of models — see `docs/design/workflow-grammar-v1.md` § Model.

  `by` is who is doing it, and it reaches the event: a setting that decides what every job on the
  project runs on — and so what it spends — is one the log has to be able to attribute.
  `Operator.set_model/3` passes the person it already checked; `:system` is for the platform
  acting on its own, and a test setting a default up front. `actor/1` is total for those two
  shapes only, so anything else raises — and raises before the transaction opens, which is why
  there is no separate guard on this head: one would be an equivalent mutant (see `set_defaults/3`).

  **The event is part of the write, not a side effect of it.** Both go in one transaction, so a
  rejected event is a rejected change rather than a setting that took effect with nothing in the
  log: attribution is this function's whole point, and a log that can silently miss a row is one
  nobody can reason from. `Events.append/3`'s result used to be discarded here.
  """
  @spec set_model(Project.t(), String.t() | nil, User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_model(%Project{} = project, model, by \\ :system) do
    set_defaults(project, %{model: model}, by)
  end

  @doc """
  Sets the project's default effort, or clears it when given nothing.

  Cleared is not "no effort": it is the machine's, as a cleared model is. The value is not checked
  against a list of levels — see `docs/design/workflow-grammar-v1.md` § Effort.

  `by` reaches the event, as `set_model/3`'s does and for the same reason: turning a project's
  effort up turns its spend up. Same guard, same transaction — see `set_model/3`.
  """
  @spec set_effort(Project.t(), String.t() | nil, User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_effort(%Project{} = project, effort, by \\ :system) do
    set_defaults(project, %{effort: effort}, by)
  end

  @doc """
  Sets the project's default harness, which a state naming none runs on. Refused for a name
  `ForgeCore.Harness.names/0` does not list. Same guard and transaction as the dials.
  """
  @spec set_harness(Project.t(), String.t(), User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_harness(%Project{} = project, harness, by \\ :system),
    do: set_defaults(project, %{harness: harness}, by)

  @doc "Sets Codex's default model for the project, or clears it (Codex's own default then)."
  @spec set_codex_model(Project.t(), String.t() | nil, User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_codex_model(%Project{} = project, model, by \\ :system),
    do: set_defaults(project, %{codex_model: model}, by)

  @doc "Sets Codex's default effort for the project, or clears it."
  @spec set_codex_effort(Project.t(), String.t() | nil, User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_codex_effort(%Project{} = project, effort, by \\ :system),
    do: set_defaults(project, %{codex_effort: effort}, by)

  @dials %{
    model: "project.model_set",
    effort: "project.effort_set",
    harness: "project.harness_set",
    codex_model: "project.codex_model_set",
    codex_effort: "project.codex_effort_set"
  }

  @doc """
  Sets the project's agent defaults together — what project settings' one Save sends
  (`docs/design/ui.md` § Model and effort): the harness, Claude's model and effort and Codex's,
  or whichever of them `attrs` names.

  **Both columns and an event for each in one transaction, or nothing.** A refused effort leaves
  the model as it was rather than saving half of what the person pressed Save on; a rejected
  event rejects the change, because attribution is this function's whole point and a log that
  can silently miss a row is one nobody can reason from. A key other than the five dials is
  ignored, so nothing else about the project can be reached through here.

  Each event carries the project's id as well as its name, so the events about one project are
  one indexed read (`observed_model/1` reads the last model change that way).

  **A `by` that is neither a user nor `:system` raises before anything is written**, because
  `actor(by)` is evaluated while this `Multi` is being built and the transaction has not opened
  yet. That is what makes a guard on the public heads an equivalent mutant: adding one moves the
  same `FunctionClauseError` a few microseconds earlier and changes nothing a caller or the
  database can see.
  """
  @spec set_defaults(Project.t(), map(), User.t() | :system) ::
          {:ok, Project.t()} | {:error, term()}
  def set_defaults(%Project{} = project, attrs, by \\ :system) when is_map(attrs) do
    attrs = Map.take(attrs, Map.keys(@dials))
    actor = actor(by)

    attrs
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(
      Multi.update(Multi.new(), :project, Project.changeset(project, attrs)),
      fn field, multi ->
        # The payload reads the *updated* row, so it says what the setting became rather than what
        # was asked for — a blank value, which the changeset stores as nil, is logged as nil.
        Events.log(multi, {:event, field}, Map.fetch!(@dials, field), actor, fn %{project: p} ->
          %{
            project_id: p.id,
            payload: %{"project" => p.name, Atom.to_string(field) => Map.fetch!(p, field)}
          }
        end)
      end
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{project: project}} -> {:ok, project}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  What the project's work was last seen running on when nothing named a model — the value "the
  machine's" stands for, as far as anything has shown it (`docs/design/ui.md` § Model and effort).

  The model the harness reported starting with (`job.harness.started`) for the project's newest
  job that named no model of its own — a workflow job whose state named none, a conversation
  opened without one — and only since the project's default model last changed: before that, such
  a job ran on the project's model, not the machine's. So while the project names a model, there
  is nothing to observe. `nil` when no such job has started.

  It is an observation and never a prediction: with no model set a worker passes no `--model`,
  and the harness picks, which the platform cannot know in advance.
  """
  @spec observed_model(Project.t()) :: %{model: String.t(), at: DateTime.t()} | nil
  def observed_model(%Project{model: model}) when is_binary(model), do: nil

  def observed_model(%Project{id: project_id, name: name}) do
    # Older events about the model carry the project's name and no id (`set_defaults/3`).
    since =
      Repo.one(
        from e in Forge.Events.Event,
          where: e.type == "project.model_set",
          where:
            e.project_id == ^project_id or
              (is_nil(e.project_id) and fragment("?->>'project'", e.payload) == ^name),
          select: max(e.seq)
      ) || 0

    Repo.one(
      from e in Forge.Events.Event,
        join: j in Forge.Jobs.Job,
        on: j.id == e.job_id,
        where: j.project_id == ^project_id and e.type == "job.harness.started",
        where: e.seq > ^since,
        where: is_nil(j.model) and is_nil(fragment("?->>'model'", j.spec)),
        where: fragment("coalesce(?->>'model', '') <> ''", e.payload),
        order_by: [desc: e.seq],
        limit: 1,
        select: %{model: fragment("?->>'model'", e.payload), at: e.inserted_at}
    )
  end

  @doc "Every mirror this project pushes to, with what the hook last said about each."
  @spec list_mirrors(Project.t()) :: [map()]
  def list_mirrors(%Project{} = project), do: Hooks.list_mirrors(repo_path(project))

  @doc """
  Creates or replaces one mirror. `opts` takes `:refs`, `:user` and `:token`, all optional.

  **The guard is here and not on the page.** A mirror sends the project's history to a host this
  node does not control, which is a decision for the project's own admins — and `put_member/4`
  is the local precedent for why hiding a form is not a guard.

  The URL is validated before it is stored *and* again by the hook before it is used, because a
  config file is editable by anything that can reach the disk.

  **Refuses `{:error, :repo_path_not_standard}` for a project whose repository is not at
  `<repos_dir>/<name>.git`.** The hook derives its mirror-credential directory from its own
  working directory and `Forge.Git.Credentials.path/2` derives it from `repos_dir/0` and the
  project's name; the two agree only for a repository at that address. `register_named/3`
  guarantees it, but `register/2` does not — `mix forge.project.add` and
  `Forge.Release.register_project/4` both register an arbitrary path — and a project registered
  that way would otherwise accept a token here, write it where `Credentials.path/2` says, and
  have the hook look for it somewhere else entirely: an authenticated mirror that always fails
  with "could not read Username … terminal prompts disabled", visible only as a `lastError`. A
  loud refusal here is better than that silent one. See `Forge.Git.Credentials`.
  """
  @spec put_mirror(Project.t(), User.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def put_mirror(%Project{} = project, %User{} = by, name, url, opts \\ []) do
    with :ok <- manageable(project, by),
         :ok <- standard_repo_path(project),
         :ok <- Mirror.validate_name(name),
         :ok <- Mirror.validate_url(url),
         :ok <-
           Hooks.put_mirror(repo_path(project), name, url, refs: opts[:refs], user: opts[:user]),
         :ok <- Credentials.put(project, name, opts[:user], opts[:token], url) do
      mirror_event("project.mirror_set", project, by, name)
    end
  end

  # See the doc on `put_mirror/5` for what this protects and why it lives here rather than in
  # `Forge.Git.Credentials` or the hook: it is the one call that both writes the credential
  # (by name) and knows the project's actual `repo_path`, so it is the one place that can catch
  # the mismatch before a token is written anywhere.
  defp standard_repo_path(%Project{} = project) do
    if repo_path(project) == Path.join(repos_dir(), project.name <> ".git") do
      :ok
    else
      {:error, :repo_path_not_standard}
    end
  end

  @doc "Removes one mirror, its recorded status, and its credential."
  @spec delete_mirror(Project.t(), User.t(), String.t()) :: :ok | {:error, term()}
  def delete_mirror(%Project{} = project, %User{} = by, name) do
    with :ok <- manageable(project, by),
         :ok <- Mirror.validate_name(name),
         :ok <- Hooks.delete_mirror(repo_path(project), name),
         :ok <- Credentials.delete(project, name) do
      mirror_event("project.mirror_removed", project, by, name)
    end
  end

  defp mirror_event(type, project, by, name) do
    case Events.append(type, {:user, by.id}, %{
           payload: %{"project" => project.name, "mirror" => name}
         }) do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Where repositories registered by name live: `repos_dir` from the `Forge.Jobs` config, or
  `repos/` next to the data directory. Only the command line may register a repository
  anywhere else.
  """
  @spec repos_dir() :: String.t()
  def repos_dir do
    case Application.get_env(:forge, Forge.Jobs, [])[:repos_dir] do
      nil -> Path.join(Path.dirname(Forge.Jobs.data_dir()), "repos")
      dir -> Path.expand(dir)
    end
  end

  @doc "Registers a project whose bare repository is `<repos_dir>/<name>.git`."
  @spec register_named(String.t() | nil, String.t(), User.t() | nil) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t() | term()}
  def register_named(name, default_branch, owner \\ nil) do
    # The name is validated by the changeset before anything touches the filesystem, so a
    # path-like name never becomes a path.
    repo_path = if is_binary(name), do: Path.join(repos_dir(), name <> ".git")

    case register(%{name: name, repo_path: repo_path, default_branch: default_branch}, owner) do
      # Here the path is derived from the name rather than given, so it is blank only because
      # the name was. Reporting it would name a field the caller never sent.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, update_in(changeset.errors, &Keyword.delete(&1, :repo_path))}

      result ->
        result
    end
  end
end
