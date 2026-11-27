defmodule Forge.WarmCopiesTest do
  @moduledoc """
  The copies of a ticket that a person may look into (`Forge.WarmBuilds.copies/1`, `copy/2`,
  `gone/3`, `explorable_until/2`; `docs/design/worker-tier.md` § Looking into a copy): every machine
  that holds one, the next command's first, a cleared one marked, and a copy reached only through
  its own ticket.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.WarmFixtures, only: [kept!: 2, kept!: 3]

  alias Forge.{FakeWorker, Repo, WarmBuilds}
  alias Forge.Workers.Worker

  setup do
    ticket = ticket_fixture()
    %{ticket: ticket, worker: FakeWorker.connect()}
  end

  describe "copies/1" do
    test "is nothing when no command kept a build", %{ticket: ticket, worker: worker} do
      assert WarmBuilds.copies(ticket) == []
      kept!(ticket, worker, warm_kept: false)
      assert WarmBuilds.copies(ticket) == []
    end

    test "is one row per machine, the latest command that kept a build there", ctx do
      %{ticket: ticket, worker: worker} = ctx
      other = FakeWorker.connect()
      kept!(ticket, worker, ago: 900, size: 1)
      latest_here = kept!(ticket, worker, ago: 300, size: 2)
      there = kept!(ticket, other, ago: 600, size: 3)

      copies = WarmBuilds.copies(ticket)
      assert Enum.map(copies, & &1.job.id) |> Enum.sort() == Enum.sort([latest_here.id, there.id])
      assert Enum.find(copies, &(&1.worker.id == worker.id)).size == 2
    end

    test "has the copy the next command starts from first, and says so", ctx do
      %{ticket: ticket, worker: worker} = ctx
      other = FakeWorker.connect()
      newest = kept!(ticket, other, ago: 60)
      older = kept!(ticket, worker, ago: 600)

      assert [first, second] = WarmBuilds.copies(ticket)
      assert first.job.id == newest.id and first.next?
      assert second.job.id == older.id and not second.next?
    end

    test "carries what a page draws: the command, its arguments, commit, folders and time", ctx do
      %{ticket: ticket, worker: worker} = ctx
      job = kept!(ticket, worker, args: ["--all", "x"], command: "test")
      folders = %{"folders" => [], "rest" => 5}

      Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^job.id),
        set: [warm_folders: folders]
      )

      assert [copy] = WarmBuilds.copies(ticket)

      assert %{
               command: "test",
               args: ["--all", "x"],
               commit: commit,
               folders: ^folders,
               kept_at: kept_at,
               cleared?: false
             } = copy

      assert commit == String.duplicate("c", 40)
      assert kept_at == job.finished_at
    end

    test "keeps a copy kept before a clear, marked cleared, and the next one is not it", ctx do
      %{ticket: ticket, worker: worker} = ctx
      old = kept!(ticket, worker, ago: 600)
      cleared = Repo.update!(Ecto.Changeset.change(ticket, warm_epoch: 1))

      assert [%{job: %{id: id}, cleared?: true, next?: false}] = WarmBuilds.copies(cleared)
      assert id == old.id

      fresh = kept!(cleared, FakeWorker.connect(), epoch: 1, ago: 30)

      assert [first, second] = WarmBuilds.copies(cleared)
      assert first.job.id == fresh.id and first.next? and not first.cleared?
      assert second.job.id == old.id and second.cleared? and not second.next?
    end

    test "leaves out a destroyed machine, one past its two days, and another ticket's copy",
         ctx do
      %{ticket: ticket, worker: worker} = ctx
      gone = FakeWorker.connect()
      old = FakeWorker.connect()
      kept!(ticket, gone, ago: 60)
      kept!(ticket, old, ago: 3 * 24 * 3600)
      kept!(ticket_fixture(), worker, ago: 60)
      Repo.update_all(from(w in Worker, where: w.id == ^gone.id), set: [status: :destroyed])

      assert WarmBuilds.copies(ticket) == []
    end
  end

  describe "copy/2" do
    test "reaches any command of this ticket that kept a build, a replaced one included", ctx do
      %{ticket: ticket, worker: worker} = ctx
      replaced = kept!(ticket, worker, ago: 600)
      latest = kept!(ticket, worker, ago: 60)

      assert {:ok, %{job: %{id: id}, next?: false}} = WarmBuilds.copy(ticket, replaced.id)
      assert id == replaced.id
      assert {:ok, %{next?: true}} = WarmBuilds.copy(ticket, latest.id)
    end

    test "is not another ticket's copy, nor another project's, nor one that kept nothing", ctx do
      %{ticket: ticket, worker: worker} = ctx
      theirs = kept!(ticket_fixture(), worker)
      nothing = kept!(ticket, worker, warm_kept: false)

      assert WarmBuilds.copy(ticket, theirs.id) == :error
      assert WarmBuilds.copy(ticket, nothing.id) == :error
      assert WarmBuilds.copy(ticket, Ecto.UUID.generate()) == :error
      assert WarmBuilds.copy(ticket, "not a uuid") == :error
      assert WarmBuilds.copy(ticket, nil) == :error
    end

    test "is not a copy on a destroyed machine", %{ticket: ticket, worker: worker} do
      job = kept!(ticket, worker)
      Repo.update_all(from(w in Worker, where: w.id == ^worker.id), set: [status: :destroyed])
      assert WarmBuilds.copy(ticket, job.id) == :error
    end
  end

  describe "gone/3" do
    test "says replaced, and by which command, when a later command kept a build there", ctx do
      %{ticket: ticket, worker: worker} = ctx
      old = kept!(ticket, worker, ago: 600)
      newer = kept!(ticket, worker, ago: 60)

      assert %{why: :replaced, replaced_by: %{id: id}} =
               WarmBuilds.gone(ticket, old.id, worker.id)

      assert id == newer.id
      assert %{why: :unknown, replaced_by: nil} = WarmBuilds.gone(ticket, newer.id, worker.id)
    end

    test "says swept when the ticket's last command there is past its two days", ctx do
      %{ticket: ticket, worker: worker} = ctx
      old = kept!(ticket, worker, ago: 3 * 24 * 3600)
      assert %{why: :swept, replaced_by: nil} = WarmBuilds.gone(ticket, old.id, worker.id)
    end

    test "says no more than unknown for an id it cannot place, another ticket's included", ctx do
      %{ticket: ticket, worker: worker} = ctx
      theirs = kept!(ticket_fixture(), worker, ago: 600)
      kept!(ticket, worker, ago: 60)

      assert %{why: :unknown, replaced_by: nil} = WarmBuilds.gone(ticket, theirs.id, worker.id)
      assert %{why: :unknown, replaced_by: nil} = WarmBuilds.gone(ticket, "x", worker.id)
    end
  end

  describe "explorable_until/2" do
    test "is two days after the ticket's last command on the machine, and nil with none", ctx do
      %{ticket: ticket, worker: worker} = ctx
      assert WarmBuilds.explorable_until(ticket, worker.id) == nil

      job = kept!(ticket, worker, ago: 3600)

      assert DateTime.diff(WarmBuilds.explorable_until(ticket, worker.id), job.finished_at) ==
               48 * 3600
    end
  end
end
