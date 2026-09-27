defmodule Mix.Tasks.Forge.Worker.RetireTest do
  @moduledoc """
  Retiring a worker by hand — the only way an unmanaged machine ever ends.

  The task's doc promises "Jobs the worker was running are re-queued, as they are whenever a
  machine is lost", and the line it prints about them cannot show whether that happened: it counts
  the jobs it *found*, not the ones it moved. So a retire that re-queued nothing would report
  "re-queued 1 job(s)", destroy the row, and strand the job in `running` on a machine that no
  longer exists — where nothing sweeps it, because the sweeps are about workers.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Jobs, Workers}
  alias Mix.Tasks.Forge.Worker.Retire

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp running_on(worker) do
    job_fixture()
    |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
    |> Repo.update!()
  end

  test "the work the machine was holding goes back on the queue" do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    job = running_on(worker)

    Retire.run([worker.id])

    assert Jobs.get!(job.id).status == :pending
    assert Workers.get!(worker.id).status == :destroyed
    assert_received {:mix_shell, :info, ["re-queued 1 job(s)"]}
  end

  # **Requeued once the row is destroyed, and not before.** The machine a refused destroy leaves
  # behind is still running its jobs, and requeued beside it they would run twice
  # (`docs/design/provisioning.md` § Whose account). It used to requeue first.
  test "a destroy the driver refuses leaves the work where it is, and force moves it" do
    Forge.Provider.Fake.refuse_destroy({:fake, "nope"})
    on_exit(&Forge.Provider.Fake.allow/0)

    {:ok, worker, _token} = Workers.create(%{provider: "fake", provider_id: "fake-1"})
    job = running_on(worker)

    assert_raise Mix.Error, ~r/could not destroy/, fn -> Retire.run([worker.id]) end
    assert Jobs.get!(job.id).status == :running
    refute_received {:mix_shell, :info, ["re-queued" <> _]}

    Retire.run([worker.id, "--force"])
    assert Jobs.get!(job.id).status == :pending
    assert Workers.get!(worker.id).status == :destroyed

    # And the machine's log says who ended it, and that it was forced.
    assert [destroyed] =
             Enum.filter(Forge.Workers.Log.for_worker(worker.id), &(&1.type == "destroyed"))

    assert destroyed.message =~ "retired by force — from the host's command line"
  end

  test "a worker that is already destroyed is said so rather than destroyed twice" do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    :ok = Workers.destroy(worker)

    Retire.run([worker.id])

    assert_received {:mix_shell, :info, [said]}
    assert said =~ "already destroyed"
  end

  test "an unknown worker is refused" do
    assert_raise Mix.Error, ~r/unknown worker/, fn -> Retire.run([Ecto.UUID.generate()]) end
  end
end
