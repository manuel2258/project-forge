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

  describe "reading a repository for a person" do
    test "branches/1 lists refs/heads only, sorted", %{repo: repo} do
      {:ok, head} = Git.resolve(repo, "main")
      :ok = Git.create_branch(repo, "ticket/9", head)
      :ok = Git.create_branch(repo, "chat/abc", head)
      # Not a branch: the platform's own pin, which nobody chooses to look at.
      :ok = Git.pin(repo, "refs/forge/approved/9", head)

      assert {:ok, ["chat/abc", "main", "ticket/9"]} = Git.branches(repo)
    end

    test "history/4 pages a branch's own commits, newest first", %{repo: repo} do
      # Thirty-one commits on one branch: the seed, then thirty of our own. The boundary is the
      # whole point — a page of thirty must say there is more, and the next page must hold the
      # thirty-first and say there is not.
      :ok = Git.create_branch(repo, "long", "refs/heads/main")
      seed_commits(repo, "long", 30)

      assert {:ok, %{commits: first, more: true}} = Git.history(repo, "refs/heads/long", 0, 30)
      assert length(first) == 30
      assert Enum.map(first, & &1.subject) |> Enum.take(2) == ["commit 30", "commit 29"]

      assert {:ok, %{commits: [last], more: false}} = Git.history(repo, "refs/heads/long", 30, 30)
      assert last.subject == "seed"

      # A page holding exactly the history is where `>` and `>=` part: there is nothing behind
      # it, and saying there is offers an `Older ›` that leads to an empty page.
      assert {:ok, %{commits: all, more: false}} = Git.history(repo, "refs/heads/long", 0, 31)
      assert length(all) == 31

      # Every commit is reachable by paging, which is what the bound promises.
      assert length(Enum.uniq_by(first ++ [last], & &1.sha)) == length(all)
    end

    test "history/4 is one ref's own history, not a range", %{repo: repo} do
      # `log/4` answers "what did this branch add"; this answers "what is on it". A branch that
      # has added nothing to main still has main's commits.
      :ok = Git.create_branch(repo, "quiet", "refs/heads/main")

      assert {:ok, []} = Git.log(repo, "refs/heads/main", "refs/heads/quiet")

      assert {:ok, %{commits: [%{subject: "seed"}], more: false}} =
               Git.history(repo, "refs/heads/quiet", 0, 30)
    end

    test "parent/2 is the first parent, and a root commit has none", %{repo: repo} do
      :ok = Git.create_branch(repo, "child", "refs/heads/main")
      seed_commits(repo, "child", 1)
      {:ok, root} = Git.resolve(repo, "refs/heads/main")
      {:ok, child} = Git.resolve(repo, "refs/heads/child")

      assert {:ok, ^root} = Git.parent(repo, child)
      assert {:error, :no_parent} = Git.parent(repo, root)
    end

    test "empty_tree/1 names the same object twice", %{repo: repo} do
      assert {:ok, tree} = Git.empty_tree(repo)
      assert {:ok, ^tree} = Git.empty_tree(repo)
      assert String.length(tree) >= 40
    end

    test "blob_size/3 is the bytes a path holds, or not found", %{repo: repo} do
      {:ok, sha} = Git.resolve(repo, "main")

      assert {:ok, size} = Git.blob_size(repo, sha, "README.md")
      assert size == byte_size("# Game\n")
      assert {:error, :not_found} = Git.blob_size(repo, sha, "nothing-here.md")
    end

    # The fix this needed: `ls-tree -z <sha> -- "/"` is a pathspec matching nothing, not the
    # root. Reverting it leaves the repository's top level invisible to the page that draws it.
    test "ls_dir/3 lists the repository's root", %{repo: repo} do
      {:ok, sha} = Git.resolve(repo, "main")

      assert {:ok, entries} = Git.ls_dir(repo, sha, "")
      assert %{name: "README.md", path: "README.md", kind: :blob} in entries
      assert %{name: ".forge", path: ".forge", kind: :tree} in entries
    end

    test "ls_dir/3 still lists a directory under the root", %{repo: repo} do
      {:ok, sha} = Git.resolve(repo, "main")

      assert {:ok, entries} = Git.ls_dir(repo, sha, ".forge")
      assert %{name: "workflow.yml", path: ".forge/workflow.yml", kind: :blob} in entries
      assert %{name: "agents", path: ".forge/agents", kind: :tree} in entries
    end
  end

  # `count` commits on `branch`, each in the same clone and pushed once: thirty-one clones to
  # seed thirty-one commits is most of this file's runtime for nothing.
  defp seed_commits(repo, branch, count) do
    work = Path.join(tmp_dir("history"), "work")
    {:ok, _out} = Git.run(tmp_dir("history-parent"), ["clone", "-q", "-b", branch, repo, work])

    for n <- 1..count do
      File.write!(Path.join(work, "n.txt"), "#{n}\n")
      {:ok, _out} = Git.run(work, ["add", "n.txt"])

      {:ok, _out} =
        Git.run(work, [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@forge",
          "commit",
          "-q",
          "-m",
          "commit #{n}"
        ])
    end

    {:ok, _out} = Git.run(work, ["push", "-q", "origin", "HEAD:refs/heads/" <> branch])
    :ok
  end
end
