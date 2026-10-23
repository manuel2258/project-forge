defmodule Forge.Jobs.WaitsTest do
  @moduledoc """
  The two batched reads the Queue's *under way* group makes about a job's current state.

  `Forge.Jobs.current_wait/1` and `current_waits/1`: why a pending job is waiting, **since it
  last started**. One job's answer and many jobs' answer come from one query shape, so the rule
  that a job which has started again is not waiting cannot hold in one and lapse in the other.

  `Forge.Jobs.Runs.started/1`: when the run a job is in began — which `jobs.started_at` stops
  answering after the first one.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Events, Jobs}
  alias Forge.Jobs.{Job, Run, Runs}

  defp worker! do
    {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
    worker
  end

  defp started(job) do
    {:ok, _event} =
      Events.append("job.started", :system, %{ticket_id: job.ticket_id, job_id: job.id})

    :ok
  end

  test "a wait recorded before the job last started is not the current one" do
    job = job_fixture()
    :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: ...")

    assert Jobs.current_wait(job).payload["reason"] == "at_capacity"
    assert %{} = Map.fetch!(Jobs.current_waits([job.id]), job.id)

    # It ran, which ends the wait: what held it up before is history, not why it is pending now.
    started(job)

    assert Jobs.current_wait(job) == nil
    assert Jobs.current_waits([job.id]) == %{}
  end

  # The other half of the contract, stated in bold in the doc and until now untested: a job that
  # is not pending is not waiting, whatever its log holds. A job can leave the queue without
  # starting again — the scheduler fails one that raised on its way to a worker — and its last
  # wait is then not why it is anything.
  test "a job that is not pending is not waiting, whatever its log holds" do
    job = job_fixture()
    :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: ...")
    assert Jobs.current_wait(job).payload["reason"] == "at_capacity"

    {:ok, running} = Repo.update(Job.progress_changeset(job, %{status: :running}))

    assert Jobs.current_wait(running) == nil
  end

  # `Runs.started/1` is the other batched read the queue's group makes, and the one that answers
  # *when the run it is in began* — the question `jobs.started_at` answers wrongly from the second
  # run on. A job with no open run has no key, which is what the caller's fallbacks are for.
  test "started/1 is the open run's start, per job, and nothing else" do
    worker = worker!()
    ran = job_fixture()
    running = job_fixture()
    never = job_fixture()

    first = DateTime.add(DateTime.utc_now(:second), -600, :second)
    now = DateTime.utc_now(:second)

    Repo.insert!(%Run{job_id: ran.id, worker_id: worker.id, started_at: first, finished_at: now})

    Repo.insert!(%Run{
      job_id: running.id,
      worker_id: worker.id,
      started_at: first,
      finished_at: now
    })

    Repo.insert!(%Run{job_id: running.id, worker_id: worker.id, started_at: now})

    started = Runs.started([ran.id, running.id, never.id])

    assert started == %{running.id => now}
  end

  test "many jobs at once, each its own latest reason" do
    room = job_fixture()
    limited = job_fixture()
    ran = job_fixture()

    :ok = Jobs.record_wait(room, "at_capacity", "Waiting for room: ...")
    :ok = Jobs.record_wait(limited, "spend_paused", "Waiting for midnight UTC: ...")
    :ok = Jobs.record_wait(limited, "limited", "Waiting for a limit to reset: ...")
    :ok = Jobs.record_wait(ran, "at_capacity", "Waiting for room: ...")
    started(ran)

    waits = Jobs.current_waits([room.id, limited.id, ran.id])

    assert waits[room.id].payload["reason"] == "at_capacity"
    assert waits[limited.id].payload["reason"] == "limited"
    refute Map.has_key?(waits, ran.id)
  end
end
