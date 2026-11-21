defmodule Forge.Events.RetentionTest do
  @moduledoc """
  What `docs/design/storage.md` § Retention says is kept and swept, checked at the sweep and at the
  database. Not async: the retention period is configuration, which every test shares.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.Events
  alias Forge.Events.{Event, Retention}
  alias Forge.Jobs

  # Every harness type the sweep may take and every one it may not, with a lifecycle event beside
  # each: the test is that the first group goes and nothing else.
  @swept ~w(tool_use tool_result notice retry starting correction unknown malformed control)
  @kept ~w(text delivered started finished rate_limit memory)
  @lifecycle ~w(job.created job.finished job.started transition.taken approval.granted
                ticket.noted merge_queue.queued chat.message chat.turn step.accepted)

  setup do
    previous = Application.get_env(:forge, Retention)
    on_exit(fn -> Application.put_env(:forge, Retention, previous) end)
    :ok
  end

  defp ended(status \\ :finished, days_ago, ticket \\ nil) do
    ticket = ticket || ticket_fixture()
    job = job_fixture(%{ticket: ticket})
    at = DateTime.utc_now() |> DateTime.add(-days_ago * 86_400 - 60) |> DateTime.truncate(:second)
    outcome = if status == :finished, do: %{outcome: :converged}, else: %{}

    job
    |> Jobs.Job.progress_changeset(Map.merge(outcome, %{status: status, finished_at: at}))
    |> Repo.update!()
  end

  defp record(job, type) do
    {:ok, event} =
      Events.append(type, {:job, job.id}, %{
        ticket_id: job.ticket_id,
        job_id: job.id,
        payload: %{"x" => 1}
      })

    event
  end

  defp fill(job) do
    for type <- @lifecycle ++ Enum.map(@kept ++ @swept, &"job.harness.#{&1}"),
        do: record(job, type)
  end

  defp types(job), do: job.id |> Events.for_job() |> Enum.map(& &1.type) |> Enum.sort()

  defp harness(types), do: Enum.map(types, &"job.harness.#{&1}")

  describe "the sweep" do
    test "takes the swept harness types of a job that ended past the period, and nothing else" do
      job = ended(31)
      fill(job)

      assert {n, 1} = Retention.sweep()
      assert n == length(@swept)

      # `job.swept` is the sweep's own record, in the place of what it removed.
      assert types(job) ==
               Enum.sort(@lifecycle ++ harness(@kept) ++ ["job.swept"])
    end

    test "records what it removed on the job and once for the run" do
      job = ended(31)
      fill(job)

      {rows, 1} = Retention.sweep()

      assert %Event{payload: %{"removed" => ^rows, "days" => 30, "ended" => ended}} =
               Events.latest_for_job(job.id, "job.swept")

      # The day the job ended, not the day it was swept: the line says "N days after this job ended".
      assert ended == DateTime.to_iso8601(job.finished_at)

      assert %Event{payload: %{"removed" => ^rows, "jobs" => 1, "days" => 30, "cutoff" => _}} =
               Events.latest_for_node("events.swept")
    end

    test "a run that removed nothing is still recorded, with no payload but counts and dates" do
      assert {0, 0} = Retention.sweep()

      assert %Event{payload: payload} = Events.latest_for_node("events.swept")
      assert Map.keys(payload) |> Enum.sort() == ~w(cutoff days jobs removed)
      assert %{"removed" => 0, "jobs" => 0} = payload
    end

    test "a job that ended 29 days ago keeps every event" do
      job = ended(29)
      fill(job)
      before = types(job)

      assert {0, 0} = Retention.sweep()
      assert types(job) == before
    end

    test "the period is configuration" do
      Application.put_env(:forge, Retention, days: 7)
      week = ended(8)
      fresh = ended(6)
      fill(week)
      fill(fresh)

      assert {_n, 1} = Retention.sweep()
      assert "job.harness.tool_use" in types(fresh)
      refute "job.harness.tool_use" in types(week)
      assert %{payload: %{"days" => 7}} = Events.latest_for_job(week.id, "job.swept")
    end

    test "a hibernated job is swept, one still going is not, whatever its age" do
      hibernated = ended(:hibernated, 40)
      fill(hibernated)

      for status <- [:pending, :running, :waiting, :parked] do
        job = ended(status, 400)
        fill(job)
        before = types(job)
        send(self(), {:kept, job, before})
      end

      assert {_n, 1} = Retention.sweep()
      refute "job.harness.tool_use" in types(hibernated)

      for _status <- 1..4 do
        assert_received {:kept, job, before}
        assert types(job) == before
      end
    end

    test "a job reopened after it was swept records again and is not swept while it is live" do
      job = ended(31)
      fill(job)
      {_n, 1} = Retention.sweep()

      {:ok, job} =
        job |> Jobs.Job.progress_changeset(%{status: :running, outcome: nil}) |> Repo.update()

      record(job, "job.harness.tool_use")

      assert {0, 0} = Retention.sweep()
      assert "job.harness.tool_use" in types(job)

      # Ended again, it ages from its new `finished_at`: not yet.
      {:ok, _job} =
        job
        |> Jobs.Job.progress_changeset(%{
          status: :finished,
          outcome: :converged,
          finished_at: DateTime.utc_now(:second)
        })
        |> Repo.update()

      assert {0, 0} = Retention.sweep()
      assert "job.harness.tool_use" in types(job)
    end

    test "what is read after a job ends survives" do
      job = ended(31)
      fill(job)
      Retention.sweep()

      for type <- @kept, do: assert("job.harness.#{type}" in types(job))
      assert Events.latest_for_job(job.id, "job.harness.rate_limit")
      assert Events.latest_for_job(job.id, "job.harness.text")
    end
  end

  describe "the database" do
    test "refuses to delete a lifecycle event or a kept harness type, and every update" do
      job = ended(31)

      for type <- @lifecycle ++ harness(@kept) do
        event = record(job, type)

        assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
          Repo.delete!(event)
        end
      end

      event = record(job, "job.harness.tool_use")
      assert {:ok, _} = Repo.delete(event)

      # Every update is refused, of a swept type as of a kept one and of a lifecycle event.
      for type <- @lifecycle ++ harness(@kept ++ @swept) do
        event = record(job, type)

        assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
          Repo.update!(Ecto.Changeset.change(event, payload: %{"tampered" => true}))
        end
      end
    end

    test "says which types are swept in one place" do
      for type <- harness(@swept), do: assert(swept?(type), type)
      for type <- harness(@kept) ++ @lifecycle, do: refute(swept?(type), type)
      refute swept?("job.harnessed")
    end
  end

  describe "a thinking_tokens notice" do
    setup do
      %{job: job_fixture()}
    end

    test "is refused, and no event or broadcast is made of it", %{job: job} do
      Events.subscribe_job(job.id)

      assert :ok =
               Jobs.record_harness_event(job.id, %{
                 type: "job.harness.notice",
                 payload: %{subtype: "thinking_tokens", raw: %{}}
               })

      assert [] = Events.for_job(job.id)
      refute_received {:job_event, _id, _event}
    end

    test "any other notice is recorded as it was", %{job: job} do
      assert :ok =
               Jobs.record_harness_event(job.id, %{
                 type: "job.harness.notice",
                 payload: %{subtype: "plugin_install"}
               })

      assert [%{type: "job.harness.notice", payload: %{"subtype" => "plugin_install"}}] =
               Events.for_job(job.id)
    end
  end

  defp swept?(type) do
    %{rows: [[swept]]} = Repo.query!("SELECT forge_event_swept($1)", [type])
    swept
  end
end
