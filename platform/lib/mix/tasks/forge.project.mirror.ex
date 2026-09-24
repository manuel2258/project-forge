defmodule Mix.Tasks.Forge.Project.Mirror do
  @shortdoc "Manages a project's mirrors: mix forge.project.mirror NAME [MIRROR [URL]]"
  @moduledoc """
  Points a project's repository at one or more named mirrors, so one machine is never the only
  copy. With a project name alone, lists its mirrors. With a mirror name and a URL, creates or
  replaces that mirror. With `--none` instead of a URL, removes it.

  `--owner` names the account the change is recorded as; omitted, it resolves to the node's only
  admin and refuses when there is more than one, the way `mix forge.project.add` does.

  A mirror is repository configuration rather than a row: the `post-receive` hook is what pushes
  it, and a hook can read only `git config`. See `docs/design/git-hosting.md`.
  """

  use Mix.Task

  alias Forge.{Accounts, CLI, Projects}

  @impl true
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [refs: :string, user: :string, token: :string, owner: :string, none: :boolean]
      )

    case positional do
      [name] ->
        CLI.boot()
        project = fetch_project(name)

        # `--none` used to remove a project's one mirror. Now that a project may have several,
        # naming none of them is not "remove the only one" — it is ambiguous, and silently
        # listing instead would leave an operator who ran the old command believing a removal
        # happened. Refuse and say what to run instead, rather than do nothing quietly.
        if Keyword.get(opts, :none, false) do
          CLI.fail(
            "usage: mix forge.project.mirror NAME MIRROR --none removes one mirror; " <>
              "NAME alone only lists them"
          )
        else
          list(project)
        end

      [name, mirror] ->
        CLI.boot()
        act(fetch_project(name), mirror, nil, opts)

      [name, mirror, url] ->
        CLI.boot()
        act(fetch_project(name), mirror, url, opts)

      _ ->
        CLI.fail(
          "usage: mix forge.project.mirror NAME [MIRROR [URL]] [--refs GLOB] [--user NAME] " <>
            "[--token TOKEN] [--owner EMAIL] [--none]"
        )
    end
  end

  defp fetch_project(name), do: Projects.by_name(name) || CLI.fail("unknown project #{name}")

  defp list(project) do
    case Projects.list_mirrors(project) do
      [] -> Mix.shell().info("no mirrors")
      mirrors -> Enum.each(mirrors, &Mix.shell().info("#{&1.name} #{&1.url}"))
    end
  end

  defp act(project, mirror, nil, opts) do
    if Keyword.get(opts, :none, false) do
      remove(project, owner(opts), mirror)
    else
      CLI.fail("usage: mix forge.project.mirror NAME MIRROR URL, or NAME MIRROR --none")
    end
  end

  defp act(project, mirror, url, opts), do: set(project, owner(opts), mirror, url, opts)

  defp owner(opts) do
    case Accounts.owner_for(Keyword.get(opts, :owner)) do
      {:ok, owner} -> owner
      {:error, :ambiguous_owner} -> CLI.fail("more than one node admin: pass --owner EMAIL")
      {:error, :no_owner} -> CLI.fail("no node admin: mix forge.user.add EMAIL PASS --node-admin")
      {:error, :unknown_user} -> CLI.fail("unknown user #{Keyword.get(opts, :owner)}")
    end
  end

  defp set(project, owner, mirror, url, opts) do
    case Projects.put_mirror(project, owner, mirror, url,
           refs: Keyword.get(opts, :refs),
           user: Keyword.get(opts, :user),
           token: Keyword.get(opts, :token)
         ) do
      :ok -> Mix.shell().info(url)
      {:error, reason} -> CLI.fail(inspect(reason))
    end
  end

  defp remove(project, owner, mirror) do
    case Projects.delete_mirror(project, owner, mirror) do
      :ok -> Mix.shell().info("mirror removed")
      {:error, reason} -> CLI.fail(inspect(reason))
    end
  end
end
