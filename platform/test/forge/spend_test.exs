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
  @grammar Path.expand("../../../docs/design/workflow-grammar-v1.md", __DIR__)

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
      ticket = admit(user, ticket_tokens: 100_000)
      spend!(ticket, 120_000)
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
      ticket = admit(user, ticket_tokens: 60_000)
      job = only_pending(ticket)

      assignment = FakeWorker.assign(job, worker)
      {:ok, _job} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      # The state declares 100,000; the ticket allows 60,000. The smaller figure is what the
      # assignment carries, which is what the worker hands the harness as its own budget and
      # what stops a runaway before the ticket's allowance is gone.
      assert budget(assignment) == 60_000
      assert %{"binding" => "ticket", "effective_tokens" => 60_000} = lowered(ticket)

      # And the job is told: what it was lowered from and by which cap, and what the ticket has.
      assert %{
               "declared" => 100_000,
               "lowered_by" => "ticket",
               "ticket_left" => 60_000,
               "ticket_limit" => 60_000
             } = assignment["spec"]["budget"]
    end

    test "a job whose state budget is the smallest runs on it untouched", %{
      user: user,
      worker: worker
    } do
      ticket = admit(user, ticket_tokens: 5_000_000)
      job = only_pending(ticket)

      assignment = FakeWorker.assign(job, worker)
      {:ok, _job} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      assert budget(assignment) == 100_000
      refute lowered(ticket)

      # Nothing lowered, and the allowance named all the same.
      refute Map.has_key?(assignment["spec"]["budget"], "lowered_by")

      assert %{"ticket_left" => 5_000_000, "ticket_limit" => 5_000_000} =
               assignment["spec"]["budget"]
    end

    # What is left, not what the ticket was allowed: the figure a job weighs another round by.
    test "the allowance named is what is left of it after what the ticket spent", %{
      user: user,
      worker: worker
    } do
      ticket = admit(user, ticket_tokens: 5_000_000)
      spend!(ticket, 800_000)

      assignment = ticket |> only_pending() |> FakeWorker.assign(worker)

      assert %{"ticket_left" => 4_200_000, "ticket_limit" => 5_000_000} =
               assignment["spec"]["budget"]
    end
  end

  # **A conversation has no ticket allowance** (`docs/design/capacity.md` § Spend caps,
  # `docs/design/conversations.md` § Spend, and `workflow-grammar-v1.md` § Budget, which now says
  # so where a reader of the budget grammar looks). The allowance exists to stop a runaway
  # workflow, and a person asking why a ticket is stuck is not one — a cap that locked them out
  # of their own ticket would work against its own purpose. The figures stay honest because a
  # chat's spend is its own and never folded into the ticket's.
  describe "a conversation about a ticket" do
    test "runs where the ticket's own job is refused, and spends none of its allowance", %{
      user: user,
      worker: worker
    } do
      ticket = admit(user, ticket_tokens: 100_000)
      spend!(ticket, 120_000)
      project = Projects.get!(ticket.project_id)
      serve!(worker, project)
      funded!(project)

      # The ticket is over its allowance, so its own next job cannot start.
      assert {:error, {:spend_exhausted, :ticket}} =
               Jobs.assign(only_pending(ticket), worker)

      {:ok, chat} = Forge.Conversations.open(project, "why is this stuck?", ticket: ticket)
      assert {:ok, _assigned} = Jobs.assign(Jobs.get!(chat.id), worker)

      # And what it spends lands on the conversation, not on the ticket it is about.
      {:ok, chat} =
        Forge.Conversations.record_turn(Jobs.get!(chat.id), %{
          "turn" => 1,
          "harness" => %{
            "session_id" => "sess-42",
            "turns" => 2,
            "usage" => 60_000,
            "cost_usd" => 0.30
          }
        })

      assert chat.usage == 60_000
      assert Tickets.get!(ticket.id).usage == 120_000
    end

    # § Budget is where a reader of the budget grammar looks for what `limits.ticket_tokens` counts,
    # and it said "the sum over all jobs of a ticket" without saying a conversation is not one of
    # them — while the two notes above said so plainly. A ticket was filed on the gap. This is the
    # check that it stays closed, beside the behaviour it documents.
    #
    # **The phrases carry the rule, not the words in it.** The first version of this asserted only
    # that § Budget mentioned "conversation" and "daily cap", which a paragraph stating the exact
    # inverse — a conversation counted, bound by the allowance *and* the day — satisfies while
    # using both. A test that passes against the defect it names is worse than none.
    test "the budget grammar says the allowance is not a conversation's" do
      budget =
        @grammar
        |> File.read!()
        |> String.split("**Budget.**")
        |> Enum.at(1)
        |> String.split("**Environment.**")
        |> hd()
        # Wrapped prose: the sentence a reader sees is not the line the file holds.
        |> String.replace(~r/\s+/, " ")

      assert budget =~ "caps the jobs the engine starts, and not a conversation"
      assert budget =~ "has no ticket allowance and meets the daily cap alone"
    end
  end

  describe "the daily cap" do
    test "pauses the node without sticking anything or filling the queue", %{
      user: user,
      worker: worker
    } do
      # The day's spend is another ticket's; this one has an allowance of its own and has spent
      # nothing, so only the daily cap can refuse it.
      spend!(admit(user, ticket_tokens: 5_000_000), 400_000, started: true)
      ticket = admit(user, ticket_tokens: 5_000_000)
      Application.put_env(:forge, Forge.Spend, daily_tokens: 200_000)

      job = only_pending(ticket)
      assert {:error, {:spend_paused, :day}} = Jobs.assign(job, worker)

      ticket = Tickets.get!(ticket.id)
      assert ticket.status == :active
      assert Jobs.get!(job.id).status == :pending
      assert Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id)) == []
      assert Spend.paused?()
    end

    # Below the state's budget but not spent: the job runs on what is left of the day, and is
    # told that the day is what lowered it. Left is 300,000 less the 160,000 used and the 100,000 this
    # pending job is itself budgeted, which the day counts as committed.
    test "narrows a job's budget to what is left of the day, and says so", %{
      user: user,
      worker: worker
    } do
      spend!(admit(user, ticket_tokens: 5_000_000), 160_000, started: true)
      ticket = admit(user, ticket_tokens: 5_000_000)
      Application.put_env(:forge, Forge.Spend, daily_tokens: 300_000)

      assignment = ticket |> only_pending() |> FakeWorker.assign(worker)

      assert %{"tokens" => 40_000, "declared" => 100_000, "lowered_by" => "day"} =
               assignment["spec"]["budget"]
    end

    # The pause is a wait like any other, and is said once. `Jobs.assign/2` asks the cap on every
    # pass for every pending job, and it used to write a `spend.paused` event each time — one per
    # job every two seconds until midnight, into a log nothing may delete from. Counted across
    # the whole log, because a conversation's version of that event named no ticket.
    test "a paused job and a paused conversation say they wait for midnight, once each", %{
      user: user,
      worker: worker
    } do
      spend!(admit(user, ticket_tokens: 5_000_000), 400_000, started: true)
      ticket = admit(user, ticket_tokens: 5_000_000)
      project = Projects.get!(ticket.project_id)
      # A machine and a credential for the project, so that the cap is what stops them.
      serve!(worker, project)
      funded!(project)
      {:ok, chat} = Forge.Conversations.open(project, "hello")
      Application.put_env(:forge, Forge.Spend, daily_tokens: 200_000)
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0
      logged = Repo.aggregate(Forge.Events.Event, :count)
      assert Forge.Jobs.Scheduler.tick() == 0
      assert Repo.aggregate(Forge.Events.Event, :count) == logged

      for job <- [only_pending(ticket), chat] do
        assert [%{payload: %{"reason" => "spend_paused", "text" => text}}] =
                 job.id |> Forge.Events.for_job() |> Enum.filter(&(&1.type == "job.waiting"))

        assert text =~ "midnight"
      end
    end

    test "counts what live jobs are budgeted to spend, not only what is recorded", %{user: user} do
      ticket = admit(user, ticket_tokens: 5_000_000)
      Application.put_env(:forge, Forge.Spend, daily_tokens: 200_000)

      # Nothing has been billed yet, but a live job is budgeted at 100,000 and a second would take
      # the day past the cap. Counting only recorded cost would let both through.
      job = only_pending(ticket)
      {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))

      assert Spend.committed() == 100_000

      other = admit(user, ticket_tokens: 5_000_000)
      {:ok, _} = Repo.update(Job.progress_changeset(only_pending(other), %{status: :running}))

      assert Spend.paused?()
    end

    # **The day is the run's** (`docs/design/credentials.md` § Spend). A job that started one day
    # and resumed the next spent on each day what it spent that day; read by the job's first start,
    # all of it landed on the first. Days well away from today, so nothing else is in them.
    test "a job that ran on two days is on each day's total for what it spent that day", %{
      user: user
    } do
      job = only_pending(admit(user, ticket_tokens: 5_000_000))
      monday = ~U[2026-03-02 23:00:00Z]
      tuesday = ~U[2026-03-03 01:00:00Z]

      {:ok, _} = Repo.update(Ecto.Changeset.change(job, started_at: monday))
      run!(job, usage: 200_000, started_at: monday, finished_at: monday)
      run!(job, usage: 400_000, started_at: tuesday, finished_at: tuesday)

      assert Spend.day_total(~D[2026-03-02]) == 200_000
      assert Spend.day_total(~D[2026-03-03]) == 400_000
    end

    test "no cap configured means nothing is ever paused", %{user: user} do
      ticket = admit(user, ticket_tokens: 5_000_000)
      spend!(ticket, 200_000_000, started: true)
      Application.put_env(:forge, Forge.Spend, daily_tokens: nil)

      assert Spend.day_remaining() == :unlimited
      refute Spend.paused?()
      assert Spend.gate(ticket, Tickets.workflow(ticket)) == :ok
    end
  end

  # The clause of the definition of usable this milestone exists to satisfy: a cap has to have
  # stopped a runaway job, not merely to have been declared.
  test "a cap stops a runaway job mid-flight", %{user: user, worker: worker} do
    ticket = admit(user, ticket_tokens: 20_000)
    job = only_pending(ticket)

    assignment = FakeWorker.assign(job, worker)
    {:ok, job} = FakeWorker.finish(assignment, "max_budget", doc: "refinement.md")

    assert job.outcome == :budget_exhausted
    assert budget(assignment) == 20_000

    ticket = Tickets.get!(ticket.id)
    assert ticket.status == :stuck
    assert [%{kind: :stuck}] = Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))
  end

  # **The dollar keys are refused for a new ticket and run on for one already admitted**
  # (`docs/design/workflow-grammar-v1.md` § Budget). The rate from dollars is a guess: fine for
  # finishing what is running, not for governing new work silently.
  describe "the dollar keys" do
    setup %{user: user} do
      workflow =
        @workflow
        |> File.read!()
        |> String.replace("ticket_tokens: 5M", "ticket_cost: 25.00")
        |> String.replace("tokens: 100k", "cost: 0.50")

      bare = seeded_repo(%{".forge/workflow.yml" => workflow})
      name = "legacy#{System.unique_integer([:positive])}"
      {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
      %{project: project, user: user}
    end

    test "a ticket cannot be admitted on them, and the refusal names what replaces them", %{
      project: project,
      user: user
    } do
      assert {:error, reason} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
      text = inspect(reason)
      assert text =~ "budget.tokens"
      assert text =~ "limits.ticket_tokens"
    end
  end

  describe "the budget a job runs with" do
    # A job started at the cap's edge would be handed a budget of nothing and stopped on its first
    # call, having billed an invocation to learn what the gate already knew.
    test "is never less than the floor", %{user: user} do
      ticket = admit(user, ticket_tokens: 1_000_000)
      spend!(ticket, 999_999)
      ticket = Tickets.get!(ticket.id)

      assert Spend.effective_tokens(100_000, ticket, Tickets.workflow(ticket)) ==
               {Spend.floor(), :ticket}

      assert Spend.floor() == 10_000
    end

    # A job pending when the platform moved to weighted tokens carries a budget in dollars
    # (`ForgeCore.Job.Spec`); the day counts it converted, or it would count as nothing.
    test "counts a pending job's budget in dollars at the rate", %{user: user} do
      job = only_pending(admit(user, ticket_tokens: 5_000_000))
      spec = Map.put(job.spec, "budget", %{"turns" => 5, "cost" => 0.5})
      {:ok, _} = Repo.update(Ecto.Changeset.change(job, spec: spec))

      assert Spend.committed() == 100_000
    end
  end

  # Counted in weighted tokens since protocol 11; the dollar variable is refused rather than
  # converted, as a malformed value always was (`config/runtime.exs`).
  describe "the node's daily cap, from the environment" do
    defp runtime(env) do
      keys = Map.keys(env)
      before = Map.new(keys, &{&1, System.get_env(&1)})
      Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

      try do
        Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :test)
      after
        Enum.each(before, fn
          {k, nil} -> System.delete_env(k)
          {k, v} -> System.put_env(k, v)
        end)
      end
    end

    test "FORGE_DAILY_TOKENS takes the notation of a budget" do
      for {text, tokens} <- [
            {"4M", 4_000_000},
            {"800k", 800_000},
            {"84.2M", 84_200_000},
            {"5000", 5000}
          ] do
        assert runtime(%{"FORGE_DAILY_TOKENS" => text})[:forge][Forge.Spend][:daily_tokens] ==
                 tokens
      end
    end

    test "a value that is not a positive number of tokens stops the node starting" do
      for bad <- ["0", "-4M", "four", "4G", "", "1e308M", "1e20"] do
        assert_raise RuntimeError, ~r/FORGE_DAILY_TOKENS must be a positive number/, fn ->
          runtime(%{"FORGE_DAILY_TOKENS" => bad})
        end
      end
    end

    test "the dollar variable stops the node starting, and names its replacement" do
      assert_raise RuntimeError, ~r/FORGE_DAILY_TOKENS/, fn ->
        runtime(%{"FORGE_DAILY_COST_USD" => "5"})
      end
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp admit(user, ticket_tokens: cap) do
    workflow =
      @workflow
      |> File.read!()
      |> String.replace("ticket_tokens: 5M", "ticket_tokens: #{cap}")

    bare = seeded_repo(%{".forge/workflow.yml" => workflow})
    name = "spend#{System.unique_integer([:positive])}"

    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    ticket
  end

  # Weighted tokens the ticket has already used. `started` also puts it in today's total.
  defp spend!(ticket, amount, opts \\ []) do
    {:ok, _} =
      ticket
      |> Ecto.Changeset.change(usage: amount)
      |> Repo.update()

    if Keyword.get(opts, :started, false) do
      job = only_pending(ticket)

      {:ok, _} =
        job
        |> Ecto.Changeset.change(
          usage: amount,
          started_at: DateTime.utc_now(:second),
          status: :finished,
          outcome: :converged,
          finished_at: DateTime.utc_now(:second)
        )
        |> Repo.update()

      run!(job, usage: amount, finished_at: DateTime.utc_now(:second))
    end

    :ok
  end

  defp only_pending(ticket) do
    [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    job
  end

  # The tokens the assignment tells the worker to run under. It is the platform's whole part in
  # stopping a runaway: the meter that counts it is the worker's, and is tested there.
  defp budget(assignment), do: assignment["spec"]["budget"]["tokens"]

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
