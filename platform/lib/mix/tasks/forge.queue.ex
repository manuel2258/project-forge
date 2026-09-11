defmodule Mix.Tasks.Forge.Queue do
  @shortdoc "Prints the operator queue"
  @moduledoc "Everything waiting on a human: questions, approvals, stuck and review-ready tickets."

  use Mix.Task

  alias Forge.CLI

  @impl true
  def run(_args) do
    CLI.boot()
    Mix.shell().info(CLI.queue())
  end
end
