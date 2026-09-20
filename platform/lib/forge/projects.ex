defmodule Forge.Projects do
  @moduledoc "Projects: a name, a bare repository the platform owns, and a default branch."

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.{Events, Git, Repo}
  alias Forge.Git.Hooks
  alias Forge.Projects.{Member, Project}

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

  ## Membership

  @doc "The role this user holds on this project, or nil for a non-member."
  @spec role(Project.t(), User.t()) :: Member.role() | nil
  def role(%Project{id: project_id}, %User{id: user_id}) do
    Repo.one(
      from m in Member,
        where: m.project_id == ^project_id and m.user_id == ^user_id,
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
  """
  @spec put_member(Project.t(), User.t(), Member.role(), User.t()) ::
          {:ok, Member.t()} | {:error, term()}
  def put_member(%Project{} = project, %User{} = user, role, %User{} = by)
      when role in [:admin, :member] do
    cond do
      manageable(project, by) != :ok ->
        {:error, :forbidden}

      # Demotion is removal by another name: a project whose last admin becomes a member has
      # nobody who can make one again, and `remove_member/3` refuses exactly this.
      role != :admin and last_admin?(project, user) ->
        {:error, :last_admin}

      true ->
        set_member(project, user, role, by)
    end
  end

  defp set_member(project, user, role, by) do
    changeset =
      Member.changeset(%Member{}, %{project_id: project.id, user_id: user.id, role: role})

    Multi.new()
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
    cond do
      manageable(project, by) != :ok ->
        {:error, :forbidden}

      last_admin?(project, user) ->
        {:error, :last_admin}

      true ->
        Multi.new()
        |> Multi.delete_all(
          :member,
          from(m in Member, where: m.project_id == ^project.id and m.user_id == ^user.id)
        )
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
  end

  # Membership is what `:manage` means, so changing it is guarded the same way the settings are.
  # Here rather than only in the page: a LiveView that hides the form is cosmetics, and this is
  # the thing an event sent by hand still has to get past.
  defp manageable(%Project{} = project, %User{} = by) do
    scope = Forge.Accounts.Scope.for_project(Forge.Accounts.Scope.for_user(by), project)
    Forge.Access.ensure(scope, :manage)
  end

  defp last_admin?(%Project{id: project_id}, %User{id: user_id}) do
    role(%Project{id: project_id}, %User{id: user_id}) == :admin and
      not Repo.exists?(
        from m in Member,
          where: m.project_id == ^project_id and m.role == :admin and m.user_id != ^user_id
      )
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
  """
  @spec set_model(Project.t(), String.t() | nil) :: {:ok, Project.t()} | {:error, term()}
  def set_model(%Project{} = project, model) do
    with {:ok, project} <- project |> Project.changeset(%{model: model}) |> Repo.update() do
      Events.append("project.model_set", :system, %{
        payload: %{"project" => project.name, "model" => project.model}
      })

      {:ok, project}
    end
  end

  @doc """
  Points the project's repository at a mirror, or removes it when `url` is `nil`. The mirror is
  repository configuration rather than a column: the `post-receive` hook is what pushes it, and
  the hook can read only `git config`. See `docs/design/git-hosting.md`.
  """
  @spec set_mirror(Project.t(), String.t() | nil, String.t() | nil) :: :ok | {:error, term()}
  def set_mirror(%Project{} = project, url, refs \\ nil) do
    with :ok <- Hooks.set_mirror(repo_path(project), url, refs) do
      Events.append("project.mirror_set", :system, %{
        payload: %{"project" => project.name, "mirror" => url}
      })
      |> case do
        {:ok, _event} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The mirror the project's repository is configured with, or `nil`."
  @spec mirror(Project.t()) :: String.t() | nil
  def mirror(%Project{} = project), do: Hooks.mirror(repo_path(project))

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
