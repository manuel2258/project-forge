defmodule Forge.GitTest do
  use ExUnit.Case, async: true

  import Forge.GitFixtures

  alias Forge.Git

  setup do
    %{repo: seeded_repo(), scratch: tmp_dir("scratch")}
  end

  test "init_bare/1 is idempotent", %{repo: repo} do
    assert :ok = Git.init_bare(repo)
    assert File.exists?(Path.join(repo, "HEAD"))
  end

  test "resolve, show and exists? read a commit", %{repo: repo} do
    assert {:ok, sha} = Git.resolve(repo, "main")
    assert String.length(sha) == 40
    assert {:ok, "version: 1\n" <> _} = Git.show(repo, sha, ".forge/workflow.yml")
    assert Git.exists?(repo, sha, ".forge/agents/refine.md")
    refute Git.exists?(repo, sha, ".forge/agents/missing.md")
    assert {:error, {:unknown_ref, "nope"}} = Git.resolve(repo, "nope")
  end

  test "branches, worktrees, commits and diffs round-trip", %{repo: repo, scratch: scratch} do
    {:ok, base} = Git.resolve(repo, "main")
    assert :ok = Git.create_branch(repo, "ticket/1", base)
    assert Git.branch_exists?(repo, "ticket/1")
    assert {:error, _} = Git.create_branch(repo, "ticket/1", base)

    worktree = Path.join(scratch, "wt")
    assert :ok = Git.worktree_add(repo, worktree, "ticket/1")
    File.write!(Path.join(worktree, "new.txt"), "hello\n")
    {:ok, _} = Git.run(worktree, ["add", "new.txt"])

    {:ok, _} =
      Git.run(worktree, [
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "-m",
        "add file"
      ])

    assert {:ok, [_sha]} = Git.commits_since(repo, base, "ticket/1")
    assert {:ok, diff} = Git.diff(repo, base, "ticket/1")
    assert diff =~ "+hello"
    assert :ok = Git.worktree_remove(repo, worktree)
    refute File.exists?(worktree)
    assert {:ok, [_sha]} = Git.commits_since(repo, base, "ticket/1")
  end
end
