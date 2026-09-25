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
  alias Forge.Workers.{ProjectWorker, Worker}

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
      {:ok, worker} -> {:ok, worker, Base.url_encode64(token, padding: false)}
      {:error, changeset} -> {:error, changeset}
    end
  end

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
  """
  @spec set_offer(User.t(), String.t(), map()) ::
          {:ok, Worker.t()} | {:error, :not_found | :made_by_the_platform | Ecto.Changeset.t()}
  def set_offer(%User{} = user, id, attrs) do
    with {:ok, worker} <- owned_permanent(user, id) do
      worker |> Worker.offer_changeset(attrs) |> Repo.update()
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
  def busy(%Worker{} = worker) do
    worker
    |> Worker.changeset(%{})
    |> Ecto.Changeset.force_change(:status, :busy)
    |> Ecto.Changeset.force_change(:idle_since, nil)
    |> Repo.update()
  end

  @doc """
  A job on this worker ended. When it was the last one the machine goes idle, and the clock
  that destroys it starts.
  """
  @spec release(String.t() | nil) :: :ok
  def release(nil), do: :ok

  def release(worker_id) do
    with %Worker{} = worker <- get(worker_id),
         true <- worker.status in [:ready, :busy],
         [] <- Forge.Jobs.running_on(worker_id) do
      {:ok, _worker} = update(worker, %{status: :idle, idle_since: now()})
      :ok
    else
      _other -> :ok
    end
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
  def ready(%Worker{} = worker, report) when is_map(report) do
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
    # here and nowhere else, because this is the only event that proves anything
    # (`docs/design/provisioning.md` § A template that cannot make a working machine is taken
    # out of service).
    Provisioning.succeeded(worker.template_id)

    update(worker, if(is_map(harness), do: Map.put(attrs, :harness, harness), else: attrs))
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
          optional(:harness) => String.t() | nil
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
  @spec assignable(demand(), String.t() | nil) :: Worker.t() | nil
  def assignable(demand, preferred \\ nil) do
    # Idle is the most assignable state there is: it means the machine is up with nothing to
    # do. It is only a step towards destruction if nothing arrives before the period is up.
    candidates =
      from(w in serving(demand[:project_id]),
        where: w.status in [:ready, :busy, :idle],
        order_by: [asc: w.inserted_at]
      )
      |> Repo.all()
      # One pass, and `and` short-circuits: `fits?/2` asks the database what a worker is
      # holding, and a worker nothing can reach is not worth asking about.
      |> Enum.filter(&(connected?(&1.id) and fits?(&1, demand)))

    Enum.find(candidates, &(&1.id == preferred)) || List.first(candidates)
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
    with true <- accepts?(worker, demand.kind),
         true <- runs?(worker, demand[:harness]) do
      {memory, reserved} = promised(worker.id)

      (worker.memory_budget || 0) - memory >= demand.memory and
        room_for_cores?(worker, reserved, demand.cores)
    end
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

  @doc """
  A worker that will take `demand`, or the reason there is not one. A worker being created is
  not an error and not a worker yet: the caller leaves the job pending and asks again on the
  next pass, which is what a queue is.
  """
  @spec provide(demand(), String.t() | nil) ::
          {:ok, Worker.t()} | {:error, :creating | :at_capacity | term()}
  def provide(demand, preferred \\ nil) do
    case assignable(demand, preferred) do
      %Worker{} = worker -> {:ok, worker}
      nil -> create_machine(demand)
    end
  end

  @doc """
  Makes a machine that could hold `demand`, or says why it cannot.

  **A template assigned to the job's project decides what to make**, and the smallest one that
  fits wins (`docs/design/provisioning.md` § Whose account). The machine inherits that
  template's provider, credential, resources and accepted kinds, and counts against that
  template's own `max_workers` rather than one ceiling for the node.

  `:no_template` is not the same answer as `:at_capacity` and the caller must not read them
  alike: at capacity is a queue, and no template is a job that will wait for ever unless
  somebody assigns one.

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
  def create_machine(demand \\ %{kind: :workflow, memory: 0, cores: 0})

  def create_machine(%{project_id: project_id} = demand) when is_binary(project_id) do
    case Provisioning.for_demand(project_id, demand) do
      nil -> no_template(project_id, demand)
      template -> create_from(template)
    end
  end

  # A demand naming no project cannot name a template either. Nothing in the platform builds
  # one — `Jobs.Scheduler` puts `project_id` on every demand and every job has one — so this is
  # the default argument and the tests that use it, and it must not be the one path left that
  # can still make a machine out of node configuration.
  def create_machine(_demand), do: {:error, {:no_template, :none_assigned}}

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

  defp holds_when_empty?(%Worker{} = worker, demand) do
    accepts?(worker, demand.kind) and runs?(worker, demand[:harness]) and
      (worker.memory_budget || 0) >= demand.memory and
      (is_nil(worker.cores) or worker.cores >= demand.cores)
  end

  defp create_from(template) do
    with :ok <- room(template),
         {:ok, credential} <- spendable(template) do
      do_create(
        Provisioning.Template.worker_attrs(template),
        %{size: template.size, image: template.image},
        credential
      )
    end
  end

  defp room(template) do
    if Provisioning.live_count(template) < template.max_workers,
      do: :ok,
      else: {:error, :at_capacity}
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

  defp do_create(attrs, shape, credential) do
    with {:ok, worker, token} <- create(attrs) do
      case Provider.create(machine_opts(worker, token, shape, credential)) do
        {:ok, machine} ->
          {:ok, _worker} = update(worker, %{provider_id: machine.provider_id})
          Logger.info("created worker #{worker.id} (#{machine.provider_id})")
          {:error, :creating}

        {:error, reason} ->
          refused(worker, reason)
      end
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
  Destroys managed workers that have had nothing to do for longer than the idle period: their
  template's `idle_ms`, or the node's `idle_period_ms`, whose default is set from M4's cold
  start (`docs/measurements.md` § M4, `docs/design/worker-tier.md` § Idle destroy).
  """
  @spec sweep_idle() :: non_neg_integer()
  def sweep_idle do
    # **And nothing running on it, whatever its status says.** A status is one write behind the
    # jobs it describes, and destroying a machine under a job leaves that job `running` for ever:
    # nothing re-queues a job whose worker was destroyed rather than lost.
    running = from(j in Job, where: j.worker_id == parent_as(:worker).id and j.status == :running)

    from(w in Worker,
      as: :worker,
      where: w.status == :idle and w.managed and not exists(running),
      preload: [:template]
    )
    |> Repo.all()
    |> Enum.filter(&idle_past?/1)
    |> Enum.count(&(destroy(&1) == :ok))
  end

  # **The period is the machine's own template's, and only then the node's.** One number cannot
  # serve two kinds of machine (`docs/design/provisioning.md` § Lifecycle is per template): an
  # agent box is cheap by the hour and its warm Nix store is worth keeping, while a command
  # machine is expensive by the hour and its warm store is worth *more*, because a cold one
  # re-fetches a whole toolchain over the provider's network rather than over loopback.
  #
  # Filtered in Elixir rather than in the query because the cutoff now differs per row, and a
  # `CASE` that computed it in SQL would put the rule somewhere nobody reads it.
  defp idle_past?(%Worker{idle_since: nil}), do: false

  defp idle_past?(%Worker{} = worker) do
    period =
      case worker.template do
        %{idle_ms: ms} when is_integer(ms) -> ms
        # config.exs always sets `idle_period_ms`, so this fallback is an equivalent mutant under
        # any configured node; it matches that value so removing the line changes nothing.
        _none -> config(:idle_period_ms, :timer.minutes(5))
      end

    DateTime.compare(worker.idle_since, DateTime.add(now(), -period, :millisecond)) == :lt
  end

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
    cutoff = DateTime.add(now(), -config(:worker_timeout_ms, :timer.minutes(3)), :millisecond)

    from(w in Worker, where: w.status != :destroyed)
    |> Repo.all()
    |> Enum.reject(&connected?(&1.id))
    |> Enum.filter(&(DateTime.compare(last_seen(&1), cutoff) == :lt))
    |> Enum.count(&(lose(&1) == :ok))
  end

  # A worker that has never reported is timed from when its row was made: a machine that never
  # finishes booting has to expire too, or a failed create holds the slot for ever.
  defp last_seen(%Worker{last_seen_at: nil, inserted_at: inserted_at}), do: inserted_at
  defp last_seen(%Worker{last_seen_at: last_seen_at}), do: last_seen_at

  # An unmanaged worker is the operator's machine, and it may well come back — a `destroyed` row
  # never can. So it loses its jobs, which are re-runnable and which nothing is observing, and
  # keeps its row. It is not assignable while it is out of touch either way: `assignable/1` asks
  # the registry, not the row.
  defp lose(%Worker{managed: false} = worker) do
    case Forge.Jobs.running_on(worker.id) do
      [] ->
        :skip

      jobs ->
        Logger.warning(
          "worker #{worker.id} is unreachable; re-queueing #{length(jobs)} job(s). It is not " <>
            "the platform's to destroy, so its row stays and it may rejoin."
        )

        Enum.each(jobs, &Forge.Jobs.requeue(&1.id, :worker_lost))
        :ok
    end
  end

  defp lose(%Worker{} = worker) do
    Logger.warning("worker #{worker.id} is unreachable; re-queueing its jobs and destroying it")

    Enum.each(Forge.Jobs.running_on(worker.id), &Forge.Jobs.requeue(&1.id, :worker_lost))
    never_connected(worker)
    destroy(worker)
  end

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
  """
  @spec destroy(Worker.t(), keyword()) :: :ok | {:error, term()}
  def destroy(%Worker{} = worker, opts \\ []) do
    case release_machine(worker) do
      :ok ->
        Logger.info("destroyed worker #{worker.id}")
        with {:ok, _worker} <- update(worker, %{status: :destroyed}), do: :ok

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

        {:ok, _worker} = update(worker, %{status: :destroyed, last_error: message(reason)})
        :ok

      # The operator has looked and said so. It is the only way out of a machine the platform
      # cannot end — a credential that was deleted, a provider that will not answer — and it is
      # deliberately a person's decision, because what it writes down is a claim about the world
      # that the platform could not check.
      {:error, reason} ->
        if Keyword.get(opts, :force, false),
          do: forced(worker, reason),
          else: kept(worker, reason)
    end
  end

  defp forced(worker, reason) do
    message = message(reason)

    Logger.warning(
      "worker #{worker.id} retired by force; the driver refused: #{message}. " <>
        "If the machine is still there it is nobody's now."
    )

    {:ok, _worker} = update(worker, %{status: :destroyed, last_error: message})
    :ok
  end

  # A row that never got a machine has nothing to release. The driver is the one that made it,
  # read from the row and never whichever is configured now — a node that has been reconfigured
  # would otherwise ask the wrong provider to destroy an id that means something else there —
  # and the credential is the machine's own, for the same reason.
  defp release_machine(%Worker{provider_id: nil}), do: :ok

  defp release_machine(%Worker{} = worker),
    do: Provider.destroy(worker.provider, worker.provider_id, credential_secret(worker))

  defp kept(worker, reason) do
    message = message(reason)

    Logger.error(
      "could not destroy worker #{worker.id}'s machine (#{worker.provider} " <>
        "#{worker.provider_id}): #{message}. The row is kept, so the machine is still counted " <>
        "and the next sweep will try again."
    )

    {:ok, _worker} = update(worker, %{last_error: message})
    {:error, reason}
  end

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
