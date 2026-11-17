defmodule ForgeWorker.Job.WorkspaceSeedTest do
  @moduledoc """
  A seed fetched into the workspace (`ForgeWorker.Job.Workspace`), against a plug that stands in
  for the platform's store.

  **Not async, and not in `WorkspaceTest`.** The plug and the platform's address are application
  environment (`:req_options`, `:platform_url`), which everything on the machine that fetches
  from the platform reads: set by a test in an async module they were read by whatever other
  async test happened to be fetching from a platform meanwhile, and a test that is given another's
  store fails for a reason that has nothing to do with it. A module that is not async runs alone.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Workspace

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
end
