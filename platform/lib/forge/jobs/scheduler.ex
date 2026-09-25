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

  alias Forge.{Credentials, Engine, Jobs, Projects, Tickets, Workers}

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
    pending = Jobs.pending(Jobs.config(:max_pending_per_pass, 10))

    # First, before anything asks for capacity: a worker the platform cannot reach still counts
    # against `max_workers`, so one machine it has lost track of is one machine's worth of
    # capacity that never comes back — and with `max_workers` at 1, that is a queue that never
    # moves again.
    Workers.sweep_unreachable()

    # Nothing to run is the only moment a machine may be destroyed for being idle: a worker with
    # work is not idle, and one without it has been idle since its last job ended. A job waiting
    # for its credentials' limits to reset is not something to run — it could wait a week, and
    # would keep every idle machine on the node alive while it did
    # (`docs/design/credentials.md` § A limit reached mid-run).
    if Enum.all?(pending, &waiting_for_reset?/1), do: Workers.sweep_idle()

    Enum.reduce(pending, 0, fn job, assigned ->
      # **The credential before the machine.** A job nothing can fund does not ask for capacity,
      # so an empty pool never makes a machine that could run nothing — the loop a disabled
      # template exists to stop, arriving by another door (`docs/design/credentials.md` § How a
      # job picks). `Jobs.assign/2` resolves it again, which is the answer that counts; this one
      # only decides whether to go looking for a machine at all.
      with {:ok, _credential} <- Credentials.for_job(job),
           {:ok, worker} <- Workers.provide(demand(job), job.worker_id) do
        assigned + assign(job, worker)
      else
        # Nothing in the project's pool can pay for this job: a person has to assign one, which
        # brings the ticket back by itself (`Engine.resume_placement/2`).
        {:error, {:no_credential, why}} ->
          stick(job, {:no_credential, why})
          assigned

        # **No template can make this job a machine**, which is a different answer from "not
        # right now" and must not be queued as one: the ticket sticks with the reason, through
        # the mechanism an exhausted allowance already uses
        # (`docs/design/provisioning.md` § The gate). A job queued for ever against capacity
        # that will never exist is the failure this distinction prevents.
        #
        # Three of them, because what the operator does about each is different and a single
        # sentence would send them at the wrong thing. Only `:at_capacity` below is a queue.
        {:error, {:no_template, why}} ->
          stick(job, {:no_template, why})
          assigned

        # Being created, none allowed, or none that will take this kind: the job waits and is
        # offered again next pass, and the pass continues to the jobs behind it. A large job can
        # therefore be jumped by small ones indefinitely, which
        # `docs/design/provisioning.md` § The gate records rather than solves — the fix is an
        # age-based reservation and the scheduler has no priority.
        #
        # So does a job whose every credential is rate-limited, `{:limited, until}`: time
        # resolves that, not a person, so the ticket stays active and nothing is created for it
        # (`docs/design/credentials.md` § How a job picks).
        {:error, _reason} ->
          assigned
      end
    end)
  end

  defp waiting_for_reset?(job), do: match?({:error, {:limited, _until}}, Credentials.for_job(job))

  # A chat has no ticket to stick, and a chat that cannot be placed is a chat that stays
  # dormant — visible as such on the page it was opened from.
  defp stick(%{ticket_id: nil}, _why), do: :ok

  defp stick(job, why) do
    ticket = Tickets.get!(job.ticket_id)

    if ticket.status == :active do
      Logger.warning("#{inspect(why)} for job #{job.id}; sticking ticket #{ticket.number}")

      # A placement stick, which an assignment to the project brings back (`Engine.resume_placement/2`).
      Engine.stick(ticket, reason(why), :placement)
    end

    :ok
  end

  # What the operator has to do about it, in the sentence they will read on the ticket.
  defp reason({:no_template, :none_assigned}),
    do:
      "no worker template is assigned to this project, so there is nothing to make a machine from"

  defp reason({:no_template, :all_disabled}),
    do:
      "every worker template assigned to this project is disabled after failing to make a machine"

  defp reason({:no_template, :none_fit}),
    do: "no worker template assigned to this project is big enough for this job"

  defp reason({:no_credential, :none_assigned}),
    do:
      "no credential is assigned to this project, so nothing can pay for its jobs; " <>
        "a credential's owner assigns one to it from their account settings"

  # What this job was admitted with, resolved at creation and written on the row
  # (`docs/design/provisioning.md` § What a job asks for). The fallbacks are for rows that
  # predate the columns: they were admitted under the single slice and are placed under it.
  #
  # `project_id` rides along because creating a machine is a decision about *whose* templates
  # may be used, which is a property of the project and not of the job's size.
  defp demand(job) do
    %{
      kind: job.kind,
      memory: job.memory_max || Workers.slice_bytes(),
      cores: job.cores || Workers.default_cores(),
      project_id: job.project_id,
      harness: Jobs.harness(job)
    }
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
