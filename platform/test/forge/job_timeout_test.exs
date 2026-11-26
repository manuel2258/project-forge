defmodule Forge.JobTimeoutTest do
  @moduledoc """
  How long one run of an agent job may take (`docs/design/workflow-grammar-v1.md` § Timeout): the
  figure a job is made with, what a run is assigned, what an extension gives it, and how a run that
  passes it is recorded.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, Events, FakeWorker, Jobs, Operator, Repo, Tickets}
  alias Forge.Jobs.{Extensions, Job}
  alias ForgeCore.Job.Spec

  # `implementing` names its own, `reviewing` takes the workflow's default.
  @workflow """
  version: 1
  initial: implementing
  defaults:
    timeout: 90m
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md]
      budget: { turns: 150, tokens: 12M }
      timeout: 3h
    reviewing:
      prompt: agents/review.md
      inputs: [implementation.md]
      produces: [review.md]
      budget: { turns: 60, tokens: 600k }
    review_ready: {}
  transitions:
    - { from: implementing, to: reviewing }
    - { from: reviewing, to: review_ready }
  limits:
    ticket_tokens: 100M
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/agents/review.md" => "Review the change.\n"
      })

    {:ok, project} =
      register_owned!(%{name: "timeout-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    worker = FakeWorker.connect()

    %{ticket: ticket, user: user, project: project, worker: worker}
  end

  defp pending(ticket) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    job
  end

  # A run that the time limit stopped and that left its session: what the worker reports is
  # `killed`/`exhausted: :wall_clock`, whatever the platform then calls it.
  defp run_out_of_time(ticket, worker) do
    assignment = ticket |> pending() |> FakeWorker.assign(worker)

    result =
      assignment
      |> FakeWorker.result("max_turns", written: %{})
      |> then(fn result ->
        %{
          result
          | outcome: :budget_exhausted,
            exhausted: :wall_clock,
            killed: :wall_clock,
            harness:
              Map.merge(result.harness, %{
                "session_id" => "sess-42",
                "session_blob" => assignment["store"]["session_prefix"] <> "1.jsonl",
                "version" => "2.1.284"
              })
        }
      end)

    {:ok, job} = Jobs.complete(assignment["job_id"], result)
    {Tickets.get!(ticket.id), Jobs.get!(job.id), assignment}
  end

  describe "what a job is made with" do
    test "its state's timeout, else the workflow's default, is in its spec", context do
      %{ticket: ticket, worker: worker} = context

      assert Jobs.spec(pending(ticket)).budget.timeout_ms == 10_800_000

      {:ok, _} =
        ticket |> pending() |> FakeWorker.run(worker, "success", doc: "implementation.md")

      assert Jobs.spec(pending(ticket)).budget.timeout_ms == 5_400_000
    end

    test "the run is assigned it, under the wire's old name, and the manifest says it", context do
      %{ticket: ticket, worker: worker} = context
      assignment = ticket |> pending() |> FakeWorker.assign(worker)

      assert assignment["wall_clock_ms"] == 10_800_000
      assert assignment["spec"]["budget"]["timeout_ms"] == 10_800_000

      manifest = ForgeCore.Prompt.manifest(Spec.from_map(assignment["spec"]), "/j")
      assert manifest =~ "- Time: 3h per run; the run is stopped when it passes it"
    end

    test "a job made before the key existed runs on the engine's two hours", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      spec = update_in(job.spec, ["budget"], &Map.delete(&1, "timeout_ms"))
      {1, _} = Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [spec: spec])

      assignment = FakeWorker.assign(Jobs.get!(job.id), worker)
      assert assignment["wall_clock_ms"] == 7_200_000
      # The manifest is told the figure the worker enforces, not nothing.
      assert assignment["spec"]["budget"]["timeout_ms"] == 7_200_000
    end

    test "a re-pin does not move the limit of a job that exists", context do
      %{ticket: ticket, user: user, project: project, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      commit_to_default(project, %{
        ".forge/workflow.yml" => String.replace(@workflow, "timeout: 3h", "timeout: 5h")
      })

      {:ok, repinned} = Engine.repin(ticket, user.id)
      assert repinned.workflow_commit != ticket.workflow_commit

      # The extended run is the same job, made with three hours: an empty box gives it its own
      # limit, which the new pin's five hours do not reach.
      {:ok, _} = Operator.extend(repinned, user, job.id, %{"tokens" => "6M"})
      assignment = repinned |> pending() |> FakeWorker.assign(worker)
      assert assignment["wall_clock_ms"] == 10_800_000
      assert [%{timeout_ms: 10_800_000}] = Extensions.all(job.id)
    end
  end

  describe "per run" do
    test "a run that returns to the queue starts its next run with the full limit", context do
      %{ticket: ticket, worker: worker} = context
      job = pending(ticket)
      first = FakeWorker.assign(job, worker)
      assert first["wall_clock_ms"] == 10_800_000

      {:ok, _} = Jobs.requeue(job.id, :worker_lost)
      second = FakeWorker.assign(Jobs.get!(job.id), worker)
      assert second["wall_clock_ms"] == 10_800_000
    end
  end

  describe "a run that passes it" do
    test "is recorded as timeout, in the row and in the event, and the engine's word stays off it",
         context do
      %{ticket: ticket, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      assert %Job{status: :finished, outcome: :budget_exhausted, exhausted: :timeout} = job
      assert %{status: :stuck} = ticket

      assert [%{payload: payload}] =
               ticket.id
               |> Events.for_ticket()
               |> Enum.filter(&(&1.type == "job.finished" and &1.job_id == job.id))

      assert payload["exhausted"] == "timeout"
      assert payload["killed"] == "timeout"
    end

    test "an extension is told the worker's word for it, which the prompt already reads",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => "4h"})
      assert [%{exhausted: :timeout}] = Extensions.all(job.id)

      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["spec"]["extension"]["exhausted"] == "wall_clock"
    end
  end

  describe "an extension's time" do
    test "left empty, it records the job's own limit, and the extended run gets it", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M"})

      assert [%{timeout_ms: 10_800_000}] = Extensions.all(job.id)
      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["wall_clock_ms"] == 10_800_000
    end

    test "a given time is recorded, logged, assigned and printed, and every later run keeps it",
         context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => "1000h"})

      assert [%{timeout_ms: 3_600_000_000}] = Extensions.all(job.id)

      assert [%{payload: %{"timeout_ms" => 3_600_000_000}}] =
               ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "job.extended"))

      first = ticket |> pending() |> FakeWorker.assign(worker)
      assert first["wall_clock_ms"] == 3_600_000_000
      assert first["spec"]["budget"]["timeout_ms"] == 3_600_000_000

      manifest = ForgeCore.Prompt.manifest(Spec.from_map(first["spec"]), "/j")
      assert manifest =~ "- Time: 1000h per run"

      # A resume after a rate limit, a question or a park is another run of the same job: it is
      # given the extension's time again, not the state's.
      {:ok, _} = Jobs.requeue(job.id, :worker_lost)
      later = FakeWorker.assign(Jobs.get!(job.id), worker)
      assert later["wall_clock_ms"] == 3_600_000_000
      assert later["spec"]["budget"]["timeout_ms"] == 3_600_000_000
    end

    test "the second extension's time replaces the first's", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)
      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => "4h"})
      {ticket, job, _assignment} = run_out_of_time(Tickets.get!(ticket.id), worker)
      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => "90m"})

      assert Jobs.timeout_ms(Jobs.get!(job.id)) == 5_400_000
    end

    test "Run again has no time box: the new job runs on the state's own limit", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)
      {:ok, _} = Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => "1000h"})
      {ticket, _job, _assignment} = run_out_of_time(Tickets.get!(ticket.id), worker)

      {:ok, _} = Operator.retry(ticket, user, note: "again")
      assignment = ticket |> pending() |> FakeWorker.assign(worker)
      assert assignment["wall_clock_ms"] == 10_800_000
    end

    test "a malformed, zero or too long time is refused and writes nothing", context do
      %{ticket: ticket, user: user, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)

      for bad <- ["abc", "0", "0h", "1h30m", "-3h", "1000001h", "3 hours"] do
        assert {:error, {:invalid_timeout, ^bad}} =
                 Operator.extend(ticket, user, job.id, %{"tokens" => "6M", "timeout" => bad})
      end

      assert Extensions.all(job.id) == []
      assert %{status: :stuck} = Tickets.get!(ticket.id)
    end

    test "the offer carries the job's own limit, for the box to start at", context do
      %{ticket: ticket, worker: worker} = context
      {ticket, _job, _assignment} = run_out_of_time(ticket, worker)

      assert %{timeout_ms: 10_800_000, exhausted: :timeout} = Extensions.offer(ticket)
    end

    test "someone who may not extend gives it no time", context do
      %{ticket: ticket, worker: worker} = context
      {ticket, job, _assignment} = run_out_of_time(ticket, worker)
      stranger = Forge.AccountsFixtures.user_fixture()

      assert {:error, :forbidden} =
               Operator.extend(ticket, stranger, job.id, %{"tokens" => "6M", "timeout" => "4h"})

      assert Extensions.all(job.id) == []
    end
  end

  describe "Extensions.parse/2" do
    test "reads the time in the grammar a workflow writes it in" do
      for {typed, ms} <- [
            {"90s", 90_000},
            {"20m", 1_200_000},
            {"3h", 10_800_000},
            {7_200, 7_200_000}
          ] do
        assert {:ok, %{timeout: ^ms}} =
                 Extensions.parse(%{"tokens" => "1M", "timeout" => typed}, true)
      end
    end

    test "blank is the job's own, and says nothing" do
      for blank <- [nil, ""] do
        assert {:ok, %{timeout: nil}} =
                 Extensions.parse(%{"tokens" => "1M", "timeout" => blank}, true)
      end

      assert {:ok, %{timeout: nil}} = Extensions.parse(%{"tokens" => "1M"}, true)
    end

    test "the refusal spells out the format and keeps what was typed" do
      assert {:error, {:invalid_timeout, "soon"} = reason} =
               Extensions.parse(%{"tokens" => "1M", "timeout" => "soon"}, true)

      assert Extensions.explain(reason) =~ "90s, 20m or 3h"
    end
  end
end
