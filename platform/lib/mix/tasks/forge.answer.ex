defmodule Mix.Tasks.Forge.Answer do
  @shortdoc "Answers a question: mix forge.answer PROJECT#N KEY (--choice X | --text T) [--user EMAIL]"
  @moduledoc "Answers an open question. A waiting job resumes once none of its blocking questions are open."

  use Mix.Task

  alias Forge.{CLI, Operator}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [choice: :string, text: :string, user: :string])

    case positional do
      [ref, key] ->
        CLI.boot()
        ticket = CLI.ticket(ref)

        case Operator.answer(ticket, CLI.user(opts), key, %{
               choice: opts[:choice],
               text: opts[:text]
             }) do
          {:ok, _ticket} -> Mix.shell().info("answered #{key} on #{CLI.label(ticket)}")
          {:error, reason} -> CLI.fail(inspect(reason))
        end

      _ ->
        CLI.fail("usage: mix forge.answer PROJECT#N KEY (--choice X | --text T) [--user EMAIL]")
    end
  end
end
