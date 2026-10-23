defmodule ForgeWorker.Job.WorkspaceTest do
  @moduledoc """
  Real git against a real bare repository. Two of these behaviours used to be tested in the
  platform's flow test, when the platform owned the worktree; they belong here now.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Workspace

  # The development slice's user, which is the worker's own: what these tests are about is the
  # git, and who runs it is `ForgeWorker.Job.WorkspaceUserTest`'s.
  @direct {ForgeWorker.Slice.Direct, %{kind: :direct}}

  setup do
    origin = Path.join(tmp_dir("origin"), "project.git")
    seed = tmp_dir("seed")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, seed])
    git!(seed, ["config", "user.name", "seed"])
    git!(seed, ["config", "user.email", "seed@forge"])
    File.write!(Path.join(seed, "README.md"), "# Game\n")
    git!(seed, ["add", "."])
    git!(seed, ["commit", "--quiet", "-m", "seed"])
    git!(seed, ["branch", "-M", "main"])
    git!(seed, ["push", "--quiet", "origin", "main"])
    git!(seed, ["push", "--quiet", "origin", "main:ticket/1"])
    git!(nil, ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/main"])

    %{origin: origin, root: tmp_dir("root")}
  end

  defp assignment(origin, opts \\ []) do
    %{
      "job_id" => Keyword.get(opts, :job_id, uuid()),
      "spec" => %{"state" => "planning", "attempt" => 1},
      "resume_session" => Keyword.get(opts, :resume_session),
      "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil}
    }
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  test "a cold start checks out the ticket branch", %{origin: origin, root: root} do
    assert {:ok, dir} = Workspace.prepare(assignment(origin), root, @direct)

    assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
    assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"
  end

  test "a cold start discards what a dead run left uncommitted", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    File.write!(Path.join(dir, "half-done.txt"), "from the run that was killed")
    File.write!(Path.join(dir, "README.md"), "clobbered")

    assert {:ok, ^dir} = Workspace.prepare(job, root, @direct)

    refute File.exists?(Path.join(dir, "half-done.txt"))
    assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
  end

  # The other side of the same `git clean`, and the flag the whole carry rests on: `-fd` and not
  # `-fdx`. The test above says untracked debris goes; this says an *ignored* directory stays,
  # because that is what `deps/`, `_build/`, `.mix-home/` and `.hex-home/` are. Add `-x` to
  # `Checkout.maybe_clean/3` and a run resuming onto its own worktree wipes every one of them.
  test "a cold start onto an existing worktree keeps the ignored build output", context do
    %{origin: origin, root: root} = context
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)

    # Tracked on the branch, so the second checkout has the rules before it cleans.
    File.write!(Path.join(dir, ".gitignore"), ".mix-home/\nbuild/\n")
    {:ok, _head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)

    File.mkdir_p!(Path.join(dir, ".mix-home/archives"))
    File.write!(Path.join(dir, ".mix-home/archives/hex.app"), "installed once")
    File.mkdir_p!(Path.join(dir, "build"))
    File.write!(Path.join(dir, "build/warm.o"), "compiled once")
    File.write!(Path.join(dir, "debris.txt"), "from the run that was killed")

    assert {:ok, ^dir} = Workspace.prepare(job, root, @direct)

    assert File.read!(Path.join(dir, ".mix-home/archives/hex.app")) == "installed once"
    assert File.read!(Path.join(dir, "build/warm.o")) == "compiled once"
    refute File.exists?(Path.join(dir, "debris.txt"))
  end

  # What a state that produces no `changeset` reports instead of a push. `head/2` would name the
  # agent's own commit, which is on no ref anybody else can fetch; a parked run's commands would
  # then be dispatched at it.
  test "the base is the fetched branch head, not the agent's own commits", context do
    %{origin: origin, root: root} = context
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    fetched = git!(dir, ["rev-parse", "origin/ticket/1"]) |> String.trim()

    git!(dir, ["config", "user.name", "agent"])
    git!(dir, ["config", "user.email", "agent@forge"])
    File.write!(Path.join(dir, "NOTES.md"), "the agent's own\n")
    git!(dir, ["add", "NOTES.md"])
    git!(dir, ["commit", "--quiet", "-m", "the agent's own commit"])

    assert {:ok, ^fetched} = Workspace.base(job, dir, @direct)
    assert {:ok, own} = Workspace.head(dir, @direct)
    refute own == fetched
  end

  # The one way `base/3` can fail, and what makes `ForgeWorker.Link`'s `{:branch_head, _}` tag
  # worth keeping apart from `{:push, _}`: nothing was pushed, so nothing about a push went
  # wrong. Reachable here and not through `Link`, where a branch the clone could not fetch fails
  # in `prepare/3` long before a run ends.
  test "the base errors when the branch has no fetched head", context do
    %{origin: origin, root: root} = context
    {:ok, dir} = Workspace.prepare(assignment(origin), root, @direct)
    elsewhere = put_in(assignment(origin), ["git", "branch"], "ticket/404")

    assert {:error, _reason} = Workspace.base(elsewhere, dir, @direct)
  end

  test "a resume keeps the work in progress", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    File.write!(Path.join(dir, "half-done.txt"), "from the attempt this one resumes")

    resumed = %{job | "resume_session" => "sess-42"}
    assert {:ok, ^dir} = Workspace.prepare(resumed, root, @direct)

    assert File.read!(Path.join(dir, "half-done.txt")) =~ "resumes"
  end

  test "the work is committed and pushed to the ticket branch", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    File.write!(Path.join(dir, "NOTES.md"), "work happened\n")

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() == head
    assert git!(nil, ["-C", origin, "show", head <> ":NOTES.md"]) == "work happened\n"
  end

  test "one commit per run, not one per file", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    File.write!(Path.join(dir, "a.md"), "a")
    File.write!(Path.join(dir, "b.md"), "b")

    {:ok, _head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)

    commits = git!(dir, ["rev-list", "--count", "HEAD"]) |> String.trim() |> String.to_integer()
    assert commits == 2
  end

  test "an agent that commits its own work still reaches the branch", %{
    origin: origin,
    root: root
  } do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)

    # What Claude Code does when it is left to use git: it commits, and possibly several times.
    # `git add -A` then finds nothing staged, and the work used to go no further than the
    # machine that is about to be destroyed.
    File.write!(Path.join(dir, "one.md"), "first\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "the agent's own message"])
    File.write!(Path.join(dir, "two.md"), "second\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "--quiet", "-m", "and another"])
    File.write!(Path.join(dir, "three.md"), "third\n")

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() == head
    assert git!(nil, ["-C", origin, "show", head <> ":one.md"]) == "first\n"
    assert git!(nil, ["-C", origin, "show", head <> ":three.md"]) == "third\n"

    # And still one commit per run: the agent's keystrokes are not the branch's history.
    assert git!(dir, ["rev-list", "--count", "HEAD"]) |> String.trim() == "2"
    assert git!(dir, ["log", "-1", "--format=%s"]) |> String.trim() == "planning: attempt 1"
  end

  test "a run that changed nothing pushes nothing", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root, @direct)
    before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"])

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) == before
    assert String.trim(before) == head
  end

  # `docs/design/job-prompt.md` § Integrating the default branch, and `git-hosting.md`
  # § Non-fast-forward on a ticket branch: an integrating job sees the default branch, and its one
  # squashed commit keeps the merge — the old ticket head first, the default branch second.
  describe "an integrating job" do
    setup %{origin: origin} do
      work = tmp_dir("diverge")
      git!(nil, ["clone", "--quiet", origin, work])
      git!(work, ["config", "user.name", "elsewhere"])
      git!(work, ["config", "user.email", "elsewhere@forge"])
      git!(work, ["config", "commit.gpgsign", "false"])

      # Both branches change README.md, as two tickets cut from one base and merged one after
      # the other did in production.
      git!(work, ["checkout", "--quiet", "ticket/1"])
      File.write!(Path.join(work, "README.md"), "# Game, the ticket's\n")
      git!(work, ["commit", "--quiet", "-am", "the ticket's work"])
      git!(work, ["push", "--quiet", "origin", "ticket/1"])

      git!(work, ["checkout", "--quiet", "main"])
      File.write!(Path.join(work, "README.md"), "# Game, another ticket's\n")
      git!(work, ["commit", "--quiet", "-am", "Merge ticket/2: another"])
      git!(work, ["push", "--quiet", "origin", "main"])

      %{
        ticket: rev(origin, "refs/heads/ticket/1"),
        main: rev(origin, "refs/heads/main")
      }
    end

    defp integrating(origin, opts \\ []),
      do: put_in(assignment(origin, opts), ["git", "default_branch"], "main")

    defp rev(dir, ref), do: git!(nil, ["-C", dir, "rev-parse", ref]) |> String.trim()

    # The index and the worktree in one string: what a conflicted path is staged as (`UU`) and
    # what is modified or untracked beside it.
    defp status(dir), do: git!(dir, ["status", "--porcelain"])

    # A path with a newline in its name, conflicting on both branches: `ls-files` quotes such a
    # name unless it is asked with `-z`.
    defp diverge_newline(origin) do
      for {branch, content} <- [{"ticket/1", "ours\n"}, {"main", "theirs\n"}] do
        work = tmp_dir("newline-" <> String.replace(branch, "/", "-"))
        git!(nil, ["clone", "--quiet", "--branch", branch, origin, work])
        git!(work, ["config", "user.name", "newline"])
        git!(work, ["config", "user.email", "newline@forge"])
        File.write!(Path.join(work, "two\nlines.md"), content)
        git!(work, ["add", "--", "two\nlines.md"])
        git!(work, ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "two lines"])
        git!(work, ["push", "--quiet", "origin", branch])
      end
    end

    # A file with a NUL byte in it, different on each branch: git merges no such file and writes
    # no marker in one, so the index is the only record that it conflicted.
    defp diverge_binary(origin) do
      for {branch, content} <- [{"ticket/1", "ours\0"}, {"main", "theirs\0"}] do
        work = tmp_dir("binary-" <> String.replace(branch, "/", "-"))
        git!(nil, ["clone", "--quiet", "--branch", branch, origin, work])
        git!(work, ["config", "user.name", "binary"])
        git!(work, ["config", "user.email", "binary@forge"])
        File.write!(Path.join(work, "logo.png"), content)
        git!(work, ["add", "logo.png"])
        git!(work, ["-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "a logo"])
        git!(work, ["push", "--quiet", "origin", branch])
      end
    end

    # What the agent is told to do: merge, resolve, commit the merge.
    defp merge_and_resolve(dir) do
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["-c", "commit.gpgsign=false", "commit", "--quiet", "-am", "merge main"])
    end

    test "has the default branch beside its own", %{origin: origin, root: root, main: main} do
      {:ok, dir} = Workspace.prepare(integrating(origin), root, @direct)

      assert rev(dir, "refs/remotes/origin/main") == main
      assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"
      assert File.read!(Path.join(dir, "README.md")) == "# Game, the ticket's\n"
    end

    test "squashes its merge into one commit that keeps both parents", context do
      %{origin: origin, root: root, ticket: ticket, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      merge_and_resolve(dir)
      File.write!(Path.join(dir, "NOTES.md"), "resolved by keeping both\n")

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == head
      assert rev(origin, head <> "^1") == ticket
      assert rev(origin, head <> "^2") == main
      assert git!(nil, ["-C", origin, "show", head <> ":README.md"]) == "# Game, both\n"
      assert git!(nil, ["-C", origin, "show", head <> ":NOTES.md"]) =~ "keeping both"
      assert git!(nil, ["-C", origin, "log", "-1", "--format=%s", head]) =~ "integrating"
    end

    # Told not to, and done anyway: the old head is still the first parent, so the commit the
    # ticket's merge was last attempted for stays an ancestor of what is pushed.
    test "a run that rebased is squashed into a merge all the same", context do
      %{origin: origin, root: root, ticket: ticket, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      git!(dir, ["reset", "--quiet", "--hard", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["-c", "commit.gpgsign=false", "commit", "--quiet", "-am", "replayed"])

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, head <> "^1") == ticket
      assert rev(origin, head <> "^2") == main
    end

    # Fetched is not merged: a run that never merged the default branch did not bring it in, and
    # a second parent would say it had.
    test "a run that did not merge keeps one parent", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      File.write!(Path.join(dir, "NOTES.md"), "could not decide\n")

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, head <> "^1") == ticket

      assert {_out, 128} =
               System.cmd("git", ["-C", origin, "rev-parse", "--verify", head <> "^2"],
                 stderr_to_stdout: true
               )
    end

    test "a later run that merged nothing new keeps one parent", context do
      %{origin: origin, root: root, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      merge_and_resolve(dir)
      {:ok, merged} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      # A cold start of the next run, on the worktree the first left: the branch already has the
      # default branch's head, so there is nothing for this run's commit to keep.
      {:ok, ^dir} = Workspace.prepare(job, root, @direct)
      assert rev(dir, "HEAD") == merged
      assert rev(dir, "refs/remotes/origin/main") == main
      File.write!(Path.join(dir, "MORE.md"), "a fix on top\n")

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 2", @direct)

      assert rev(origin, head <> "^1") == merged

      assert {_out, 128} =
               System.cmd("git", ["-C", origin, "rev-parse", "--verify", head <> "^2"],
                 stderr_to_stdout: true
               )
    end

    # A run that merged and died before its squash is resumed on its own worktree — after the
    # default branch moved on. The fetch brings the newer head, which the merge does not contain;
    # what is kept is what the run merged.
    test "a resumed run keeps what it merged, after the default branch moved", context do
      %{origin: origin, root: root, ticket: ticket, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      merge_and_resolve(dir)

      work = tmp_dir("moves-on")
      git!(nil, ["clone", "--quiet", "--branch", "main", origin, work])
      File.write!(Path.join(work, "LATER.md"), "landed meanwhile\n")
      git!(work, ["add", "."])

      git!(
        work,
        ["-c", "user.name=t", "-c", "user.email=t@forge", "-c", "commit.gpgsign=false"] ++
          ["commit", "--quiet", "-m", "later"]
      )

      git!(work, ["push", "--quiet", "origin", "main"])

      resumed = %{job | "resume_session" => "sess-1"}
      assert {:ok, ^dir} = Workspace.prepare(resumed, root, @direct)
      refute rev(dir, "refs/remotes/origin/main") == main

      assert {:ok, head} =
               Workspace.commit_and_push(resumed, dir, "integrating: attempt 1", @direct)

      assert rev(origin, head <> "^1") == ticket
      assert rev(origin, head <> "^2") == main
    end

    # On every run, not only the clone: a later run on the worktree an earlier one left is handed
    # the default branch as it is now.
    test "a later run on its own worktree fetches the default branch again", context do
      %{origin: origin, root: root, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      assert rev(dir, "refs/remotes/origin/main") == main

      work = tmp_dir("moves")
      git!(nil, ["clone", "--quiet", "--branch", "main", origin, work])
      File.write!(Path.join(work, "LATER.md"), "landed meanwhile\n")
      git!(work, ["add", "."])

      git!(work, [
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@forge",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--quiet",
        "-m",
        "later"
      ])

      git!(work, ["push", "--quiet", "origin", "main"])

      assert {:ok, ^dir} = Workspace.prepare(job, root, @direct)
      assert rev(dir, "refs/remotes/origin/main") == rev(origin, "refs/heads/main")
    end

    # The run ended mid-merge, with the conflict still open: `git reset --soft` is refused in the
    # middle of a merge, and before this the whole squash died on it with the run's work neither
    # committed nor explained (ticket 11). A conflicted tree is not work to push, so nothing is
    # committed — and nothing is touched either, so the next run can finish the merge.
    test "an unresolved conflict commits nothing and names the paths", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      before = status(dir)

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      # Nothing pushed; and the whole index and worktree are as the run left them, which is the
      # claim "nothing is staged, committed or reset" makes and the one a stray `add -A` breaks.
      assert rev(origin, "refs/heads/ticket/1") == ticket
      assert status(dir) == before
      assert File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))
      assert File.read!(Path.join(dir, "README.md")) =~ "<<<<<<<"
      assert rev(dir, "HEAD") == ticket
    end

    # **`git add` on a conflicted path clears the index's record of the conflict**, so an index
    # with nothing unmerged says only that the agent staged something. Staging the markers and
    # stopping is the commonest reflex there is, and judging the index alone pushed
    # `<<<<<<< HEAD` onto the branch as the merge's resolution — with the merge kept as a second
    # parent, so nothing would ever find that conflict again.
    test "a conflict staged without being resolved is still unresolved", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])

      # A second file with the same markers, left untracked — `git mergetool` leaves exactly this
      # behind as `<path>.orig`, and `add -A` would commit it. Both are named, once each and in
      # the order a person reads them in.
      File.write!(Path.join(dir, "AAA.orig"), "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> x\n")
      git!(dir, ["add", "README.md"])

      assert {:error, {:merge_unresolved, ["AAA.orig", "README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
      refute git!(nil, ["-C", origin, "show", ticket <> ":README.md"]) =~ "<<<<<<<"
    end

    # **An attribute must not be able to hide a conflict from the question.** `*.lock -diff`,
    # `*.min.js binary` and `*.svg binary` are ordinary, and git's text-only readers skip exactly
    # those paths — including a `.gitattributes` the run itself wrote and has not committed, which
    # would otherwise take a conflicted tree from refused to pushed and commit the attribute file
    # along with the markers.
    test "an attribute that calls a path binary does not hide its conflict", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      File.write!(Path.join(dir, ".gitattributes"), "README.md -diff\n")
      git!(dir, ["add", "-A"])

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
    end

    # A marker-shaped line is not a conflict: a Markdown heading underlined with seven `=` is one
    # line of the three, and refusing a run for it would lose a turn's work over a file nothing
    # conflicted in — on the default branch's own content, every turn, for ever.
    test "a line of seven equals signs on its own is not a conflict", context do
      %{origin: origin, root: root} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      File.write!(Path.join(dir, "NOTES.md"), "Heading\n=======\n\nand a line with a tab\t\n")
      git!(dir, ["add", "-A"])

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)
      assert git!(nil, ["-C", origin, "show", head <> ":NOTES.md"]) =~ "======="
    end

    # **`git commit` is what closes an operation**, so an agent that staged its markers and
    # committed them leaves nothing open: no `MERGE_HEAD`, no unmerged index, and the markers
    # still in the tree. That is the worst case, not the mildest — the squash would keep the merge
    # as a second parent, so no later `merge-tree` would ever find that conflict again — and it is
    # why the question is also asked of a run with a merge to keep.
    test "a conflict the run committed itself is still refused", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      git!(dir, ["add", "-A"])
      git!(dir, ["-c", "commit.gpgsign=false", "commit", "--quiet", "--no-edit"])
      refute File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
    end

    # And not asked of a run with no merge to keep and nothing open: a repository whose own files
    # show a conflict — a design note about one, a `.orig` nobody cleaned up — is asked about
    # while it is resolving or merging, and not on every run for the rest of time.
    test "a file that shows a conflict is no business of a run that merged nothing", context do
      %{origin: origin, root: root} = context
      job = assignment(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      File.write!(Path.join(dir, "NOTES.md"), "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> x\n")

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)
      assert git!(nil, ["-C", origin, "show", head <> ":NOTES.md"]) =~ "<<<<<<<"
    end

    # **The dialect is not the repository's to choose.** `grep.patternType` is read from a config
    # the job's user can write, and `fixed` makes every pattern a literal — `^` included — so a
    # conflicted tree matched nothing and was called resolved.
    test "a repository's own grep config cannot switch the question off", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      git!(dir, ["config", "grep.patternType", "fixed"])
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      git!(dir, ["add", "-A"])

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
    end

    # A git that failed is not a tree that is clean. Provoked with a config git refuses outright,
    # which is also what a `grep.patternType` it does not know would do: the run fails saying so,
    # rather than passing on an answer nobody got.
    test "a git that fails the question fails the run", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      git!(dir, ["add", "-A"])
      git!(dir, ["config", "grep.threads", "not-a-number"])

      assert {:error, {128, out}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert out =~ "grep.threads"
      assert rev(origin, "refs/heads/ticket/1") == ticket
    end

    # **What git chatters is not an answer.** `git/3` folds stderr into stdout, so a repository
    # whose `core.fsmonitor` writes there mixes its lines into every reply. The verdicts are exit
    # statuses, which that cannot touch; the names are filtered to what git prints as a path, so
    # the chatter does not reach the person as a conflicted file.
    test "a repository that chatters on stderr is still read correctly", context do
      %{origin: origin, root: root} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      monitor = Path.join(root, "chatter.sh")
      File.write!(monitor, "#!/bin/sh\necho 'fsmonitor chatter' >&2\nexit 1\n")
      File.chmod!(monitor, 0o755)
      git!(dir, ["config", "core.fsmonitor", monitor])
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      # And with the markers staged, where the answer comes from `git grep` instead.
      git!(dir, ["add", "-A"])

      assert {:error, {:merge_unresolved, paths}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      refute Enum.any?(paths, &(&1 =~ "chatter"))
    end

    # **What git wrote to stderr is not a conflicted file.** `git/3` folds stderr into stdout, so a
    # directory the run cannot read makes `git grep` warn into the middle of its own answer — and
    # that warning went into the reason, and from there into the sentence the person in a chat
    # reads. The verdict is an exit status, which the warning cannot touch; the names keep only
    # what git prints as a path, so the worst it costs is a name.
    test "what git warns about is kept out of the paths a person reads", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      git!(dir, ["add", "-A"])
      locked = Path.join(dir, "locked")
      File.mkdir_p!(locked)
      File.write!(Path.join(locked, "x.md"), "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n")
      File.chmod!(locked, 0o000)
      on_exit(fn -> File.chmod(locked, 0o755) end)

      assert {:error, {:merge_unresolved, paths}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
      refute Enum.any?(paths, &(&1 =~ "Permission denied"))
    end

    # A path with a newline in it, which `ls-files` quotes unless it is asked with `-z`: the name
    # a person reads is the name on disk.
    test "a conflicted path with a newline in its name is named whole", context do
      %{origin: origin, root: root} = context
      job = integrating(origin)
      diverge_newline(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])

      assert {:error, {:merge_unresolved, paths}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert "two\nlines.md" in paths
    end

    # Resolved and staged, and the run ended before `git commit`: the same refusal from git, and
    # the work was there to keep. The merge is finished for it, which is what makes `merged/4`
    # see the default branch in the run's history at all.
    test "a merge resolved but not committed is finished and kept", context do
      %{origin: origin, root: root, ticket: ticket, main: main} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["add", "README.md"])

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == head
      assert rev(origin, head <> "^1") == ticket
      assert rev(origin, head <> "^2") == main
      assert git!(nil, ["-C", origin, "show", head <> ":README.md"]) == "# Game, both\n"
      refute File.exists?(Path.join([dir, ".git", "MERGE_HEAD"]))
    end

    # **An edit left unstaged is not a resolution**, which is a decision and not an oversight:
    # judging the content instead would need a model the operation does not have for a binary
    # conflict or a `-diff` path, where nothing but `git add` can say the agent chose. So the run
    # is refused, the paths are named, and the tree is left — a conversation's next turn stages it
    # and the work goes with that turn.
    test "a resolution the run never staged is refused, and the tree is left alone", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      before = status(dir)

      assert {:error, {:merge_unresolved, ["README.md"]}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, "refs/heads/ticket/1") == ticket
      assert status(dir) == before
      assert File.read!(Path.join(dir, "README.md")) == "# Game, both\n"
    end

    # **A binary conflict can only be resolved by staging**: git writes no marker in one, leaves
    # *ours* in the worktree, and no reading of the content can tell a choice from an untouched
    # file. The index is what knows, which is why it is what is asked.
    test "a binary conflict is unresolved until it is staged", context do
      %{origin: origin, root: root} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      diverge_binary(origin)
      {:ok, ^dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "merge", "--quiet", "origin/main"])

      assert {:error, {:merge_unresolved, paths}} =
               Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert "logo.png" in paths

      # Staging it *is* the resolution — ours, deliberately — and the squash keeps the merge. The
      # text conflict beside it is resolved the ordinary way, since nothing is resolved by halves.
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["add", "-A"])
      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)
      assert rev(origin, head <> "^2") == rev(origin, "refs/heads/main")
    end

    # **`MERGE_HEAD` is not the question git asks.** `reset --soft` refuses on an unmerged index
    # as well (`builtin/reset.c`), and a conflicted cherry-pick, rebase or revert has no
    # `MERGE_HEAD` at all — so a guard that asked only for one died on exactly the error ticket 11
    # is about, with no paths in it. There is no second parent to keep for any of them: what the
    # tree needs is the conflict gone.
    for {op, args} <- [
          {"cherry-pick", ["cherry-pick", "origin/main"]},
          {"rebase", ["rebase", "origin/main"]},
          {"revert", ["revert", "--no-edit", "origin/main"]}
        ] do
      test "a conflicted #{op} is refused, not run into a git error", context do
        %{origin: origin, root: root, ticket: ticket} = context
        job = integrating(origin)
        {:ok, dir} = Workspace.prepare(job, root, @direct)
        {_out, code} = System.cmd("git", ["-C", dir] ++ unquote(args), stderr_to_stdout: true)
        assert code != 0, "#{unquote(op)} was expected to conflict"

        assert {:error, {:merge_unresolved, ["README.md"]}} =
                 Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

        # And the same with the markers staged, where the index has nothing left to say and only
        # the sequencer's own head says an operation is open at all.
        git!(dir, ["add", "-A"])

        assert {:error, {:merge_unresolved, ["README.md"]}} =
                 Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

        assert rev(origin, "refs/heads/ticket/1") == ticket
      end
    end

    # **A finished rebase leaves `REBASE_HEAD` behind for ever.** Asking that ref said an operation
    # was open for the rest of the worktree's life — every later turn of a conversation — so one
    # file carrying markers, which this one has, meant nothing was ever committed again and the
    # person was told a conflict was unresolved in a file that has none. The rebase's own
    # directory is what git asks, and it goes when the rebase does. This run keeps no merge, so
    # the one thing that could open the gate is the operation.
    test "a rebase that finished is not an operation in progress", context do
      %{origin: origin, root: root} = context
      job = assignment(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      git!(dir, ["fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main"])
      {_out, 1} = System.cmd("git", ["-C", dir, "rebase", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["add", "-A"])

      {_out, 0} =
        System.cmd("git", ["-C", dir, "-c", "commit.gpgsign=false", "rebase", "--continue"],
          env: [{"GIT_EDITOR", "true"}]
        )

      # The ref git leaves behind, and the directory it does not: the first is why this test
      # exists, the second is what the code asks.
      assert File.exists?(Path.join([dir, ".git", "REBASE_HEAD"]))
      refute File.exists?(Path.join([dir, ".git", "rebase-merge"]))

      File.write!(Path.join(dir, "stale.orig"), "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n")

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)
      assert rev(origin, "refs/heads/ticket/1") == head
    end

    test "a cherry-pick resolved and staged is squashed, with one parent", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      {_out, 1} = System.cmd("git", ["-C", dir, "cherry-pick", "origin/main"])
      File.write!(Path.join(dir, "README.md"), "# Game, both\n")
      git!(dir, ["add", "-A"])

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "integrating: attempt 1", @direct)

      assert rev(origin, head <> "^1") == ticket
      assert git!(nil, ["-C", origin, "show", head <> ":README.md"]) == "# Game, both\n"

      # Not a merge: nothing named `origin/main` as merged, and a cherry-pick does not merge it.
      assert {_out, 128} =
               System.cmd("git", ["-C", origin, "rev-parse", "--verify", head <> "^2"],
                 stderr_to_stdout: true
               )
    end

    # The default branch is fetched after the ticket's, and a fetch writes FETCH_HEAD, which is
    # what a cold start resets the worktree to: in the other order the ticket's worktree became
    # the default branch.
    test "a cold start on its own worktree is the ticket's branch, not the default", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = integrating(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      File.write!(Path.join(dir, "half-done.txt"), "from a run that died")

      assert {:ok, ^dir} = Workspace.prepare(job, root, @direct)

      assert rev(dir, "HEAD") == ticket
      assert File.read!(Path.join(dir, "README.md")) == "# Game, the ticket's\n"
    end

    test "any other job neither fetches the default branch nor keeps a second parent", context do
      %{origin: origin, root: root, ticket: ticket} = context
      job = assignment(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)

      assert {_out, 128} =
               System.cmd("git", ["-C", dir, "rev-parse", "--verify", "refs/remotes/origin/main"],
                 stderr_to_stdout: true
               )

      # Even if the default branch reached the worktree some other way, the squash is one parent.
      git!(dir, ["fetch", "--quiet", "origin", "+refs/heads/main:refs/remotes/origin/main"])
      merge_and_resolve(dir)

      assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", @direct)
      assert rev(origin, head <> "^1") == ticket

      assert {_out, 128} =
               System.cmd("git", ["-C", origin, "rev-parse", "--verify", head <> "^2"],
                 stderr_to_stdout: true
               )
    end

    test "a default branch that is not a branch name is refused", %{origin: origin, root: root} do
      job = put_in(assignment(origin), ["git", "default_branch"], "main:refs/heads/ticket/1")

      assert {:error, {:not_a_branch, "main:refs/heads/ticket/1"}} =
               Workspace.prepare(job, root, @direct)
    end
  end

  describe "seeds" do
    setup %{origin: origin} do
      # What `mix forge.seed.publish` uploads: a full clone of the project with its build
      # directory warm beside it. Served to the worker from a plug rather than a platform.
      seed = tmp_dir("published-seed")
      git!(nil, ["clone", "--quiet", origin, seed])
      File.mkdir_p!(Path.join(seed, "build"))
      File.write!(Path.join(seed, "build/warm.o"), "already compiled\n")

      tarball = Path.join(tmp_dir("tar"), "seed.tar.gz")
      {_out, 0} = System.cmd("tar", ["-czf", tarball, "-C", seed, "."])
      body = File.read!(tarball)

      test = self()

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          send(test, {:seed_fetched, conn.request_path})
          Plug.Conn.send_resp(conn, 200, body)
        end
      )

      Application.put_env(:forge_worker, :platform_url, "http://platform.test")

      on_exit(fn ->
        Application.delete_env(:forge_worker, :req_options)
        Application.delete_env(:forge_worker, :platform_url)
      end)

      :ok
    end

    defp seeded(origin, opts \\ []) do
      put_in(assignment(origin, opts), ["seed"], %{
        "key" => "seed/demo/sha256-abc",
        "token" => "get-token"
      })
    end

    test "a worktree starts from the seed, warm build and all", %{origin: origin, root: root} do
      assert {:ok, dir} = Workspace.prepare(seeded(origin), root, @direct)

      assert_receive {:seed_fetched, "/store/seed/demo/sha256-abc"}

      # The branch the platform has, checked out on top of what the seed brought.
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"

      # And the reason the seed exists at all: `git clean -fd` leaves ignored files alone, so
      # the warm build directory survives becoming this job's branch.
      assert File.read!(Path.join(dir, "build/warm.o")) == "already compiled\n"
    end

    # A resume keeps the tree it finds, and a snapshot is not a tree it found: it is on whatever
    # commit the seed was built at. Kept as it was, the agent ran on the wrong tree and the squash
    # at the end pushed the difference as a commit undoing the ticket's work — which is exactly
    # the resume that lands on a machine without the job's own worktree.
    test "a resume onto a fresh snapshot is the branch, not the seed", context do
      %{origin: origin, root: root} = context

      # The ticket moved on after the seed was published.
      work = tmp_dir("ticket-work")
      git!(nil, ["clone", "--quiet", "--branch", "ticket/1", origin, work])
      git!(work, ["config", "user.name", "job"])
      git!(work, ["config", "user.email", "job@forge"])
      File.write!(Path.join(work, "PLAN.md"), "the earlier run's work\n")
      git!(work, ["add", "."])
      git!(work, ["commit", "--quiet", "-m", "planning: attempt 1"])
      git!(work, ["push", "--quiet", "origin", "ticket/1"])
      tip = git!(work, ["rev-parse", "HEAD"]) |> String.trim()

      job = seeded(origin, resume_session: "sess-42")
      assert {:ok, dir} = Workspace.prepare(job, root, @direct)

      assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"
      assert git!(dir, ["rev-parse", "HEAD"]) |> String.trim() == tip
      assert File.read!(Path.join(dir, "PLAN.md")) == "the earlier run's work\n"

      # Still the seed's warmth: reset, not cleaned.
      assert File.read!(Path.join(dir, "build/warm.o")) == "already compiled\n"

      # And the run that ends here builds on that work rather than undoing it. (The fixture's
      # seed does not ignore `build/`, so the squash does commit the seed's own output.)
      assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 2", @direct)
      assert git!(nil, ["-C", origin, "rev-parse", head <> "^"]) |> String.trim() == tip
      assert git!(nil, ["-C", origin, "show", head <> ":PLAN.md"]) =~ "earlier run"
    end

    test "the seed is fetched once and snapshotted per job", %{origin: origin, root: root} do
      assert {:ok, _first} = Workspace.prepare(seeded(origin, job_id: uuid()), root, @direct)
      assert_receive {:seed_fetched, _path}

      assert {:ok, second} = Workspace.prepare(seeded(origin, job_id: uuid()), root, @direct)
      refute_receive {:seed_fetched, _path}, 200

      assert File.read!(Path.join(second, "build/warm.o")) == "already compiled\n"
    end

    test "a project with no seed clones and builds cold", %{origin: origin, root: root} do
      assert {:ok, dir} = Workspace.prepare(assignment(origin), root, @direct)

      refute_receive {:seed_fetched, _path}, 200
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      refute File.exists?(Path.join(dir, "build/warm.o"))
    end

    test "a seed that will not fetch is slow, not fatal", %{origin: origin, root: root} do
      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "no such key") end
      )

      assert {:ok, dir} = Workspace.prepare(seeded(origin), root, @direct)
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      refute File.exists?(Path.join(dir, "build/warm.o"))
    end

    test "the seeds a machine holds are what it reports", %{origin: origin, root: root} do
      assert ForgeWorker.Job.Seed.present(root) == []
      {:ok, _dir} = Workspace.prepare(seeded(origin), root, @direct)
      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-abc"]
    end

    test "a new seed supersedes the old one rather than joining it", %{
      origin: origin,
      root: root
    } do
      {:ok, _dir} = Workspace.prepare(seeded(origin), root, @direct)
      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-abc"]

      # The project's seed_id moved. A worker needs the current seed and no other; on a machine
      # that is never destroyed, keeping them all is a few hundred megabytes a time, for ever.
      newer = put_in(seeded(origin, job_id: uuid()), ["seed", "key"], "seed/demo/sha256-def")
      {:ok, _dir} = Workspace.prepare(newer, root, @direct)

      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-def"]
    end

    test "the worktree is thrown away when the job ends", %{origin: origin, root: root} do
      job = seeded(origin)
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      assert File.dir?(dir)

      assert :ok = Workspace.discard(job, root)
      refute File.exists?(dir)

      # The seed it came from stays: the next job snapshots it again.
      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-abc"]
    end
  end

  describe "ticket volumes" do
    # What the agent leaves behind: a commit, and a build directory git was told to ignore.
    defp run!(job, root, message) do
      {:ok, dir} = Workspace.prepare(job, root, @direct)
      File.write!(Path.join(dir, ".gitignore"), "build/\n")
      File.mkdir_p!(Path.join(dir, "build"))
      File.write!(Path.join(dir, "build/warm.o"), message)
      File.write!(Path.join(dir, "NOTES.md"), message)
      {:ok, _head} = Workspace.commit_and_push(job, dir, message, @direct)
      :ok = Workspace.promote(job, root, dir)
      :ok = Workspace.discard(job, root)
      dir
    end

    test "a ticket's next job starts where its last one left off", context do
      %{origin: origin, root: root} = context
      run!(assignment(origin, job_id: uuid()), root, "first")

      assert {:ok, second} = Workspace.prepare(assignment(origin, job_id: uuid()), root, @direct)

      # The ignored build output the seed mechanism exists to carry, now carried between two
      # jobs of one ticket rather than only out of the project's seed.
      assert File.read!(Path.join(second, "build/warm.o")) == "first"

      # And it is this branch at the head the platform has, exactly as a cold start would be.
      assert git!(second, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"
      assert File.read!(Path.join(second, "NOTES.md")) == "first"
    end

    # A clone that fails must leave nothing behind. `prepare/3` reads a worktree that is already
    # there as an unfinished run's own and refreshes it, so an empty directory left by a clone
    # that never got going sends the job's next attempt past the ticket's template — the warmth
    # this whole mechanism is for — and nothing sweeps `worktrees/*` to clear it either.
    test "a cold clone that fails leaves nothing for the retry to mistake for a tree", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      broken = put_in(job, ["git", "url"], Path.join(tmp_dir("gone"), "missing.git"))

      assert {:error, _reason} = Workspace.prepare(broken, root, @direct)
      refute File.exists?(Workspace.dir(job, root))

      # The ticket gets its template meanwhile, from another of its jobs.
      run!(assignment(origin, job_id: uuid()), root, "first")

      assert {:ok, dir} = Workspace.prepare(job, root, @direct)
      assert File.read!(Path.join(dir, "build/warm.o")) == "first"
    end

    test "each job's own work reaches the next one through the template", context do
      %{origin: origin, root: root} = context
      run!(assignment(origin, job_id: uuid()), root, "first")
      run!(assignment(origin, job_id: uuid()), root, "second")

      assert {:ok, third} = Workspace.prepare(assignment(origin, job_id: uuid()), root, @direct)
      assert File.read!(Path.join(third, "build/warm.o")) == "second"
    end

    # What `bin/check` points MIX_HOME and HEX_HOME at: a dependency cache, hidden, at the
    # checkout root. Carried with its contents and not merely present — "warm" means the archive
    # Hex installed is still the archive Hex installed — and, the half no test above covers,
    # *untracked*. `add -A -f` in `Checkout.squash/5` is a mutation only this test fails on: the
    # `build/warm.o` tests would pass while every run pushed its own Hex cache onto the ticket
    # branch, which is the way putting a cache in the checkout goes wrong rather than merely
    # cold. (A snapshot that dropped hidden files is *not* what this adds over them: it would
    # drop `.git` too, and they all fail on it already.)
    test "a hidden dependency cache at the checkout root is carried, and not committed",
         context do
      %{origin: origin, root: root} = context
      first = assignment(origin, job_id: uuid())
      {:ok, dir} = Workspace.prepare(first, root, @direct)

      File.write!(Path.join(dir, ".gitignore"), ".mix-home/\n")
      File.mkdir_p!(Path.join(dir, ".mix-home/archives/hex-2.5.3"))
      File.write!(Path.join(dir, ".mix-home/archives/hex-2.5.3/hex.app"), "installed once")
      {:ok, _head} = Workspace.commit_and_push(first, dir, "first", @direct)
      :ok = Workspace.promote(first, root, dir)
      :ok = Workspace.discard(first, root)

      assert {:ok, second} = Workspace.prepare(assignment(origin, job_id: uuid()), root, @direct)

      assert File.read!(Path.join(second, ".mix-home/archives/hex-2.5.3/hex.app")) ==
               "installed once"

      # The other half of putting a cache in the checkout: the squash's `add -A` must not have
      # committed it onto the ticket branch. `add -Af` would, and this is what would notice.
      assert git!(second, ["ls-files", ".mix-home"]) == ""
    end

    # The promotion happens after the push, and this is what that buys: `add -A` has already
    # staged everything untracked that is not ignored, so the template holds no file a later run
    # could inherit and mistake for its own work. Promote before the push and this is dirty.
    test "the template carries nothing but the checkout and its ignored output", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      run!(job, root, "first")

      template = Workspace.template(job, root)
      assert git!(template, ["status", "--porcelain"]) == ""
      assert File.read!(Path.join(template, "build/warm.o")) == "first"
    end

    test "a promotion that fails leaves the ticket the template it had", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      run!(job, root, "first")
      template = Workspace.template(job, root)

      assert :ok = Workspace.promote(job, root, Path.join(root, "no-such-worktree"))

      assert File.read!(Path.join(template, "build/warm.o")) == "first"
      assert Path.wildcard(template <> ".promoting.*") == []
    end

    test "a conversation gets none: it keeps one worktree for its whole life", context do
      %{origin: origin, root: root} = context
      branch = "chat/" <> uuid()
      git!(nil, ["-C", origin, "branch", branch, "main"])
      chat = put_in(assignment(origin), ["git", "branch"], branch)

      assert Workspace.template(chat, root) == nil
      {:ok, dir} = Workspace.prepare(chat, root, @direct)
      assert :ok = Workspace.promote(chat, root, dir)
      assert Path.wildcard(Path.join([root, "volumes", "*", "*"])) == []
    end

    # The branch becomes a path. The platform builds it and `pre-receive` enforces its shape, so
    # this is belt and braces — and it is the belt that would be missing if either ever slipped.
    test "a branch that is not a ticket's is never turned into a path", context do
      %{origin: origin, root: root} = context

      for branch <- ["ticket/../../etc", "ticket/1/../2", "tickets/1", "ticket/", "ticket/1x"] do
        job = put_in(assignment(origin), ["git", "branch"], branch)
        assert Workspace.template(job, root) == nil, "#{branch} was made into a path"
      end

      assert Workspace.template(put_in(assignment(origin), ["git", "branch"], nil), root) == nil
    end

    test "a ticket volume nothing has used lately is swept, and a fresh one is kept", context do
      %{origin: origin, root: root} = context
      stale = assignment(origin, job_id: uuid())
      run!(stale, root, "first")
      stale_path = Workspace.template(stale, root)

      fresh = put_in(assignment(origin, job_id: uuid()), ["git", "branch"], "ticket/2")
      git!(nil, ["-C", origin, "branch", "ticket/2", "main"])
      run!(fresh, root, "second")
      fresh_path = Workspace.template(fresh, root)

      # Three days ago, against a two-day retention.
      File.touch!(stale_path, System.os_time(:second) - 3 * 24 * 60 * 60)

      assert Workspace.sweep(root, 2 * 24 * 60 * 60 * 1000) == 1

      refute File.exists?(stale_path)
      assert File.dir?(fresh_path)
    end

    # The seed note says a seed was cloned from wherever it was built, which is not necessarily
    # where this job fetches from, so the remote is set rather than trusted. A volume with no
    # remote at all is the same case with nothing to set.
    test "a template with no origin still becomes this job's checkout", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      run!(job, root, "first")

      git!(Workspace.template(job, root), ["remote", "remove", "origin"])

      assert {:ok, second} = Workspace.prepare(assignment(origin, job_id: uuid()), root, @direct)
      assert File.read!(Path.join(second, "build/warm.o")) == "first"
      assert git!(second, ["remote", "get-url", "origin"]) |> String.trim() == origin
    end

    # A warm start is what makes a job fast, not what makes it correct. A volume that cannot
    # become this branch is thrown away and the job takes the colder path rather than failing,
    # which is the same rule the seed has.
    test "a template that cannot become the branch is dropped, not fatal", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      template = Workspace.template(job, root)

      # Not a repository, and not empty either: `git clone` into it fails as well, so the only
      # way out is to remove it and start over.
      File.mkdir_p!(template)
      File.write!(Path.join(template, "junk.txt"), "not a checkout\n")

      assert {:ok, dir} = Workspace.prepare(job, root, @direct)
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      refute File.exists?(Path.join(dir, "junk.txt"))
    end

    # A volume's age has to mean "when this ticket last ran", and the tree's own mtime does not:
    # a snapshot carries the mtime of what it came from, and a worktree's root only changes when
    # an entry is added or removed at its top level — not when a job edits a file two directories
    # down. Without the touch this volume is swept minutes after the job that filled it.
    test "a ticket that ran just now survives, however old its files are", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())

      {:ok, dir} = Workspace.prepare(job, root, @direct)
      File.write!(Path.join(dir, "NOTES.md"), "first")
      {:ok, _head} = Workspace.commit_and_push(job, dir, "first", @direct)
      File.touch!(dir, System.os_time(:second) - 3 * 24 * 60 * 60)
      :ok = Workspace.promote(job, root, dir)

      assert Workspace.sweep(root, 2 * 24 * 60 * 60 * 1000) == 0
      assert File.dir?(Workspace.template(job, root))
    end

    # A promotion stages into a sibling of the volume it is replacing. Sweeping one would delete
    # a finishing job's copy out from under it, which is the seed's `.fetching.` rule again.
    test "a promotion in flight is never swept", context do
      %{origin: origin, root: root} = context
      job = assignment(origin, job_id: uuid())
      run!(job, root, "first")

      in_flight = Workspace.template(job, root) <> ".promoting.abcdef"
      File.mkdir_p!(in_flight)
      File.touch!(in_flight, System.os_time(:second) - 3 * 24 * 60 * 60)

      assert Workspace.sweep(root, 2 * 24 * 60 * 60 * 1000) == 0
      assert File.dir?(in_flight)
    end
  end

  test "the credential never lands in the repository", %{origin: origin, root: root} do
    job = put_in(assignment(origin), ["git", "token"], "secret-token")
    {:ok, dir} = Workspace.prepare(job, root, @direct)

    config = File.read!(Path.join([dir, ".git", "config"]))
    refute config =~ "secret-token"
  end

  # `docs/design/worker-channel.md` § A platform restart: a run that ends while the platform is
  # away waits to push rather than failing with its work unpushed. Only a push that did not reach
  # the platform is retried; a refusal is final.
  describe "pushing to a platform that is not there" do
    @refused "fatal: unable to access 'https://forge.example/git/p/': Failed to connect to " <>
               "forge.example port 443 after 3 ms: Couldn't connect to server"

    defp pushes(answers) do
      {:ok, agent} = Agent.start_link(fn -> answers end)

      fn ->
        Agent.get_and_update(agent, fn
          [answer | rest] -> {answer, rest}
          [] -> {:ok, []}
        end)
      end
    end

    defp sleeper do
      test = self()
      fn ms -> send(test, {:slept, ms}) end
    end

    test "waits, backing off, and pushes once the platform is back" do
      push = pushes([{:error, {128, @refused}}, {:error, {128, @refused}}, :ok])

      assert Workspace.patiently(push, 60_000, sleeper()) == :ok
      assert_received {:slept, 1_000}
      assert_received {:slept, 2_000}
      refute_received {:slept, _ms}
    end

    test "a refusal is not waited on" do
      denied = {:error, {128, "remote: Authentication failed\nfatal: Authentication failed"}}

      assert Workspace.patiently(pushes([denied]), 60_000, sleeper()) == denied
      refute_received {:slept, _ms}
    end

    test "gives up once its patience is spent" do
      push = fn -> {:error, {128, @refused}} end

      assert {:error, {128, @refused}} = Workspace.patiently(push, 3_000, sleeper())
      assert_received {:slept, 1_000}
      assert_received {:slept, 2_000}
      refute_received {:slept, _ms}
    end

    test "what counts as the platform not being there" do
      assert Workspace.unreachable?(@refused)
      assert Workspace.unreachable?("Could not resolve host: forge.example")
      assert Workspace.unreachable?("The requested URL returned error: 503")
      refute Workspace.unreachable?("The requested URL returned error: 403")

      refute Workspace.unreachable?(
               "! [remote rejected] HEAD -> ticket/1 (pre-receive hook declined)"
             )
    end
  end
end
