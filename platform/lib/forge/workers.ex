defmodule Forge.Workers do
  @moduledoc """
  Workers: the machines that host jobs. A row exists before its machine does and outlives it,
  so there is never a machine the platform has no record of. See `docs/design/worker-tier.md`.

  A connected worker registers its channel process here. Nothing else knows how to reach one:
  `push/2` is the only way to say something to a worker, and it fails plainly when the
  machine is not there.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Accounts.User
  alias Forge.{Engine, Events, Projects, Provider, Provisioning, Repo}
  alias Forge.Jobs.Job
  alias Forge.Provisioning.ProjectTemplate
  alias Forge.Workers.{Log, ProjectWorker, Worker}
  alias ForgeCore.WorkerProtocol

  require Logger

  @registry Forge.Workers.Registry
  @hash_algorithm :sha256
  @token_bytes 32

  # -- rows -----------------------------------------------------------------------------------

  @doc """
  Creates a worker row and its token. The token is returned once, for the provider driver to
  inject at creation; only its hash is kept, as `Forge.Accounts.UserToken` does for the same
  reason.
  """
  @spec create(map()) :: {:ok, Worker.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs \\ %{}) do
    token = :crypto.strong_rand_bytes(@token_bytes)

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("provider", "local")
      |> Map.put_new("status", :creating)
      |> Map.put("token_hash", hash(token))

    case Repo.insert(Worker.changeset(%Worker{}, attrs)) do
      {:ok, worker} ->
        by_hand(worker)
        {:ok, worker, Base.url_encode64(token, padding: false)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # A managed machine's `created` line is written when its driver has made it (`made/3`), and a
  # refusal is `create.refused` instead: a row is not yet a machine. A permanent one is a row and
  # a token for a machine somebody else builds, and this is all the platform ever sees of that.
  defp by_hand(%Worker{managed: false} = worker),
    do:
      Log.record(
        worker.id,
        "created",
        :info,
        "provisioned by hand, on #{worker.provider}; the platform will not destroy it"
      )

  defp by_hand(%Worker{}), do: :ok

  @spec get(String.t()) :: Worker.t() | nil
  def get(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Worker, id)
      :error -> nil
    end
  end

  @spec get!(String.t()) :: Worker.t()
  def get!(id), do: Repo.get!(Worker, id)

  @doc "Every machine on the node, for the host's command line. No page reads this."
  @spec list() :: [Worker.t()]
  def list, do: Repo.all(from w in Worker, order_by: w.inserted_at)

  @doc """
  The machines this user owns, which is all a person is shown (`docs/design/ui.md` § The workers
  page). Another person's machine names the projects it serves, and a project a person is not in
  is not one they may learn exists.
  """
  @spec list(User.t()) :: [Worker.t()]
  def list(%User{id: user_id}),
    do: Repo.all(from w in Worker, where: w.user_id == ^user_id, order_by: w.inserted_at)

  @doc "A machine of this user's, or nil. Never another user's, whatever the id."
  @spec owned(User.t(), String.t() | nil) :: Worker.t() | nil
  def owned(%User{id: user_id}, id) do
    case id && Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one(from w in Worker, where: w.id == ^id and w.user_id == ^user_id)
      _other -> nil
    end
  end

  @doc """
  Gives a machine that has no owner one. `Forge.Release.own_worker/2` is the only caller: the host's
  repair for a machine the move to owned machines could not place.

  **Refused for a machine that already has an owner**, and in the statement that writes it, so two
  of these racing cannot both succeed. Changing whose machine it is would move the right to put
  work on it, which is not a repair.
  """
  @spec adopt(Worker.t(), User.t()) :: {:ok, Worker.t()} | {:error, :already_owned}
  def adopt(%Worker{id: id}, %User{id: user_id}) do
    case Repo.update_all(from(w in Worker, where: w.id == ^id and is_nil(w.user_id)),
           set: [user_id: user_id, updated_at: now()]
         ) do
      {1, _rows} -> {:ok, get!(id)}
      {0, _rows} -> {:error, :already_owned}
    end
  end

  @doc """
  Sets what a permanent machine offers the gate: its memory, cores and kinds.

  **Only the owner's, and only a machine the platform did not make.** A managed machine was given
  its figures by its template and is replaced rather than corrected, so an edit would last one
  idle period; a permanent one is its owner's, and the row governing the gate
  (`docs/design/provisioning.md` § What a worker offers) is what makes the edit survive a
  reconnect.

  **The guard is here and not on the workers page**, where it once was: the page matched
  `managed: false` itself and then called `update/2`, whose changeset casts every field the row
  has (`docs/design/identity.md` § Where the guard lives). Only the three figures are cast
  (`Worker.offer_changeset/2`), and both numbers are required.

  **Every figure it sets is one the gate reads**, so a changed offer is an arrival in each project
  the machine is assigned to, as assigning it is: a ticket stuck because no machine could ever hold
  its job may be waiting for exactly this (`docs/design/credentials.md` § How a job picks). A save
  that changed nothing is not one.
  """
  @spec set_offer(User.t(), String.t(), map()) ::
          {:ok, Worker.t()} | {:error, :not_found | :made_by_the_platform | Ecto.Changeset.t()}
  def set_offer(%User{} = user, id, attrs) do
    with {:ok, worker} <- owned_permanent(user, id),
         changeset = Worker.offer_changeset(worker, attrs),
         {:ok, worker} <- Repo.update(changeset) do
      if changeset.changes != %{}, do: arrived(worker, {:user, user.id})
      {:ok, worker}
    end
  end

  # -- assignment -----------------------------------------------------------------------------

  @doc """
  Lets `project` run its jobs on this permanent machine.

  Refused unless the caller owns the machine *and* is a member of the project — the first stops
  an admin spending somebody else's hardware, the second stops an owner pointing their machine at
  a project they have nothing to do with (`docs/design/identity.md` § Workers). **A machine the
  platform made is refused too**: it reaches projects through its template, and a second way
  would be a machine still serving a project after its template was taken out of it.

  Tickets stuck because nothing could be placed for this project are brought back, since this may
  be what they were waiting for (`docs/design/credentials.md` § How a job picks).
  """
  @spec assign(User.t(), String.t(), String.t()) ::
          {:ok, ProjectWorker.t()}
          | {:error, :not_found | :not_a_member | :made_by_the_platform | Ecto.Changeset.t()}
  def assign(%User{} = user, worker_id, project_id) do
    with {:ok, worker} <- owned_permanent(user, worker_id),
         :ok <- member(user, project_id) do
      Multi.new()
      |> Multi.insert(
        :assignment,
        ProjectWorker.changeset(%ProjectWorker{}, %{project_id: project_id, worker_id: worker.id})
      )
      |> Events.log(:event, "worker.assigned", {:user, user.id}, %{
        project_id: project_id,
        payload: %{"worker_id" => worker.id, "project_id" => project_id}
      })
      |> Repo.transaction()
      |> case do
        {:ok, %{assignment: assignment}} ->
          Engine.resume_placement(project_id, {:user, user.id})
          {:ok, assignment}

        {:error, :assignment, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc "Stops `project` running its jobs on this machine. The same two rules apply."
  @spec unassign(User.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found | :not_a_member | :made_by_the_platform}
  def unassign(%User{} = user, worker_id, project_id) do
    with {:ok, worker} <- owned_permanent(user, worker_id),
         :ok <- member(user, project_id) do
      Multi.new()
      |> Multi.delete_all(
        :assignment,
        from(a in ProjectWorker, where: a.worker_id == ^worker.id and a.project_id == ^project_id)
      )
      |> Events.log(:event, "worker.unassigned", {:user, user.id}, %{
        project_id: project_id,
        payload: %{"worker_id" => worker.id, "project_id" => project_id}
      })
      |> Repo.transaction()

      :ok
    end
  end

  @doc "The projects this machine was assigned to directly, by name."
  @spec projects(Worker.t()) :: [Forge.Projects.Project.t()]
  def projects(%Worker{id: id}) do
    Repo.all(
      from p in Forge.Projects.Project,
        join: a in ProjectWorker,
        on: a.project_id == p.id,
        where: a.worker_id == ^id,
        order_by: p.name
    )
  end

  defp owned_permanent(user, worker_id) do
    case owned(user, worker_id) do
      nil -> {:error, :not_found}
      %Worker{managed: true} -> {:error, :made_by_the_platform}
      worker -> {:ok, worker}
    end
  end

  defp member(%User{} = user, project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, id} ->
        if Projects.role(%Forge.Projects.Project{id: id}, user),
          do: :ok,
          else: {:error, :not_a_member}

      :error ->
        {:error, :not_a_member}
    end
  end

  @doc """
  The worker this token belongs to, if it is one and the machine has not been destroyed. A
  destroyed row is the platform's record that the machine is gone; a machine that disagrees
  does not get to argue.
  """
  @spec authenticate(String.t(), String.t()) :: {:ok, Worker.t()} | :error
  def authenticate(worker_id, token) when is_binary(worker_id) and is_binary(token) do
    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %Worker{} = worker <- get(worker_id),
         true <- worker.status != :destroyed,
         true <- Plug.Crypto.secure_compare(worker.token_hash, hash(raw)) do
      {:ok, worker}
    else
      _other -> :error
    end
  end

  def authenticate(_worker_id, _token), do: :error

  @doc """
  Writes any field of the row. **The platform's own writes only** — `busy/1`, `ready/2`,
  `release/1`, the sweeps. It takes no actor and casts every field, `managed` and the token hash
  included, so no page or API route may call it; a person's writes are `set_offer/3`,
  `assign/3` and `unassign/3`.
  """
  @spec update(Worker.t(), map()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def update(%Worker{} = worker, attrs), do: Repo.update(Worker.changeset(worker, attrs))

  @doc """
  The worker has taken a job on.

  **Written whatever the struct says.** The scheduler holds the row it read at the start of the
  pass, and a job ending in between can have made the machine idle since: a struct that still
  says `busy` is no change to Ecto, so nothing was written, the row stayed idle under a running
  job, and the idle sweep destroyed the machine with the job still on it.
  """
  @spec busy(Worker.t()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def busy(%Worker{id: id}) do
    unless_destroyed(id, fn worker ->
      worker
      |> Worker.changeset(%{})
      |> Ecto.Changeset.force_change(:status, :busy)
      |> Ecto.Changeset.force_change(:idle_since, nil)
      |> Repo.update()
    end)
  end

  # **A status is written from the row as it is, locked, and never over `destroyed`.** `busy/1`,
  # `release/1` and `ready/2` each decide from a row read earlier — the scheduler's pass, the
  # channel's message — and a retire can commit in between. Written from that stale read, the
  # row went back to `busy` or `idle`: assignable again, its token valid again, a Retire undone
  # without anybody seeing it. So each re-reads the row under `FOR UPDATE` and leaves a destroyed
  # one alone; `gone/2`'s write waits on the same lock, so whichever commits first, destroyed
  # wins. The same model as the operation it guards (`CLAUDE.md` § Rules): the row, not a struct.
  defp unless_destroyed(worker_id, fun) do
    Repo.transaction(fn ->
      from(w in Worker, where: w.id == ^worker_id, lock: "FOR UPDATE")
      |> Repo.one()
      |> write_unless_destroyed(fun)
    end)
  end

  defp write_unless_destroyed(%Worker{status: :destroyed} = worker, _fun), do: worker

  defp write_unless_destroyed(%Worker{} = worker, fun) do
    case fun.(worker) do
      {:ok, worker} -> worker
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  A job on this worker ended. When it was the last one the machine goes idle, and the clock
  that destroys it starts.
  """
  @spec release(String.t() | nil) :: :ok
  def release(nil), do: :ok

  def release(worker_id) do
    with %Worker{} <- get(worker_id) do
      {:ok, _worker} = unless_destroyed(worker_id, &idle_if_empty/1)
    end

    :ok
  end

  defp idle_if_empty(worker) do
    if worker.status in [:ready, :busy] and Forge.Jobs.running_on(worker.id) == [],
      do: update(worker, %{status: :idle, idle_since: now()}),
      else: {:ok, worker}
  end

  @doc """
  Records that the worker is up, from the `ready` payload it sent.

  `harness` is kept as reported. A worker that sends none — one running a release older than the
  probe, or one whose probe could not reach anything — keeps whatever it last said rather than
  having it cleared: the last answer is better than no answer, and a worker with no answer is
  still a worker that takes jobs.

  **The machine fills what the row does not have and never overwrites what it does.**
  `docs/design/provisioning.md` § What a worker offers: the row is what the gate reads, so an
  operator's edit to a permanent worker's budget, cores or kinds survives every reconnect —
  which it would not if `ready` wrote them each time, and the field on the page would be a lie.
  A machine created from a template arrives with its figures already set and only reports; a
  machine that arrived from nowhere has nothing, and the first `ready` is where it gets them.

  What the machine actually said is kept in `reported` either way, so a disagreement can be
  shown rather than silently resolved.
  """
  @spec ready(Worker.t(), map()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def ready(%Worker{id: id}, report) when is_map(report) do
    # **A destroyed row stays destroyed.** `readiness/1` would make it `idle` — assignable — and a
    # `ready` can be in flight on a channel when its row is retired, or arrive on a join made
    # before the row changed (`docs/design/worker-channel.md` § Authentication).
    case unless_destroyed(id, &record_ready(&1, report)) do
      # After the transaction, so the tickets come back while nothing holds this row and what
      # tells a page about them is sent once they are there to read. Inside it would be an
      # equivalent mutant for the suite, which shares one connection under the SQL sandbox and so
      # cannot see the commit's order; it is kept out for the lock and the notification.
      {:ok, {worker, template_back?, offer_changed?}} ->
        if template_back?,
          do:
            Provisioning.resume_projects(%Provisioning.Template{id: worker.template_id}, :system)

        if offer_changed?, do: arrived(worker, :system)
        {:ok, worker}

      # The row was destroyed, and `record_ready/2` never ran.
      {:ok, %Worker{} = destroyed} ->
        {:ok, destroyed}

      {:error, _reason} = refused ->
        refused
    end
  end

  # **A machine that may now take what it could not is an arrival in every project its owner
  # assigned it to**, the way assigning it is to one (`Forge.Engine.resume_placement/2`) — and only
  # those. A machine the platform made has none (`assign/3` refuses it): it reaches projects through
  # its template, whose figures it was made with and which arrives on its own
  # (`Forge.Provisioning.resume_projects/2`). Reading the template's projects here brought back
  # every stuck ticket in them at every boot, since a first report's harness is always new — to be
  # stuck, and pushed, again two seconds later.
  defp arrived(%Worker{} = worker, actor),
    do: worker |> projects() |> Enum.each(&Engine.resume_placement(&1.id, actor))

  # **What `ready` can widen of what a machine offers the gate**: memory, which it fills where the
  # row had none, and which jobs its harness takes — the driver, and per-job credentials
  # (`runs?/2` reads those two and nothing else of the map, so a new `claude` version or a slow
  # probe is not an arrival). Cores and kinds are left out on purpose: `ready` only ever fills
  # them from nil, and nil is ungated, so filling them can narrow what the machine holds and never
  # widen it. The protocol is written at the join, before the `ready` (`admit/2`), which is the
  # gap `docs/design/credentials.md` § How a job picks records.
  defp gate_offer(%Worker{memory_budget: memory, harness: harness}),
    do: {memory, Map.take(harness || %{}, ["driver", "credential"])}

  defp record_ready(worker, report) do
    harness = report["harness"]
    memory_budget = report["memory_budget"] || 0
    cores = report["cores"]
    accepts = accepts_from(report["accepts"])

    attrs =
      %{last_seen_at: now(), reported: reported(report)}
      |> Map.merge(readiness(worker))
      |> fill(worker, :memory_budget, memory_budget)
      |> fill(worker, :cores, cores)
      |> fill(worker, :accepts, accepts)

    # The recipe works: a machine from it booted and called home. Consecutive failures reset
    # here and nowhere else, because this is the only event that proves anything — and only at a
    # machine's first `ready`, from the image its template still names: a reconnect of a machine
    # made from an older snapshot put a template that the new one had taken out of service back
    # in, at every restart of the platform (`docs/design/provisioning.md` § A template that cannot
    # make a working machine is taken out of service). First is never seen, as the sweep that
    # counts a machine that never called home reads it.
    template_back? =
      is_nil(worker.last_seen_at) and Provisioning.succeeded(worker.template_id, worker.image)

    with {:ok, readied} <-
           update(worker, if(is_map(harness), do: Map.put(attrs, :harness, harness), else: attrs)) do
      Log.record(readied.id, "ready", :info, offers(readied))

      # **An arrival is a template back in service, or a machine whose offer to the gate changed**
      # (`docs/design/credentials.md` § How a job picks). A reconnect saying what it said before is
      # neither.
      {:ok, {readied, template_back?, gate_offer(readied) != gate_offer(worker)}}
    end
  end

  # What the row now offers, which is not always what the machine said: a permanent machine's
  # figures are its owner's once set, and this is the line that says what it will be given.
  defp offers(%Worker{} = worker) do
    [
      "offers #{ForgeCore.Workflow.Resources.gib(worker.memory_budget)} of memory",
      worker.cores && "#{worker.cores} cores",
      worker.accepts not in [nil, []] && "for #{Enum.join(worker.accepts, ", ")}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  # **Up with nothing to do is idle, and the clock starts now.** Only a job ending used to make a
  # machine idle, so a machine that came up and was never given anything — made for a job that
  # was placed elsewhere first, or whose project stopped being one its template serves — sat
  # `:ready` and was never swept, billing until somebody noticed. A machine that was already idle
  # keeps its clock, or reconnecting would be a way to live for ever.
  defp readiness(%Worker{id: id} = worker) do
    cond do
      Forge.Jobs.running_on(id) != [] -> %{status: :ready, idle_since: nil}
      worker.status == :idle and not is_nil(worker.idle_since) -> %{status: :idle}
      true -> %{status: :idle, idle_since: now()}
    end
  end

  # Only the figures, and only as the machine gave them: `harness` has a column of its own and
  # duplicating it here would be two copies of one blob that can disagree.
  defp reported(report), do: Map.take(report, ["memory_budget", "cores", "accepts"])

  defp fill(attrs, _worker, _field, nil), do: attrs

  defp fill(attrs, worker, field, value) do
    case Map.get(worker, field) do
      nil -> Map.put(attrs, field, value)
      _set -> attrs
    end
  end

  # A kind this platform does not know is dropped rather than refused. A worker from a newer
  # release naming a kind that arrives in a later migration is still a worker, and the kinds it
  # names that *are* known are the ones the gate can act on. An empty list after filtering is
  # left as nil — "said nothing this platform understood" is not "takes nothing".
  defp accepts_from(accepts) when is_list(accepts) do
    known = Enum.map(Job.kinds(), &Atom.to_string/1)

    case Enum.filter(accepts, &(is_binary(&1) and &1 in known)) do
      [] -> nil
      kinds -> kinds
    end
  end

  defp accepts_from(_accepts), do: nil

  @doc """
  What a person may pick from for a job in `project_id`: the aliases the harness resolves, and the
  models the credentials in that project's pool may use.

  Two lists rather than one, because they are different kinds of name. An alias floats — `opus`
  is whatever the harness resolves it to today, which is usually what a workflow wants — and an
  id is exact and pins. A form shows them apart so that choosing between them is deliberate.

  **The aliases are the machines'; the models are the accounts'.** An alias is a name the harness
  binary resolves, so it is read from the live workers, the union across them — a union that is
  not a single set is an image rollout half done. Which models may be called is a property of a
  credential and not of a machine, which holds none, so it is read from the project's pool
  (`docs/design/credentials.md` § Checked on save): the set a job there will actually run under.

  Both empty when nothing is connected and nothing is pooled, which is a form with nothing to
  offer and never a reason to stop one being submitted — `docs/design/workflow-grammar-v1.md`
  § Model.
  """
  @spec offered(String.t() | nil) :: %{
          aliases: [String.t()],
          models: [%{id: String.t(), name: String.t()}]
        }
  def offered(project_id) do
    harnesses =
      Repo.all(
        from w in Worker,
          where: w.status in [:ready, :busy, :idle] and not is_nil(w.harness),
          select: w.harness
      )

    %{aliases: aliases(harnesses), models: Forge.Credentials.models(project_id)}
  end

  defp aliases(harnesses) do
    harnesses
    |> Enum.flat_map(&(&1["aliases"] || []))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc "Records that we have heard from the worker."
  @spec touch(Worker.t()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def touch(%Worker{} = worker), do: update(worker, %{last_seen_at: now()})

  @spec status(Worker.t(), atom()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def status(%Worker{} = worker, status), do: update(worker, %{status: status})

  # -- joining --------------------------------------------------------------------------------

  @doc """
  Whether the platform will talk to this machine, decided at its join and before any work
  (`docs/design/worker-channel.md` § Versions).

  What the machine said — its release, its build, the protocol it speaks — is written onto the row
  first, refused or not, so the workers page can say what it runs and why it was turned away. A
  machine that sends no protocol is protocol 0: every release before the field existed.

  **Refused:**

  - a row that is `destroyed`: the socket checked that when the connection was made, and a
    connection outlives its row — a rejoin on a live socket never passes `connect/3` again;
  - a protocol outside `ForgeCore.WorkerProtocol`'s range. A **managed** machine is then destroyed
    on the spot, its jobs requeued, because it bills by the hour and can never take work, and its
    template learns the protocol of the image it was made from (`learn/2`). A **permanent** one
    keeps its row; the row says why.

  `last_seen_at` is not written here, and must not be: a refused machine that keeps knocking is not
  one the platform can hear from, and its jobs have to reach `sweep_unreachable/0`'s timeout.
  """
  @spec admit(String.t(), map()) ::
          :ok | {:error, :not_found | :destroyed | {:protocol, integer() | nil}}
  def admit(worker_id, payload) when is_map(payload) do
    protocol = protocol_of(payload["protocol"])

    case get(worker_id) do
      nil ->
        {:error, :not_found}

      %Worker{status: :destroyed} ->
        {:error, :destroyed}

      worker ->
        first = first_join?(worker)

        {:ok, worker} =
          update(worker, %{
            release: text(payload["release"]),
            build: text(payload["build"]),
            protocol: protocol
          })

        if first, do: learn(worker, protocol)
        if WorkerProtocol.compatible?(protocol), do: :ok, else: refuse(worker, protocol)
    end
  end

  # **Only a machine's first join says anything about the image it was made from.** A later one
  # may be running a release `bin/worker-update` put there, and it may be somebody holding a copy
  # of the machine's token — who would otherwise teach its template a protocol that stops the
  # template making anything (`docs/design/worker-channel.md` § Authentication). A machine that
  # has joined before has a protocol on its row, or has been seen.
  defp first_join?(%Worker{protocol: nil, last_seen_at: nil}), do: true
  defp first_join?(%Worker{}), do: false

  # Absent is 0, a release from before the field. Anything that is not a whole number this
  # platform can record is not a protocol it can compare, and is recorded as nothing and refused.
  defp protocol_of(nil), do: 0

  defp protocol_of(protocol),
    do: if(WorkerProtocol.recordable?(protocol), do: protocol)

  # Shown on a page and nothing else, so anything a machine sends that is not text is not kept,
  # and text is kept only as the column can hold it: 255 code points — not graphemes, which
  # `String.slice/3` counts and a combining accent makes two of — and no NUL, which Postgres will
  # not store at all. A write the column refused would crash the join rather than refuse it.
  defp text(value), do: Log.clean(value, 255)

  defp refuse(%Worker{managed: true} = worker, protocol) do
    Logger.warning(
      "worker #{worker.id} speaks protocol #{inspect(protocol)} and this platform accepts " <>
        "#{WorkerProtocol.range()}; refusing it, destroying the machine and marking its image"
    )

    Log.record(
      worker.id,
      "join.refused",
      :error,
      "speaks #{spoken(protocol)} and this platform accepts #{WorkerProtocol.range()}; " <>
        "destroying it, since a managed machine that can take no work only bills",
      once: true
    )

    case retire(worker, reason: :worker_refused, by: :protocol) do
      {:ok, _jobs} -> :ok
      # Kept with the driver's words, as any refused destroy is, and the sweep tries again.
      {:error, _reason} -> :ok
    end

    {:error, {:protocol, protocol}}
  end

  defp refuse(%Worker{} = worker, protocol) do
    Logger.warning(
      "worker #{worker.id} speaks protocol #{inspect(protocol)} and this platform accepts " <>
        "#{WorkerProtocol.range()}; refusing it. It is not the platform's to destroy."
    )

    Log.record(
      worker.id,
      "join.refused",
      :error,
      "speaks #{spoken(protocol)} and this platform accepts #{WorkerProtocol.range()}; its row " <>
        "stays, since it is not the platform's to destroy — update its release",
      once: true
    )

    {:error, {:protocol, protocol}}
  end

  defp spoken(nil), do: "a protocol this platform cannot read"
  defp spoken(protocol), do: "protocol #{protocol}"

  # What the image this machine was made from speaks, and which build it carries, onto its
  # template: a refusal stops the template making more from it, and an acceptance ends the probe
  # an unlabelled image is held to (`create_from/1`). A permanent machine came from no template
  # and teaches nothing, and neither does a protocol that could not be read.
  defp learn(%Worker{template_id: nil}, _protocol), do: :ok
  defp learn(%Worker{}, nil), do: :ok

  defp learn(%Worker{template_id: template_id, image: image, build: build}, protocol),
    do: Provisioning.learn_protocol(template_id, image, protocol, build)

  @doc """
  The build of the worker release this platform ships with, or nil on a node built outside Nix.

  `flake.nix` sets it while building the release, as the first twelve characters of the worker
  package's store hash (`docs/design/worker-tier.md` § Updating a worker). A hint for the pages,
  never a gate: nothing is refused for its build, only for its protocol.
  """
  @spec current_build() :: String.t() | nil
  def current_build, do: config(:current_build, nil)

  # -- connections ----------------------------------------------------------------------------

  @doc "Registers the calling process as `worker_id`'s channel."
  @spec connected(String.t()) :: :ok | {:error, {:already_connected, pid()}}
  def connected(worker_id) do
    case Registry.register(@registry, worker_id, nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_connected, pid}}
    end
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(worker_id) do
    case Registry.lookup(@registry, worker_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec connected?(String.t()) :: boolean()
  def connected?(worker_id), do: whereis(worker_id) != nil

  @stats [:cpu, :memory_used, :memory_total, :disk_used, :disk_total]

  @doc """
  Keeps a machine's latest figures as its channel's registry value (`docs/design/worker-channel.md`
  § Live figures). **Called by the channel process itself**, which is the only process that may
  change the value it registered, and it writes nothing else: no row, no table, no history — so
  the figures go when the channel does, and a machine that is not connected has none.

  Only the figures the protocol names, and only as non-negative numbers: what a machine sent that
  is not one is left out, the way the worker leaves out what it could not read.
  """
  @spec put_stats(String.t(), map()) :: :ok
  def put_stats(worker_id, payload) when is_map(payload) do
    stats =
      for key <- @stats,
          value = payload[Atom.to_string(key)],
          figure?(key, value),
          into: %{},
          do: {key, value}

    Registry.update_value(@registry, worker_id, fn _previous -> stats end)
    :ok
  end

  # **What the page can draw, and nothing it would choke on.** A CPU share is a percentage, and a
  # byte count is a whole number no machine exceeds — 2^60 is an exbibyte. A float of 1e-300 bytes
  # or of 1e308 passed `>= 0` and divided the page into an `ArithmeticError`, which took the
  # owner's whole workers page down, Destroy buttons and all, for as long as that machine stayed
  # connected.
  @most_bytes Bitwise.bsl(1, 60)

  defp figure?(:cpu, value), do: is_number(value) and value >= 0 and value <= 100
  defp figure?(_bytes, value), do: is_integer(value) and value >= 0 and value <= @most_bytes

  @doc "A connected machine's latest figures, or nil when it is not connected or has sent none."
  @spec stats(String.t()) :: map() | nil
  def stats(worker_id) do
    case Registry.lookup(@registry, worker_id) do
      [{_pid, stats}] -> stats
      [] -> nil
    end
  end

  @doc "Sends a message to a worker's channel. The only way to reach one."
  @spec push(String.t(), term()) :: :ok | {:error, :not_connected}
  def push(worker_id, message) do
    case whereis(worker_id) do
      nil ->
        {:error, :not_connected}

      pid ->
        send(pid, message)
        :ok
    end
  end

  # -- scheduling -----------------------------------------------------------------------------

  @typedoc """
  What a job needs placing: its kind, and the memory and cores it was admitted with.

  Three dimensions and not one, because a machine that will not run inference is as real a
  refusal as one with no room (`docs/design/provisioning.md` § The gate).
  """
  @type demand :: %{
          required(:kind) => atom(),
          required(:memory) => non_neg_integer(),
          required(:cores) => non_neg_integer(),
          optional(:project_id) => String.t() | nil,
          optional(:harness) => String.t() | nil,
          optional(:protocol) => non_neg_integer()
        }

  @doc """
  A connected worker that will take `demand`, or nil. The rule `docs/vision.md` states: a job is
  admitted only when its slice fits what is left, because the tier rests on an out-of-memory
  build killing one job rather than the machine — extended here by the cores it reserves and the
  kinds the machine says it takes.

  `preferred` is the worker this job was last on, and it is a preference and never a
  requirement: a resumed job whose worktree is still somewhere finds its Claude Code session
  there and pays for a re-composed prompt anywhere else
  (`docs/design/provisioning.md` § Affinity on resume). When that machine is gone, or full, or
  will not take the kind, any other that fits is taken instead — which is what makes this free.
  """
  @spec assignable(demand(), String.t() | nil, MapSet.t()) :: Worker.t() | nil
  def assignable(demand, preferred \\ nil, reserved \\ MapSet.new()) do
    # Idle is the most assignable state there is: it means the machine is up with nothing to
    # do. It is only a step towards destruction if nothing arrives before the period is up.
    candidates =
      from(w in serving(demand[:project_id]),
        where: w.status in [:ready, :busy, :idle] and is_nil(w.unhealthy_at),
        order_by: [asc: w.inserted_at]
      )
      |> Repo.all()
      # One pass, and `and` short-circuits: `fits?/2` asks the database what a worker is
      # holding, and a worker nothing can reach is not worth asking about. A machine held for an
      # older job is not offered at all (`docs/design/provisioning.md` § The gate).
      |> Enum.filter(
        &(not MapSet.member?(reserved, &1.id) and connected?(&1.id) and fits?(&1, demand))
      )

    Enum.find(candidates, &(&1.id == preferred)) || List.first(candidates)
  end

  @doc """
  The machines that could hold `demand` once empty: serving its project, taking its kind, running
  its harness, speaking its protocol, and with the memory and cores it asks for in total. What a
  job that has waited long enough reserves (`docs/design/provisioning.md` § The gate), so the room
  that frees up on them goes to it and not to younger work.
  """
  @spec holders(demand()) :: MapSet.t()
  def holders(demand) do
    # The status filter is an equivalent mutant: a machine in any other state is not assignable
    # either, so holding it back from younger jobs changes nothing. It keeps the set to machines
    # that could empty.
    from(w in serving(demand[:project_id]), where: w.status in [:ready, :busy, :idle])
    |> Repo.all()
    |> Enum.filter(&holds_when_empty?(&1, demand))
    |> MapSet.new(& &1.id)
  end

  @doc """
  The machines that may run this project's jobs: those its owner assigned to it, and those made
  from a template assigned to it (`docs/design/identity.md` § Workers).

  **The template is read now, not copied at creation.** Which projects a machine may serve is its
  owner's standing consent rather than a value of the machine, so unassigning a template stops its
  machines taking that project's work on the next pass instead of when the last of them idles out.

  A demand naming no project is served by nothing, for the reason `create_machine/1` makes
  nothing for one: the scheduler always names the project, and the one path that did not would
  be the one path left that ignores whose machine it is.
  """
  @spec serving(String.t() | nil) :: Ecto.Query.t()
  def serving(nil), do: from(w in Worker, where: false)

  def serving(project_id) do
    from w in Worker,
      as: :worker,
      where:
        exists(
          from a in ProjectWorker,
            where: a.worker_id == parent_as(:worker).id and a.project_id == ^project_id
        ) or
          exists(
            from a in ProjectTemplate,
              where:
                a.template_id == parent_as(:worker).template_id and a.project_id == ^project_id
          )
  end

  @doc """
  Whether this worker will take this job: the kind it accepts, and room in both dimensions.

  The kind is checked first and short-circuits, so a machine that will not run inference is
  refused without asking the database what it is holding.
  """
  @spec fits?(Worker.t(), demand()) :: boolean()
  def fits?(%Worker{} = worker, demand) do
    with true <- takes?(worker, demand) do
      {memory, reserved} = promised(worker.id)

      (worker.memory_budget || 0) - memory >= demand.memory and
        room_for_cores?(worker, reserved, demand.cores)
    end
  end

  # What the demand is, against what the machine is — its kind, protocol and harness — as against
  # how big it is. One conjunction for `fits?/2` and `holds_when_empty?/2`, so a gate dimension
  # added to one is in the other.
  defp takes?(%Worker{} = worker, demand) do
    accepts?(worker, demand.kind) and speaks?(worker, demand[:protocol]) and
      runs?(worker, demand[:harness])
  end

  # **A worker that has not said how many cores it has is not gated on cores**, for the same
  # reason `accepts?/2` lets a silent worker take anything: nil is *unknown*, not *zero*, and
  # reading it as zero would strand every machine that predates the column — which is the whole
  # fleet the moment this ships, since nothing reported cores before it.
  #
  # Memory is not treated this way and must not be: a worker with no budget is one that has not
  # reported `ready` at all, and handing it work is the overcommit the tier exists to prevent.
  # The asymmetry is that a missing budget means the machine never spoke, while missing cores
  # means it spoke before this field existed.
  defp room_for_cores?(%Worker{cores: nil}, _reserved, _wanted), do: true
  defp room_for_cores?(%Worker{cores: cores}, reserved, wanted), do: cores - reserved >= wanted

  @doc """
  Whether this worker takes jobs of `kind`.

  **A worker that has said nothing takes anything**, and that is deliberate rather than lax: a
  row written before this column existed, or a machine running a release older than the field,
  would otherwise drop out of the fleet on an upgrade. It is the same trap
  `docs/design/worker-channel.md` § Open records for matching the model — a worker reporting no
  harness must stay assignable, or a probe failure idles everything.
  """
  @spec accepts?(Worker.t(), atom()) :: boolean()
  def accepts?(%Worker{accepts: nil}, _kind), do: true
  def accepts?(%Worker{accepts: []}, _kind), do: true
  def accepts?(%Worker{accepts: accepts}, kind), do: kind in accepts

  @doc """
  Whether this worker runs `harness` and takes its credential from the assignment.

  **A worker that reported no harness runs none**, and that inverts what this platform did before
  a job carried its credential (`docs/design/credentials.md` § What a worker offers now). A
  release that does not say `"credential": "per_job"` ignores the assignment's credential and
  runs the job on whatever its own environment holds — which the platform would then record
  against a credential it did not spend. What remains of the probe makes no request and cannot
  fail on the network, so a current release always says it.

  A demand naming no harness is a job that runs none, and any machine will do for it.
  """
  @spec runs?(Worker.t(), String.t() | nil) :: boolean()
  def runs?(%Worker{}, nil), do: true

  def runs?(%Worker{harness: %{"driver" => harness, "credential" => "per_job"}}, harness),
    do: true

  def runs?(%Worker{}, _harness), do: false

  @doc """
  Whether this worker speaks at least `protocol`: what it said at its last join, and nothing for a
  worker that has not said. A command reaching a release from before commands would be run as an
  agent job (`docs/design/commands.md` § Worker pools), and an agent reaching one from before
  protocol 3 would be taught a question block this platform refuses to record
  (`Forge.Jobs.protocol/1`), so unknown is not enough here — unlike `accepts?/2`, where an old
  release taking anything was the safe reading.
  """
  @spec speaks?(Worker.t(), non_neg_integer() | nil) :: boolean()
  def speaks?(%Worker{}, need) when need in [nil, 0], do: true
  def speaks?(%Worker{protocol: protocol}, need) when is_integer(protocol), do: protocol >= need
  def speaks?(%Worker{}, _need), do: false

  @doc "Memory not already promised to a job on this worker."
  @spec remaining(Worker.t()) :: integer()
  def remaining(%Worker{} = worker),
    do: (worker.memory_budget || 0) - elem(promised(worker.id), 0)

  @doc "Cores not already reserved by a job on this worker."
  @spec remaining_cores(Worker.t()) :: integer()
  def remaining_cores(%Worker{} = worker), do: (worker.cores || 0) - elem(promised(worker.id), 1)

  # Both dimensions in one pass, summed from the job rows rather than multiplied out of one
  # constant. A job that predates the columns counts as the constant it was admitted under —
  # `coalesce` rather than skipping it, because a NULL dropped from a sum is capacity the
  # platform would hand out twice.
  defp promised(worker_id) do
    slice = slice_bytes()
    cores = default_cores()

    {memory, reserved} =
      Repo.one(
        from j in Job,
          where: j.worker_id == ^worker_id and j.status in [:running, :waiting],
          select: {
            sum(coalesce(j.memory_max, ^slice)),
            sum(coalesce(j.cores, ^cores))
          }
      )

    {count(memory), count(reserved)}
  end

  # Postgres widens `sum()` over a bigint to `numeric`, which arrives as a `Decimal` — and
  # subtracting one of those from an integer raises rather than coercing. The sum is also NULL
  # rather than zero when the worker holds nothing, because that is what summing no rows gives.
  defp count(nil), do: 0
  defp count(%Decimal{} = sum), do: Decimal.to_integer(sum)
  defp count(sum) when is_integer(sum), do: sum

  @typedoc """
  What the jobs earlier in a scheduling pass were pointed at, per booting worker: the memory and
  cores they will take of it once it is up. `provide/3` reads it and the scheduler adds to it.
  """
  @type claims :: %{optional(String.t()) => {non_neg_integer(), non_neg_integer()}}

  @doc """
  A worker that will take `demand`, or the reason there is not one. A worker being created is
  not an error and not a worker yet: the caller leaves the job pending and asks again on the
  next pass, which is what a queue is.

  `{:creating, worker}` names the booting machine the job is waiting for — one already being
  made that would hold it, or one made for it now — so the caller can add the job to `claims`
  and the next job in the pass does not count on the same room
  (`docs/design/provisioning.md` § The gate). **A booting machine that would hold the job is
  asked before a new one is made**: a `creating` worker is not assignable, and without this
  every pass until it booted made another, up to the template's `max_workers`.

  `{:yield, worker}` is a full template with an idle machine past its period that could not hold
  the job: the caller passes it to `sweep_idle/1` at the end of the pass, which destroys it if the
  pass left it idle, and the job has the slot on the next pass (`docs/design/worker-tier.md` § The
  hour already paid for).
  """
  @spec provide(demand(), String.t() | nil, claims(), MapSet.t()) ::
          {:ok, Worker.t()}
          | {:creating, Worker.t()}
          | {:yield, Worker.t()}
          | {:error, :at_capacity | term()}
  def provide(demand, preferred \\ nil, claims \\ %{}, reserved \\ MapSet.new()) do
    with nil <- assignable(demand, preferred, reserved),
         nil <- booting(demand, claims) do
      make_machine(demand)
    else
      %Worker{status: :creating} = worker -> {:creating, worker}
      %Worker{} = worker -> {:ok, worker}
    end
  end

  # A machine the platform asked for that has not reported `ready`, and that this project may
  # use, which would hold the job with what the pass has already pointed at it. Measured against
  # the figures it was made with, since it has reported none of its own — the same figures the
  # template was chosen by. A row the driver refused is not booting; it carries `last_error`
  # and only holds its slot until `sweep_unreachable/0` retires it.
  defp booting(demand, claims) do
    from(w in serving(demand[:project_id]),
      where: w.status == :creating and is_nil(w.last_error),
      order_by: [asc: w.inserted_at]
    )
    |> Repo.all()
    |> Enum.find(fn worker ->
      {memory, cores} = Map.get(claims, worker.id, {0, 0})

      accepts?(worker, demand.kind) and
        (worker.memory_budget || 0) - memory >= demand.memory and
        room_for_cores?(worker, cores, demand.cores)
    end)
  end

  @doc """
  Makes a machine that could hold `demand`, or says why it cannot.

  **A template assigned to the job's project decides what to make**, and the smallest one that
  fits wins (`docs/design/provisioning.md` § Whose account). The machine inherits that
  template's provider, credential, resources and accepted kinds, and counts against that
  template's own `max_workers` rather than one ceiling for the node.

  `:no_template` is not the same answer as `:at_capacity` and the caller must not read them
  alike: at capacity is a queue, and no template is a job that will wait for ever unless
  somebody assigns one, enables one, or makes one fit.

  **There is no node fallback.** A project with nothing assigned creates nothing, and this says
  which wall was hit rather than quietly making something else
  (`docs/design/provisioning.md` § Whose account records why that reversed). The reason matters
  because the operator's next move differs: assign one, fix and enable one, make a bigger one,
  or wait.
  """
  @type refusal ::
          :creating
          | :at_capacity
          | {:no_template, :none_assigned | :all_disabled | :none_fit}
          | term()

  @spec create_machine(demand()) :: {:error, refusal()}
  def create_machine(demand \\ %{kind: :workflow, memory: 0, cores: 0}) do
    case make_machine(demand) do
      {:creating, _worker} -> {:error, :creating}
      # A slot that one machine has to give up first is a slot not yet there.
      {:yield, _worker} -> {:error, :at_capacity}
      refusal -> refusal
    end
  end

  defp make_machine(%{project_id: project_id} = demand) when is_binary(project_id) do
    case Provisioning.for_demand(project_id, demand) do
      nil -> no_template(project_id, demand)
      template -> create_from(template, demand)
    end
  end

  # A demand naming no project cannot name a template either. Nothing in the platform builds
  # one — `Jobs.Scheduler` puts `project_id` on every demand and every job has one — so this is
  # the default argument and the tests that use it, and it must not be the one path left that
  # can still make a machine out of node configuration.
  defp make_machine(_demand), do: {:error, {:no_template, :none_assigned}}

  # Why nothing was made, in the order that tells the operator the most. Assigned-but-disabled
  # is asked before could-ever-hold, because a disabled template is invisible to the gate and
  # the honest answer is *fix your template*, not *nothing here is big enough*. Nothing-assigned
  # was unreachable while the node fallback existed; without it, it is the state every new
  # project is in.
  # **A machine that already exists and could take this once it is free is a queue, not a wall**,
  # and it is asked first because it outranks every template answer. A node running the pure
  # permanent model — machines provisioned by hand, `managed: false`, no templates at all
  # (`worker-tier.md` § Managed and unmanaged) — would otherwise have every ticket stuck the
  # first time a job had to wait for a busy worker. Removing the node fallback is what made that
  # reachable: `create_default/0` used to answer `:at_capacity` here.
  defp no_template(project_id, demand) do
    if could_wait?(demand),
      do: {:error, :at_capacity},
      else: no_template_for(project_id, demand)
  end

  defp no_template_for(project_id, demand) do
    case Provisioning.for_project(project_id) do
      [] ->
        {:error, {:no_template, :none_assigned}}

      assigned ->
        cond do
          Enum.all?(assigned, &Provisioning.disabled?/1) ->
            {:error, {:no_template, :all_disabled}}

          Provisioning.could_ever_hold?(project_id, demand) ->
            {:error, :at_capacity}

          true ->
            {:error, {:no_template, :none_fit}}
        end
    end
  end

  # Whether any machine that exists could hold this **if it were empty**, which is a different
  # question from `fits?/2` — that one asks whether there is room now, and the answer to this
  # one does not change when a job ends.
  # Only machines that may serve this project: one that exists and could hold the job but is not
  # assigned here is not a queue for it, and answering `:at_capacity` would leave the ticket
  # waiting for a machine that will never be given it.
  defp could_wait?(demand) do
    from(w in serving(demand[:project_id]), where: w.status != :destroyed)
    |> Repo.all()
    |> Enum.any?(&holds_when_empty?(&1, demand))
  end

  # Every dimension of `fits?/2` but the room: a machine that could never speak the job's protocol
  # is no more a queue for it than one too small, and waiting on it is waiting for ever.
  defp holds_when_empty?(%Worker{} = worker, demand) do
    takes?(worker, demand) and (worker.memory_budget || 0) >= demand.memory and
      (is_nil(worker.cores) or worker.cores >= demand.cores)
  end

  defp create_from(template, demand) do
    with {:ok, slot} <- room(template, demand),
         :ok <- speaks(template),
         :ok <- probed(template),
         {:ok, credential} <- spendable(template) do
      make_in(slot, template, credential)
    end
  end

  # **A slot that has to be freed first is not made in, it is named.** The machine giving it up is
  # destroyed at the end of the pass (`sweep_idle/1`), not here, for two reasons the review of this
  # found: here, a younger job later in the same pass that *could* have used the machine found it
  # gone, and a destroy the driver refused was asked again by every job that reached this line —
  # up to ten requests a pass against one account. Named only once the checks above have passed,
  # so a machine is never given up for a create that was going to be refused anyway.
  defp make_in({:yield, worker}, _template, _credential), do: {:yield, worker}

  defp make_in(:free, template, credential) do
    unlabelled(template)

    do_create(
      Provisioning.Template.worker_attrs(template),
      %{size: template.size, image: template.image},
      credential,
      template.name
    )
  end

  # **A snapshot the platform knows it would refuse is not paid for.** Its protocol is on the
  # template, from its labels or learnt from a machine refused at join, and a mismatch is the
  # template's failure the way a credential it may not spend is — no row, no request, the words
  # on the templates page, and the template out of service after three passes
  # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol). Asked of the
  # range every time rather than stored, so upgrading the platform to one that accepts it is all
  # it takes to create from it again.
  defp speaks(template) do
    case Provisioning.image_refusal(template) do
      nil ->
        :ok

      message ->
        Logger.warning("not making a machine from template #{template.id}: #{message}")
        Provisioning.failed(template.id, message)
        {:error, {:create_failed, {:image, message}}}
    end
  end

  # **An image nobody has heard speak is probed by one machine, not several.** Its protocol is
  # learnt at the first join of a machine made from it (`admit/2`), and until then the platform
  # cannot tell a good snapshot from one it will refuse — so while one machine from it is booting
  # and has not joined, no second is made, and what does not fit in that one waits. Without this
  # a queue of jobs that did not fit one machine made one each, up to `max_workers`, all refused
  # and destroyed on arrival (`docs/design/provisioning.md` § A snapshot that speaks the wrong
  # protocol). Once one has joined, the template knows, and this stops applying — so a machine
  # from the image that is still here is one that has not joined, or one refused and on its way
  # out, and either is reason to wait.
  #
  # A template naming no image is not probed, for the reason `unlabelled/1` does not warn about
  # one: it boots the driver's default, this host's own. Every Hetzner template names one.
  defp probed(%{image: image, image_protocol: nil} = template) when is_binary(image) do
    probing =
      Repo.exists?(
        from w in Worker,
          where: w.template_id == ^template.id and w.image == ^image and w.status != :destroyed
      )

    if probing, do: {:error, :at_capacity}, else: :ok
  end

  defp probed(_template), do: :ok

  # **Unlabelled is unknown, not compatible**, and it is still made: the join decides, and a
  # refusal teaches the template, so an unlabelled snapshot that cannot work costs one machine.
  # A template naming no image boots the driver's default, which is the node's own and was built
  # with this platform.
  defp unlabelled(%{image: image, image_protocol: nil} = template) when is_binary(image) do
    Logger.warning(
      "making a machine from template #{template.id}, whose image #{image} carries no protocol " <>
        "label; the machine's join will say whether this platform can use it"
    )
  end

  defp unlabelled(_template), do: :ok

  # **A machine kept past its period gives its slot up to a job it cannot take.** On a provider
  # that bills by the hour an idle machine is kept to a leeway point of an hour it has paid for
  # (`goes_at/2`), and it still counts against `max_workers` — so a job it cannot hold, because
  # the template was edited since it was made or the job needs a protocol it does not speak, would
  # wait for a leeway point instead of the period's end. One past its period is named instead, and
  # destroyed at the end of the pass if nothing in the pass took it (`make_in/3`); one inside its
  # period is not, and the job waits it out as it always did (`docs/design/worker-tier.md` § The
  # hour already paid for).
  defp room(template, demand) do
    if Provisioning.live_count(template) < template.max_workers do
      {:ok, :free}
    else
      case outstayed_by(template, demand) do
        nil -> {:error, :at_capacity}
        worker -> {:ok, {:yield, worker}}
      end
    end
  end

  # The machine that gives its slot up: idle past its period and unable to hold the job even
  # empty. **One the driver has refused to destroy before goes last**, so a machine whose account
  # will not let it go does not stand in front of one that would. On an idle row `last_error` is a
  # refused destroy's words (`kept/4`), or — rarely — a create the driver called refused and made
  # anyway (`refused/2`), which puts that machine last too and costs only the order.
  defp outstayed_by(template, demand) do
    now = now()

    from(w in idle_managed(),
      where: w.template_id == ^template.id,
      order_by: [asc: not is_nil(w.last_error), asc: w.idle_since],
      preload: [:template]
    )
    |> Repo.all()
    |> Enum.find(&(outstayed?(&1, now) and not holds_when_empty?(&1, demand)))
  end

  # **Whose account, asked again where it costs money.** `Template.changeset/2` refuses a
  # credential that is not the template owner's, but only for rows written after it existed; a
  # template saved before then still names whatever it was given. So the credential the driver
  # would be handed is read and checked here, before a worker row or a request exists, and a
  # refusal is the template's failure like any other (`docs/design/provisioning.md` § Whose
  # account). No row means no slot is held, so this is not rate-limited to one attempt per sweep
  # the way a driver's refusal is — and a template spending somebody else's account is out of
  # service three scheduling passes later, which is sooner, and is the point.
  defp spendable(template) do
    case Provisioning.spendable_credential(template) do
      {:ok, credential} ->
        {:ok, credential}

      {:error, message} ->
        Logger.warning("not making a machine from template #{template.id}: #{message}")
        Provisioning.failed(template.id, message)
        {:error, {:create_failed, {:credential, message}}}
    end
  end

  # `template` is the template's name, read while it was in hand: it may be deleted while the
  # driver is making the machine, and the row's `template_id` then names nothing.
  defp do_create(attrs, shape, credential, template) do
    with {:ok, worker, token} <- create(attrs) do
      case Provider.create(machine_opts(worker, token, shape, credential)) do
        {:ok, machine} ->
          made(worker, machine, credential, template)

        {:error, reason} ->
          refused(worker, reason)
      end
    end
  end

  # **Recorded only on a row that is still there to hold it.** A create can take a while — a
  # provider's `POST /servers` — and the row is on the workers page with its Destroy button the
  # whole time. Retired in between, the row said destroyed with no `provider_id`, so nothing was
  # released; written afterwards, the id landed on a destroyed row that no sweep looks at, and the
  # machine booted into a platform that refuses its token, billing with nobody watching. So the id
  # is written only where the row is not destroyed, and a machine that arrives for a destroyed row
  # is given straight back.
  defp made(worker, machine, credential, template) do
    case Repo.update_all(
           from(w in Worker, where: w.id == ^worker.id and w.status != :destroyed),
           set: [provider_id: machine.provider_id, updated_at: now()]
         ) do
      {1, _} ->
        Logger.info("created worker #{worker.id} (#{machine.provider_id})")

        Log.record(
          worker.id,
          "created",
          :info,
          "#{worker.provider} made #{machine.provider_id} from template #{template}"
        )

        {:creating, get!(worker.id)}

      {0, _} ->
        Logger.warning(
          "worker #{worker.id} was retired while its machine was being made; destroying " <>
            "#{machine.provider_id} at once"
        )

        {:ok, _} = update(get!(worker.id), %{provider_id: machine.provider_id})
        _ = Provider.destroy(worker.provider, machine.provider_id, open_secret(credential))

        Log.record(
          worker.id,
          "destroyed",
          :warning,
          "#{worker.provider} made #{machine.provider_id} after the row was retired; asked it to " <>
            "destroy the machine at once"
        )

        {:error, :at_capacity}
    end
  end

  # **The driver said no, and until this existed nobody was told.** The error went back to the
  # scheduler, which reads every error alike as *not right now* and offers the job again next
  # pass — so a node with no image configured made a row, failed, swept it three minutes later
  # and did it again for ever, looking idle throughout. That is how it was found.
  #
  # The row is left `creating` rather than destroyed on purpose. It holds its place against
  # `max_workers`, which is what rate-limits the retry to one attempt per sweep instead of one
  # per scheduling pass; `sweep_unreachable/0` retires it on the usual timeout, because
  # `last_seen/1` falls back to `inserted_at` for a machine that never spoke.
  defp refused(worker, reason) do
    message = message(reason)
    Logger.warning("could not make a machine for worker #{worker.id}: #{message}")
    {:ok, _worker} = update(worker, %{last_error: message})
    Log.record(worker.id, "create.refused", :error, "#{worker.provider} refused: #{message}")
    Provisioning.failed(worker.template_id, message)
    {:error, {:create_failed, reason}}
  end

  # A driver's own words where it gave them, because "create failed" sends an operator nowhere
  # and "the template names no image" sends them straight to the thing to fix.
  defp message({:hetzner, message}) when is_binary(message), do: message
  defp message({_provider, status, message}) when is_binary(message), do: "#{status}: #{message}"
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  # `size` and `image` are the template's own and opaque above the driver; a template that
  # names no image passes nil, and what that means is the driver's: the local one boots this
  # host's image whatever it is given, and Hetzner refuses — there is no node-wide image for it,
  # `Forge.Provider.required_template_fields/1` keeps new templates from naming none, and a row
  # saved before that rule is refused by the driver and counts against its template.
  defp machine_opts(worker, token, shape, credential) do
    %{
      provider: worker.provider,
      worker_id: worker.id,
      token: token,
      platform_url: Forge.Jobs.config(:platform_url, nil) || ForgeWeb.Endpoint.url(),
      harness_env: harness_env(),
      size: Map.get(shape, :size),
      image: Map.get(shape, :image),
      credential: open_secret(credential)
    }
  end

  # A worker's own credential, for asking its driver about the machine it made. A machine with
  # none is a local one, and the driver ignores it.
  defp credential_secret(%{provider_credential_id: nil}), do: nil

  defp credential_secret(%{provider_credential_id: id}),
    do: open_secret(Repo.get(Provisioning.Credential, id))

  # A credential that cannot be decrypted is passed as nil rather than crashing the scheduler:
  # the driver refuses with its own message, which is visible, and the operator re-enters the
  # secret.
  defp open_secret(nil), do: nil

  defp open_secret(%Provisioning.Credential{} = credential) do
    case Provisioning.Credential.secret(credential) do
      {:ok, secret} ->
        secret

      :error ->
        Logger.error(
          "provider credential #{credential.id} cannot be decrypted; asking without it"
        )

        nil
    end
  end

  @doc """
  What the machine is given for its harness at creation, as `{name, value}` pairs: the model, when
  the node names one, and nothing else.

  **No credential, and that is the design rather than an omission.** A machine used to boot with
  the node's `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` in its environment and spend it on
  every job it ran; a job now brings its own credential in the assignment, sealed for that worker
  (`docs/design/credentials.md` § The credential belongs to the job, not to the machine), and the
  node's variables are not read at all. `executable` is not here either: it is a path on this
  host, and the worker image has its own.

  Public because `mix forge.worker.new` mints the environment for a machine the operator is
  provisioning by hand, and that machine needs exactly what the driver would have given it.
  """
  @spec harness_env() :: [{String.t(), String.t()}]
  def harness_env do
    case Keyword.get(Forge.Jobs.config(:harness_opts, []), :model) do
      model when is_binary(model) -> [{"FORGE_CLAUDE_MODEL", model}]
      _other -> []
    end
  end

  @doc """
  Destroys managed workers that have had nothing to do for long enough (`goes_at/2`): past their
  period — their template's `idle_ms`, or the node's `idle_period_ms`, whose default is set from
  M4's cold start (`docs/measurements.md` § M4, `docs/design/worker-tier.md` § Idle destroy) —
  with no job still claiming them, and on a provider that bills by the hour, at a leeway point of
  an hour they have paid for.

  `yields` are the machines this pass named to give up their slot (`provide/4`). One is destroyed
  only if the pass left it idle — a younger job that fitted it has made it busy — and it is still
  past its period.

  **Decided one machine at a time, each at its own moment**, because a destroy is a provider call
  that can take its thirty-second timeout, and a decision taken before the first of several would
  be stale by the last.
  """
  @spec sweep_idle(MapSet.t()) :: non_neg_integer()
  def sweep_idle(yields \\ MapSet.new()) do
    from(w in idle_managed(), preload: [:template])
    |> Repo.all()
    |> Enum.count(fn worker ->
      case ending(worker, yields, now()) do
        nil -> false
        by -> destroy(worker, by: by) == :ok
      end
    end)
  end

  defp ending(worker, yields, now) do
    cond do
      reached?(leaves_at(worker, now), now) -> :idle
      MapSet.member?(yields, worker.id) and outstayed?(worker, now) -> :yielded
      true -> nil
    end
  end

  # **And nothing running on it, whatever its status says.** A status is one write behind the
  # jobs it describes, and destroying a machine under a job leaves that job `running` for ever:
  # nothing re-queues a job whose worker was destroyed rather than lost. One definition for the
  # sweep, the yield and the workers page (`goes_at/2`), so none of them can mean something else.
  defp idle_managed do
    running = from(j in Job, where: j.worker_id == parent_as(:worker).id and j.status == :running)

    from(w in Worker,
      as: :worker,
      where: w.status == :idle and w.managed and not exists(running)
    )
  end

  # Whether a moment has come. Nil never has. One comparison for the sweep's two questions — is a
  # machine due, is it past its period — so the second of the boundary means the same to both.
  defp reached?(nil, _now), do: false
  defp reached?(at, now), do: DateTime.compare(at, now) != :gt

  @doc """
  When the idle sweep will destroy this machine, as of `now` — nil for one it never will: a
  machine that is not idle, has a job running whatever its status says, has no idle clock, or is
  not the platform's to destroy.

  **Once nothing has a claim on it** (`claimed_until/1`): its idle period is over, no job parked on
  it is still waiting on commands that have not timed out, and no job that last ran on it has just
  come back to the queue. On a provider that bills by the hour that is not yet the moment. The
  machine is decided on at the **leeway point** of each billed increment
  (`Forge.Provider.billed_increment_ms/1`) — `billing_leeway_ms` before it ends, counted from when
  its row was made, which is before the provider's own clock started, so an error in the anchor
  goes early and never into an hour nobody meant to buy. It goes at the first leeway point by which
  nothing has a claim on it; a claim still standing at a leeway point — a chat that has not reached
  its own idle timeout keeps its machine busy, so it is one — buys the whole next hour
  (`docs/design/worker-tier.md` § The hour already paid for).

  **Not in an hour's last call** (`billing_last_call_ms`): a destroy sent then could complete in the
  next hour, which would be billed with the machine already gone. A machine the sweep did not get
  to before the last call — a refused destroy, a node that was down — is kept to the next hour's
  leeway point, and so is one whose hour ended meanwhile.

  One function for the sweep and the workers page, asking the sweep's own question of the row
  (`idle_managed/0`), so what the page says and what the sweep does cannot drift apart.
  """
  @spec goes_at(Worker.t(), DateTime.t()) :: DateTime.t() | nil
  def goes_at(%Worker{id: id} = worker, now) do
    if Repo.exists?(from w in idle_managed(), where: w.id == ^id),
      do: worker |> Repo.preload(:template) |> leaves_at(now)
  end

  defp leaves_at(%Worker{idle_since: %DateTime{}} = worker, now) do
    free = latest(period_ends(worker), claimed_until(worker))

    case Provider.billed_increment_ms(worker.provider) do
      nil -> latest(free, now)
      increment -> leeway_point(worker.inserted_at, increment, free, now)
    end
  end

  defp leaves_at(%Worker{}, _now), do: nil

  # Three cases, in the order `goes_at/2` states them: the first leeway point by which nothing has
  # a claim, while it is still to come; `now`, once it has passed and an hour's leeway is open —
  # after its point and before its last call; otherwise the next leeway point from `now`.
  # Increments are counted from `from`.
  defp leeway_point(from, increment, free, now) do
    point = increment - leeway()
    closes = increment - config(:billing_last_call_ms, :timer.minutes(1))
    first = next_point(from, increment, point, free)
    into = into(now, from, increment)

    # The two boundaries here are equivalent mutants: at `now == first`, and at `into == point`,
    # every arm answers `now`.
    cond do
      DateTime.compare(now, first) == :lt -> first
      into >= point and into < closes -> now
      true -> next_point(from, increment, point, now)
    end
  end

  # **A claim that ends after an hour's leeway point buys the next hour**, so it is that hour's
  # point that comes next — not the moment the claim ends, however soon before the hour's end.
  defp next_point(from, increment, point, at) do
    into = into(at, from, increment)
    wait = if into <= point, do: point - into, else: increment - into + point

    DateTime.add(at, wait, :millisecond)
  end

  # How far into its increment `at` is. `Integer.mod/2` rather than `rem/2` is an equivalent
  # mutant while the clock only moves forward: every moment asked about is after the row was made.
  # They differ only for a clock stepped back past a row's making, where `rem/2` would go late.
  defp into(at, from, increment),
    do: Integer.mod(DateTime.diff(at, from, :millisecond), increment)

  # config.exs always sets `billing_leeway_ms`, so this fallback is an equivalent mutant under any
  # configured node; it matches that value so removing the line changes nothing. The same holds for
  # `billing_last_call_ms` above.
  defp leeway, do: config(:billing_leeway_ms, :timer.minutes(5))

  @doc """
  Refuses a billing configuration that cannot work, when the node starts rather than in the pass
  that meets it. The leeway must open after the last call is over — `billing_last_call_ms` below
  `billing_leeway_ms` — and before every billed increment a configured driver declares, and both
  must be whole seconds' worth, since the rows and the sweep count in seconds.

  **Each wrong value was a silent failure** (`docs/design/worker-tier.md` § The hour already paid
  for): a leeway no longer than the last call is a window that never opens, so a billed machine is
  never destroyed; one as long as the increment destroys at the hour's end or after it.
  """
  @spec check_billing!() :: :ok
  def check_billing! do
    leeway = leeway()
    last_call = config(:billing_last_call_ms, :timer.minutes(1))

    increments =
      Provider.names() |> Enum.map(&Provider.billed_increment_ms/1) |> Enum.reject(&is_nil/1)

    cond do
      not (is_integer(last_call) and last_call >= 1_000) ->
        raise ArgumentError,
              "billing_last_call_ms must be at least a second, got #{inspect(last_call)}"

      not (is_integer(leeway) and leeway > last_call) ->
        raise ArgumentError,
              "billing_leeway_ms (#{inspect(leeway)}) must be longer than billing_last_call_ms " <>
                "(#{last_call}), or a billed machine is never destroyed"

      Enum.any?(increments, &(leeway >= &1)) ->
        raise ArgumentError,
              "billing_leeway_ms (#{leeway}) must be shorter than every billed increment " <>
                "(#{inspect(increments)}), or a machine is destroyed at its hour's end or after it"

      true ->
        :ok
    end
  end

  @doc """
  Refuses a slice no job can run in, when the node starts: `slice_bytes`, what a workflow job
  declaring nothing gets, and `chat_slice_bytes`, a chat's. Both are configuration, and
  `FORGE_SLICE_BYTES` takes a bare number of bytes, so `2` is a value an operator can set — and
  every job made from it would be refused at its row (`Forge.Jobs.Job`), one ticket at a time,
  rather than once here (`docs/design/workflow-grammar-v1.md` § Resources).
  """
  @spec check_slices!() :: :ok
  def check_slices! do
    for {key, bytes} <- [slice_bytes: slice_bytes(), chat_slice_bytes: chat_slice_bytes()],
        not ForgeCore.Workflow.Resources.enough_memory?(bytes) do
      raise ArgumentError,
            "#{key} (#{inspect(bytes)}) #{ForgeCore.Workflow.Resources.too_little_memory()}"
    end

    :ok
  end

  # **What still has a claim on this machine, and until when** — nil when nothing does.
  #
  # - **A job parked on it**, waiting on commands it invoked, until the last of its open commands
  #   would time out: `timeout_ms` from when the command's row last changed — its start, or its
  #   return to the queue after a lost worker — so a command stuck in the queue cannot hold a
  #   machine for ever. The worker starts that clock only once it has prepared the command, so the
  #   claim can end a preparation's length early. The job's `worker_id` is the machine it ran on and
  #   the one it prefers when it resumes (`docs/design/provisioning.md` § Affinity on resume).
  # - **A job that last ran on it and is back in the queue** — resumed from a park, reopened,
  #   requeued — for one idle period from its return, which is what covers the gap between the
  #   resume and the pass that places it, and no longer: a job waiting for a rate limit to reset
  #   does not hold a machine for a week.
  defp claimed_until(%Worker{id: id} = worker) do
    commands =
      from(c in Forge.Jobs.Commands.open(),
        join: p in Job,
        on: p.id == c.parent_job_id,
        where: p.worker_id == ^id and p.status == :parked
      )
      |> Repo.all()
      |> Enum.map(&DateTime.add(&1.updated_at, Forge.Jobs.wall_clock_ms(&1), :millisecond))

    returned =
      from(j in Job, where: j.worker_id == ^id and j.status == :pending)
      |> Repo.all()
      |> Enum.map(&DateTime.add(&1.updated_at, period(worker), :millisecond))

    Enum.max(commands ++ returned, DateTime, fn -> nil end)
  end

  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # Past its period: the warmth the operator asked for is spent, and what is left of the hour is
  # the platform's to give up (`room/2`). A parked job's claim is not asked about here: it resumes
  # on any machine, and a queue that does not move is worse than a session rebuilt elsewhere.
  defp outstayed?(%Worker{idle_since: nil}, _now), do: false
  defp outstayed?(%Worker{} = worker, now), do: reached?(period_ends(worker), now)

  defp period_ends(%Worker{} = worker),
    do: DateTime.add(worker.idle_since, period(worker), :millisecond)

  # **The period is the machine's own template's, and only then the node's.** One number cannot
  # serve two kinds of machine (`docs/design/provisioning.md` § Lifecycle is per template): an
  # agent box is cheap by the hour and its warm Nix store is worth keeping, while a command
  # machine is expensive by the hour and its warm store is worth *more*, because a cold one
  # re-fetches a whole toolchain over the provider's network rather than over loopback.
  #
  # Read in Elixir rather than in the query because it differs per row, and a `CASE` that
  # computed it in SQL would put the rule somewhere nobody reads it.
  defp period(%Worker{template: %{idle_ms: ms}}) when is_integer(ms), do: ms

  # config.exs always sets `idle_period_ms`, so this fallback is an equivalent mutant under any
  # configured node; it matches that value so removing the line changes nothing.
  defp period(%Worker{}), do: config(:idle_period_ms, :timer.minutes(5))

  @doc """
  Destroys workers the platform cannot reach any more. `docs/design/worker-channel.md` § When
  the machine goes away: past the timeout the platform stops waiting — it re-queues that
  worker's running jobs, asks the driver to destroy the machine and marks the row. Destroying a
  machine that is merely partitioned is the right trade, because the jobs are re-runnable by
  construction and a worker nobody can reach is doing nothing that can be observed or billed.

  A row left behind is not cosmetic. A template's `max_workers` counts every row made from it
  that is not `destroyed`, so one machine the platform has lost track of is one machine's worth
  of that template's capacity that never comes back, and with `max_workers` at 1 that is all of
  it.
  """
  @spec sweep_unreachable() :: non_neg_integer()
  def sweep_unreachable do
    now = now()
    cutoff = DateTime.add(now, -config(:worker_timeout_ms, :timer.minutes(3)), :millisecond)

    from(w in Worker, where: w.status != :destroyed)
    |> Repo.all()
    |> Enum.reject(&connected?(&1.id))
    |> Enum.filter(&(DateTime.compare(last_seen(&1), cutoff) == :lt))
    |> Enum.reject(&rebooting?(&1, now))
    |> Enum.count(&(lose(&1) == :ok))
  end

  # **A machine told to reboot is away because it was told to**, and a reboot takes longer than
  # the timeout allows a heartbeat: for `reboot_grace_ms` from when it was told, the row is left
  # for it to come back to (`docs/design/worker-tier.md` § The same machine, the same row). Only
  # while it is still marked and was told in this episode — one that rejoined healthy and went
  # unhealthy again was not told this time, and is not rebooting.
  defp rebooting?(%Worker{unhealthy_at: %DateTime{}, rebooted_at: %DateTime{}} = worker, now) do
    grace = config(:reboot_grace_ms, :timer.minutes(10))

    told_this_time?(worker) and
      DateTime.compare(DateTime.add(worker.rebooted_at, grace, :millisecond), now) == :gt
  end

  defp rebooting?(%Worker{}, _now), do: false

  # A worker that has never reported is timed from when its row was made: a machine that never
  # finishes booting has to expire too, or a failed create holds the slot for ever.
  defp last_seen(%Worker{last_seen_at: nil, inserted_at: inserted_at}), do: inserted_at
  defp last_seen(%Worker{last_seen_at: last_seen_at}), do: last_seen_at

  # An unmanaged worker is the operator's machine, and it may well come back — a `destroyed` row
  # never can. So it loses its jobs, which are re-runnable and which nothing is observing, and
  # keeps its row. It is not assignable while it is out of touch either way: `assignable/1` asks
  # the registry, not the row.
  defp lose(%Worker{managed: false} = worker) do
    case requeue_running(worker, :worker_lost) do
      [] ->
        :skip

      jobs ->
        Logger.warning(
          "worker #{worker.id} is unreachable; re-queued #{length(jobs)} job(s). It is not " <>
            "the platform's to destroy, so its row stays and it may rejoin."
        )

        Log.record(
          worker.id,
          "unreachable",
          :warning,
          "#{silent(worker)}; requeued #{length(jobs)} job(s). Its row stays: it is not the " <>
            "platform's to destroy, and it may rejoin"
        )

        :ok
    end
  end

  defp lose(%Worker{} = worker) do
    Logger.warning("worker #{worker.id} is unreachable; re-queueing its jobs and destroying it")

    jobs = requeue_running(worker, :worker_lost)

    # **Said once, not every pass.** A destroy the driver refuses leaves the row as it was, and
    # this runs again on every scheduling pass until one goes through.
    Log.record(
      worker.id,
      "unreachable",
      :warning,
      "#{silent(worker)}; requeued #{length(jobs)} job(s) and destroying it",
      once: true
    )

    never_connected(worker)
    destroy(worker, by: :unreachable)
  end

  defp silent(%Worker{last_seen_at: nil} = worker),
    do: "made #{utc(worker.inserted_at)} and never connected"

  defp silent(%Worker{last_seen_at: at}), do: "not heard from since #{utc(at)}"

  defp utc(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  # **A machine that was made and never called home is the template's failure**, and it is the
  # one that matters: in the loop this was written for every create succeeded, so a counter
  # watching only refusals would have watched it run for ever, making a machine every three
  # minutes and paying for each.
  #
  # A worker that connected and *later* went away is not the template's failure — the machine
  # worked and something else happened to it — and `last_seen_at` being null is the only thing
  # that separates the two.
  defp never_connected(%Worker{last_seen_at: nil} = worker),
    do: Provisioning.failed(worker.template_id, "made a machine that never connected")

  defp never_connected(%Worker{}), do: :ok

  @doc """
  Puts back in the queue every job the platform believes is running on this machine, and returns
  them: a workflow job and a command to `pending`, a chat to dormant (`Forge.Jobs.requeue/2`).

  **The one way a machine loses its jobs** — lost past the timeout, retired, or saying its systemd
  stopped answering (`docs/design/worker-channel.md` § When the machine goes away). Each differs
  in what it does to the row, and none in what it does to the jobs.
  """
  @spec requeue_running(Worker.t(), atom()) :: [Job.t()]
  def requeue_running(%Worker{id: id}, reason) do
    jobs = Forge.Jobs.running_on(id)
    Enum.each(jobs, &Forge.Jobs.requeue(&1.id, reason))
    jobs
  end

  # -- a machine that can run nothing ---------------------------------------------------------

  @doc """
  A machine saying its systemd stopped answering, and the platform's answer: whether it should
  reboot, and why (`docs/design/worker-tier.md` § A machine whose systemd stops answering).

  **The row is marked first**, and once: the first reason and the time the episode began stand
  however often it is said. A marked row is assignable to nothing (`assignable/3`), and the
  channel requeues an assignment that reaches it afterwards. Then what was running there goes back
  to the queue, exactly as a lost machine's does (`requeue_running/2`). A yes is written down as
  `rebooted_at` before it is given, so the hour is counted from an answer that was made.
  """
  @spec unhealthy(String.t(), term()) :: {:ok, %{reboot: boolean(), why: String.t()}}
  def unhealthy(worker_id, reason) do
    now = DateTime.utc_now()
    worker = mark(get!(worker_id), reason, now)
    jobs = requeue_running(worker, :worker_unhealthy)
    {reboot, why} = reboot?(worker)
    if reboot, do: {:ok, _worker} = update(worker, %{rebooted_at: now})

    Log.record(
      worker.id,
      "unhealthy",
      :error,
      "#{worker.unhealthy_reason}; requeued #{length(jobs)} job(s); #{why}"
    )

    {:ok, %{reboot: reboot, why: why}}
  end

  defp mark(%Worker{unhealthy_at: nil} = worker, reason, now) do
    {:ok, worker} =
      update(worker, %{
        unhealthy_at: now,
        unhealthy_reason: Log.clean(reason, 500) || "it gave no reason"
      })

    worker
  end

  defp mark(%Worker{} = worker, _reason, _now), do: worker

  # **The platform's key of the two** (`docs/design/worker-tier.md` § What happens then); the
  # machine's own `FORGE_MANAGED=1` is the other. A permanent machine is somebody's own computer.
  # A managed one is told to once in `reboot_interval_ms`, counted from when this episode began and
  # not from now, so the same episode asked again later gets the same answer; and an episode
  # already told yes is told yes again, since that reply may have been lost with its socket.
  defp reboot?(%Worker{managed: false}),
    do: {false, "not rebooted: it is not the platform's machine, and its owner restarts it"}

  defp reboot?(%Worker{rebooted_at: nil}), do: {true, "told to reboot"}

  defp reboot?(%Worker{} = worker) do
    interval = config(:reboot_interval_ms, :timer.hours(1))

    cond do
      told_this_time?(worker) ->
        {true, "told to reboot"}

      DateTime.diff(worker.unhealthy_at, worker.rebooted_at, :millisecond) >= interval ->
        {true, "told to reboot"}

      true ->
        {false,
         "not rebooted: it was told to at #{utc(worker.rebooted_at)}, within the hour, so it " <>
           "waits for a person"}
    end
  end

  defp told_this_time?(%Worker{} = worker),
    do: DateTime.compare(worker.rebooted_at, worker.unhealthy_at) != :lt

  @doc """
  A machine marked unhealthy joined again without saying it is: it rebooted, or its owner
  restarted it. The mark goes and it takes work again; `rebooted_at` stays, because it is the
  hour. There is no other way to clear it — the worker's own belief is what refuses work.
  """
  @spec healthy(Worker.t()) :: :ok
  def healthy(%Worker{unhealthy_at: nil}), do: :ok

  def healthy(%Worker{} = worker) do
    {:ok, _worker} = update(worker, %{unhealthy_at: nil, unhealthy_reason: nil})
    Log.record(worker.id, "healthy", :info, "joined without saying it is unhealthy; takes work")
    :ok
  end

  @doc """
  Destroys a worker's machine and records that it is gone — **only if it went**.

  **The row is the platform's claim that the machine is not billing any more, so it may not be
  written until the driver says so.** It used to be written either way: the call was
  `if worker.provider_id, do: Provider.destroy(...)` with the answer discarded, and it logged
  *destroyed worker* unconditionally. On a node whose Hetzner credential was a user's rather
  than the node's, every destroy was refused before a request was even sent — and the refusal
  went nowhere, so the row said destroyed, `live_count/0` stopped counting it, the
  `max_workers` slot came free, and the scheduler made another. One machine leaked every sweep,
  all of them invisible to the product and none of them stopped.

  A failure now keeps the row exactly as it is, with the driver's words in `last_error`:

  - **The machine is still there, so the row that represents it must be.** It goes on holding
    its `max_workers` slot, which is what stops the platform making a replacement for a machine
    that never left.
  - **The next sweep tries again.** `sweep_unreachable/0` picks up anything not `destroyed`
    past the timeout, so a transient refusal — an API that is down, a credential being
    re-entered — resolves itself without anybody watching.
  - **A permanent refusal wedges the fleet at `max_workers` instead of leaking**, and says why
    on the workers page. That is the trade, and it is the right way round: a stuck fleet is
    visible and a leaking one is not.

  `by:` says what ended it — `:idle`, `:yielded`, `:unreachable`, `:owner`, `:command_line`,
  `:protocol` — for the machine's log (`docs/design/worker-log.md`), which is where "why did it
  go away?" is asked.
  """
  @spec destroy(Worker.t(), keyword()) :: :ok | {:error, term()}
  def destroy(%Worker{} = worker, opts \\ []) do
    by = Keyword.get(opts, :by)
    # **Said before anything is asked of the driver**, so a cause this does not know raises while
    # the machine is still there, rather than after it has gone and before its row says so.
    why = cause(by)

    case release_machine(worker) do
      :ok ->
        Logger.info("destroyed worker #{worker.id}")
        gone(worker, %{status: :destroyed}, {:info, "#{ended(worker)}#{why}"})

      # **No driver to ask is not the same as a driver that said no.** A row naming a provider
      # this node no longer has can never be destroyed from here however many times it is
      # tried, so keeping it holds a `max_workers` slot for ever and the queue never moves
      # again — the deadlock `worker-tier.md` § What the operator's machine settled records
      # finding the hard way. The row is retired with the reason on it; the machine, if there
      # is one, belongs to a provider this node cannot speak to and somebody has to go and look.
      {:error, {:unknown_provider, _name} = reason} ->
        Logger.error(
          "worker #{worker.id} names provider #{worker.provider}, which this node does not " <>
            "have; retiring the row. Check the provider's console for #{worker.provider_id}."
        )

        gone(
          worker,
          %{status: :destroyed, last_error: message(reason)},
          {:warning,
           "row retired#{why}, but its provider #{worker.provider} is not on this node, " <>
             "so nothing was asked to destroy #{worker.provider_id}: check that provider's console"}
        )

      # The operator has looked and said so. It is the only way out of a machine the platform
      # cannot end — a credential that was deleted, a provider that will not answer — and it is
      # deliberately a person's decision, because what it writes down is a claim about the world
      # that the platform could not check.
      {:error, reason} ->
        if Keyword.get(opts, :force, false),
          do: forced(worker, reason, why),
          else: kept(worker, reason, by, why)
    end
  end

  defp forced(worker, reason, why) do
    message = message(reason)

    Logger.warning(
      "worker #{worker.id} retired by force; the driver refused: #{message}. " <>
        "If the machine is still there it is nobody's now."
    )

    gone(
      worker,
      %{status: :destroyed, last_error: message},
      {:warning,
       "retired by force#{why}; #{worker.provider} would not destroy " <>
         "#{worker.provider_id}: #{message}. If the machine is still there it is nobody's now"}
    )
  end

  # What ending this row did. A permanent machine is only forgotten — it was never the platform's
  # to stop, and it runs on — and a managed row whose driver never made anything had no machine.
  defp ended(%Worker{managed: false}),
    do: "retired: forgotten, not destroyed, since the machine was never the platform's to stop"

  defp ended(%Worker{provider_id: nil}), do: "row retired; no machine had been made for it"
  defp ended(%Worker{} = worker), do: "destroyed #{worker.provider_id} on #{worker.provider}"

  # By what, which is the question this line is there to answer ("why did it go away?").
  defp cause(nil), do: ""
  defp cause(:idle), do: " — idle past its period"

  defp cause(:yielded),
    do: " — idle past its period, and its slot wanted by a job it could not take"

  defp cause(:unreachable), do: " — unreachable"
  defp cause(:owner), do: " — by its owner, from the workers page"
  defp cause(:command_line), do: " — from the host's command line"
  defp cause(:protocol), do: " — it speaks a protocol this platform refuses"

  # **Every way a row becomes `destroyed` closes its channel**, because a connection outlives the
  # row it was made for: a retired permanent machine that is still running is still joined, and
  # would otherwise go on heartbeating into a row that says it is gone
  # (`docs/design/worker-channel.md` § Authentication). A machine not connected here — or
  # connected to another node, which the host's command line is — has nothing to close.
  #
  # The channel is handed the jobs still running there, to cancel before it closes: a retired
  # permanent machine keeps running, and a job requeued from it would otherwise run twice — once
  # there, on the job's credential, with nobody left to record what it spent.
  defp gone(worker, attrs, {level, line}) do
    with {:ok, _worker} <- update(worker, attrs) do
      Log.record(worker.id, "destroyed", level, line)
      jobs = Enum.map(Forge.Jobs.running_on(worker.id), & &1.id)
      push(worker.id, {:retired, jobs})
      :ok
    end
  end

  @doc """
  Ends a machine: destroys it through its driver — or, for a permanent one, only forgets it — and
  requeues what it was running. `mix forge.worker.retire` and the workers page both come here,
  the page through `retire_by_owner/2`.

  **The jobs are requeued once the row is `destroyed`, and not before.** A refused destroy leaves
  the machine running them, still connected and still assignable, and requeuing them beside it
  would put a second copy of each on the queue for the scheduler to hand straight back to the
  machine that already has it (`docs/design/provisioning.md` § Whose account). `force` is passed
  through to `destroy/2`, and only the command line passes it.
  """
  @spec retire(Worker.t(), keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def retire(%Worker{} = worker, opts \\ []) do
    {reason, opts} = Keyword.pop(opts, :reason, :worker_retired)

    with :ok <- destroy(worker, opts), do: {:ok, requeue_running(worker, reason)}
  end

  @doc """
  Ends one of `user`'s machines, named by an id off the wire: *Destroy machine* and *Retire* on the
  workers page (`docs/design/ui.md` § The workers page).

  **The row is read scoped to the caller**, so somebody else's machine is `:not_found` exactly as
  a missing one is, and so is one already destroyed. Never with `force`: what force writes down is
  a claim about the provider's console that only a person who has looked can make, and it stays on
  the command line (`docs/design/provisioning.md` § Whose account).
  """
  @spec retire_by_owner(User.t(), String.t() | nil) ::
          {:ok, [Job.t()]} | {:error, :not_found | term()}
  def retire_by_owner(%User{} = user, id) do
    case owned(user, id) do
      nil -> {:error, :not_found}
      %Worker{status: :destroyed} -> {:error, :not_found}
      worker -> retire(worker, by: :owner)
    end
  end

  # A row that never got a machine has nothing to release. The driver is the one that made it,
  # read from the row and never whichever is configured now — a node that has been reconfigured
  # would otherwise ask the wrong provider to destroy an id that means something else there —
  # and the credential is the machine's own, for the same reason.
  defp release_machine(%Worker{provider_id: nil}), do: :ok

  defp release_machine(%Worker{} = worker),
    do: Provider.destroy(worker.provider, worker.provider_id, credential_secret(worker))

  defp kept(worker, reason, by, why) do
    message = message(reason)

    Logger.error(
      "could not destroy worker #{worker.id}'s machine (#{worker.provider} " <>
        "#{worker.provider_id}): #{message}#{retry(by)}."
    )

    {:ok, _worker} = update(worker, %{last_error: message})

    # Once until the machine next joins: the sweep asks again every pass, and the row's
    # `last_error` holds the driver's latest words.
    Log.record(
      worker.id,
      "destroy.refused",
      :error,
      "#{worker.provider} would not destroy #{worker.provider_id}#{why}: #{message}#{retry(by)}",
      once: true
    )

    {:error, reason}
  end

  # **A retry is promised only where something will make one.** The sweeps ask again for a machine
  # that is idle or unreachable, and a refused machine's next knock asks again; a Destroy pressed
  # on the page or a retire from the command line is asked once, and the machine it was pressed on
  # is usually neither idle nor unreachable (`docs/design/ui.md` § The workers page).
  defp retry(by) when by in [:idle, :yielded, :unreachable, :protocol],
    do: ". The row is kept, and the platform tries again"

  defp retry(_by), do: ". The row is kept, so the machine is still counted"

  @doc """
  What one job is allowed to use. M3's observed peak plus its margin, carried as a default
  until the operator's own project replaces it (`docs/measurements.md` § M3).
  """
  @spec slice_bytes() :: pos_integer()
  # 2009 MiB observed, times the 1.1 margin, rounded up to 2210 MiB.
  def slice_bytes, do: config(:slice_bytes, 2210 * 1024 * 1024)

  @doc """
  What a chat is allowed to use, which is not what a build is.

  `slice_bytes/0` is M3's *cold build* peak, and a chat inherited it for no better reason than
  being the one job kind with nothing to declare — `resources` is a workflow state's grammar
  and a chat has no state. So opening a conversation reserved 2210 MiB to run an agent that
  talks, which is the figure that put a 2 GiB machine out of reach of a chat.

  **An estimate, and deliberately a crude one.** Nothing has measured an agent: M3 measured
  builds. What lives inside this ceiling is the harness process and what it shells out to —
  the `forge_worker` release is outside the slice, so the agent manager's own memory is not
  what this sizes. Claude Code is a Node process in the few hundred megabytes with a loaded
  context, git and ripgrep add tens, and `nix develop` entry measured at 7 MiB
  (`docs/measurements.md` § M3, `env-baseline`), so the environment is free. A gibibyte is
  that rounded up, and it should be replaced by a measurement rather than by a better guess.

  **The cost is that a chat cannot do a cold build.** `MemoryMax` is hard and swap is off
  (`ForgeWorker.Slice.flags/1`), and M3 put a cold build of this repository at 1612 MiB debug
  and 1879 MiB release. A conversation asked to run the full gate is killed rather than slow.
  That is the trade this number makes: conversations are the common case and builds are a
  workflow's job, which still gets `slice_bytes/0`.
  """
  @spec chat_slice_bytes() :: pos_integer()
  def chat_slice_bytes, do: config(:chat_slice_bytes, 1024 * 1024 * 1024)

  @doc """
  Cores a job reserves when neither its state nor the workflow's defaults say.

  One, and not a measured figure: nothing has measured a machine whose cores bind
  (`docs/design/provisioning.md` § What this gives up). One is the value that makes the new
  dimension behave like the old fleet — every job equal, every machine holding as many as it
  has cores — so a workflow that declares nothing schedules as it did before this existed.
  """
  @spec default_cores() :: pos_integer()
  def default_cores, do: config(:cores, 1)

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  defp hash(token), do: Base.encode16(:crypto.hash(@hash_algorithm, token), case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
