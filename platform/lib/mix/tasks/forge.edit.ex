defmodule Mix.Tasks.Forge.Edit do
  @shortdoc "Writes a new version of a document: mix forge.edit PROJECT#N NAME FILE [--user EMAIL]"
  @moduledoc "A human edit is a new version like any other, authored by the user."

  use Mix.Task

  alias Forge.{CLI, Operator}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [user: :string])

    case positional do
      [ref, name, file] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)

        case Operator.edit(ticket, user, name, File.read!(file)) do
          {:ok, _ticket} ->
            Mix.shell().info("wrote a new version of #{name}")

          {:error, {:invalid_document, errors}} ->
            CLI.fail("document invalid:\n" <> ForgeCore.Error.format(errors))

          {:error, reason} ->
            CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.edit PROJECT#N NAME FILE [--user EMAIL]")
    end
  end
end
