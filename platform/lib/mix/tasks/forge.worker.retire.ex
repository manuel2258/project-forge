defmodule Mix.Tasks.Forge.Worker.Retire do
  @shortdoc "Ends a worker: mix forge.worker.retire WORKER_ID"

  @moduledoc """
  Marks a worker destroyed, and destroys its machine if the platform made one.

  This is the only way an unmanaged worker ends. Neither sweep will touch it — that is what
  `mix forge.worker.new` buys — so a machine the operator has finished with needs saying so,
  or its row stays for ever.

  Destruction is the platform's record that the machine is gone: the token stops working and a
  machine that disagrees is refused at the socket. So retire the row *after* the machine is
  off, or be ready for a worker retrying against a platform that will not have it.

  Jobs the worker was running are re-queued, as they are whenever a machine is lost.

  **A destroy the driver refuses leaves the row alone**, so the machine goes on being counted
  and the next sweep tries again rather than the platform forgetting a machine that is still
  billing. `--force` retires the row anyway, and is for the case where the operator has looked
  at the provider and knows better than the platform can.
  """

  use Mix.Task

  alias Forge.{CLI, Jobs, Workers}

  @impl true
  def run(args) do
    case args do
      [id] -> retire(id, [])
      [id, "--force"] -> retire(id, force: true)
      _other -> CLI.fail("usage: mix forge.worker.retire WORKER_ID [--force]")
    end
  end

  defp retire(id, opts) do
    CLI.boot()

    worker = Workers.get(id) || CLI.fail("unknown worker #{id}")

    if worker.status == :destroyed do
      Mix.shell().info("#{worker.id} is already destroyed")
    else
      jobs = Jobs.running_on(worker.id)
      Enum.each(jobs, &Jobs.requeue(&1.id, :worker_retired))
      if jobs != [], do: Mix.shell().info("re-queued #{length(jobs)} job(s)")

      case Workers.destroy(worker, opts) do
        :ok ->
          Mix.shell().info("#{worker.id} destroyed")

        {:error, reason} ->
          CLI.fail(
            "could not destroy #{worker.id}: #{inspect(reason)}. The row is kept, so the " <>
              "machine is still counted and the next sweep will try again. If you have " <>
              "checked the provider and the machine is gone, retire it with --force."
          )
      end
    end
  end
end
