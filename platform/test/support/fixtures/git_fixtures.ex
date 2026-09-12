defmodule Forge.GitFixtures do
  @moduledoc "A bare repository seeded with a `.forge/` directory, for tests that need git."

  alias Forge.Git

  @workflow Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  @doc "A fresh temporary directory, removed when the test process exits."
  def tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "forge-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  A bare repository whose `main` holds `.forge/workflow.yml` (the grammar example), the four
  prompts it names, and a README. Returns the bare path.

  `files` overrides or adds paths; a path mapped to `nil` is left out of the commit, which is
  how to seed a repository that is pushed but missing something.
  """
  def seeded_repo(files \\ %{}) do
    bare = Path.join(tmp_dir("bare"), "project.git")
    work = tmp_dir("work")
    :ok = Git.init_bare(bare)

    files =
      Map.merge(
        %{
          "README.md" => "# Game\n",
          ".forge/workflow.yml" => File.read!(@workflow),
          ".forge/agents/refine.md" => "Refine the ticket into a crisp problem statement.\n",
          ".forge/agents/plan.md" => "Write a plan.\n",
          ".forge/agents/implement.md" => "Implement the plan.\n",
          ".forge/agents/verify.md" => "Verify the implementation.\n"
        },
        files
      )

    files
    |> Enum.reject(fn {_path, content} -> is_nil(content) end)
    |> Enum.each(fn {path, content} ->
      full = Path.join(work, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)

    git!(work, ["init", "-q", "-b", "main"])
    git!(work, ["add", "."])

    git!(work, [
      "-c",
      "user.name=seed",
      "-c",
      "user.email=seed@forge",
      "commit",
      "-q",
      "-m",
      "seed"
    ])

    git!(work, ["push", "-q", bare, "main"])
    bare
  end

  defp git!(dir, args) do
    {:ok, _} = Git.run(dir, args)
  end
end
