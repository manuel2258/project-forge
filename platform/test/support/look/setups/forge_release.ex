defmodule Forge.Look.Setups.ForgeRelease do
  @moduledoc """
  Projects whose repositories record a forge release in each of the ways the project page draws
  (`docs/design/ui.md` § The project page): behind, current, not recorded, newer than the node, and
  not a release (hostile and over the bound). One member, `member`, of all of them. Paths are
  `behind`, `current`, `unrecorded`, `newer`, `garbage` and `huge`.

  The values are made up. The node here runs `Forge.Changelog.running/0`; "behind" is 0.17.0, which
  stays behind whatever the next release is, and "newer" is 99.0.0.
  """

  @behaviour Forge.Look.Setups

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  import Forge.AccountsFixtures

  @impl true
  def build do
    member = user_fixture()
    running = Forge.Changelog.running()

    cases = [
      {"behind", "0.17.0\n"},
      {"current", running <> "\n"},
      {"unrecorded", nil},
      {"newer", "99.0.0\n"},
      {"garbage", "<b>not</b> a release <a href=\"http://x.test\">link</a>\n"},
      {"huge", String.duplicate("0", 70)}
    ]

    paths =
      for {name, content} <- cases, into: %{} do
        {:ok, project} =
          Forge.Projects.register(
            %{
              name: "look-#{name}",
              repo_path: repo(content)
            },
            member
          )

        {name, "/projects/#{project.name}"}
      end

    %{users: %{"member" => member}, paths: paths}
  end

  # A bare repository whose `main` holds the grammar example as its workflow, its prompts, and the
  # record when there is one. Built here rather than by `Forge.GitFixtures.seeded_repo/1`, which
  # registers its directory with the test process that is running and a look has none.
  defp repo(content) do
    root =
      Path.join(
        System.tmp_dir!(),
        "#{System.pid()}-forge-look-#{System.unique_integer([:positive])}"
      )

    bare = Path.join(root, "project.git")
    work = Path.join(root, "work")
    :ok = Forge.Git.init_bare(bare)

    files =
      %{
        "README.md" => "# Game\n",
        ".forge/workflow.yml" => File.read!(@workflow),
        ".forge/agents/refine.md" => "Refine the ticket.\n",
        ".forge/agents/plan.md" => "Write a plan.\n",
        ".forge/agents/implement.md" => "Implement the plan.\n",
        ".forge/agents/verify.md" => "Verify the implementation.\n"
      }
      |> then(&if content, do: Map.put(&1, ".forge/forge-release", content), else: &1)

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(work, path)))
      File.write!(Path.join(work, path), text)
    end

    {:ok, _} = Forge.Git.run(work, ["init", "-q", "-b", "main"])
    {:ok, _} = Forge.Git.run(work, ["add", "."])

    {:ok, _} =
      Forge.Git.run(work, [
        "-c",
        "user.name=look",
        "-c",
        "user.email=look@forge",
        "commit",
        "-q",
        "-m",
        "seed"
      ])

    {:ok, _} = Forge.Git.run(work, ["push", "-q", bare, "main"])
    bare
  end
end
