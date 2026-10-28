defmodule Mix.Tasks.Forge.Git.Token do
  @shortdoc "Issues a project token: mix forge.git.token PROJECT [--git reader|developer|admin|none] [--api none|read|write] [--ticket N|--default] [--name NAME] [--days 7]"
  @moduledoc """
  Prints a clone URL carrying a project token for the platform's git endpoint, once, and the bare
  secret for the JSON API.

  By default the token may only read git. `--git developer` also pushes the branch of any open
  ticket and `--git admin` also fast-forwards the default branch; `--git none` leaves git out.
  `--api read` or `--api write` opens `/api/v1` to the same secret. `--ticket N` instead scopes the
  token to one ticket's branch, and `--default` to the project's default branch alone (the shape a
  repository is seeded with, fast-forward only), which is the one shape no job is ever given.
  `--days` is the lifetime (1 to 365, default 7); `--minutes` is a shorter one, for a throwaway.
  See `docs/design/git-hosting.md` § One project token, two doors.
  """

  use Mix.Task

  alias Forge.{CLI, Projects, Tickets}
  alias Forge.Git.{Tokens, Url}

  @git ~w(none reader developer admin)
  @api ~w(none read write)

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          ticket: :integer,
          default: :boolean,
          minutes: :integer,
          days: :integer,
          name: :string,
          git: :string,
          api: :string
        ]
      )

    case positional do
      [name] ->
        CLI.boot()
        project = Projects.by_name(name) || CLI.fail("unknown project #{name}")

        case Tokens.issue(project, scope(project, opts)) do
          {:ok, secret, token} -> print(project, secret, token)
          {:error, reason} -> CLI.fail("not issued: #{inspect(reason)}")
        end

      _ ->
        CLI.fail(
          "usage: mix forge.git.token PROJECT [--git G] [--api A] [--ticket N|--default] " <>
            "[--name NAME] [--days 7]"
        )
    end
  end

  defp print(project, secret, token) do
    if token.git_access != :none, do: Mix.shell().info(Url.with_token(project, secret))
    if token.api_access != :none, do: Mix.shell().info("api token: #{secret}")

    Mix.shell().info(
      "git: #{git_words(token)}, api: #{token.api_access}, until #{token.expires_at}"
    )
  end

  defp git_words(%{git_access: :branch, ref: ref}), do: "writes #{ref}"
  defp git_words(%{git_access: :developer}), do: "developer, writes every open ticket's branch"

  defp git_words(%{git_access: :admin}),
    do: "admin, writes every open ticket's branch and the default branch"

  defp git_words(%{git_access: access}), do: to_string(access)

  defp scope(project, opts) do
    base = [name: opts[:name] || "mix task", api: choice(opts[:api], @api, :none)]
    base ++ lifetime(opts) ++ git_scope(project, opts)
  end

  defp lifetime(opts) do
    case {opts[:minutes], opts[:days]} do
      {nil, nil} -> [days: 7]
      {minutes, nil} -> [ttl_minutes: minutes]
      {nil, days} -> [days: days]
      {_minutes, _days} -> CLI.fail("--minutes and --days are two lifetimes; ask for one")
    end
  end

  # One of: a git group, one ticket's branch, or the default branch alone. They are different
  # scopes and asking for two is a mistake worth failing on.
  defp git_scope(project, opts) do
    case {opts[:ticket], opts[:default] || false, opts[:git]} do
      {nil, false, git} ->
        [git: choice(git, @git, :reader)]

      {nil, true, nil} ->
        [ref: Tokens.default_ref(project), git: :branch]

      {number, false, nil} when is_integer(number) ->
        ticket = Tickets.get_by_number!(project, number)
        [ticket_id: ticket.id, ref: "refs/heads/" <> ticket.branch, git: :branch]

      _several ->
        CLI.fail("--git, --ticket and --default are different scopes; ask for one")
    end
  end

  defp choice(nil, _allowed, default), do: default

  defp choice(value, allowed, _default) do
    if value in allowed,
      do: String.to_existing_atom(value),
      else: CLI.fail("#{value} is not one of #{Enum.join(allowed, ", ")}")
  end
end
