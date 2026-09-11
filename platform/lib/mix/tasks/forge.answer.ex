defmodule Mix.Tasks.Forge.Answer do
  @shortdoc "Answers a question: mix forge.answer PROJECT#N KEY (--choice X | --text T) [--user EMAIL]"
  @moduledoc "Answers an open question. A waiting job resumes once none of its blocking questions are open."

  use Mix.Task

  alias Forge.{Artifacts, CLI, Jobs}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [choice: :string, text: :string, user: :string])

    case positional do
      [ref, key] ->
        CLI.boot()
        ticket = CLI.ticket(ref)
        user = CLI.user(opts)

        question =
          Artifacts.find_open_question(ticket.id, key) ||
            CLI.fail("no open question #{key} on #{ref}")

        case Artifacts.answer(question, user.id, %{choice: opts[:choice], text: opts[:text]}) do
          {:ok, _answer} ->
            Mix.shell().info("answered #{key}")
            resume_if_unblocked(ticket, question)

          {:error, reason} ->
            CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.answer PROJECT#N KEY (--choice X | --text T) [--user EMAIL]")
    end
  end

  defp resume_if_unblocked(ticket, question) do
    job_id = question.artifact_version.author["id"]

    with %{status: :waiting} = job <- Jobs.get!(job_id),
         [] <- Artifacts.open_blocking_questions(job.id),
         {:ok, _} <- Jobs.resume(job) do
      Mix.shell().info("job #{job.state} ##{job.attempt} on #{CLI.label(ticket)} will resume")
    else
      _ -> :ok
    end
  end
end
