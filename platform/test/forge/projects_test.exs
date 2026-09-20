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

  # The name is the authority on who owns a repository. A registration for a name that already
  # exists must fail before any git runs, or a second caller — a member of nothing — rewrites the
  # first project's HEAD and default-branch guard and empties its clones. This is the guard for
  # that; mutate `register/2` to run the git steps before the insert and it fails.
  test "registering an existing name does not touch the existing repository" do
    repo = Path.join(tmp_dir("bare"), "victim.git")
    name = "victim-#{System.unique_integer([:positive])}"
    {:ok, _project} = register_owned!(%{name: name, repo_path: repo})
    {:ok, head_before} = Git.run(repo, ["symbolic-ref", "HEAD"])

    attacker = Forge.AccountsFixtures.user_fixture()

    assert {:error, %Ecto.Changeset{}} =
             Projects.register(
               %{name: name, repo_path: repo, default_branch: "attacker"},
               attacker
             )

    assert {:ok, ^head_before} = Git.run(repo, ["symbolic-ref", "HEAD"])
    assert Git.branch_exists?(repo, "main")
    refute Git.branch_exists?(repo, "attacker")
  end

  # A git failure after the row is reserved must leave neither the row nor a directory: the
  # transaction rolls the row back and the initializer removes a directory it created.
  test "a git failure during registration leaves no row and no directory" do
    repo = Path.join(tmp_dir("bare"), "broken.git")
    name = "broken-#{System.unique_integer([:positive])}"

    # A branch name the changeset accepts but git refuses (a path component beginning with a
    # dot), so init runs, the directory is created, and `ensure_head` then fails.
    assert {:error, _reason} =
             Projects.register(
               %{name: name, repo_path: repo, default_branch: "trunk/.x"},
               Forge.AccountsFixtures.user_fixture()
             )

    refute File.exists?(repo)
    assert Projects.by_name(name) == nil
  end

  test "an imported repository the caller pushed first survives a later git failure" do
    repo = seeded_repo()
    {:ok, before} = Git.resolve(repo, "refs/heads/main")

    # Import is by name onto an existing directory; a git failure must not delete the caller's
    # pushed history, because this call did not create the directory.
    assert {:error, _reason} =
             Projects.register(
               %{
                 name: "import-#{System.unique_integer([:positive])}",
                 repo_path: repo,
                 default_branch: "trunk/.x"
               },
               Forge.AccountsFixtures.user_fixture()
             )

    assert File.dir?(repo)
    assert {:ok, ^before} = Git.resolve(repo, "refs/heads/main")
  end

  describe "the default branch" do
    for bad <- ["-rf", "../evil", "a b", "master;touch x", "trunk/", "a..b", "a//b", "main.lock"] do
      test "is rejected: #{inspect(bad)}" do
        changeset =
          Forge.Projects.Project.changeset(%Forge.Projects.Project{}, %{
            name: "p",
            repo_path: "/x",
            default_branch: unquote(bad)
          })

        refute changeset.valid?
        assert Keyword.has_key?(changeset.errors, :default_branch)
      end
    end

    for good <- ["main", "master", "release/1.0", "feature_x", "v2.3-rc1"] do
      test "is accepted: #{inspect(good)}" do
        changeset =
          Forge.Projects.Project.changeset(%Forge.Projects.Project{}, %{
            name: "p",
            repo_path: "/x",
            default_branch: unquote(good)
          })

        assert changeset.valid?
      end
    end
  end
end
