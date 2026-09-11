defmodule Mix.Tasks.Forge.Transition do
  @shortdoc "Takes a transition by hand: mix forge.transition PROJECT#N TO [--user EMAIL]"
  @moduledoc "Moves a ticket from a human state, or unsticks it, along any declared transition."

  use Mix.Task

  alias Forge.{CLI, Engine}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [user: :string])

    case positional do
      [ref, to] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)

        case Engine.choose(ticket, user.id, to) do
          {:ok, ticket} ->
            Mix.shell().info("#{CLI.label(ticket)} is now in #{ticket.state} (#{ticket.status})")

          {:error, reason} ->
            CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.transition PROJECT#N TO [--user EMAIL]")
    end
  end
end
