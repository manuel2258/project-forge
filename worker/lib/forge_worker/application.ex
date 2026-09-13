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
        {Task.Supervisor, name: ForgeWorker.TaskSupervisor}
      ] ++ link()

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
