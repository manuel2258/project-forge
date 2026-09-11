defmodule Forge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ForgeWeb.Telemetry,
        Forge.Repo,
        {DNSCluster, query: Application.get_env(:forge, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Forge.PubSub},
        {Task.Supervisor, name: Forge.TaskSupervisor},
        # Start to serve requests, typically the last entry
        ForgeWeb.Endpoint
      ] ++ scheduler()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Forge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  # The scheduler runs jobs on this node; off in tests, which drive jobs explicitly.
  defp scheduler do
    if Forge.Jobs.config(:run_jobs, true), do: [Forge.Jobs.Scheduler], else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    ForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
