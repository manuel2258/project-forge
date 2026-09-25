defmodule Forge.SpendTest do
  @moduledoc """
  The two caps and the difference between them: one is a human's to resolve and sticks the ticket
  into the queue, the other is the clock's and only pauses. And the evidence the PoC's definition
  of usable asks for — a cap stopping a runaway job.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Projects, Queue, Spend, Tickets}
  alias Forge.Jobs.Job

  @workflow Path.expand("../../../core/test/fixtures/workflow_example.yml", __DIR__)

  setup do
    data_dir = tmp_dir("spend-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    spend = Application.get_env(:forge, Forge.Spend)

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, config)
      Application.put_env(:forge, Forge.Spend, spend)
    end)

    # A worker with room for anything: what is under test is the spend gate, which runs
    # before a machine is spoken to at all.
    %{user: user_fixture(), worker: FakeWorker.connect()}
  end

  describe "the ticket allowance" do
    test "a ticket over it is refused, stuck, and in the queue", %{user: user, worker: worker} do
      ticket = admit(user, ticket_cost: 0.50)
      spend!(ticket, "0.60")
      job = only_pending(ticket)

      assert {:error, {:spend_exhausted, :ticket}} = Jobs.assign(job, worker)
      assert Jobs.get!(job.id).status == :pending

      ticket = Tickets.get!(ticket.id)
      assert ticket.status == :stuck
      assert [%{kind: :stuck}] = Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))

      # Stuck also takes it out of the pending set, so the scheduler stops retrying every tick.
      refute Enum.any?(Jobs.pending(), &(&1.id == job.id))
    end

    test "a ticket under it runs with a budget narrowed to what is left", %{
      user: user,
      worker: worker
    } do
      ticket = admit(user, ticket_cost: 0.30)
      job = only_pending(ticket)

      assignment = FakeWorker.assign(job, worker)
      {:ok, _job} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      # The state declares 0.50; the ticket allows 0.30. The smaller figure is what the
      # assignment carries, which is what the worker hands the harness as its own budget and
      # what stops a runaway before the ticket's allowance is gone.
      assert budget(assignment) == 0.30
      assert %{"binding" => "ticket", "effective_cost" => 0.3} = lowered(ticket)
    end

    test "a job whose state budget is the smallest runs on it untouched", %{
      user: user,
      worker: worker
    } do
      ticket = admit(user, ticket_cost: 25.0)
      job = only_pending(ticket)

      assignment = FakeWorker.assign(job, worker)
      {:ok, _job} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      assert budget(assignment) == 0.50
      refute lowered(ticket)
    end
  end

  describe "the daily cap" do
    test "pauses the node without sticking anything or filling the queue", %{
      user: user,
      worker: worker
    } do
      # The day's spend is another ticket's; this one has an allowance of its own and has spent
      # nothing, so only the daily cap can refuse it.
      spend!(admit(user, ticket_cost: 25.0), "2.00", started: true)
      ticket = admit(user, ticket_cost: 25.0)
      Application.put_env(:forge, Forge.Spend, daily_cost_usd: 1.0)

      job = only_pending(ticket)
      assert {:error, {:spend_paused, :day}} = Jobs.assign(job, worker)

      ticket = Tickets.get!(ticket.id)
      assert ticket.status == :active
      assert Jobs.get!(job.id).status == :pending
      assert Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id)) == []
      assert Spend.paused?()
    end

    test "counts what live jobs are budgeted to spend, not only what is recorded", %{user: user} do
      ticket = admit(user, ticket_cost: 25.0)
      Application.put_env(:forge, Forge.Spend, daily_cost_usd: 1.0)

      # Nothing has been billed yet, but a live job is budgeted at 0.50 and a second would take
      # the day past the cap. Counting only recorded cost would let both through.
      job = only_pending(ticket)
      {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))

      assert Decimal.compare(Spend.committed(), Decimal.new("0.50")) == :eq

      other = admit(user, ticket_cost: 25.0)
      {:ok, _} = Repo.update(Job.progress_changeset(only_pending(other), %{status: :running}))

      assert Spend.paused?()
    end

    # **The day is the run's** (`docs/design/credentials.md` § Spend). A job that started one day
    # and resumed the next spent on each day what it spent that day; read by the job's first start,
    # all of it landed on the first. Days well away from today, so nothing else is in them.
    test "a job that ran on two days is on each day's total for what it spent that day", %{
      user: user
    } do
      job = only_pending(admit(user, ticket_cost: 25.0))
      monday = ~U[2026-03-02 23:00:00Z]
      tuesday = ~U[2026-03-03 01:00:00Z]

      {:ok, _} = Repo.update(Ecto.Changeset.change(job, started_at: monday))
      run!(job, cost: "1.00", started_at: monday, finished_at: monday)
      run!(job, cost: "2.00", started_at: tuesday, finished_at: tuesday)

      assert Decimal.equal?(Spend.day_total(~D[2026-03-02]), Decimal.new("1.00"))
      assert Decimal.equal?(Spend.day_total(~D[2026-03-03]), Decimal.new("2.00"))
    end

    test "no cap configured means nothing is ever paused", %{user: user} do
      ticket = admit(user, ticket_cost: 25.0)
      spend!(ticket, "1000.00", started: true)
      Application.put_env(:forge, Forge.Spend, daily_cost_usd: nil)

      assert Spend.day_remaining() == :unlimited
      refute Spend.paused?()
      assert Spend.gate(ticket, Tickets.workflow(ticket)) == :ok
    end
  end

  # The clause of the definition of usable this milestone exists to satisfy: a cap has to have
  # stopped a runaway job, not merely to have been declared.
  test "a cap stops a runaway job mid-flight", %{user: user, worker: worker} do
    ticket = admit(user, ticket_cost: 0.10)
    job = only_pending(ticket)

    assignment = FakeWorker.assign(job, worker)
    {:ok, job} = FakeWorker.finish(assignment, "max_budget", doc: "refinement.md")

    assert job.outcome == :budget_exhausted
    assert budget(assignment) == 0.10

    ticket = Tickets.get!(ticket.id)
    assert ticket.status == :stuck
    assert [%{kind: :stuck}] = Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp admit(user, ticket_cost: cap) do
    workflow =
      @workflow
      |> File.read!()
      |> String.replace("ticket_cost: 25.00", "ticket_cost: #{cap}")

    bare = seeded_repo(%{".forge/workflow.yml" => workflow})
    name = "spend#{System.unique_integer([:positive])}"

    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    ticket
  end

  # Money the ticket has already spent. `started` also puts it in today's total.
  defp spend!(ticket, amount, opts \\ []) do
    {:ok, _} =
      ticket
      |> Ecto.Changeset.change(cost_usd: Decimal.new(amount))
      |> Repo.update()

    if Keyword.get(opts, :started, false) do
      job = only_pending(ticket)

      {:ok, _} =
        job
        |> Ecto.Changeset.change(
          cost_usd: Decimal.new(amount),
          started_at: DateTime.utc_now(:second),
          status: :finished,
          outcome: :converged,
          finished_at: DateTime.utc_now(:second)
        )
        |> Repo.update()

      run!(job, cost: amount, finished_at: DateTime.utc_now(:second))
    end

    :ok
  end

  defp only_pending(ticket) do
    [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    job
  end

  # The cost the assignment tells the worker to run under. It is the platform's whole part in
  # stopping a runaway: the harness flag it becomes is the worker's, and is tested there.
  defp budget(assignment), do: assignment["spec"]["budget"]["cost"]

  defp lowered(ticket) do
    ticket.id
    |> Forge.Events.for_ticket()
    |> Enum.find(&(&1.type == "job.budget_lowered"))
    |> case do
      nil -> nil
      event -> event.payload
    end
  end
end
