defmodule Forge.Jobs.Scheduler do
  @moduledoc """
  Assigns pending jobs to workers that have room for them, and re-queues jobs left running by
  a previous node on boot. Jobs are rows, so anything may enqueue one; only this process hands
  them out.

  The gate is memory, not a count: a job is assigned only when its slice fits what its worker
  has left, because the tier rests on an out-of-memory build killing one job rather than the
  machine (`docs/design/worker-tier.md` § Scheduling). A job that fits nowhere stays pending
  and is offered again on the next pass; that is a queue, not an error.
  """

  use GenServer

  alias Forge.{Jobs, Projects, Workers}

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one scheduling pass now. Returns how many jobs were assigned."
  @spec tick() :: non_neg_integer()
  def tick, do: GenServer.call(__MODULE__, :tick)

  @impl true
  def init(_opts) do
    # **Recovery is a boot, not a restart.** This used to run here, which meant any crash in a
    # scheduling pass took every *running* conversation with it: the supervisor restarts this
    # process, `recover/0` runs again, and a chat that was mid-reply on a healthy worker goes
    # dormant. A workflow job survived that — it went back to pending and was scheduled again —
    # so the cost was invisible until conversations existed. It is `Forge.Application`'s now, and
    # happens once per node.

    # This is the process that owns the repositories on this node's filesystem, so it is where
    # the generated hooks are brought up to date — a rule that only ever reached repositories
    # created after it was written would not be enforcement at all.
    Projects.ensure_hooks()

    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, assign_pending(), state}

  @impl true
  def handle_info(:tick, state) do
    assign_pending()
    schedule()
    {:noreply, state}
  end

  defp assign_pending do
    slice = Workers.slice_bytes()
    pending = Jobs.pending(Jobs.config(:max_pending_per_pass, 10))

    # First, before anything asks for capacity: a worker the platform cannot reach still counts
    # against `max_workers`, so one machine it has lost track of is one machine's worth of
    # capacity that never comes back — and with `max_workers` at 1, that is a queue that never
    # moves again.
    Workers.sweep_unreachable()

    # Nothing to run is the only moment a machine may be destroyed for being idle: a worker with
    # work is not idle, and one without it has been idle since its last job ended.
    if pending == [], do: Workers.sweep_idle()

    Enum.reduce(pending, 0, fn job, assigned ->
      case Workers.provide(slice) do
        {:ok, worker} -> assigned + assign(job, worker)
        # Being created, or none allowed: the job waits and is offered again next pass.
        {:error, _reason} -> assigned
      end
    end)
  end

  # A job that raises on its way to a worker is one job's problem. Left to crash the scheduler it
  # is every job's and every conversation's, because the restart recovers the node — see `init/1`.
  defp assign(job, worker) do
    do_assign(job, worker)
  rescue
    error ->
      Logger.error("assigning job #{job.id} raised: #{Exception.message(error)}")
      Jobs.fail(job.id, {:assign_raised, Exception.message(error)})
      0
  end

  defp do_assign(job, worker) do
    case Jobs.assign(job, worker) do
      {:ok, _job} ->
        1

      # Not an error the operator needs: a worker that went away between being chosen and
      # being spoken to leaves the job pending, and the next pass finds another.
      {:error, :not_connected} ->
        0

      {:error, reason} ->
        Logger.error("could not assign job #{job.id}: #{inspect(reason)}")
        0
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, Jobs.config(:poll_ms, 2_000))
end
