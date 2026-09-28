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

    assert {:ok, [sha]} = Git.commits_since(repo, base, "ticket/1")

    assert {:ok, [%{sha: ^sha, subject: "add file", at: %DateTime{}}]} =
             Git.log(repo, base, "ticket/1")

    assert {:ok, diff} = Git.diff(repo, base, "ticket/1")
    assert diff =~ "+hello"
    assert :ok = Git.worktree_remove(repo, worktree)
    refute File.exists?(worktree)
    assert {:ok, [_sha]} = Git.commits_since(repo, base, "ticket/1")
  end

  # The Changes tab lists a branch's commits the way `git log` does: the latest on top, which is
  # the one a person is most likely looking for.
  test "log/3 lists a branch's commits newest first", %{repo: repo, scratch: scratch} do
    {:ok, base} = Git.resolve(repo, "main")
    :ok = Git.create_branch(repo, "ticket/2", base)
    worktree = Path.join(scratch, "log")
    :ok = Git.worktree_add(repo, worktree, "ticket/2")

    for subject <- ["first", "second"] do
      {:ok, _out} =
        Git.run(worktree, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@t",
          "commit",
          "-q",
          "--allow-empty",
          "-m",
          subject
        ])
    end

    assert {:ok, [%{subject: "second"}, %{subject: "first"}]} = Git.log(repo, base, "ticket/2")
  end

  # A chat page reads the commits of a branch its close deleted, and git complains on stderr. With
  # stderr kept apart from stdout that complaint used to go to the platform's own stderr — the
  # server log — on every render, and the error the caller got carried nothing. It is the error's
  # now, and only the error's.
  describe "a range whose end is gone" do
    test "log/3 says why in the error", %{repo: repo} do
      assert {:error, {128, why}} = Git.log(repo, "refs/heads/main", "refs/heads/chat/gone")
      assert why =~ "ambiguous argument 'refs/heads/main..refs/heads/chat/gone'"
    end

    test "diff/3 and diff_stat/3 say why in the error", %{repo: repo} do
      assert {:error, {128, why}} = Git.diff(repo, "refs/heads/main", "refs/heads/chat/gone")
      assert why =~ "unknown revision"

      assert {:error, {128, why}} = Git.diff_stat(repo, "refs/heads/main", "refs/heads/chat/gone")
      assert why =~ "unknown revision"
    end

    # Separate still means separate on success: stdout alone, whatever git said on stderr. And
    # the default still merges them.
    test "a success returns stdout alone, and the default both", %{repo: repo} do
      both = ["-c", "alias.both=!echo out; echo err >&2", "both"]

      assert Git.run(repo, both, stderr: :separate) == {:ok, "out\n"}
      assert Git.run(repo, both) == {:ok, "out\nerr\n"}
    end
  end

  describe "ensure_initial_commit/2" do
    # A bare repository has no commits, so its default branch is unborn — and everything starts
    # from it: a ticket's base, a conversation's branch, a merge's destination. Nothing outside
    # can fix that either, because `pre-receive` lets only the platform's merge write the
    # default branch, so there is no push an operator could make.
    test "a fresh repository gets an empty commit on its default branch" do
      repo = Path.join(tmp_dir("bare"), "new.git")
      :ok = Git.init_bare(repo)
      refute Git.branch_exists?(repo, "main")

      assert :ok = Git.ensure_initial_commit(repo, "main")

      assert {:ok, sha} = Git.resolve(repo, "refs/heads/main")
      assert String.length(sha) >= 40

      # Empty, and a root: nothing to conflict with whatever is pushed on top of it.
      assert {:ok, ""} = Git.run(repo, ["ls-tree", "--name-only", sha])
      assert {:ok, parents} = Git.run(repo, ["rev-list", "--parents", "-n", "1", sha])
      assert String.trim(parents) == sha
    end

    test "a repository that already has the branch is left exactly as it was" do
      repo = seeded_repo()
      {:ok, before} = Git.resolve(repo, "refs/heads/main")

      assert :ok = Git.ensure_initial_commit(repo, "main")

      assert {:ok, ^before} = Git.resolve(repo, "refs/heads/main")
    end

    # The whole point: a branch can be forked from it, which is what a conversation and a ticket
    # both do on a project nobody has pushed to yet.
    test "a branch can be made from it" do
      repo = Path.join(tmp_dir("bare"), "new.git")
      :ok = Git.init_bare(repo)
      :ok = Git.ensure_initial_commit(repo, "main")

      assert :ok = Git.create_branch(repo, "chat/x", "refs/heads/main")
      assert Git.branch_exists?(repo, "chat/x")
    end
  end
end
