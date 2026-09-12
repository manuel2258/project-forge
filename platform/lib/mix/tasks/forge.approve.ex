defmodule Mix.Tasks.Forge.Approve do
  @shortdoc "Decides a pending transition: mix forge.approve PROJECT#N [--reject] [--comment C] [--user EMAIL]"
  @moduledoc "Approves (default) or rejects the artifacts a pending transition asks for."

  use Mix.Task

  alias Forge.{CLI, Operator}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [reject: :boolean, comment: :string, user: :string])

    case positional do
      [ref] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)
        decision = if opts[:reject], do: :rejected, else: :approved

        case Operator.decide(ticket, user, decision, opts[:comment]) do
          {:ok, ticket} ->
            Mix.shell().info("#{decision}; #{CLI.label(ticket)} is now in #{ticket.state}")

          {:error, reason} ->
            CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.approve PROJECT#N [--reject] [--comment C] [--user EMAIL]")
    end
  end
end
