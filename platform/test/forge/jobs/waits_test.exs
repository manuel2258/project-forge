defmodule Forge.Jobs.WaitsTest do
  @moduledoc """
  `Forge.Jobs.current_wait/1` and `current_waits/1`: why a pending job is waiting, **since it
  last started**. One job's answer and many jobs' answer come from one query shape, so the rule
  that a job which has started again is not waiting cannot hold in one and lapse in the other.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Events, Jobs}

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
