defmodule Forge.Workers do
  @moduledoc """
  Workers: the machines that host jobs. A row exists before its machine does and outlives it,
  so there is never a machine the platform has no record of. See `docs/design/worker-tier.md`.

  A connected worker registers its channel process here. Nothing else knows how to reach one:
  `push/2` is the only way to say something to a worker, and it fails plainly when the
  machine is not there.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Jobs.Job
  alias Forge.Provider
  alias Forge.Repo
  alias Forge.Workers.Worker

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

  @spec list() :: [Worker.t()]
  def list, do: Repo.all(from w in Worker, order_by: w.inserted_at)

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

  @spec update(Worker.t(), map()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def update(%Worker{} = worker, attrs), do: Repo.update(Worker.changeset(worker, attrs))

  @doc "The worker has taken a job on."
  @spec busy(Worker.t()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def busy(%Worker{} = worker), do: update(worker, %{status: :busy, idle_since: nil})

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

  @doc "Records that the worker is up, with the memory it has to give out."
  @spec ready(Worker.t(), non_neg_integer()) :: {:ok, Worker.t()} | {:error, Ecto.Changeset.t()}
  def ready(%Worker{} = worker, memory_budget),
    do: update(worker, %{status: :ready, memory_budget: memory_budget, last_seen_at: now()})

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

  @doc """
  A connected worker with `bytes` of memory to spare, or nil. The rule
  `docs/vision.md` states: a job is admitted only when its slice fits what is left, because
  the tier rests on an out-of-memory build killing one job rather than the machine.
  """
  @spec assignable(non_neg_integer()) :: Worker.t() | nil
  def assignable(bytes) do
    # Idle is the most assignable state there is: it means the machine is up with nothing to
    # do. It is only a step towards destruction if nothing arrives before the period is up.
    from(w in Worker, where: w.status in [:ready, :busy, :idle], order_by: [asc: w.inserted_at])
    |> Repo.all()
    |> Enum.filter(&connected?(&1.id))
    |> Enum.find(&(remaining(&1) >= bytes))
  end

  @doc "Memory not already promised to a job on this worker."
  @spec remaining(Worker.t()) :: integer()
  def remaining(%Worker{} = worker), do: (worker.memory_budget || 0) - promised(worker.id)

  defp promised(worker_id) do
    running =
      Repo.one(
        from j in Job,
          where: j.worker_id == ^worker_id and j.status in [:running, :waiting],
          select: count(j.id)
      )

    running * slice_bytes()
  end

  @doc """
  A worker with room for `bytes`, or the reason there is not one. A worker being created is
  not an error and not a worker yet: the caller leaves the job pending and asks again on the
  next pass, which is what a queue is.
  """
  @spec provide(non_neg_integer()) ::
          {:ok, Worker.t()} | {:error, :creating | :at_capacity | term()}
  def provide(bytes) do
    case assignable(bytes) do
      %Worker{} = worker -> {:ok, worker}
      nil -> create_machine()
    end
  end

  defp create_machine do
    if live_count() < config(:max_workers, 1) do
      with {:ok, worker, token} <- create(%{provider: Provider.name()}),
           {:ok, machine} <- Provider.create(machine_opts(worker, token)),
           {:ok, _worker} <- update(worker, %{provider_id: machine.provider_id}) do
        Logger.info("created worker #{worker.id} (#{machine.provider_id})")
        {:error, :creating}
      end
    else
      {:error, :at_capacity}
    end
  end

  defp machine_opts(worker, token) do
    %{
      worker_id: worker.id,
      token: token,
      platform_url: Forge.Jobs.config(:platform_url, nil) || ForgeWeb.Endpoint.url(),
      harness_env: harness_env(),
      size: config(:machine_size, nil)
    }
  end

  @doc """
  What the machine needs to run an agent at all, as `{name, value}` pairs.

  It is the machine's and not any job's, so it is injected at creation rather than carried in an
  assignment (`docs/design/worker-tier.md` § The worker image), and it is the same environment
  the platform read for itself while it still ran jobs. `executable` is deliberately not here:
  it is a path on this host, and the worker image has its own.

  Public because `mix forge.worker.new` mints the environment for a machine the operator is
  provisioning by hand, and that machine needs exactly what the driver would have given it. A
  worker minted without this joins and reports `ready` and then fails every job with *Not logged
  in* — see § Managed and unmanaged.
  """
  def harness_env do
    opts = Forge.Jobs.config(:harness_opts, [])

    credential =
      case Keyword.get(opts, :credential) do
        {:api_key, value} -> [{"ANTHROPIC_API_KEY", value}]
        {:oauth, value} -> [{"CLAUDE_CODE_OAUTH_TOKEN", value}]
        _other -> []
      end

    model =
      case Keyword.get(opts, :model) do
        model when is_binary(model) -> [{"FORGE_CLAUDE_MODEL", model}]
        _other -> []
      end

    credential ++ model
  end

  defp live_count do
    Repo.one(from w in Worker, where: w.status != :destroyed, select: count(w.id))
  end

  @doc """
  Destroys workers that have had nothing to do for longer than the idle period. The default
  is a guess: `docs/poc-plan.md` takes it from M4, and M4 cannot run until this milestone
  exists (`docs/design/worker-tier.md` § Idle destroy).
  """
  @spec sweep_idle() :: non_neg_integer()
  def sweep_idle do
    cutoff = DateTime.add(now(), -config(:idle_period_ms, :timer.minutes(10)), :millisecond)

    from(w in Worker, where: w.status == :idle and w.managed and w.idle_since < ^cutoff)
    |> Repo.all()
    |> Enum.count(&(destroy(&1) == :ok))
  end

  @doc """
  Destroys workers the platform cannot reach any more. `docs/design/worker-channel.md` § When
  the machine goes away: past the timeout the platform stops waiting — it re-queues that
  worker's running jobs, asks the driver to destroy the machine and marks the row. Destroying a
  machine that is merely partitioned is the right trade, because the jobs are re-runnable by
  construction and a worker nobody can reach is doing nothing that can be observed or billed.

  A row left behind is not cosmetic. `max_workers` counts every row that is not `destroyed`, so
  one machine the platform has lost track of is one machine's worth of capacity that never comes
  back, and with `max_workers` at 1 that is all of it.
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
    destroy(worker)
  end

  @doc "Destroys a worker's machine and records that it is gone."
  @spec destroy(Worker.t()) :: :ok | {:error, term()}
  def destroy(%Worker{} = worker) do
    if worker.provider_id, do: Provider.destroy(worker.provider_id)
    Logger.info("destroyed worker #{worker.id}")
    with {:ok, _worker} <- update(worker, %{status: :destroyed}), do: :ok
  end

  @doc """
  What one job is allowed to use. M3's observed peak plus its margin, carried as a default
  until the operator's own project replaces it (`docs/measurements.md` § M3).
  """
  @spec slice_bytes() :: pos_integer()
  # 2009 MiB observed, times the 1.1 margin, rounded up to 2210 MiB.
  def slice_bytes, do: config(:slice_bytes, 2210 * 1024 * 1024)

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  defp hash(token), do: Base.encode16(:crypto.hash(@hash_algorithm, token), case: :lower)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
