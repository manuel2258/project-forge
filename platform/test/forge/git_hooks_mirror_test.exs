defmodule Forge.GitHooksMirrorTest do
  @moduledoc """
  Named mirrors in a repository's own config, and the migration off the single `forge.mirror`
  that came before them. `docs/design/git-hosting.md` § Hooks.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.Git
  alias Forge.Git.Hooks

  setup do
    bare = seeded_repo()

    {:ok, project} =
      register_owned!(%{
        name: "hooksmirror#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    %{project: project, repo: Forge.Projects.repo_path(project)}
  end

  test "a mirror round-trips under its own name", %{repo: repo} do
    :ok = Hooks.put_mirror(repo, "github", "https://github.com/x/y.git", refs: "refs/heads/*")

    assert [mirror] = Hooks.list_mirrors(repo)
    assert mirror.name == "github"
    assert mirror.url == "https://github.com/x/y.git"
    assert mirror.refs == "refs/heads/*"
  end

  test "several mirrors coexist and come back in a stable order", %{repo: repo} do
    :ok = Hooks.put_mirror(repo, "zeta", "https://z.example/y.git", [])
    :ok = Hooks.put_mirror(repo, "alpha", "https://a.example/y.git", [])

    assert ["alpha", "zeta"] = Enum.map(Hooks.list_mirrors(repo), & &1.name)
  end

  test "deleting one leaves the others", %{repo: repo} do
    :ok = Hooks.put_mirror(repo, "one", "https://one.example/y.git", [])
    :ok = Hooks.put_mirror(repo, "two", "https://two.example/y.git", [])

    :ok = Hooks.delete_mirror(repo, "one")

    assert ["two"] = Enum.map(Hooks.list_mirrors(repo), & &1.name)
  end

  test "status keys written by the hook are read back", %{repo: repo} do
    :ok = Hooks.put_mirror(repo, "github", "https://github.com/x/y.git", [])
    {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirror.github.lastStatus", "failed"])
    {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirror.github.lastError", "nope"])

    assert [%{last_status: "failed", last_error: "nope"}] = Hooks.list_mirrors(repo)
  end

  describe "the migration off the scalar" do
    # A node upgrading has `forge.mirror` set and no named mirrors. `install/2` runs on every
    # boot, which is where this has to happen: there is no other moment every repository passes.
    test "moves a scalar mirror to the name `default`", %{project: project, repo: repo} do
      {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirror", "https://old.example/y.git"])
      {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirrorRefs", "refs/heads/main"])

      :ok = Hooks.install(repo, project)

      assert [%{name: "default", url: "https://old.example/y.git", refs: "refs/heads/main"}] =
               Hooks.list_mirrors(repo)

      assert Git.run(repo, ["config", "--get", "forge.mirror"]) == {:error, {1, ""}}
    end

    # An ssh mirror is no longer usable, and the note says so: it is carried over so that its
    # status can say it stopped, rather than vanishing and leaving somebody to wonder.
    test "carries over a URL the rules now refuse, rather than dropping it", %{
      project: project,
      repo: repo
    } do
      {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirror", "git@github.com:x/y.git"])

      :ok = Hooks.install(repo, project)

      assert [%{name: "default", url: "git@github.com:x/y.git"}] = Hooks.list_mirrors(repo)
    end

    test "does nothing when named mirrors already exist", %{project: project, repo: repo} do
      :ok = Hooks.put_mirror(repo, "github", "https://github.com/x/y.git", [])
      {:ok, _} = Git.run(repo, ["config", "--local", "forge.mirror", "https://old.example/y.git"])

      :ok = Hooks.install(repo, project)

      assert ["github"] = Enum.map(Hooks.list_mirrors(repo), & &1.name)
    end

    test "is fine on a repository that never had a mirror", %{project: project, repo: repo} do
      :ok = Hooks.install(repo, project)

      assert Hooks.list_mirrors(repo) == []
    end

    # The old mechanism had no credential store, so `https://user:token@host/x.git` was the only
    # way to authenticate a mirror and is the likeliest thing a node upgrading has configured.
    # Carrying it over keeps the mirror working; reading it back with the userinfo would print a
    # token on the settings page, the project page and anywhere else a mirror is rendered.
    test "reads back a migrated URL without the credential it carries", %{
      project: project,
      repo: repo
    } do
      {:ok, _} =
        Git.run(repo, ["config", "--local", "forge.mirror", "https://u:tok@old.example/y.git"])

      :ok = Hooks.install(repo, project)

      assert [%{name: "default", url: "https://old.example/y.git"}] = Hooks.list_mirrors(repo)
    end

    # ...and the stored value keeps it, because the hook still has to authenticate with it. The
    # stripping is a property of the read, not of what is on disk.
    test "leaves the credential in the stored config, where the hook needs it", %{
      project: project,
      repo: repo
    } do
      {:ok, _} =
        Git.run(repo, ["config", "--local", "forge.mirror", "https://u:tok@old.example/y.git"])

      :ok = Hooks.install(repo, project)

      assert {:ok, stored} =
               Git.run(repo, ["config", "--local", "--get", "forge.mirror.default.url"])

      assert String.trim(stored) == "https://u:tok@old.example/y.git"
    end
  end

  describe "config that is not this repository's" do
    # `forge.*` is per-repository by design. Without `--local` a `forge.mirror.<name>.url` in the
    # service user's own ~/.gitconfig would be listed as a mirror of every repository on the node
    # and could not be removed from the UI, since `delete_mirror/2` unsets `--local`.
    #
    # `GIT_CONFIG_GLOBAL` has to be in this VM's own environment, because that is where
    # `Forge.Git.run/3` gets it from — safe here only because the module is `async: false`, which
    # ExUnit runs with nothing else beside it.
    test "a mirror in the global config is not listed as this repository's", %{repo: repo} do
      global = ghost_global_config()
      System.put_env("GIT_CONFIG_GLOBAL", global)
      on_exit(fn -> System.delete_env("GIT_CONFIG_GLOBAL") end)

      # git sees it perfectly well without `--local`, so this fails for the reason it claims.
      assert {:ok, seen} = Git.run(repo, ["config", "--get", "forge.mirror.ghost.url"])
      assert String.trim(seen) == "http://127.0.0.1:1/ghost.git"

      assert Hooks.list_mirrors(repo) == []
    end

    # The same rule in the hook, which is the half that would actually push to it. The hook
    # inherits the pushing process's environment, so this one needs no VM-wide variable.
    test "the hook does not push to a mirror from the global config", %{repo: repo} do
      global = ghost_global_config()
      work = Path.join(tmp_dir("ghost-work"), "clone")

      {:ok, _} = Git.run(Path.dirname(work), ["clone", "--quiet", repo, work])
      File.write!(Path.join(work, "new.txt"), "x\n")
      {:ok, _} = Git.run(work, ["add", "new.txt"])

      {:ok, _} =
        Git.run(work, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@forge",
          "commit",
          "-q",
          "-m",
          "x"
        ])

      {:ok, _} =
        Git.run(work, ["push", "--quiet", repo, "main"],
          # The default branch, so `pre-receive` wants the platform's own authority; this push
          # stands in for the merge.
          env: [{"GIT_CONFIG_GLOBAL", global}, {"FORGE_INTERNAL", "1"}]
        )

      # Had the hook enumerated it, the failed push to 127.0.0.1:1 would have left the ghost's
      # `lastStatus` and `lastError` in this repository's own config.
      assert Git.run(repo, ["config", "--local", "--get-regexp", "^forge\\.mirror\\."]) ==
               {:error, {1, ""}}
    end

    defp ghost_global_config do
      path = Path.join(tmp_dir("gitconfig"), "config")

      File.write!(path, """
      [forge "mirror.ghost"]
      \turl = http://127.0.0.1:1/ghost.git
      """)

      path
    end
  end
end
