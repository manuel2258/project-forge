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
    # **`Enum.sort` in `branches/1` is an equivalent mutant.** `for-each-ref` sorts by refname
    # already, and a short name orders the same way as its `refs/heads/` form, so no repository
    # can tell the two apart. The sort is kept because the order is this function's promise and
    # not git's to change; this test is for the pattern, which is not equivalent to anything.
    test "branches/1 lists refs/heads only", %{repo: repo} do
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

    test "empty_tree/1 names a tree, the same one twice", %{repo: repo} do
      assert {:ok, tree} = Git.empty_tree(repo)
      assert {:ok, ^tree} = Git.empty_tree(repo)
      # What the object *is* rather than only that two calls agreed: without this the test
      # passes against `-t blob`, against a different input file, and against a dropped trim.
      assert {:ok, "tree\n"} = Git.run(repo, ["cat-file", "-t", tree])
      assert {:ok, ""} = Git.run(repo, ["cat-file", "-p", tree])
    end

    # Naming it writes nothing — git carries the empty tree whether a repository holds it or
    # not — which is what lets a commit page read a root commit's diff against it without
    # writing to the repository it is only looking at.
    test "empty_tree/1 writes nothing unless asked to", %{repo: repo} do
      before = tree_of(repo)

      assert {:ok, tree} = Git.empty_tree(repo)
      assert tree_of(repo) == before

      assert {:ok, ^tree} = Git.empty_tree(repo, write: true)
      assert tree_of(repo) != before
    end

    # And why the writing half is kept for the one caller that makes a commit of it: an
    # unwritten tree a commit references is a repository that fails `fsck` for ever.
    test "a root commit's own empty tree is written, so the repository stays whole" do
      repo = Path.join(tmp_dir("fsck"), "new.git")
      :ok = Git.init_bare(repo)
      :ok = Git.ensure_initial_commit(repo, "main")

      assert {:ok, out} = Git.run(repo, ["fsck"])
      refute out =~ "missing tree"
    end

    test "blob_size/3 is the bytes a path holds, or not found", %{repo: repo} do
      {:ok, sha} = Git.resolve(repo, "main")

      assert {:ok, size} = Git.blob_size(repo, sha, "README.md")
      assert size == byte_size("# Game\n")
      assert {:error, :not_found} = Git.blob_size(repo, sha, "nothing-here.md")
    end

    # The hole this closed: `git log` takes `--output=<file>`, relative to its working
    # directory, and `history/4` put the caller's ref in git's option position. One `GET` of
    # `/repo/commits/--output=HEAD` emptied a project's `HEAD`, and `--output=../../x` wrote
    # outside the repositories directory — an arbitrary create-or-truncate as the platform's own
    # user, to anybody who is a member of one project.
    test "a value that git would read as an option is refused, and writes nothing", %{
      repo: repo
    } do
      {:ok, head} = Git.resolve(repo, "main")
      before = tree_of(repo)

      for call <- [
            fn -> Git.history(repo, "--output=pwned", 0, 1) end,
            fn -> Git.log(repo, "--output=pwned", "HEAD") end,
            fn -> Git.resolve(repo, "--output=pwned") end,
            fn -> Git.parent(repo, "--output=pwned") end,
            fn -> Git.diff(repo, "--output=pwned", head) end,
            fn -> Git.diff_stat(repo, "--output=pwned", head) end,
            fn -> Git.ls_dir(repo, "--output=pwned", "") end,
            fn -> Git.blob_size(repo, "--output=pwned", "README.md") end,
            fn -> Git.show(repo, "--output=pwned", "README.md") end,
            fn -> Git.commits_since(repo, "--output=pwned", head) end,
            fn -> Git.merge_base(repo, "--output=pwned", head) end,
            fn -> Git.create_branch(repo, "--output=pwned", head) end,
            fn -> Git.pin(repo, "--output=pwned", head) end
          ] do
        # Each refuses in its own vocabulary — `:not_a_rev` from `run/3`, or the miss the
        # function already answers a bad ref with. None of them succeeds.
        assert {:error, _reason} = call.()
      end

      # The point of the whole test: not one of those left anything behind.
      assert tree_of(repo) == before
      refute File.exists?(Path.join(repo, "pwned"))
    end

    # The crash this closes, one layer below the patch guard: a repository may hold a file whose
    # name is not valid UTF-8, and the platform asks git for paths as they were written, so those
    # bytes arrive raw. Rendered into a page they are a response body that is not UTF-8, and
    # through the socket the serializer raises on them in the transport process.
    test "a path that is not text leaves this module in a form a page can draw", %{repo: repo} do
      {:ok, head} = Git.resolve(repo, "main")
      :ok = Git.create_branch(repo, "ticket/3", head)
      raw = "caf" <> <<0xE9>> <> ".txt"
      commit_to(repo, "ticket/3", %{raw => "latin\n", ("dir" <> <<0xFF>> <> "/in.txt") => "x\n"})
      {:ok, sha} = Git.resolve(repo, "refs/heads/ticket/3")

      # `ls-tree -z` never quotes, and `--numstat` does not either under `core.quotePath=false`.
      {:ok, entries} = Git.ls_dir(repo, sha, "")
      {:ok, stat} = Git.diff_stat(repo, head, sha)
      {:ok, changed} = Git.changed_paths(repo, head, sha, [])

      for path <- Enum.map(entries, & &1.path) ++ Enum.map(entries, & &1.name) do
        assert String.valid?(path), inspect(path)
      end

      assert Enum.all?(Enum.map(stat, &elem(&1, 0)), &String.valid?/1)
      assert Enum.all?(changed, &String.valid?/1)
      assert ~s("caf\\351.txt") in Enum.map(entries, & &1.name)

      # And the escaped form reads back to the bytes git wants, so a page can round-trip it.
      assert Git.unquote_path(~s("caf\\351.txt")) == raw
      assert {:ok, "latin\n"} = Git.show(repo, sha, Git.unquote_path(~s("caf\\351.txt")))
    end

    test "printable_path/1 and unquote_path/1 are inverses", %{repo: _repo} do
      for raw <- [
            "README.md",
            "résumé.md",
            ~s(we"ird.md),
            "a b/c",
            ~s("quoted"),
            "caf" <> <<0xE9>> <> ".txt",
            "dir/" <> <<0xFF, 0xFE>> <> "x",
            "tab\there",
            "nl\nhere"
          ] do
        printed = Git.printable_path(raw)
        assert String.valid?(printed), inspect(raw)
        assert Git.unquote_path(printed) == raw, inspect(raw)
      end
    end

    # `skip` and `limit` are the caller's and are interpolated into flags rather than marked,
    # so the guard is what stands in for the mark.
    test "history/4 refuses a skip or a limit that is not a number", %{repo: repo} do
      assert_raise FunctionClauseError, fn -> Git.history(repo, "main", "0; rm -rf /", 30) end
      assert_raise FunctionClauseError, fn -> Git.history(repo, "main", -1, 30) end
      assert_raise FunctionClauseError, fn -> Git.history(repo, "main", 0, 0) end
    end

    # A literal is still a literal. Without this the refusal could be "no argument may begin
    # with a dash", which would take every flag in the module with it.
    test "a flag written at the call site is not refused", %{repo: repo} do
      assert {:ok, out} = Git.run(repo, ["log", "--max-count=1", "--format=%s", {:data, "main"}])
      assert String.trim(out) == "seed"
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
end
