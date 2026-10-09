defmodule Forge.Secrets do
  @moduledoc """
  A project's secrets: values its jobs may be handed and the platform never uses.
  `docs/design/secrets.md`.

  **Nothing here is guarded.** These are the context's functions; the human writes reach them
  through `Forge.Operator.set_secret/4` and `delete_secret/3`, which ask for `:manage` first, as
  every other project setting does (`decisions.md` § Security and users). A read takes a project
  the caller has already been allowed into, as `Forge.Git.Tokens.list/1` does.

  **Every id is resolved inside the project it is given.** An id arrives from a page and is the
  client's; a secret of another project answers `:not_found` exactly as one that does not exist.

  **Delivery** (`secrets.md` § Delivery) reads the names a job holds (`jobs.secret_names`) and
  resolves them here: `missing/2` for the scheduler, which sticks a ticket whose job names a secret
  the project has not set; `for_wire/3` for the assignment, which opens each value and seals all of
  them for one worker and one job in a single step, so a plaintext never sits in an assignment
  map; and `held/1` for the run's record, which names each secret by id and version.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.{Engine, Events, Repo}
  alias Forge.Projects.Project
  alias Forge.Secrets.Secret
  alias Forge.Workers.Worker
  alias ForgeCore.Job.Credential

  @doc """
  The project's live secrets by name, each with who set its current version. Never a value: the
  query does not load one (`Forge.Secrets.Secret`). A deleted secret is not listed; the event log
  is its record.
  """
  @spec list(Project.t()) :: [Secret.t()]
  def list(%Project{id: project_id}) do
    Repo.all(from s in live(project_id), order_by: s.name, preload: :set_by)
  end

  # **The one statement of what a secret of this project is**: its row, not deleted. Every read
  # below is this and something more, so the rule that a secret belongs to one project is one
  # line to keep and one to mutate.
  defp live(project_id),
    do: from(s in Secret, where: s.project_id == ^project_id and is_nil(s.deleted_at))

  @doc """
  Sets a secret: a new one at version 1, or a new version of the live one with that name.

  **A replaced value is gone.** The row keeps one value, the current one; the version counts how
  many there have been. `secret.set` names the secret by its id, name and version — the id
  because a deleted name set again is a new row that starts at 1 again — and never by its value.

  **Everything a person typed is checked before the database is asked anything.** The name is a
  parameter of the query that finds the live row, and a name the database refuses outright — one
  with a NUL byte in it — would raise there rather than be refused here, and take the page's
  process down with the value in its last message (`secrets.md` § Surfaces).
  """
  @spec set(Project.t(), User.t(), term(), term()) ::
          {:ok, Secret.t()} | {:error, Ecto.Changeset.t()}
  def set(%Project{} = project, %User{} = by, name, value) do
    attrs = %{
      project_id: project.id,
      name: name,
      version: 1,
      set_by_id: by.id,
      set_at: DateTime.utc_now(:second)
    }

    case Secret.changeset(%Secret{}, attrs, value) do
      %Ecto.Changeset{valid?: false} = changeset -> {:error, changeset}
      new -> store(project, by, new, attrs, value)
    end
  end

  defp store(project, by, new, attrs, value) do
    Multi.new()
    |> Multi.run(:secret, fn repo, _changes ->
      case live(repo, project, attrs.name) do
        nil ->
          repo.insert(new)

        %Secret{version: version} = secret ->
          secret
          |> Secret.changeset(%{attrs | version: version + 1}, value)
          |> repo.update()
      end
    end)
    |> Events.log(:event, "secret.set", {:user, by.id}, fn %{secret: secret} ->
      %{project_id: project.id, payload: describe(project, secret)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{secret: secret}} ->
        arrived(project, by, secret)
        {:ok, %{secret | value: nil}}

      {:error, :secret, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  # **A new name is an arrival** (`docs/design/credentials.md` § How a job picks): a ticket stuck
  # because its job names a secret the project had not set comes back by itself once it is set,
  # rather than waiting for somebody to find the stuck ticket. A new version of a secret that
  # already existed answers no stick, so only the first version of a row is one.
  defp arrived(project, by, %Secret{version: 1}),
    do: Engine.resume_placement(project.id, {:user, by.id})

  defp arrived(_project, _by, %Secret{}), do: 0

  # Locked, so two admins replacing the same secret at once make versions n+1 and n+2 rather than
  # two n+1s. Removing the lock is an **equivalent mutant** in every sequential test: it is for
  # that race and nothing else. Two setting a *new* name at once cannot be serialised by a lock on
  # a row that does not exist yet; the unique index refuses the second, and its changeset says to
  # set it again.
  defp live(repo, %Project{id: project_id}, name) do
    repo.one(from s in live(project_id), where: s.name == ^name, lock: "FOR UPDATE")
  end

  @doc """
  Deletes a secret, and destroys its value in the same statement.

  **The value is overwritten with nothing, not left behind a flag**, for the reason
  `Forge.Credentials.revoke/2` gives: a flag would leave it in the database and every backup for as
  long as the row lives. The row stays, because events name a secret by its id and version.

  An update statement rather than a changeset, for the same reason as there: the struct never
  carries the value, so `change(secret, value: nil)` would compare nil with nil and write nothing.
  """
  @spec delete(Project.t(), User.t(), term()) :: {:ok, Secret.t()} | {:error, :not_found}
  def delete(%Project{} = project, %User{} = by, id) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:secret, fn repo, _changes ->
      case live_by_id(repo, project, id) do
        %Secret{} = secret -> {:ok, secret}
        nil -> {:error, :not_found}
      end
    end)
    |> Multi.update_all(
      :delete,
      fn %{secret: secret} -> from(s in Secret, where: s.id == ^secret.id) end,
      set: [deleted_at: now, value: nil, updated_at: now]
    )
    |> Events.log(:event, "secret.deleted", {:user, by.id}, fn %{secret: secret} ->
      %{project_id: project.id, payload: describe(project, secret)}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{secret: secret}} -> {:ok, %{secret | deleted_at: now}}
      {:error, :secret, :not_found, _changes} -> {:error, :not_found}
    end
  end

  # A live secret of this project, or nil — never another project's, whatever the id. Locked, and
  # inside the deletion's transaction, so the version it reads is the one it destroys: a deletion
  # racing a replacement waits for it and records the new version rather than the old, and one
  # racing another deletion reads nothing once the first commits, and writes no second event.
  # Removing the lock is an **equivalent mutant** in every sequential test, as in `live/3`.
  defp live_by_id(repo, %Project{id: project_id}, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        repo.one(from s in live(project_id), where: s.id == ^id, lock: "FOR UPDATE")

      :error ->
        nil
    end
  end

  # -- delivery -------------------------------------------------------------------------------

  @doc "The names of the project's live secrets, sorted: what a conversation may pick from."
  @spec names(String.t()) :: [String.t()]
  def names(project_id) do
    Repo.all(from s in live(project_id), order_by: s.name, select: s.name)
  end

  @doc """
  The sentence for `who` naming secrets the project has not set: what a stuck ticket says, and
  what an agent whose invocation was refused reads (`secrets.md` § Delivery).
  """
  @spec unset(String.t(), [String.t()]) :: String.t()
  def unset(who, names),
    do:
      "#{who} names #{Enum.map_join(names, ", ", &"`#{&1}`")}, which this project has not set; " <>
        "a project admin sets it in the project's settings"

  @doc """
  Of `names`, the ones the project has not set — in the order given. What the scheduler sticks a
  ticket on before a machine is asked for, what refuses an agent's invocation of a command that
  names one, and what refuses a conversation opened with one (`secrets.md` § Delivery).
  """
  @spec missing(String.t(), [String.t()]) :: [String.t()]
  def missing(project_id, names), do: project_id |> named(names, false) |> elem(1)

  @doc """
  Of `names`, the project's live secrets with their sealed values — the one read of the value
  column besides the key check — and the names it has not set.
  """
  @spec resolve(String.t(), [String.t()]) :: {[Secret.t()], [String.t()]}
  def resolve(project_id, names), do: named(project_id, names, true)

  # The live secrets `names` names, with their values only when asked for, and the rest of
  # `names` in the order given. Loading the values for `missing/2` too is an **equivalent mutant**:
  # it returns names, so no test can tell. They are left off because the value column is read in
  # one place, which is what `Forge.Secrets.Secret`'s `load_in_query: false` is for.
  defp named(_project_id, [], _values?), do: {[], []}

  defp named(project_id, names, values?) do
    query = from s in live(project_id), where: s.name in ^names, order_by: s.name
    query = if values?, do: from(s in query, select_merge: %{value: s.value}), else: query
    found = Repo.all(query)
    {found, names -- Enum.map(found, & &1.name)}
  end

  @doc """
  `secrets`, opened and sealed again for `worker` and `job_id` in one function: a JSON object of
  name to value under `ForgeCore.Job.Credential`'s seal, for the purpose `:secrets`, so neither the
  assignment map nor the channel process ever holds a plaintext (`secrets.md` § Delivery).

  `{:error, {:unreadable, names}}` when any value will not open — a rotated `secret_key_base` —
  because a job handed some of what it names and not the rest is a job that fails somewhere
  harder to read.
  """
  @spec for_wire([Secret.t()], Worker.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:unreadable, [String.t()]}}
  def for_wire(secrets, %Worker{token_hash: token_hash}, job_id) when is_binary(token_hash) do
    opened = Enum.map(secrets, &{&1.name, Secret.open(&1.value)})

    case for {name, :error} <- opened, do: name do
      [] ->
        plain = Map.new(opened, fn {name, {:ok, value}} -> {name, value} end)
        {:ok, Credential.seal(Jason.encode!(plain), token_hash, job_id, :secrets)}

      unreadable ->
        {:error, {:unreadable, unreadable}}
    end
  end

  @doc "What a run held, for its `job.secrets` event: each secret's id, name and version."
  @spec held([Secret.t()]) :: [map()]
  def held(secrets),
    do: Enum.map(secrets, &%{"secret_id" => &1.id, "name" => &1.name, "version" => &1.version})

  # -- what a settings row says ------------------------------------------------------------------

  @doc """
  Who receives each secret, read backwards out of every ticket type's workflow at the default
  branch's head (`ticket-types.md`): `names`, a map of name to the states and commands that name
  it, in the words a row says them — with the type, when the project has types — and `invalid`,
  the types whose workflow is refused and so says nothing here (nil for the one
  `.forge/workflow.yml`, or a layout that is itself refused). `:none` when the default branch has
  no workflow yet, or no commit: a project that names nothing yet and one whose list cannot be read
  are not the same answer (`secrets.md` § Surfaces).
  """
  @spec received_by(Project.t()) ::
          %{names: %{String.t() => [String.t()]}, invalid: [String.t() | nil]} | :none
  def received_by(%Project{} = project) do
    case Forge.Tickets.types(project) do
      {:ok, %{types: types}} ->
        names =
          for %{name: type, workflow: {:ok, workflow}} <- types,
              {secret, who} <- naming(workflow),
              do: {secret, in_type(who, type)}

        %{
          names: names |> Enum.sort() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)),
          invalid: for(%{name: type, workflow: {:error, _errors}} <- types, do: type)
        }

      {:error, {:no_workflow_file, _path}} ->
        :none

      {:error, {:unknown_ref, _ref}} ->
        :none

      # Both forms at once, or a directory with no type in it: there is no workflow to read.
      {:error, _layout} ->
        %{names: %{}, invalid: [nil]}
    end
  end

  defp naming(workflow) do
    for(
      {name, state} <- workflow.states,
      secret <- state.secrets,
      do: {secret, "state `#{name}`"}
    ) ++
      for {name, command} <- workflow.commands,
          secret <- command.secrets,
          do: {secret, "command `#{name}`"}
  end

  defp in_type(who, nil), do: who
  defp in_type(who, type), do: "#{who} of `#{type}`"

  @doc """
  When a run last held each of `secrets`, from the `job.secrets` events: a map of secret id to the
  time. A secret no run has held is not a key. One query, however many rows the page draws.
  """
  @spec last_held(Project.t(), [Secret.t()]) :: %{String.t() => DateTime.t()}
  def last_held(%Project{id: project_id}, secrets) do
    ids = Enum.map(secrets, & &1.id)

    Repo.all(
      from e in Forge.Events.Event,
        join: held in fragment("jsonb_array_elements(?)", e.payload["held"]),
        on: true,
        # The project and the type are **equivalent mutants** to the suite: a secret's id is a
        # UUID no other project's event names, and only `job.secrets` carries `held`. They stay
        # because they are what an index on events can use, and what keeps this a project's.
        where:
          e.project_id == ^project_id and e.type == "job.secrets" and
            fragment("?->>'secret_id'", held.value) in ^ids,
        distinct: fragment("?->>'secret_id'", held.value),
        order_by: [desc: e.seq],
        select: {fragment("?->>'secret_id'", held.value), e.inserted_at}
    )
    |> Map.new()
  end

  @doc """
  How many of the project's live conversations name each secret — running, or waiting to be
  placed — by `Forge.Conversations.live_statuses/0`, so the two cannot disagree about what live is.
  A dormant one holds nothing until it is reopened.
  """
  @spec held_by_conversations(Project.t()) :: %{String.t() => pos_integer()}
  def held_by_conversations(%Project{id: project_id}) do
    from(j in Forge.Jobs.Job,
      where:
        j.project_id == ^project_id and j.kind == :chat and
          j.status in ^Forge.Conversations.live_statuses(),
      select: j.secret_names
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.frequencies()
  end

  defp describe(%Project{name: project}, %Secret{id: id, name: name, version: version}),
    do: %{"project" => project, "secret_id" => id, "name" => name, "version" => version}
end
