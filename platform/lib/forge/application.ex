defmodule Forge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        ForgeWeb.Telemetry,
        Forge.Repo,
        {DNSCluster, query: Application.get_env(:forge, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Forge.PubSub},
        {Task.Supervisor, name: Forge.TaskSupervisor},
        # Where a connected worker's channel process registers itself, so the platform has
        # somewhere to look when it wants to speak to a machine.
        {Registry, keys: :unique, name: Forge.Workers.Registry},
        # Start to serve requests, typically the last entry
        ForgeWeb.Endpoint
      ] ++ scheduler() ++ digest()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Forge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  # The daily digest goes out from the node that runs jobs, and only when push is configured; so
  # does the push for whatever starts waiting on a person.
  defp digest do
    if Forge.Jobs.config(:run_jobs, true) and Forge.Push.enabled?() do
      [
        {Forge.Push.Digest,
         hour_utc: Application.get_env(:forge, Forge.Push, [])[:digest_hour_utc] || 9},
        Forge.Push.Watch
      ]
    else
      []
    end
  end

  # The scheduler runs jobs on this node; off in tests, which drive jobs explicitly.
  #
  # Recovery is a task beside it rather than part of its `init/1`, and once per boot rather than
  # once per restart. In the scheduler it meant a crash in one scheduling pass recovered the
  # whole node: every running conversation went dormant because one job raised. A task runs when
  # the tree comes up and then finishes, which is what "on boot" means.
  defp scheduler do
    if Forge.Jobs.config(:run_jobs, true),
      do: [{Task, &recover/0}, Forge.Jobs.Scheduler],
      else: []
  end

  defp recover do
    case Forge.Jobs.recover() do
      0 -> :ok
      count -> Logger.info("recovered #{count} interrupted job(s) from a previous run")
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    ForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
