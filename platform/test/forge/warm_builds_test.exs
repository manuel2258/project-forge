defmodule Forge.WarmBuildsTest do
  @moduledoc """
  A ticket's warm build on the platform (`docs/design/worker-tier.md` § The command copy): what a
  command's spec and assignment say about it, what is recorded of what a worker reported, which
  copy the ticket's next command is sent to, and the clear that makes every copy unusable.

  The scheduler's preference is `Forge.WarmSchedulerTest`'s, and the pages and the API have theirs.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.WarmFixtures, only: [kept!: 2, kept!: 3, ticket_in_checking!: 0]

  alias Forge.{Events, FakeWorker, Jobs, Operator, Repo, Tickets, WarmBuilds, Workers}

  @kept %{"source" => "clone", "kept" => true, "size" => 4096}

  defp worker(project), do: FakeWorker.connect(project: project)

  defp events(ticket, type),
    do: ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == type))

  describe "what a command's spec, assignment and row say" do
    test "the spec carries what the command declares, and a command that declares nothing keeps nothing" do
      %{commands: [build, test | _]} = ticket_in_checking!()

      assert %{"keep_build" => [0, 1], "warm_start" => true} = Jobs.spec(test).command
      assert Jobs.spec(build).command["keep_build"] == []
      assert Jobs.spec(build).command["warm_start"] == true
    end

    test "the assignment names the ticket and its epoch, and the row keeps the epoch it started with" do
      %{project: project, ticket: ticket, commands: [_build, first, second | _], user: user} =
        ticket_in_checking!()

      worker = worker(project)

      assignment = FakeWorker.assign(first, worker)
      assert assignment["warm"] == %{"ticket" => ticket.id, "epoch" => 0}
      assert Jobs.get!(first.id).warm_epoch == 0

      {:ok, _ticket} = Operator.clear_warm_build(ticket, user)

      assignment = FakeWorker.assign(second, worker)
      assert assignment["warm"] == %{"ticket" => ticket.id, "epoch" => 1}
      assert Jobs.get!(second.id).warm_epoch == 1
    end
  end

  describe "recording what a worker reported" do
    setup do
      context = ticket_in_checking!()
      Map.put(context, :worker, worker(context.project))
    end

    defp run!(job, worker, warm) do
      assignment = FakeWorker.assign(job, worker)
      {:ok, finished} = FakeWorker.finish_command(assignment, 0, warm: warm)
      finished
    end

    test "the facts are on the row, and a kept build has its size",
         %{commands: [_ | [test | _]]} = c do
      row = run!(test, c.worker, @kept)

      assert %{warm_source: "clone", warm_kept: true, warm_size: 4096, warm_unkept: nil} = row
      assert row.warm_from_id == nil
    end

    test "a build not kept says why, and has no size", %{commands: [_ | [test | _]]} = c do
      row =
        run!(test, c.worker, %{
          "source" => "ticket",
          "kept" => false,
          "unkept" => "timeout",
          "size" => 9
        })

      assert %{warm_source: "ticket", warm_kept: false, warm_unkept: "timeout", warm_size: nil} =
               row
    end

    test "the command a tree came from is kept when it is one of the ticket's",
         %{
           commands: [_, first, second | _]
         } = c do
      run!(first, c.worker, @kept)

      row = run!(second, c.worker, %{"source" => "copy", "from" => first.id, "kept" => true})
      assert %{warm_source: "copy", warm_from_id: from} = row
      assert from == first.id
    end

    test "a `from` that is another ticket's job, or no job at all, is dropped",
         %{
           commands: commands
         } = c do
      elsewhere = job_fixture(%{ticket: ticket_fixture(%{project: c.project}), kind: :command})
      froms = [elsewhere.id, Ecto.UUID.generate(), "not-a-uuid", 7]

      for {job, from} <- Enum.zip(commands, froms) do
        row = run!(job, c.worker, %{"source" => "copy", "from" => from, "kept" => false})
        assert row.warm_source == "copy"
        assert row.warm_from_id == nil
      end
    end

    test "a source or a reason the platform does not know is dropped, not stored",
         %{
           commands: [_, first | _]
         } = c do
      row =
        run!(first, c.worker, %{"source" => "the moon", "kept" => false, "unkept" => "boredom"})

      assert row.warm_source == nil
      assert row.warm_unkept == nil
      assert row.warm_kept == false
    end

    test "a worker that reports nothing leaves every fact empty",
         %{commands: [_, first | _]} = c do
      row = run!(first, c.worker, nil)

      assert %{warm_source: nil, warm_kept: nil, warm_unkept: nil, warm_size: nil} = row
      assert row.warm_from_id == nil
    end
  end

  describe "declared?/1" do
    test "is true when a command of the pinned workflow keeps its build" do
      %{ticket: ticket} = ticket_in_checking!()
      assert WarmBuilds.declared?(ticket)
    end

    test "is false when none does, and for a pin that can no longer be built" do
      ticket = ticket_fixture()
      refute WarmBuilds.declared?(ticket)

      refute WarmBuilds.declared?(%{ticket | workflow: %{"version" => "nonsense"}})
    end
  end

  describe "current/1" do
    setup do
      ticket = ticket_fixture()
      worker = FakeWorker.connect()
      %{ticket: ticket, worker: worker}
    end

    test "is nothing when no command kept its build", %{ticket: ticket, worker: worker} do
      assert WarmBuilds.current(ticket) == nil
      kept!(ticket, worker, warm_kept: false)
      assert WarmBuilds.current(ticket) == nil
    end

    test "is the latest kept command, its machine, size and time", %{
      ticket: ticket,
      worker: worker
    } do
      kept!(ticket, worker, ago: 600, size: 1)
      latest = kept!(ticket, worker, ago: 60, size: 2)

      assert %{job: job, worker: found, size: 2, kept_at: kept_at} = WarmBuilds.current(ticket)
      assert job.id == latest.id
      assert found.id == worker.id
      assert kept_at == latest.finished_at
    end

    test "prefers the machine of the latest copy, whichever was first", %{
      ticket: ticket,
      worker: worker
    } do
      other = FakeWorker.connect()
      kept!(ticket, worker, ago: 600)
      kept!(ticket, other, ago: 60)

      assert %{worker: %{id: id}} = WarmBuilds.current(ticket)
      assert id == other.id
    end

    test "is not a copy on a destroyed machine, and falls back to the one before it", %{
      ticket: ticket,
      worker: worker
    } do
      gone = FakeWorker.connect()
      kept!(ticket, worker, ago: 600)
      kept!(ticket, gone, ago: 60)

      Repo.update_all(from_id(gone.id), set: [status: :destroyed])

      assert %{worker: %{id: id}} = WarmBuilds.current(ticket)
      assert id == worker.id

      Repo.update_all(from_id(worker.id), set: [status: :destroyed])
      assert WarmBuilds.current(ticket) == nil
    end

    test "is not a copy past its two days, counted from the ticket's last command there", %{
      ticket: ticket,
      worker: worker
    } do
      three_days = 3 * 24 * 3600
      kept!(ticket, worker, ago: three_days)
      assert WarmBuilds.current(ticket) == nil

      # A later command that kept nothing still touched the copy on the machine.
      kept!(ticket, worker, ago: 3600, warm_kept: false)
      assert %{worker: %{id: id}} = WarmBuilds.current(ticket)
      assert id == worker.id
    end

    test "the retention is the platform's setting", %{ticket: ticket, worker: worker} do
      previous = Application.get_env(:forge, Forge.Jobs)
      on_exit(fn -> Application.put_env(:forge, Forge.Jobs, previous) end)

      Application.put_env(
        :forge,
        Forge.Jobs,
        Keyword.put(previous || [], :warm_retention_ms, 1_000)
      )

      kept!(ticket, worker, ago: 60)
      assert WarmBuilds.current(ticket) == nil
    end

    test "is not a copy another ticket's command left", %{ticket: ticket, worker: worker} do
      kept!(ticket_fixture(), worker)
      assert WarmBuilds.current(ticket) == nil
    end

    test "is not a copy kept before a clear, nor by a command assigned before it", %{
      ticket: ticket,
      worker: worker
    } do
      kept!(ticket, worker)
      assert WarmBuilds.current(ticket)

      cleared = Repo.update!(Ecto.Changeset.change(ticket, warm_epoch: 1))
      assert WarmBuilds.current(cleared) == nil

      # Assigned in epoch 0, finished after the clear: it kept a copy no command may use.
      kept!(cleared, worker, epoch: 0, ago: 5)
      assert WarmBuilds.current(cleared) == nil

      kept!(cleared, worker, epoch: 1, ago: 1)
      assert %{job: %{warm_epoch: 1}} = WarmBuilds.current(cleared)
    end
  end

  describe "preferred_worker/1" do
    setup do
      ticket = ticket_fixture()
      worker = FakeWorker.connect()
      kept!(ticket, worker)
      %{ticket: ticket, worker: worker}
    end

    defp command(ticket, warm_start) do
      job_fixture(%{
        ticket: ticket,
        kind: :command,
        attempt: System.unique_integer([:positive]),
        spec: %{"command" => %{"name" => "test", "warm_start" => warm_start}}
      })
    end

    test "is the machine holding the copy, for a command that starts from it", %{
      ticket: ticket,
      worker: worker
    } do
      assert WarmBuilds.preferred_worker(command(ticket, true)) == worker.id
    end

    test "is nothing for a command that turns it off", %{ticket: ticket} do
      assert WarmBuilds.preferred_worker(command(ticket, false)) == nil
    end

    test "is nothing for an agent's job, a conversation's, or a ticket with no copy", %{
      ticket: ticket
    } do
      assert WarmBuilds.preferred_worker(job_fixture(%{ticket: ticket})) == nil
      assert WarmBuilds.preferred_worker(chat_fixture()) == nil
      assert WarmBuilds.preferred_worker(command(ticket_fixture(), true)) == nil
    end
  end

  describe "clearing" do
    setup do
      context = ticket_in_checking!()
      worker = worker(context.project)
      kept!(context.ticket, worker)
      Map.put(context, :worker, worker)
    end

    test "raises the epoch, says who in Activity, and leaves no copy", %{
      ticket: ticket,
      user: user
    } do
      assert WarmBuilds.current(ticket)

      assert {:ok, cleared} = Operator.clear_warm_build(ticket, user)
      assert cleared.warm_epoch == 1
      assert Tickets.get!(ticket.id).warm_epoch == 1
      assert WarmBuilds.current(cleared) == nil

      assert [%{actor: actor, payload: %{"epoch" => 1}}] = events(ticket, "ticket.warm_cleared")
      assert actor == %{"kind" => "user", "id" => user.id}

      assert {:ok, again} = Operator.clear_warm_build(cleared, user)
      assert again.warm_epoch == 2
    end

    test "is every member's, and nobody else's, guarded on the act", %{ticket: ticket} do
      outsider = Forge.AccountsFixtures.user_fixture()

      assert {:error, _reason} = Operator.clear_warm_build(ticket, outsider)
      assert Tickets.get!(ticket.id).warm_epoch == 0
      assert events(ticket, "ticket.warm_cleared") == []

      member = member_fixture(Forge.Projects.get!(ticket.project_id), :member)
      assert {:ok, %{warm_epoch: 1}} = Operator.clear_warm_build(ticket, member)
    end

    test "an event describes it", %{ticket: ticket, user: user} do
      {:ok, _cleared} = Operator.clear_warm_build(ticket, user)
      [event] = events(ticket, "ticket.warm_cleared")

      assert Events.summary(event) =~ "cleared the warm build"
    end
  end

  defp from_id(id), do: from(w in Workers.Worker, where: w.id == ^id)
end
