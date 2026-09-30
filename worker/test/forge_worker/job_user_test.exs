defmodule ForgeWorker.JobUserTest do
  @moduledoc """
  **A hook the job wrote runs as the job's user, never as the worker** — the property
  `docs/design/worker-tier.md` § The job slice exists for, with `Slice.Systemd`'s real users.

  It makes and removes Unix users, so it needs root, and it is excluded unless asked for:

      sudo mix test --include root test/forge_worker/job_user_test.exs

  `ForgeWorker.Job.WorkspaceUserTest` checks the order everywhere else, with a slice that only
  records; this is the one place the order is shown to mean what it says. Before it, the worker
  handed the tree back to root and then ran `git commit` in it — and the job's `pre-commit` with
  it, as root.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures, only: [uuid: 0]

  alias ForgeWorker.Job.Workspace
  alias ForgeWorker.Slice.Systemd

  @moduletag :root

  setup do
    # Not `tmp_dir/1`: a job's user has to get through every directory above its tree, and a
    # development shell's temporary directory is its own user's alone.
    base = Path.join("/tmp", "forge-job-user-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    File.chmod!(base, 0o755)
    ran_as = Path.join(base, "ran-as")
    File.write!(ran_as, "")
    File.chmod!(ran_as, 0o666)
    on_exit(fn -> File.rm_rf!(base) end)

    origin = Path.join(base, "project.git")
    work = Path.join(base, "work")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, work])
    git!(work, ["config", "user.name", "seed"])
    git!(work, ["config", "user.email", "seed@forge"])
    File.write!(Path.join(work, "README.md"), "# Game\n")
    git!(work, ["add", "."])
    git!(work, ["commit", "--quiet", "-m", "seed"])
    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

    root = Path.join(base, "root")
    File.mkdir_p!(root)

    %{origin: origin, root: root, ran_as: ran_as}
  end

  defp job(origin) do
    %{
      "job_id" => uuid(),
      "spec" => %{"state" => "planning", "attempt" => 1},
      "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil}
    }
  end

  defp enter(job) do
    {:ok, owner} = Systemd.enter(job["job_id"])
    on_exit(fn -> Systemd.leave(owner, []) end)
    owner
  end

  # What the job does: a hook in its own `.git`, written as its own user, that says who ran it —
  # its user, its group, and every group it holds, since a gid or a supplementary group left at
  # root's is root's permissions on anything root's group may write.
  defp plant(dir, hook, owner, ran_as) do
    path = Path.join([dir, ".git", "hooks", hook])
    File.write!(path, "#!/bin/sh\necho \"$(id -un) $(id -gn) $(id -G)\" >> #{ran_as}\n")
    File.chmod!(path, 0o755)
    :ok = Systemd.own(owner, [dir])
  end

  # Who the hook said ran it, once per run of it.
  defp ran_as(path), do: path |> File.read!() |> String.split("\n", trim: true)

  defp as_the_job(owner) do
    {group, 0} = System.cmd("id", ["-gn", owner.user])
    {groups, 0} = System.cmd("id", ["-g", owner.user])
    "#{owner.user} #{String.trim(group)} #{String.trim(groups)}"
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  test "the job's pre-commit runs as the job's user when the worker commits", context do
    job = job(context.origin)
    owner = enter(job)
    user = {Systemd, owner}

    {:ok, dir} = Workspace.prepare(job, context.root, user)
    File.write!(Path.join(dir, "PLAN.md"), "the plan\n")
    plant(dir, "pre-commit", owner, context.ran_as)

    # The origin here is a directory, and git as the job's user will not push into one root
    # owns. On a machine it is the platform's endpoint over HTTP, which has no owner to ask.
    :ok = Systemd.own(owner, [context.origin])

    assert {:ok, head} = Workspace.commit_and_push(job, dir, "planning: attempt 1", user)

    assert ran_as(context.ran_as) == [as_the_job(owner)]

    # Read as root, which git now rightly refuses in a directory the job's user owns — this once,
    # for a test's look at its own origin.
    pushed = git!(nil, ["-c", "safe.directory=*", "-C", context.origin, "rev-parse", "ticket/1"])
    assert String.trim(pushed) == head
  end

  # The template is the last job's tree, `.git` and all. The next job's checkout of it is where a
  # `post-checkout` the last job left would run.
  test "the last job's post-checkout runs as the next job's user, not the worker's", context do
    first = job(context.origin)
    first_owner = enter(first)
    {:ok, dir} = Workspace.prepare(first, context.root, {Systemd, first_owner})
    plant(dir, "post-checkout", first_owner, context.ran_as)
    Systemd.leave(first_owner, [dir])
    :ok = Workspace.promote(first, context.root, dir)
    :ok = Workspace.discard(first, context.root)

    second = job(context.origin)
    second_owner = enter(second)
    {:ok, _dir} = Workspace.prepare(second, context.root, {Systemd, second_owner})

    assert ran_as(context.ran_as) |> Enum.uniq() == [as_the_job(second_owner)]
  end

  # `prepare/1` is the only way the unit's stop command gets a script to run, and it runs only as
  # root with a real user: no other test reaches it. Without the script, `ExecStopPost=-+` fails
  # silently and every run loses its last reading — and with it *killed at its ceiling* and any
  # kill no sample saw (`docs/design/worker-tier.md` § The job slice).
  test "preparing writes the unit's stop command where only root can touch it", %{root: root} do
    job = job("unused")
    owner = enter(job)
    job_dir = Path.join(root, "jobs/#{job["job_id"]}")
    File.mkdir_p!(job_dir)

    # A reading an earlier worker's run of this job left: it would hide this run's bus error.
    File.mkdir_p!(job_dir <> ".worker")
    stale = job_dir <> ".worker/at-exit.reading"
    File.write!(stale, "exit_code killed\nexit_status KILL\nevents oom_kill 1\n")

    {:ok, context} =
      Systemd.prepare(
        Map.merge(owner, %{job_id: job["job_id"], worktree: "/w", job_dir: job_dir})
      )

    script = job_dir <> ".worker/at-exit"
    assert "--property=ExecStopPost=-+#{script}" in Systemd.flags(context)

    %File.Stat{mode: mode, uid: 0} = File.stat!(script)
    assert Bitwise.band(mode, 0o111) != 0, "the stop command must be executable"
    assert File.read!(script) =~ "at-exit.reading"
    refute File.exists?(stale)

    # In a directory the job's user cannot enter, so nothing it runs can rewrite what root runs.
    %File.Stat{mode: dir_mode, uid: 0} = File.stat!(job_dir <> ".worker")
    assert Bitwise.band(dir_mode, 0o077) == 0
  end

  test "leaving gives the tree back to root and removes the user", context do
    job = job(context.origin)
    owner = enter(job)
    {:ok, dir} = Workspace.prepare(job, context.root, {Systemd, owner})
    assert %File.Stat{uid: uid} = File.stat!(dir)
    assert uid != 0

    assert :ok = Systemd.leave(owner, [dir])

    assert %File.Stat{uid: 0} = File.stat!(dir)
    assert {_out, code} = System.cmd("id", [owner.user], stderr_to_stdout: true)
    assert code != 0
  end
end
