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
