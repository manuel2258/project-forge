defmodule Mix.Tasks.Forge.Admit do
  @shortdoc "Admits a ticket: mix forge.admit PROJECT TITLE (--start | --hold) [--milestone NAME] [--type TYPE] [--body-file FILE] [--user EMAIL]"
  @moduledoc """
  Admits a ticket to a project. **Exactly one of `--start` and `--hold` is required**, with neither
  chosen for you: `--start` creates its first pending job, `--hold` admits it on hold, running
  nothing until it is released (`docs/design/workflow-grammar-v1.md` § Holding a ticket).
  `--milestone` names an open milestone of the project to put it in, at the bottom of that order.
  `--type` names the ticket type, required when the project's `.forge/workflows/` holds more than
  one (`docs/design/ticket-types.md`).
  """

  use Mix.Task

  alias Forge.{CLI, Projects, Tickets}

  @usage "usage: mix forge.admit PROJECT TITLE (--start | --hold) [--milestone NAME] " <>
           "[--type TYPE] [--body-file FILE] [--user EMAIL]"

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          body_file: :string,
          user: :string,
          type: :string,
          start: :boolean,
          hold: :boolean,
          milestone: :string
        ]
      )

    case positional do
      [project_name, title] -> admit(project_name, title, opts)
      _ -> CLI.fail(@usage)
    end
  end

  defp admit(project_name, title, opts) do
    CLI.boot()
    project = Projects.by_name(project_name) || CLI.fail("unknown project #{project_name}")
    user = CLI.user(opts)
    body = if path = Keyword.get(opts, :body_file), do: File.read!(path), else: ""
    on_hold = on_hold(opts)

    attrs = %{
      title: title,
      body: body,
      ticket_type: Keyword.get(opts, :type),
      on_hold: on_hold,
      milestone_id: milestone_id(project, Keyword.get(opts, :milestone))
    }

    case Tickets.admit(project, attrs, {:user, user.id}) do
      {:ok, ticket} ->
        Mix.shell().info(
          "admitted #{CLI.label(ticket)} in state #{ticket.state}" <>
            if(on_hold, do: ", on hold", else: "")
        )

      {:error, errors} when is_list(errors) ->
        CLI.fail("workflow invalid:\n" <> ForgeCore.Error.format(errors))

      {:error, reason} ->
        CLI.fail(ForgeWeb.Operator.Admission.explain(reason))
    end
  end

  defp milestone_id(_project, nil), do: nil
  defp milestone_id(project, name), do: milestone_named(project, name)

  # Exactly one, so that nothing is started or held by leaving a flag off.
  defp on_hold(opts) do
    case {Keyword.get(opts, :start, false), Keyword.get(opts, :hold, false)} do
      {true, false} -> false
      {false, true} -> true
      _neither_or_both -> CLI.fail("say whether to --start the ticket or --hold it: exactly one")
    end
  end

  defp milestone_named(project, name) do
    case Enum.find(Forge.Milestones.list(project.id), &(&1.name == name)) do
      nil -> CLI.fail("unknown milestone #{name} in #{project.name}")
      milestone -> milestone.id
    end
  end
end
