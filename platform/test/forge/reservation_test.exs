defmodule Forge.ReservationTest do
  @moduledoc """
  The age-based reservation (`docs/design/provisioning.md` § The gate): a job that has waited
  long enough for room holds the machines that could take it, so the room that frees up goes to it
  and not to the younger, smaller jobs that used to jump it for ever.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Jobs, Tickets, Workers}
  alias Forge.Jobs.Scheduler

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "res-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    user = member_fixture(project)
    funded!(project)

    previous = Application.get_env(:forge, Forge.Jobs)
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)

    # One machine of ten, holding five already: room for a small job, not for a big one.
    worker = FakeWorker.connect(memory_budget: 10_000, cores: 8, project: project)

    %{project: project, user: user, worker: worker, previous: previous}
  end

  defp admit(%{project: project, user: user}, title, memory) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, {:user, user.id})
    [job] = Jobs.for_ticket(ticket.id)
    {:ok, job} = job |> Ecto.Changeset.change(memory_max: memory, cores: 1) |> Forge.Repo.update()
    job
  end

  # A job already on the machine, taking half of it.
  defp occupy(context) do
    job = admit(context, "running", 5_000)
    FakeWorker.assign(job, context.worker)
  end

  defp age(job, ms) do
    {:ok, job} =
      job
      |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), -ms, :millisecond))
      |> Forge.Repo.update()

    job
  end

  defp wait_reason(job), do: job |> Jobs.current_wait() |> then(&(&1 && &1.payload["reason"]))

  defp reserve_after(context, ms),
    do:
      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(context.previous, :reservation_after_ms, ms)
      )

  test "a young big job is jumped: the small one takes the room", context do
    reserve_after(context, :timer.minutes(10))
    occupy(context)
    big = admit(context, "big", 8_000)
    small = admit(context, "small", 3_000)
    start_supervised!(Scheduler)

    assert Scheduler.tick() == 1
    assert Jobs.get!(small.id).status == :running
    assert wait_reason(big) == "at_capacity"
  end

  test "an old big job holds the machine, and the small one waits behind it", context do
    reserve_after(context, :timer.minutes(10))
    running = occupy(context)
    big = context |> admit("big", 8_000) |> age(:timer.minutes(11))
    small = admit(context, "small", 3_000)
    start_supervised!(Scheduler)

    assert Scheduler.tick() == 0
    assert Jobs.get!(small.id).status == :pending
    assert wait_reason(big) == "reserving"
    assert wait_reason(small) == "behind"

    # The room it was holding out for arrives, and it is the old job that gets it.
    {:ok, _job} = FakeWorker.finish(running, "success", doc: "refinement.md")
    assert Scheduler.tick() == 1
    assert Jobs.get!(big.id).status == :running
    assert Jobs.get!(small.id).status == :pending
  end

  # By insertion alone, a job made earlier and pending again only just now — a parked agent back
  # from its commands — was offered first, and took the room the old job was holding out for.
  test "the old job is offered before one made earlier that has only just come back", context do
    reserve_after(context, :timer.minutes(10))
    running = occupy(context)
    back = admit(context, "back", 3_000)
    big = context |> admit("big", 8_000) |> age(:timer.minutes(11))
    start_supervised!(Scheduler)

    assert Scheduler.tick() == 0
    assert Jobs.get!(back.id).status == :pending
    assert wait_reason(big) == "reserving"
    assert wait_reason(back) == "behind"

    {:ok, _job} = FakeWorker.finish(running, "success", doc: "refinement.md")
    assert Scheduler.tick() == 1
    assert Jobs.get!(big.id).status == :running
  end

  # And a window of ten fetched by insertion could hold no room for it at all.
  test "the old job is in the pass however many younger ones were made before it", context do
    reserve_after(context, :timer.minutes(10))
    earlier = for n <- 1..3, do: admit(context, "earlier-#{n}", 1_000)
    big = context |> admit("big", 8_000) |> age(:timer.minutes(11))
    since = DateTime.add(DateTime.utc_now(), -:timer.minutes(10), :millisecond)

    assert [first | _] = Jobs.pending(2, since)
    assert first.id == big.id
    assert Enum.map(Jobs.pending(2), & &1.id) == Enum.map(Enum.take(earlier, 2), & &1.id)
  end

  # A machine that could never speak the job's protocol is not a queue for it.
  test "a job only a newer machine could take does not wait on an older one" do
    {:ok, project} =
      register_owned!(%{
        name: "old-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    old = FakeWorker.connect(memory_budget: 10_000, cores: 8, protocol: 1, project: project)
    demand = %{kind: :command, memory: 1_000, cores: 1, project_id: project.id, protocol: 2}

    refute MapSet.member?(Workers.holders(demand), old.id)
    assert {:error, {:no_template, _why}} = Workers.provide(demand)
    assert {:ok, %{id: id}} = Workers.provide(%{demand | protocol: 1})
    assert id == old.id
  end

  # A machine that could never hold the old job is not held for it.
  test "a machine too small for the old job is still offered to the young one", context do
    reserve_after(context, :timer.minutes(10))
    occupy(context)
    small_machine = FakeWorker.connect(memory_budget: 4_000, cores: 8, project: context.project)
    _big = context |> admit("big", 8_000) |> age(:timer.minutes(11))
    small = admit(context, "small", 3_000)
    start_supervised!(Scheduler)

    assert Scheduler.tick() == 1
    assert Jobs.get!(small.id).worker_id == small_machine.id
  end

  describe "holders/1" do
    test "are the machines that could take the job once empty, not the ones with room now",
         context do
      occupy(context)
      small_machine = FakeWorker.connect(memory_budget: 4_000, cores: 8, project: context.project)

      demand = %{
        kind: :workflow,
        memory: 8_000,
        cores: 1,
        project_id: context.project.id,
        harness: "claude_code"
      }

      holders = Workers.holders(demand)
      assert MapSet.member?(holders, context.worker.id)
      refute MapSet.member?(holders, small_machine.id)

      # One dimension at a time, so each is seen to count on its own.
      refute MapSet.member?(Workers.holders(%{demand | cores: 9}), context.worker.id)
      refute MapSet.member?(Workers.holders(%{demand | memory: 10_001}), context.worker.id)

      refute MapSet.member?(
               Workers.holders(
                 Map.put(demand, :protocol, ForgeCore.WorkerProtocol.current() + 1)
               ),
               context.worker.id
             )

      refute MapSet.member?(Workers.holders(%{demand | harness: "other"}), context.worker.id)
      assert Workers.holders(%{demand | project_id: Ecto.UUID.generate()}) == MapSet.new()

      {:ok, _worker} = Workers.update(Workers.get!(context.worker.id), %{accepts: [:workflow]})
      assert MapSet.member?(Workers.holders(demand), context.worker.id)
      refute MapSet.member?(Workers.holders(%{demand | kind: :command}), context.worker.id)
    end
  end
end
