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

    test "each job's own work reaches the next one through the template", context do
      %{origin: origin, root: root} = context
      run!(assignment(origin, job_id: uuid()), root, "first")
      run!(assignment(origin, job_id: uuid()), root, "second")

      assert {:ok, third} = Workspace.prepare(assignment(origin, job_id: uuid()), root, @direct)
      assert File.read!(Path.join(third, "build/warm.o")) == "second"
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
