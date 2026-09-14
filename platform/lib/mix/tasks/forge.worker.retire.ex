defmodule Mix.Tasks.Forge.Worker.Retire do
  @shortdoc "Ends a worker: mix forge.worker.retire WORKER_ID"

  @moduledoc """
  Marks a worker destroyed, and destroys its machine if the platform made one.

  This is the only way an unmanaged worker ends. Neither sweep will touch it — that is what
  `mix forge.worker.new` buys — so a machine the operator has finished with needs saying so,
  or it counts against `max_workers` for ever.

  Destruction is the platform's record that the machine is gone: the token stops working and a
  machine that disagrees is refused at the socket. So retire the row *after* the machine is
  off, or be ready for a worker retrying against a platform that will not have it.

  Jobs the worker was running are re-queued, as they are whenever a machine is lost.
  """

  use Mix.Task

  alias Forge.{CLI, Jobs, Workers}

  @impl true
  def run(args) do
    case args do
      [id] -> retire(id)
      _other -> CLI.fail("usage: mix forge.worker.retire WORKER_ID")
    end
  end

  defp retire(id) do
    CLI.boot()

    worker = Workers.get(id) || CLI.fail("unknown worker #{id}")

    if worker.status == :destroyed do
      Mix.shell().info("#{worker.id} is already destroyed")
    else
      jobs = Jobs.running_on(worker.id)
      Enum.each(jobs, &Jobs.requeue(&1.id, :worker_retired))
      if jobs != [], do: Mix.shell().info("re-queued #{length(jobs)} job(s)")

      case Workers.destroy(worker) do
        :ok -> Mix.shell().info("#{worker.id} destroyed")
        {:error, reason} -> CLI.fail("could not destroy #{worker.id}: #{inspect(reason)}")
      end
    end
  end
end
