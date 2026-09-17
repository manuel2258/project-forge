defmodule Forge.ProjectsTest do
  @moduledoc """
  What the platform guarantees about a registered repository, on the way in and at every boot.

  The boot pass is the part worth testing: a rule that only ever reached repositories created
  after it was written would not be a guarantee, it would be a coincidence of timing.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  import Forge.GitFixtures

  alias Forge.{Git, Projects}

  test "registering gives the default branch a commit to start from" do
    repo = Path.join(tmp_dir("bare"), "new.git")

    {:ok, project} =
      register_owned!(%{name: "new-#{System.unique_integer([:positive])}", repo_path: repo})

    assert Git.branch_exists?(repo, project.default_branch)
  end

  # Fixing this only on the way in would leave every project that already exists broken for
  # ever: nothing outside the platform may write the default branch — `pre-receive` accepts the
  # platform's own merge and nothing else — so there is no push that would repair one.
  # `ensure_hooks/0` runs at boot for exactly this kind of catch-up, and now carries it.
  test "boot gives an already-registered project its first commit" do
    repo = Path.join(tmp_dir("bare"), "old.git")

    {:ok, project} =
      register_owned!(%{name: "old-#{System.unique_integer([:positive])}", repo_path: repo})

    # Exactly what a project registered before this change looks like: hooks, a HEAD, no commit.
    {:ok, _out} = Git.run(repo, ["update-ref", "-d", "refs/heads/#{project.default_branch}"])
    refute Git.branch_exists?(repo, project.default_branch)

    assert Projects.ensure_hooks() >= 1

    assert Git.branch_exists?(repo, project.default_branch)
  end

  test "boot leaves a repository that already has history alone" do
    repo = seeded_repo()
    {:ok, before} = Git.resolve(repo, "refs/heads/main")

    {:ok, _project} =
      register_owned!(%{name: "seeded-#{System.unique_integer([:positive])}", repo_path: repo})

    assert Projects.ensure_hooks() >= 1
    assert {:ok, ^before} = Git.resolve(repo, "refs/heads/main")
  end
end
