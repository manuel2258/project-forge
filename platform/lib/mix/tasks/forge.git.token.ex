defmodule Mix.Tasks.Forge.Git.Token do
  @shortdoc "Issues a git token: mix forge.git.token PROJECT [--ticket N|--default] [--minutes 90]"
  @moduledoc """
  Prints a clone URL carrying a short-lived credential for the platform's git endpoint, once.

  Without `--ticket` the token may only read. With it the token may also write that ticket's
  branch, and nothing else. `--default` writes the project's default branch instead — the shape a
  repository is seeded with, fast-forward only — and is the one shape no job is ever given. See
  `docs/design/git-hosting.md`.
  """

  use Mix.Task

  alias Forge.{CLI, Projects, Tickets}
  alias Forge.Git.{Tokens, Url}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [ticket: :integer, default: :boolean, minutes: :integer])

    case positional do
      [name] ->
        CLI.boot()
        project = Projects.by_name(name) || CLI.fail("unknown project #{name}")
        {:ok, secret, token} = Tokens.issue(project, scope(project, opts))

        Mix.shell().info(Url.with_token(project, secret))
        Mix.shell().info("writes #{token.ref || "nothing"}, until #{token.expires_at}")

      _ ->
        CLI.fail("usage: mix forge.git.token PROJECT [--ticket N|--default] [--minutes 90]")
    end
  end

  defp scope(project, opts) do
    minutes = Keyword.take(opts, [:minutes]) |> Keyword.get(:minutes)
    ttl = if minutes, do: [ttl_minutes: minutes], else: []

    case {Keyword.get(opts, :ticket), Keyword.get(opts, :default, false)} do
      {nil, false} ->
        ttl

      {nil, true} ->
        [ref: Tokens.default_ref(project), write: true] ++ ttl

      {_number, true} ->
        CLI.fail("--ticket and --default are two different scopes; ask for one")

      {number, false} ->
        ticket = Tickets.get_by_number!(project, number)
        [ticket_id: ticket.id, ref: "refs/heads/" <> ticket.branch, write: true] ++ ttl
    end
  end
end
