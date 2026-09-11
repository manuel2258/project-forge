defmodule ForgeWorker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # One runner per running job; started by the manager, gone when the job ends.
      {DynamicSupervisor, name: ForgeWorker.Job.Supervisor, strategy: :one_for_one}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ForgeWorker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
