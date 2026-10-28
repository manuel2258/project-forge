defmodule ForgeWorker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        # One runner per running job; started by the link, gone when the job ends.
        {DynamicSupervisor, name: ForgeWorker.Job.Supervisor, strategy: :one_for_one},
        # A conversation is reached by its job id for as long as it is running, because unlike
        # a job it is spoken to while it runs.
        {Registry, keys: :unique, name: ForgeWorker.Job.Registry},
        {Task.Supervisor, name: ForgeWorker.TaskSupervisor},
        # Whether this machine can still run anything: asks PID 1 once a minute, hears from a run
        # whose `systemd-run` could not, and is what the link asks before it takes work.
        ForgeWorker.Health
      ] ++ link()

    # A worker that was killed left its jobs' archives mounted; nothing may walk a job directory
    # under one (`docs/design/archive.md` § The worker's side).
    ForgeWorker.Archive.sweep(Path.join(ForgeWorker.Config.root(), "jobs"))

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ForgeWorker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A machine that has not been told who it is and where the platform is has nothing to dial.
  # That is the case in tests and in a shell on a half-built image, and it is not an error:
  # the release starts, says so, and waits to be configured.
  defp link do
    cond do
      not Application.get_env(:forge_worker, :connect, true) -> []
      ForgeWorker.Config.configured?() -> [ForgeWorker.Link]
      true -> log_unconfigured()
    end
  end

  defp log_unconfigured do
    Logger.warning(
      "no platform configured: set FORGE_WORKER_ID, FORGE_WORKER_TOKEN and FORGE_PLATFORM_URL"
    )

    []
  end
end
