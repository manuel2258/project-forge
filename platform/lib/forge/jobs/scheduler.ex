defmodule Forge.Jobs.Scheduler do
  @moduledoc """
  Assigns pending jobs to workers that have room for them, and re-queues jobs left running by
  a previous node on boot. Jobs are rows, so anything may enqueue one; only this process hands
  them out.

  The gate is what the job asked for, not a count: a job is assigned only when its memory and
  cores fit what a worker has left and the worker takes its kind, because the tier rests on an
  out-of-memory build killing one job rather than the machine (`docs/design/provisioning.md`
  § The gate). A job that fits nowhere now stays pending and is offered again on the next pass;
  that is a queue, not an error, and it says why — once each time the reason changes, not once
  per pass. One that no assigned template could ever hold sticks its ticket.
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
    # against its template's `max_workers`, so one machine it has lost track of is one machine's
    # worth of capacity that never comes back — and with a template's `max_workers` at 1, that
    # is a queue that never moves again.
    Workers.sweep_unreachable()

    # The claims are what the jobs so far in this pass were pointed at on machines still booting,
    # so the next job does not count on the same room (`Workers.provide/3`). They start empty
    # every pass: the jobs keep their order, so each pass divides the machines the same way.
    {assigned, _claims} = Enum.reduce(pending, {0, %{}}, &offer/2)

    # **After the pass, not before it, and whatever is still pending.** Before it, the sweep
    # destroyed the very machine the pass was about to use — a machine that has just finished one
    # job and has another waiting is idle for the moment between them. So it was gated on nothing
    # being pending at all, and that gate let one job nobody can place keep every idle machine on
    # the node alive: a conversation in a project with no template waits for ever, and so does a
    # job waiting for its credentials' limits to reset, which could be a week
    # (`docs/design/credentials.md` § A limit reached mid-run). After the pass, a machine that was
    # given work is busy and out of the sweep's reach, and one that was not is idle by any measure.
    Workers.sweep_idle()

    assigned
  end

  defp offer(job, {assigned, claims}) do
    # **The credential before the machine.** A job nothing can fund does not ask for capacity,
    # so an empty pool never makes a machine that could run nothing — the loop a disabled
    # template exists to stop, arriving by another door (`docs/design/credentials.md` § How a
    # job picks). `Jobs.assign/2` resolves it again, which is the answer that counts; this one
    # only decides whether to go looking for a machine at all.
    demand = demand(job)

    with {:ok, _credential} <- Credentials.for_job(job),
         {:ok, worker} <- Workers.provide(demand, job.worker_id, claims) do
      {assigned + assign(job, worker), claims}
    else
      # A machine is being made that will hold it: this one, or one an earlier pass asked for.
      {:creating, worker} ->
        wait(job, :creating)
        {assigned, claim(claims, worker.id, demand)}

      # Nothing in the project's pool can pay for this job: a person has to assign one, which
      # brings the ticket back by itself (`Engine.resume_placement/2`).
      {:error, {:no_credential, why}} ->
        stick(job, {:no_credential, why})
        {assigned, claims}

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
        {assigned, claims}

      # At capacity, or refused by the driver: the job waits and is offered again
      # next pass, and the pass continues to the jobs behind it. A large job can therefore be
      # jumped by small ones indefinitely, which `docs/design/provisioning.md` § The gate
      # records rather than solves — the fix is an age-based reservation and the scheduler has
      # no priority. What it does now is say why, which it used to drop on the floor.
      #
      # So does a job whose every credential is rate-limited, `{:limited, until}`: time
      # resolves that, not a person, so the ticket stays active and nothing is created for it
      # (`docs/design/credentials.md` § How a job picks).
      {:error, reason} ->
        wait(job, reason)
        {assigned, claims}
    end
  end

  defp claim(claims, worker_id, %{memory: memory, cores: cores}),
    do: Map.update(claims, worker_id, {memory, cores}, fn {m, c} -> {m + memory, c + cores} end)

  # A chat is not the ticket's work, so a chat that cannot be placed sticks nothing — not even a
  # ticket chat's ticket, whose own jobs may place perfectly well (a template can take workflow
  # jobs and refuse chats). It stays pending and says why on its own page, in the sentence the
  # ticket would have been stuck with; nothing puts it in the queue, which is the gap
  # `docs/design/provisioning.md` § The gate records.
  defp stick(%{kind: :chat} = job, why), do: wait(job, why)

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

  # Big enough *and* taking this kind: `Provisioning.could_ever_hold?/2` asks both, and a template
  # that refuses chats is this answer for a chat however large it is.
  defp reason({:no_template, :none_fit}),
    do:
      "no worker template assigned to this project both takes this kind of job and is big " <>
        "enough for it"

  defp reason({:no_credential, :none_assigned}),
    do:
      "no credential is assigned to this project, so nothing can pay for its jobs; " <>
        "a credential's owner assigns one to it from their account settings"

  # Why a job the pass could not place is still pending: the code `Jobs.record_wait/3` compares,
  # and the sentence drawn under the job (`docs/design/ui.md` § A job waiting for a machine).
  defp wait(job, reason) do
    {code, text} = waiting(reason)
    Jobs.record_wait(job, code, text)
  end

  defp waiting(:creating), do: {"creating", "Waiting for a machine: one is being made for it."}

  # A template at its `max_workers` — whose machines may be busy, still booting, or holding a
  # slot after a failed create until the sweep retires them — or a machine that could take it
  # once it is free.
  defp waiting(:at_capacity),
    do:
      {"at_capacity",
       "Waiting for room: the machines that could take it are busy or still starting, and no " <>
         "more may be made."}

  # The platform refused before any driver was asked: the template's provider credential is not
  # one its owner may spend. No worker row was written, so the workers page has nothing to say;
  # the words are the template's `last_error`, which the templates page draws
  # (`docs/design/provisioning.md` § The gate). Before the clause below, which would otherwise
  # send the operator to the wrong page.
  defp waiting({:create_failed, {:credential, _message}}),
    do:
      {"credential_refused",
       "Waiting for a machine: the template it would be made from names a provider credential " <>
         "it may not spend, and the templates page of whoever owns the template says why."}

  # The driver's own words are on the worker row it refused (`Workers.create_machine/1`), which
  # the workers page draws.
  defp waiting({:create_failed, _reason}),
    do:
      {"create_failed",
       "Waiting for a machine: the provider refused to make one, and the workers page of " <>
         "whoever owns the template says why."}

  # Only a chat reaches these two: anything else sticks its ticket instead (`stick/2`).
  defp waiting({:no_template, why} = refusal),
    do: {Atom.to_string(why), "Waiting for a template: " <> reason(refusal) <> "."}

  defp waiting({:no_credential, _why} = refusal),
    do: {"no_credential", "Waiting for a credential: " <> reason(refusal) <> "."}

  # Every credential in the pool is rate-limited, and time resolves it
  # (`docs/design/credentials.md` § How a job picks). **No reset time in it**: a reason is
  # recorded once, when it changes, and the soonest reset moves while the reason stays `limited`
  # — another window blocking once the first resets — so a time here would go stale on the page.
  defp waiting({:limited, _until}),
    do:
      {"limited",
       "Waiting for a limit to reset: every credential this project may use is rate-limited."}

  defp waiting({:spend_paused, :day}),
    do: {"spend_paused", "Waiting for midnight UTC: the node has spent its daily cap."}

  # **An equivalent mutant, for what reaches it today.** `wait/2` has two callers. `offer/2` passes
  # what `Workers.provide/2` refused, which is only the refusals above and, in principle, a
  # changeset from `Workers.create/1` — which a template's own values cannot fail, since its
  # changeset already requires the provider and positive memory and cores. `do_assign/2` passes
  # only `{:spend_paused, :day}`. `Jobs.assign/2`'s other refusals — `{:spend_exhausted, :ticket}`,
  # a token or a row that could not be written — are deliberately not waits and never come here;
  # routed here, the allowance would read "unexplained" under a ticket that is stuck for it, which
  # is what "a ticket over its allowance is stuck, and its job records no wait" in
  # `Forge.FlowTest` refuses. This clause is so that a refusal nobody named is recorded rather
  # than crashing the pass, and a test for it would have to invent the refusal.
  defp waiting(other),
    do:
      {"unexplained",
       "Waiting, for a reason with no sentence yet: " <> String.slice(inspect(other), 0, 200)}

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
      # being spoken to leaves the job pending, and the next pass finds another. Not recorded
      # as a wait either — it is a race the next pass routes around, not a reason anyone can act
      # on, and one that flapped pass to pass would be noise with the look of a signal.
      #
      # **An equivalent mutant as far as a test can reach.** Without this clause the one below
      # answers the same `0` and only logs louder; with a wait recorded here instead, nothing
      # observes it unless the channel drops between `Workers.provide/2` finding the worker
      # connected and `Jobs.assign/2` pushing to it, which is two calls apart in this process and
      # has no seam a test can hold open.
      {:error, :not_connected} ->
        0

      # Moved by somebody else since the pass read it — a conversation closed meanwhile. There is
      # nothing left to place. An equivalent mutant: without it the clause below answers the same
      # `0` and only logs an error for a race that is not one.
      {:error, {:changed, _now}} ->
        0

      # The daily cap, asked only once a worker was found: the job waits for midnight, and says
      # so once rather than on every pass (`docs/design/provisioning.md` § The gate). The ticket
      # allowance is the other cap and sticks the ticket, which is its own record.
      {:error, {:spend_paused, :day} = reason} ->
        wait(job, reason)
        0

      {:error, reason} ->
        Logger.error("could not assign job #{job.id}: #{inspect(reason)}")
        0
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, Jobs.config(:poll_ms, 2_000))
end
