defmodule Forge.Release do
  @moduledoc """
  Commands for the running release, where Mix does not exist. Invoke with
  `bin/forge eval 'Forge.Release.migrate()'` and friends; see the deployment guide.
  """

  @app :forge

  @doc "Runs pending migrations."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls one repo back to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Creates a confirmed, approved operator who can log in with the password.

  `opts` are `Forge.Accounts.create_operator/3`'s, and `node_admin: true` is the one that
  matters on a fresh node: **the very first account has to be made with it.** Nothing else can
  grant it afterwards — `/accounts` is behind `require_node_admin`, so with no node admin there
  is nobody to approve a second account, and `register_project/2` resolving its owner through
  `Forge.Accounts.owner_for/1` answers `:no_owner`. A container has no second way round it: the
  image sets `RELEASE_DISTRIBUTION=none` so `forge remote` has no node to attach to, and a bare
  `forge eval` reaches no repo, because starting one is what `with_app/1` below is for.
  """
  def create_operator(email, password, opts \\ []) do
    with_app(fn ->
      case Forge.Accounts.create_operator(email, password, opts) do
        {:ok, user} -> IO.puts("created #{described(user)} #{user.email} (#{user.id})")
        {:error, changeset} -> fail(inspect(changeset.errors))
      end
    end)
  end

  # What was made, not merely that something was: `node_admin: true` is the difference between a
  # first account that can admit the second and one that is a dead end.
  defp described(%{node_admin: true}), do: "node admin"
  defp described(_user), do: "user"

  @doc "Prints a new API token for the user, once."
  def create_token(email, name \\ "cli") do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> IO.puts(Forge.Accounts.create_api_token(user, name))
      end
    end)
  end

  @doc "Lists the user's API tokens by name."
  def list_tokens(email) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> Enum.each(Forge.Accounts.list_api_tokens(user), &print_token/1)
      end
    end)
  end

  defp print_token(token), do: IO.puts("#{token.name}\t#{token.inserted_at}\t#{token.id}")

  @doc "Revokes the user's API tokens with that name."
  def revoke_token(email, name) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> IO.puts("revoked #{Forge.Accounts.revoke_api_tokens(user, name)} token(s)")
      end
    end)
  end

  @doc """
  Registers a project; the bare repository is created if missing.

  `owner_email` names who administers it. Omitted, it resolves to the node's only admin, and
  refuses when there is more than one — a project with no members is invisible to everyone and
  repairable only with SQL, so guessing is worse than asking.
  """
  def register_project(name, repo_path, default_branch \\ "main", owner_email \\ nil) do
    with_app(fn ->
      with {:ok, owner} <- Forge.Accounts.owner_for(owner_email),
           {:ok, project} <-
             Forge.Projects.register(
               %{name: name, repo_path: repo_path, default_branch: default_branch},
               owner
             ) do
        IO.puts(
          "registered #{project.name} at #{Forge.Projects.repo_path(project)}, owned by #{owner.email}"
        )
      else
        {:error, :ambiguous_owner} ->
          fail("more than one node admin: pass the owner address as the fourth argument")

        {:error, :no_owner} ->
          fail(
            "no node admin exists: create one with " <>
              "`Forge.Release.create_operator(EMAIL, PASSWORD, node_admin: true)`"
          )

        {:error, :unknown_user} ->
          fail("unknown user #{owner_email}")

        {:error, %Ecto.Changeset{} = changeset} ->
          fail(inspect(changeset.errors))

        {:error, reason} ->
          fail(inspect(reason))
      end
    end)
  end

  @doc """
  Adds a member to a project, from the host.

  The repair path for a project whose admins are all gone: there is nobody left holding
  `:manage` for the product's own membership page to act through.
  """
  def add_member(project_name, email, role \\ "member") do
    with_app(fn ->
      project = Forge.Projects.by_name(project_name)
      user = Forge.Accounts.get_user_by_email(email)

      cond do
        is_nil(project) -> fail("unknown project #{project_name}")
        is_nil(user) -> fail("unknown user #{email}")
        role not in ["admin", "member"] -> fail("role must be admin or member")
        true -> grant(project, user, role)
      end
    end)
  end

  @doc """
  Mints a permanent machine for the user, from the host, and prints its environment once.

  What `mix forge.worker.new --owner` does where Mix does not exist — the owner always named, and
  no seed lines or `--out` — and what *New machine* on `/workers` does for the person logged in:
  all three are `Forge.Workers.mint/2`
  (`docs/design/identity.md` § Minting a permanent machine). With a project, the user must be a
  member of it and the machine is assigned there; without one it takes no work until they assign
  it on `/workers`.

  **It needs `FORGE_PLATFORM_URL`**, and refuses before writing anything without it. The page
  and the Mix task ask the endpoint its address when it is unset, and this cannot: `with_app/1`
  starts the repository and nothing else, because the endpoint is the running service's.

  The output holds the machine's token, so send it somewhere with a sane umask rather than into
  a terminal's scrollback.
  """
  def new_worker(email, project_name \\ nil) do
    with_app(fn ->
      user = Forge.Accounts.get_user_by_email(email)
      project = project_name && Forge.Projects.by_name(project_name)

      cond do
        is_nil(Forge.Jobs.config(:platform_url, nil)) ->
          fail(
            "FORGE_PLATFORM_URL is not set, and a command on the host cannot ask the running " <>
              "platform its address: set it to the address machines dial, or mint from /workers"
          )

        is_nil(user) ->
          fail("unknown user #{email}")

        project_name && is_nil(project) ->
          fail("unknown project #{project_name}")

        true ->
          mint(user, project)
      end
    end)
  end

  defp mint(user, project) do
    case Forge.Workers.mint(user, project && project.id) do
      {:ok, _worker, env} -> IO.puts(env)
      {:error, :not_a_member} -> fail("#{user.email} is not a member of #{project.name}")
      {:error, :not_approved} -> fail("#{user.email} is not approved")
      {:error, :suspended} -> fail("#{user.email} is suspended")
      {:error, changeset} -> fail(inspect(changeset.errors))
    end
  end

  @doc """
  Gives a machine with no owner one, from the host.

  The repair path for a permanent machine the move to owned machines could not place: on a node
  with more than one node admin, `WorkersHaveOwners` would not guess whose it was, and a machine
  nobody owns can be assigned to no project and takes no work (`docs/design/identity.md`
  § Workers). The owner then assigns it on `/workers`.

  **Only a machine with no owner.** Changing whose machine it is would move the right to put
  work on it, which is not a repair and not something to do from a shell.
  """
  def own_worker(worker_id, email) do
    with_app(fn ->
      worker = Forge.Workers.get(worker_id)
      user = Forge.Accounts.get_user_by_email(email)

      cond do
        is_nil(worker) -> fail("unknown worker #{worker_id}")
        is_nil(user) -> fail("unknown user #{email}")
        true -> own(worker, user)
      end
    end)
  end

  defp own(worker, user) do
    case Forge.Workers.adopt(worker, user) do
      {:ok, _worker} ->
        IO.puts("worker #{worker.id} is now #{user.email}'s; assign it to projects on /workers")

      {:error, :already_owned} ->
        fail("worker #{worker.id} already has an owner")
    end
  end

  defp grant(project, user, role) do
    case Forge.Projects.grant_member(project, user, String.to_existing_atom(role)) do
      {:ok, _member} -> IO.puts("#{user.email} is now #{role} of #{project.name}")
      {:error, reason} -> fail(inspect(reason))
    end
  end

  @doc """
  Attaches an OIDC identity to an account that already exists.

  The deliberate version of a join an OIDC login will never make on its own: a login whose
  address is already somebody's is refused rather than adopted, because adopting it would let
  any configured issuer assert a node admin's address and become them
  (`docs/design/identity.md` § What the first implementation settled). This is that same join,
  made by somebody with a shell, who is past every gate there is.

  `issuer` is the issuer URL exactly as configured, and `subject` is the `sub` claim — the
  accounts page shows the first and the provider's own console has the second.
  """
  def link_identity(email, issuer, subject) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> link(user, issuer, subject)
      end
    end)
  end

  defp link(user, issuer, subject) do
    case Forge.Accounts.link_identity(user, issuer, subject) do
      {:ok, _identity} -> IO.puts("#{user.email} now logs in as #{subject} at #{issuer}")
      {:error, :already_linked} -> fail("that identity already belongs to an account")
      {:error, reason} -> fail(inspect(reason))
    end
  end

  @doc "Approves a pending account from the host, which is how the first one gets in."
  def approve_user(email) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> approve(user)
      end
    end)
  end

  defp approve(user) do
    case Forge.Accounts.approve_user(user, :host) do
      {:ok, user} -> IO.puts("approved #{user.email}")
      {:error, reason} -> fail(inspect(reason))
    end
  end

  @doc """
  Prints a clone URL carrying a short-lived git credential, once.

  Without a ticket number the token may only read. With one it may also write that ticket's
  branch, and nothing else. With `:default` it may write the project's default branch — the shape
  a repository is seeded with, fast-forward only. See `docs/design/git-hosting.md`.
  """
  def git_token(name, ticket_number \\ nil) do
    with_app(fn ->
      case Forge.Projects.by_name(name) do
        nil -> fail("unknown project #{name}")
        project -> print_git_token(project, ticket_number)
      end
    end)
  end

  defp print_git_token(project, ticket_number) do
    scope =
      case ticket_number do
        nil ->
          []

        :default ->
          [ref: Forge.Git.Tokens.default_ref(project)]

        number ->
          ticket = Forge.Tickets.get_by_number!(project, number)
          [ticket_id: ticket.id, ref: "refs/heads/" <> ticket.branch]
      end

    {:ok, secret, token} = Forge.Git.Tokens.issue(project, [name: "release task"] ++ scope)
    IO.puts(Forge.Git.Url.with_token(project, secret))
    IO.puts("writes #{token.ref || "nothing"}, until #{token.expires_at}")
  end

  @doc """
  Creates or replaces one of a project's mirrors, named `mirror_name`. `opts` takes `:refs`,
  `:user` and `:token`, all optional — the same options `Forge.Projects.put_mirror/5` takes.

  Goes through that same context function, with the node's own admin as the actor, so the rules
  it enforces (the URL allowlist, who may set one) hold from a shell exactly as they do from the
  UI. See `docs/design/identity.md` § Where the guard lives.
  """
  def set_mirror(name, mirror_name, url, opts \\ []) do
    with_app(fn ->
      with {:ok, project} <- fetch_project(name),
           {:ok, admin} <- Forge.Accounts.owner_for(nil),
           :ok <- Forge.Projects.put_mirror(project, admin, mirror_name, url, opts) do
        IO.puts(url)
      else
        {:error, reason} -> fail(mirror_error(reason))
      end
    end)
  end

  @doc "Removes one of a project's mirrors, named `mirror_name`."
  def delete_mirror(name, mirror_name) do
    with_app(fn ->
      with {:ok, project} <- fetch_project(name),
           {:ok, admin} <- Forge.Accounts.owner_for(nil),
           :ok <- Forge.Projects.delete_mirror(project, admin, mirror_name) do
        IO.puts("mirror removed")
      else
        {:error, reason} -> fail(mirror_error(reason))
      end
    end)
  end

  defp fetch_project(name) do
    case Forge.Projects.by_name(name) do
      nil -> {:error, {:unknown_project, name}}
      project -> {:ok, project}
    end
  end

  defp mirror_error({:unknown_project, name}), do: "unknown project #{name}"
  defp mirror_error(:ambiguous_owner), do: "more than one node admin"
  defp mirror_error(:no_owner), do: "no node admin"
  defp mirror_error(reason), do: inspect(reason)

  @doc "Prints a fresh VAPID key pair for web push, to put into the environment."
  def generate_vapid_keys do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    IO.puts("FORGE_VAPID_PUBLIC_KEY=" <> Base.url_encode64(public_key, padding: false))
    IO.puts("FORGE_VAPID_PRIVATE_KEY=" <> Base.url_encode64(private_key, padding: false))
    :ok
  end

  # Starts the repo (not the whole app, so no scheduler runs) around a command.
  defp with_app(fun) do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> fun.() end)
    end

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
