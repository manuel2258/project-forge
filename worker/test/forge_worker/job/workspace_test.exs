defmodule ForgeWorker.Job.WorkspaceTest do
  @moduledoc """
  Real git against a real bare repository. Two of these behaviours used to be tested in the
  platform's flow test, when the platform owned the worktree; they belong here now.
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Workspace

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
      "spec" => %{"state" => "planned", "attempt" => 1},
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
    assert {:ok, dir} = Workspace.prepare(assignment(origin), root)

    assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
    assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"
  end

  test "a cold start discards what a dead run left uncommitted", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)
    File.write!(Path.join(dir, "half-done.txt"), "from the run that was killed")
    File.write!(Path.join(dir, "README.md"), "clobbered")

    assert {:ok, ^dir} = Workspace.prepare(job, root)

    refute File.exists?(Path.join(dir, "half-done.txt"))
    assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
  end

  test "a resume keeps the work in progress", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)
    File.write!(Path.join(dir, "half-done.txt"), "from the attempt this one resumes")

    resumed = %{job | "resume_session" => "sess-42"}
    assert {:ok, ^dir} = Workspace.prepare(resumed, root)

    assert File.read!(Path.join(dir, "half-done.txt")) =~ "resumes"
  end

  test "the work is committed and pushed to the ticket branch", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)
    File.write!(Path.join(dir, "NOTES.md"), "work happened\n")

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planned: attempt 1")

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() == head
    assert git!(nil, ["-C", origin, "show", head <> ":NOTES.md"]) == "work happened\n"
  end

  test "one commit per run, not one per file", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)
    File.write!(Path.join(dir, "a.md"), "a")
    File.write!(Path.join(dir, "b.md"), "b")

    {:ok, _head} = Workspace.commit_and_push(job, dir, "planned: attempt 1")

    commits = git!(dir, ["rev-list", "--count", "HEAD"]) |> String.trim() |> String.to_integer()
    assert commits == 2
  end

  test "an agent that commits its own work still reaches the branch", %{
    origin: origin,
    root: root
  } do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)

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

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planned: attempt 1")

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() == head
    assert git!(nil, ["-C", origin, "show", head <> ":one.md"]) == "first\n"
    assert git!(nil, ["-C", origin, "show", head <> ":three.md"]) == "third\n"

    # And still one commit per run: the agent's keystrokes are not the branch's history.
    assert git!(dir, ["rev-list", "--count", "HEAD"]) |> String.trim() == "2"
    assert git!(dir, ["log", "-1", "--format=%s"]) |> String.trim() == "planned: attempt 1"
  end

  test "a run that changed nothing pushes nothing", %{origin: origin, root: root} do
    job = assignment(origin)
    {:ok, dir} = Workspace.prepare(job, root)
    before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"])

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planned: attempt 1")

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
      assert {:ok, dir} = Workspace.prepare(seeded(origin), root)

      assert_receive {:seed_fetched, "/store/seed/demo/sha256-abc"}

      # The branch the platform has, checked out on top of what the seed brought.
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) |> String.trim() == "ticket/1"

      # And the reason the seed exists at all: `git clean -fd` leaves ignored files alone, so
      # the warm build directory survives becoming this job's branch.
      assert File.read!(Path.join(dir, "build/warm.o")) == "already compiled\n"
    end

    test "the seed is fetched once and snapshotted per job", %{origin: origin, root: root} do
      assert {:ok, _first} = Workspace.prepare(seeded(origin, job_id: uuid()), root)
      assert_receive {:seed_fetched, _path}

      assert {:ok, second} = Workspace.prepare(seeded(origin, job_id: uuid()), root)
      refute_receive {:seed_fetched, _path}, 200

      assert File.read!(Path.join(second, "build/warm.o")) == "already compiled\n"
    end

    test "a project with no seed clones and builds cold", %{origin: origin, root: root} do
      assert {:ok, dir} = Workspace.prepare(assignment(origin), root)

      refute_receive {:seed_fetched, _path}, 200
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      refute File.exists?(Path.join(dir, "build/warm.o"))
    end

    test "a seed that will not fetch is slow, not fatal", %{origin: origin, root: root} do
      Application.put_env(:forge_worker, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "no such key") end
      )

      assert {:ok, dir} = Workspace.prepare(seeded(origin), root)
      assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
      refute File.exists?(Path.join(dir, "build/warm.o"))
    end

    test "the seeds a machine holds are what it reports", %{origin: origin, root: root} do
      assert ForgeWorker.Job.Seed.present(root) == []
      {:ok, _dir} = Workspace.prepare(seeded(origin), root)
      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-abc"]
    end

    test "the worktree is thrown away when the job ends", %{origin: origin, root: root} do
      job = seeded(origin)
      {:ok, dir} = Workspace.prepare(job, root)
      assert File.dir?(dir)

      assert :ok = Workspace.discard(job, root)
      refute File.exists?(dir)

      # The seed it came from stays: the next job snapshots it again.
      assert ForgeWorker.Job.Seed.present(root) == ["seed/demo/sha256-abc"]
    end
  end

  test "the credential never lands in the repository", %{origin: origin, root: root} do
    job = put_in(assignment(origin), ["git", "token"], "secret-token")
    {:ok, dir} = Workspace.prepare(job, root)

    config = File.read!(Path.join([dir, ".git", "config"]))
    refute config =~ "secret-token"
  end
end
