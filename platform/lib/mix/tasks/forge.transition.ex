defmodule Mix.Tasks.Forge.Transition do
  @shortdoc "Takes a transition by hand: mix forge.transition PROJECT#N TO [--user EMAIL]"
  @moduledoc "Moves a ticket from a human state, or unsticks it, to any state — by the declared transition that reaches it, or by a jump when none does."

  use Mix.Task

  alias Forge.{CLI, Operator}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [user: :string])

    case positional do
      [ref, to] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)

        case Operator.transition(ticket, user, to) do
          {:ok, ticket} ->
            Mix.shell().info("#{CLI.label(ticket)} is now in #{ticket.state} (#{ticket.status})")

          {:error, reason} ->
            CLI.fail(Forge.Engine.refusal(reason) || inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.transition PROJECT#N TO [--user EMAIL]")
    end
  end
end
