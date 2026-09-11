defmodule Mix.Tasks.Forge.Edit do
  @shortdoc "Writes a new version of a document: mix forge.edit PROJECT#N NAME FILE [--user EMAIL]"
  @moduledoc "A human edit is a new version like any other, authored by the user."

  use Mix.Task

  alias Forge.{Artifacts, CLI}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [user: :string])

    case positional do
      [ref, name, file] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)

        case Artifacts.record_version(ticket.id, name, :document, {:user, user.id}, %{
               content: File.read!(file)
             }) do
          {:ok, version} ->
            Mix.shell().info("wrote #{name} v#{version.version}")

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
