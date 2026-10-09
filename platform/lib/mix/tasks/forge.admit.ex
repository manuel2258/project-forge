defmodule Mix.Tasks.Forge.Admit do
  @shortdoc "Admits a ticket: mix forge.admit PROJECT TITLE [--type TYPE] [--body-file FILE] [--user EMAIL]"
  @moduledoc """
  Admits a ticket to a project and creates its first pending job. `--type` names the ticket type,
  required when the project's `.forge/workflows/` holds more than one
  (`docs/design/ticket-types.md`).
  """

  use Mix.Task

  alias Forge.{CLI, Projects, Tickets}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [body_file: :string, user: :string, type: :string])

    case positional do
      [project_name, title] ->
        CLI.boot()
        project = Projects.by_name(project_name) || CLI.fail("unknown project #{project_name}")
        user = CLI.user(opts)
        body = if path = Keyword.get(opts, :body_file), do: File.read!(path), else: ""

        attrs = %{title: title, body: body, ticket_type: Keyword.get(opts, :type)}

        case Tickets.admit(project, attrs, {:user, user.id}) do
          {:ok, ticket} ->
            Mix.shell().info("admitted #{CLI.label(ticket)} in state #{ticket.state}")

          {:error, errors} when is_list(errors) ->
            CLI.fail("workflow invalid:\n" <> ForgeCore.Error.format(errors))

          {:error, reason} ->
            CLI.fail(ForgeWeb.Operator.Admission.explain(reason))
        end

      _ ->
        CLI.fail(
          "usage: mix forge.admit PROJECT TITLE [--type TYPE] [--body-file FILE] [--user EMAIL]"
        )
    end
  end
end
