defmodule Forge.WarmSchedulerTest do
  @moduledoc """
  A command prefers the machine holding its ticket's warm build and waits for it for two minutes
  (`docs/design/provisioning.md` § Affinity on resume): taken when it has room, waited for when it
  has none but would take the command, and never placed anywhere the gate does not allow.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.WarmFixtures, only: [kept!: 3, ticket_in_checking!: 0]

  alias Forge.{FakeWorker, Jobs, Operator, Repo}
  alias Forge.Jobs.Scheduler
  alias Forge.Workers.{ProjectWorker, Worker}

  # The wait is judged from when the job became pending, so a test ages a job to leave it.
  defp age(job, ms) do
    job
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), -ms, :millisecond))
    |> Repo.update!()
  end

  defp wait(job), do: job.id |> Jobs.get!() |> Jobs.current_wait()

  defp placed(commands) do
    commands |> Enum.map(&Jobs.get!(&1.id)) |> Enum.filter(&(&1.status == :running))
  end

  defp waiting(commands) do
    commands |> Enum.map(&Jobs.get!(&1.id)) |> Enum.filter(&(&1.status == :pending))
  end

  # An older machine with room for everything, and the machine that kept the ticket's build, with
  # room for `warm_room` commands of 4000 bytes. The first command has run there and kept it.
  defp ticket_with_a_copy(warm_room) do
    %{project: project, ticket: ticket, commands: [first | rest]} =
      context = ticket_in_checking!()

    previous = Application.get_env(:forge, Forge.Jobs)
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)

    old = FakeWorker.connect(memory_budget: 100_000, cores: 64, project: project)
    warm = FakeWorker.connect(memory_budget: 4_000 * warm_room, cores: 8, project: project)

    assignment = FakeWorker.assign(first, warm)
    warm_facts = %{"source" => "clone", "kept" => true, "size" => 10}
    {:ok, _job} = FakeWorker.finish_command(assignment, 0, warm: warm_facts)
    assert Forge.WarmBuilds.current(ticket).worker.id == warm.id

    start_supervised!(Scheduler)
    Map.merge(context, %{old: old, warm: warm, rest: rest})
  end

  test "the machine holding the copy is taken over an older one that also has room" do
    %{rest: rest, warm: warm} = ticket_with_a_copy(10)

    assert Scheduler.tick() == 3
    assert Enum.map(placed(rest), & &1.worker_id) == [warm.id, warm.id, warm.id]
  end

  test "a full machine is waited for, with the sentence, and no other is used meanwhile" do
    %{rest: rest, warm: warm, old: old} = ticket_with_a_copy(1)

    assert Scheduler.tick() == 1
    assert [on_warm] = placed(rest)
    assert on_warm.worker_id == warm.id

    assert [one, two] = waiting(rest)

    for job <- [one, two] do
      assert %{payload: %{"reason" => "warm", "text" => text}} = wait(job)
      assert text == ForgeCore.WarmBuild.wait_sentence()
    end

    refute Repo.get(Worker, old.id).status == :busy
  end

  test "after two minutes the command goes to any machine with room" do
    %{rest: rest, warm: warm, old: old} = ticket_with_a_copy(1)
    assert Scheduler.tick() == 1

    [one, two] = waiting(rest)
    age(one, :timer.minutes(1))
    age(two, :timer.minutes(1))
    assert Scheduler.tick() == 0
    assert wait(one).payload["reason"] == "warm"

    age(one, :timer.minutes(3))
    age(two, :timer.minutes(3))
    assert Scheduler.tick() == 2

    assert rest |> placed() |> Enum.map(& &1.worker_id) |> Enum.sort() ==
             Enum.sort([warm.id, old.id, old.id])
  end

  # Each puts the warm machine out of reach of a command that would otherwise wait for it, or takes
  # away the reason to prefer it. The warm machine only has room for one command, so a command that
  # waited anyway would show: every one of them goes to the other machine at once.
  defp break_it(:disconnected, ctx) do
    # `FakeWorker.connect/1` registered this process as the machine's channel.
    Registry.unregister(Forge.Workers.Registry, ctx.warm.id)
  end

  defp break_it(:destroyed, ctx), do: set(ctx.warm, status: :destroyed)
  defp break_it(:unhealthy, ctx), do: set(ctx.warm, unhealthy_at: DateTime.utc_now(:second))
  defp break_it(:updating, ctx), do: set(ctx.warm, updating_at: DateTime.utc_now(:second))
  defp break_it(:takes_no_commands, ctx), do: set(ctx.warm, accepts: [:workflow])

  defp break_it(:no_longer_serves_the_project, ctx),
    do: Repo.delete_all(from a in ProjectWorker, where: a.worker_id == ^ctx.warm.id)

  defp break_it(:warm_start_off, ctx) do
    for job <- ctx.rest do
      job
      |> Ecto.Changeset.change(spec: put_in(job.spec, ["command", "warm_start"], false))
      |> Repo.update!()
    end
  end

  defp break_it(:cleared, ctx),
    do: {:ok, _ticket} = Operator.clear_warm_build(ctx.ticket, ctx.user)

  defp set(worker, changes),
    do: Repo.update_all(from(w in Worker, where: w.id == ^worker.id), set: changes)

  describe "does not wait" do
    for name <- ~w(disconnected destroyed unhealthy updating takes_no_commands
                   no_longer_serves_the_project warm_start_off cleared)a do
      test "when #{name}" do
        ctx = ticket_with_a_copy(1)
        break_it(unquote(name), ctx)

        assert Scheduler.tick() == 3
        assert waiting(ctx.rest) == []

        # A machine put out of reach is not used; a copy that is cleared, or a command that turns
        # it off, leaves the warm machine as good as any other.
        if unquote(name) not in [:warm_start_off, :cleared] do
          assert ctx.rest |> placed() |> Enum.map(& &1.worker_id) == List.duplicate(ctx.old.id, 3)
        end
      end
    end
  end

  # A machine held for an older job is not one a command may wait for: `would_take?/3` is the gate
  # a preference waits behind, and it asks for the reservation as a placement does.
  test "a machine reserved for an older job is not waited for" do
    %{project: project, warm: warm} = ticket_with_a_copy(1)
    demand = %{kind: :command, memory: 4_000, cores: 1, project_id: project.id}

    assert Forge.Workers.would_take?(demand, warm.id, MapSet.new())
    refute Forge.Workers.would_take?(demand, warm.id, MapSet.new([warm.id]))
  end

  test "a machine outside the project is never used, copy or not" do
    %{project: project, ticket: ticket, rest: rest, old: old, warm: warm} = ticket_with_a_copy(10)
    stranger = FakeWorker.connect(memory_budget: 100_000, cores: 64)
    kept!(ticket, stranger, ago: 1)
    refute Repo.get_by(ProjectWorker, worker_id: stranger.id, project_id: project.id)

    assert Scheduler.tick() == 3
    ids = rest |> placed() |> Enum.map(& &1.worker_id)
    assert length(ids) == 3
    refute stranger.id in ids
    assert Enum.all?(ids, &(&1 in [old.id, warm.id]))
  end
end
