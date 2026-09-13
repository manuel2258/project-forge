defmodule Mix.Tasks.Forge.Project.Mirror do
  @shortdoc "Sets a project's mirror: mix forge.project.mirror NAME [URL] [--refs GLOB]"
  @moduledoc """
  Points a project's repository at a mirror, so one machine is never the only copy. Without a
  URL it prints the mirror the repository has; with `--none` it removes it.

  The mirror is repository configuration rather than a row: the `post-receive` hook is what
  pushes it, and a hook can read only `git config`. See `docs/design/git-hosting.md`.
  """

  use Mix.Task

  alias Forge.{CLI, Projects}

  @impl true
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [refs: :string, none: :boolean])

    case positional do
      [name] ->
        CLI.boot()
        project = Projects.by_name(name) || CLI.fail("unknown project #{name}")
        act(project, opts)

      [name, url] ->
        CLI.boot()
        project = Projects.by_name(name) || CLI.fail("unknown project #{name}")
        set(project, url, Keyword.get(opts, :refs))

      _ ->
        CLI.fail("usage: mix forge.project.mirror NAME [URL] [--refs GLOB] [--none]")
    end
  end

  defp act(project, opts) do
    if Keyword.get(opts, :none, false) do
      set(project, nil, nil)
    else
      Mix.shell().info(Projects.mirror(project) || "no mirror")
    end
  end

  defp set(project, url, refs) do
    case Projects.set_mirror(project, url, refs) do
      :ok -> Mix.shell().info(url || "mirror removed")
      {:error, reason} -> CLI.fail(inspect(reason))
    end
  end
end
