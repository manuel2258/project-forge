defmodule Forge.JobsChatTest do
  @moduledoc """
  A job with a kind, and every reader that assumed a job has a ticket.

  Most of what this pins fails silently rather than loudly: a chat dropped from the queue by an
  inner join sits pending for ever, a chat re-queued on boot starts itself and spends money, and
  `Engine.after_job` over a chat logs `job.orphaned` and returns success. Each test below is
  written to fail on the *observable* thing rather than on a return value, because the return
  value is the same either way.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Events, Jobs, Spend}
  alias Forge.Jobs.Job

  describe "the shape of a row" do
    test "a chat has a project and none of a workflow job's fields" do
      chat = chat_fixture()

      assert chat.kind == :chat
      assert chat.project_id
      assert is_nil(chat.ticket_id)
      assert is_nil(chat.state)
      assert is_nil(chat.spec)
    end

    test "a chat carrying a state without a ticket, or a spec, is refused" do
      project = project_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 Job.create_changeset(%Job{}, %{
                   kind: :chat,
                   project_id: project.id,
                   attempt: 1,
                   state: "planning"
                 })
               )

      assert "a conversation is a step only of a ticket" in errors_on(changeset).state

      assert {:error, changeset} =
               Repo.insert(
                 Job.create_changeset(%Job{}, %{
                   kind: :chat,
                   project_id: project.id,
                   attempt: 1,
                   spec: %{"x" => 1}
                 })
               )

      assert "belongs to a workflow job, not a conversation" in errors_on(changeset).spec
    end

    test "the database refuses a chat that names a state and no ticket" do
      project = project_fixture()
      chat = chat_fixture(%{project: project})

      assert_raise Postgrex.Error, ~r/jobs_kind_shape/, fn ->
        Repo.update_all(Ecto.Query.from(j in Job, where: j.id == ^chat.id), set: [state: "x"])
      end
    end

    test "a workflow job still requires its ticket, state and spec" do
      project = project_fixture()

      assert {:error, changeset} =
               Repo.insert(
                 Job.create_changeset(%Job{}, %{
                   kind: :workflow,
                   project_id: project.id,
                   attempt: 1
                 })
               )

      assert errors_on(changeset).ticket_id == ["can't be blank"]
      assert errors_on(changeset).state == ["can't be blank"]
      assert errors_on(changeset).spec == ["can't be blank"]
    end

    # The unique index was `(ticket_id, state, attempt)` and constrains nothing once any of them
    # can be null, because Postgres treats NULLs as distinct. It is partial now, over the rows it
    # was always about — and two chats on one project must still both exist.
    test "two conversations on one project are both allowed" do
      project = project_fixture()

      a = chat_fixture(%{project: project})
      b = chat_fixture(%{project: project})

      refute a.id == b.id
      assert length(Jobs.chats_for_project(project.id)) == 2
    end
  end

  describe "scheduling" do
    # An inner join on tickets dropped a project chat from the queue entirely. Asserting on the
    # ids rather than the count, because a count passes if any row of the right number comes
    # back — including the workflow job that was going to be there anyway.
    test "a conversation with no ticket is pending work" do
      job = job_fixture()
      chat = chat_fixture()

      ids = Jobs.pending(10) |> Enum.map(& &1.id)

      assert chat.id in ids
      assert job.id in ids
    end

    test "a conversation about a stuck ticket is still pending work" do
      ticket = ticket_fixture()

      ticket
      |> Forge.Tickets.Ticket.progress_changeset(%{status: :stuck})
      |> Repo.update!()

      chat = chat_fixture(%{ticket: ticket, ticket_id: ticket.id})

      assert chat.id in (Jobs.pending(10) |> Enum.map(& &1.id))
    end
  end

  describe "spend" do
    # A conversation has no spec, so it has no budget to commit against the day. Its cost is in
    # `day_total/0` instead, recorded per turn — see § Spend.
    test "a live conversation commits nothing to the day's budget" do
      before = Spend.committed()
      chat_fixture(%{status: :running})

      assert Decimal.compare(Spend.committed(), before) == :eq
    end
  end

  describe "what a restart does" do
    # Re-queueing a chat would mean every platform restart starting conversations nobody is in.
    test "a running conversation goes dormant, a running job is re-queued" do
      job = job_fixture(%{status: :running})
      chat = chat_fixture(%{status: :running})

      assert Jobs.recover() == 2

      assert Repo.get!(Job, job.id).status == :pending
      assert Repo.get!(Job, chat.id).status == :hibernated
    end

    # A restart alone loses nothing (`docs/design/worker-channel.md` § A platform restart): a
    # conversation whose machine will rejoin with it carries on where it was.
    test "a conversation on a machine that is still there carries on" do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

      chat =
        chat_fixture(%{status: :running})
        |> Job.progress_changeset(%{worker_id: worker.id})
        |> Repo.update!()

      assert Jobs.recover() == 0
      assert Repo.get!(Job, chat.id).status == :running
    end

    test "losing the worker puts a conversation to sleep rather than back in the queue" do
      chat = chat_fixture(%{status: :running})

      {:ok, chat} = Jobs.requeue(chat.id, :worker_lost)

      assert chat.status == :hibernated
      refute chat.id in (Jobs.pending(10) |> Enum.map(& &1.id))
    end
  end

  describe "completing" do
    # A conversation ends by hibernating; a result arriving for one is a worker the platform does
    # not understand. Recording it would run the workflow follow-up over a job with no state.
    test "a result for a conversation is refused, and writes no transition" do
      chat = chat_fixture(%{status: :running})

      assert {:error, :not_a_workflow_job} =
               Jobs.complete(chat.id, %ForgeCore.Job.Result{
                 status: :finished,
                 outcome: :converged
               })

      types = chat.id |> Events.for_job() |> Enum.map(& &1.type)
      refute "transition.taken" in types
      refute "job.orphaned" in types
    end

    # A *ticket* chat has a ticket, so a guard of "does it have a ticket" let every failed one
    # into `Engine.after_job` — which has no state to move from and logs `job.orphaned`. The
    # first version of the test below used a project chat, which has no ticket, so it passed
    # while the bug was there. This is the same test with the shape that actually reaches it.
    test "a ticket conversation that fails does not reach the engine" do
      ticket = ticket_fixture()
      chat = chat_fixture(%{ticket: ticket, ticket_id: ticket.id, status: :running})

      assert {:ok, failed} = Jobs.fail(chat.id, :runner_died)
      assert failed.status == :finished

      types = chat.id |> Events.for_job() |> Enum.map(& &1.type)
      refute "job.orphaned" in types
      refute "transition.taken" in types
    end

    # `Tickets.get!(nil)` raises, and this is reached from the channel: a project chat whose
    # runner died took the worker's channel down with it.
    test "a conversation with no ticket can fail without crashing" do
      chat = chat_fixture(%{status: :running})

      assert {:ok, failed} = Jobs.fail(chat.id, :runner_died)
      assert failed.status == :finished
      # Finished means over. An outcome is a workflow word, and a chat carrying one would be a
      # chat the engine could act on.
      assert is_nil(failed.outcome)
    end
  end

  describe "the ticket's own lists" do
    test "a ticket's timeline is its workflow jobs, and its chats are a separate list" do
      ticket = ticket_fixture()
      job = job_fixture(%{ticket: ticket})
      chat = chat_fixture(%{ticket: ticket, ticket_id: ticket.id})

      assert Jobs.for_ticket(ticket.id) |> Enum.map(& &1.id) == [job.id]
      assert Jobs.chats_for_ticket(ticket.id) |> Enum.map(& &1.id) == [chat.id]
    end
  end

  describe "recovery is a boot, not a restart" do
    # `recover/0` used to run in `Scheduler.init/1`, so any crash in a scheduling pass recovered
    # the whole node: the supervisor restarts the scheduler, recovery runs again, and every
    # running conversation goes dormant because one unrelated job raised. A workflow job survived
    # it — back to pending, scheduled again — which is why the cost was invisible until chats
    # existed. This is the property that made it invisible, pinned so it stays visible.
    test "starting the scheduler does not touch running work" do
      job = job_fixture(%{status: :running})
      chat = chat_fixture(%{status: :running})

      # The scheduler is off in tests, so it is started here on purpose: what is under test is
      # what its `init/1` does, which is what a supervisor restart repeats.
      {:ok, pid} = Forge.Jobs.Scheduler.start_link([])
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert Repo.get!(Job, chat.id).status == :running
      assert Repo.get!(Job, job.id).status == :running
    end

    # And recovery itself still works — it is a boot task now, not gone.
    test "recovering explicitly still does what a boot needs" do
      job = job_fixture(%{status: :running})
      chat = chat_fixture(%{status: :running})

      assert Jobs.recover() == 2

      assert Repo.get!(Job, job.id).status == :pending
      assert Repo.get!(Job, chat.id).status == :hibernated
    end
  end

  describe "live output" do
    test "a harness event is broadcast to whoever is watching that job" do
      job = job_fixture(%{status: :running})
      Events.subscribe_job(job.id)

      :ok = Jobs.record_harness_event(job.id, %{type: "job.harness.text", payload: %{text: "hi"}})

      assert_receive {:job_event, job_id, event}
      assert job_id == job.id
      assert event.payload["text"] == "hi"
    end

    test "a page watching one job is not woken by another job's output" do
      watched = job_fixture(%{status: :running})
      other = job_fixture(%{status: :running})
      Events.subscribe_job(watched.id)

      :ok =
        Jobs.record_harness_event(other.id, %{type: "job.harness.text", payload: %{text: "x"}})

      refute_receive {:job_event, _id, _event}, 100
    end
  end
end
