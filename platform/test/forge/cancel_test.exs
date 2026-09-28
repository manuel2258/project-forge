defmodule Forge.CancelTest do
  @moduledoc """
  Cancelling a ticket and restoring it (`docs/design/workflow-grammar-v1.md` § Cancelling a
  ticket): its live jobs end, a machine running one is told to stop, and it is hidden everywhere a
  ticket is listed — without anything being deleted.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{
    Backlog,
    Engine,
    Events,
    FakeWorker,
    Jobs,
    Operator,
    Projects,
    Queue,
    Repo,
    Tickets
  }

  alias Forge.Jobs.Job

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "cancel-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, user: user, ticket: ticket, worker: FakeWorker.connect()}
  end

  test "a ticket with a pending job is cancelled: the job ends, nothing is deleted", %{
    ticket: ticket,
    user: user
  } do
    [%Job{status: :pending} = job] = Jobs.for_ticket(ticket.id)

    {:ok, cancelled} = Engine.cancel(ticket, user.id)

    assert cancelled.status == :cancelled
    assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job.id)

    assert [%{payload: %{"jobs" => [id], "state" => "refining"}}] =
             Enum.filter(Events.for_ticket(ticket.id), &(&1.type == "ticket.cancelled"))

    assert id == job.id
    assert Forge.Artifacts.latest(ticket.id, "ticket")
  end

  test "a machine running one of its jobs is told to stop, and its late report changes nothing",
       %{ticket: ticket, user: user, worker: worker} do
    [job] = Jobs.for_ticket(ticket.id)
    assignment = FakeWorker.assign(job, worker)
    job_id = assignment["job_id"]
    assert %Job{status: :running} = Jobs.get!(job_id)

    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

    assert_receive {:cancel, ^job_id, :ticket_cancelled}, 1_000

    # What the worker answers a cancel with. The job stays ended, not resumable.
    {:ok, _job} = Jobs.hibernate(job_id, nil, "cancelled")
    assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job_id)
  end

  test "a cancelled ticket is hidden everywhere a ticket is listed", %{
    project: project,
    ticket: ticket,
    user: user,
    worker: worker
  } do
    {:ok, _job} =
      FakeWorker.run(hd(Jobs.for_ticket(ticket.id)), worker, "invalid_document",
        doc: "refinement.md"
      )

    assert Tickets.get!(ticket.id).status == :stuck
    assert Enum.any?(Queue.items(), &(&1.ticket && &1.ticket.id == ticket.id))

    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

    refute Enum.any?(Tickets.list(project), &(&1.id == ticket.id))
    refute Enum.any?(Tickets.list(), &(&1.id == ticket.id))
    refute Enum.any?(Queue.items(), &(&1.ticket && &1.ticket.id == ticket.id))

    assert [%{open_tickets: 0}] =
             Enum.filter(Projects.summaries(user), &(&1.project.id == project.id))

    backlog = Backlog.compose(project)
    assert backlog["tickets"] == []
    refute backlog["index"] =~ "Persist scores"

    # Reached by its own address, still.
    assert Tickets.get_by_number!(project, 1).status == :cancelled
  end

  # What a cancel must not change — money spent, and which ticket a proposal came from — reads
  # every ticket; what lists tickets does not.
  test "all/1 keeps a cancelled ticket that list/1 hides", %{
    project: project,
    ticket: ticket,
    user: user
  } do
    {:ok, _cancelled} = Engine.cancel(ticket, user.id)

    assert [%{id: id}] = Tickets.all(project)
    assert id == ticket.id
    assert Tickets.list(project) == []
  end

  # Each status a job holds while it is not finished. Hibernated matters most: a hibernated job is
  # resumable, and a cancelled ticket's must not come back.
  for status <- [:waiting, :parked, :hibernated] do
    test "a #{status} job is ended with its ticket", %{ticket: ticket, user: user} do
      [job] = Jobs.for_ticket(ticket.id)
      job |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()

      {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

      assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job.id)
    end
  end

  # A conversation is ended by closing it; cancelling its ticket leaves it as it was.
  test "a conversation about the ticket is left as it was", %{
    project: project,
    ticket: ticket,
    user: user
  } do
    {:ok, chat} = Forge.Conversations.open(project, "about this", ticket: ticket)
    {:ok, _cancelled} = Engine.cancel(ticket, user.id)

    assert Jobs.get!(chat.id).status == chat.status
  end

  test "a pending approval is cleared", %{ticket: ticket, user: user, worker: worker} do
    {:ok, _job} =
      FakeWorker.run(hd(Jobs.for_ticket(ticket.id)), worker, "success", doc: "refinement.md")

    assert Tickets.get!(ticket.id).pending_transition

    {:ok, cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)
    assert cancelled.pending_transition == nil
    assert Tickets.get!(ticket.id).pending_transition == nil
  end

  # The run the cancel ends is closed, and the job's push credential goes with it.
  test "a running job's run is closed and its git token revoked", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    [job] = Jobs.for_ticket(ticket.id)
    FakeWorker.assign(job, worker)

    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

    assert [%{finished_at: %DateTime{}}] =
             Repo.all(Ecto.Query.from(r in Forge.Jobs.Run, where: r.job_id == ^job.id))

    assert [_ | _] =
             tokens = Repo.all(Ecto.Query.from(t in Forge.Git.Token, where: t.job_id == ^job.id))

    assert Enum.all?(tokens, & &1.revoked_at)
  end

  # The machine says it stopped, with what the run spent. The cancel closed the run with nothing,
  # and nothing else releases the machine: without this it stayed busy for ever.
  test "the machine's report after a cancel settles the spend and releases it, once", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    [job] = Jobs.for_ticket(ticket.id)
    FakeWorker.assign(job, worker)
    assert Forge.Workers.get!(worker.id).status == :busy

    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)
    report = %{"harness" => %{"cost_usd" => 0.25}}

    for _twice <- 1..2 do
      {:ok, _job} = Jobs.hibernate(job.id, nil, "cancelled", report)
    end

    assert Forge.Workers.get!(worker.id).status == :idle
    assert Decimal.equal?(Jobs.get!(job.id).cost_usd, Decimal.from_float(0.25))
    assert Decimal.equal?(Tickets.get!(ticket.id).cost_usd, Decimal.from_float(0.25))
    assert Decimal.equal?(Forge.Jobs.Runs.total(job.id), Decimal.from_float(0.25))
  end

  # A command, or an agent that ended with a result rather than hibernating, reports a result.
  test "a result after a cancel settles the same way", %{
    ticket: ticket,
    user: user,
    worker: worker
  } do
    [job] = Jobs.for_ticket(ticket.id)
    FakeWorker.assign(job, worker)
    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

    result = %ForgeCore.Job.Result{
      status: :finished,
      outcome: :error,
      harness: %{"cost_usd" => 0.5}
    }

    assert {:error, :already_recorded} = Jobs.complete(job.id, result)

    assert Forge.Workers.get!(worker.id).status == :idle
    assert Decimal.equal?(Jobs.get!(job.id).cost_usd, Decimal.from_float(0.5))
  end

  # The scheduler decides to stick from a ticket it read earlier. One cancelled since stays so.
  test "sticking a cancelled ticket is refused, and it stays hidden", %{
    ticket: ticket,
    user: user
  } do
    {:ok, _cancelled} = Engine.cancel(ticket, user.id)

    assert {:error, {:open, {:not_open, :cancelled}}} = Engine.stick(ticket, "no machine")
    assert Tickets.get!(ticket.id).status == :cancelled
  end

  test "restoring leaves it stuck in its state, and nothing starts", %{ticket: ticket, user: user} do
    {:ok, cancelled} = Engine.cancel(ticket, user.id)
    {:ok, restored} = Engine.restore(cancelled, user.id)

    assert %{status: :stuck, state: "refining"} = restored
    refute Enum.any?(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    assert Engine.retryable?(restored)

    assert [_] = Enum.filter(Events.for_ticket(ticket.id), &(&1.type == "ticket.restored"))
  end

  test "nothing acts on a cancelled ticket, and a done one cannot be cancelled", %{
    ticket: ticket,
    user: user
  } do
    {:ok, cancelled} = Engine.cancel(ticket, user.id)

    assert {:error, {:not_cancellable, :cancelled}} = Engine.cancel(cancelled, user.id)
    assert {:error, {:not_active, :cancelled}} = Engine.choose(cancelled, user.id, "planning")
    assert {:error, {:not_retryable, :cancelled}} = Engine.retry(cancelled, user.id)

    assert {:error, {:not_cancelled, :active}} =
             Engine.restore(Tickets.get!(ticket.id) |> Map.put(:status, :active), user.id)

    # Read from the row, not the caller's struct: a ticket that finished since is not cancelled.
    {:ok, done} = cancelled |> Ecto.Changeset.change(status: :done) |> Repo.update()
    assert {:error, {:not_cancellable, :done}} = Engine.cancel(done, user.id)
  end

  test "a non-member can neither cancel nor restore", %{ticket: ticket} do
    outsider = member_fixture(project_fixture(), :admin)

    assert {:error, :forbidden} = Operator.cancel(ticket, outsider)
    assert {:error, :forbidden} = Operator.restore(ticket, outsider)
    assert Tickets.get!(ticket.id).status == :active
  end
end
