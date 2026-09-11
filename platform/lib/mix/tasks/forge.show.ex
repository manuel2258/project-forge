defmodule Mix.Tasks.Forge.Show do
  @shortdoc "Shows a ticket: mix forge.show PROJECT#N"
  @moduledoc "The ticket's state, jobs, artifacts and event timeline."

  use Mix.Task

  alias Forge.CLI

  @impl true
  def run([ref]) do
    CLI.boot()
    Mix.shell().info(CLI.show(CLI.ticket(ref)))
  end

  def run(_), do: CLI.fail("usage: mix forge.show PROJECT#N")
end
