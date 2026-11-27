defmodule ForgeWorker.Job.WorkspaceCommandTest do
  @moduledoc """
  Where a command's tree comes from (`Workspace.prepare_command/3`, `docs/design/worker-tier.md`
  § The command copy): the ticket's command copy when there is one it may use, the ticket's volume,
  the project's seed, a clone — and never a copy for anyone else.

  Not async: the volume implementation is one application environment key for the node.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.{CommandCopy, Workspace}
  alias ForgeWorker.RefusingVolume

  @direct {ForgeWorker.Slice.Direct, %{kind: :direct}}
  @ticket "5f0a6d1e-0000-4000-8000-000000000001"

  setup do
    origin = Path.join(tmp_dir("origin"), "project.git")
    work = tmp_dir("work")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, work])
    git!(work, ["config", "user.name", "seed"])
    git!(work, ["config", "user.email", "seed@forge"])
    File.write!(Path.join(work, "README.md"), "# Game\n")
    git!(work, ["add", "."])
    git!(work, ["commit", "--quiet", "-m", "seed"])
    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])
    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/chat/abc"])

    Application.put_env(:forge_worker, :volume, RefusingVolume)

    on_exit(fn ->
      Application.delete_env(:forge_worker, :volume)
      Application.delete_env(:forge_worker, :refuse_snapshot)
    end)

    %{origin: origin, root: tmp_dir("root"), work: work}
  end

  defp command(origin, overrides \\ %{}) do
    Map.merge(
      %{
        "job_id" => uuid(),
        "kind" => "command",
        "spec" => %{"command" => %{"keep_build" => [0], "name" => "test"}},
        "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil},
        "warm" => %{"ticket" => @ticket, "epoch" => 0}
      },
      overrides
    )
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  # What a command that kept its build left: an ignored build directory, a stray untracked file and
  # an edit to a tracked one.
  defp leave_a_copy(origin, root) do
    first = command(origin)
    {:ok, dir, %{source: "clone"}} = Workspace.prepare_command(first, root, @direct)
    File.write!(Path.join(dir, ".git/info/exclude"), "_build/\n", [:append])
    File.mkdir_p!(Path.join(dir, "_build"))
    File.write!(Path.join(dir, "_build/x"), "built")
    File.write!(Path.join(dir, "stray.txt"), "debris")
    File.write!(Path.join(dir, "README.md"), "edited\n")

    {:ok, key} = CommandCopy.key(first)

    {:ok, _size, _folders} =
      CommandCopy.keep(root, key, dir, %{"job_id" => first["job_id"], "commit" => "c"})

    :ok = Workspace.discard(first, root)
    first
  end

  test "starts from the ticket's copy: the build is there, the debris is not, the tracked files are the branch's",
       %{origin: origin, root: root} do
    first = leave_a_copy(origin, root)

    second = command(origin)
    assert {:ok, dir, source} = Workspace.prepare_command(second, root, @direct)

    assert source == %{source: "copy", from: first["job_id"]}
    assert File.read!(Path.join(dir, "_build/x")) == "built"
    refute File.exists?(Path.join(dir, "stray.txt"))
    assert File.read!(Path.join(dir, "README.md")) == "# Game\n"
  end

  # The ordinary case: a script rewrote a tracked file (a lock file, a formatter's output) and the
  # agent has since pushed a commit that changes it too, and adds a file the script left untracked.
  # A plain `checkout -B` refuses both, and the whole copy was thrown away.
  test "a copy a script edited is still used when the branch has moved under its edits",
       %{origin: origin, root: root, work: work} do
    first = leave_a_copy(origin, root)
    File.write!(Path.join(work, "README.md"), "# Game, moved\n")
    File.write!(Path.join(work, "stray.txt"), "now tracked\n")
    git!(work, ["add", "."])
    git!(work, ["commit", "--quiet", "-m", "moves"])
    git!(work, ["push", "--quiet", "origin", "HEAD:refs/heads/ticket/1"])

    assert {:ok, dir, source} = Workspace.prepare_command(command(origin), root, @direct)

    assert source == %{source: "copy", from: first["job_id"]}
    assert File.read!(Path.join(dir, "_build/x")) == "built"
    assert File.read!(Path.join(dir, "README.md")) == "# Game, moved\n"
    assert File.read!(Path.join(dir, "stray.txt")) == "now tracked\n"
  end

  test "a copy the ticket's epoch has moved past is not used", %{origin: origin, root: root} do
    leave_a_copy(origin, root)

    assert {:ok, dir, %{source: "clone", from: nil}} =
             Workspace.prepare_command(
               put_in(command(origin), ["warm", "epoch"], 1),
               root,
               @direct
             )

    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "another ticket's copy is not used, though the branch name is the same",
       %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    other = put_in(command(origin), ["warm", "ticket"], "5f0a6d1e-0000-4000-8000-000000000002")

    assert {:ok, dir, %{source: "clone"}} = Workspace.prepare_command(other, root, @direct)
    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "a command that turns the copy off starts as it did before", %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    off = put_in(command(origin), ["spec", "command", "warm_start"], false)

    assert {:ok, dir, %{source: "clone"}} = Workspace.prepare_command(off, root, @direct)
    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "a conversation's command is not a ticket's and uses no copy", %{
    origin: origin,
    root: root
  } do
    leave_a_copy(origin, root)
    chat = put_in(command(origin), ["git", "branch"], "chat/abc")

    assert {:ok, dir, %{source: "clone"}} = Workspace.prepare_command(chat, root, @direct)
    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "an id that is not a UUID makes no path and uses no copy", %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    evil = put_in(command(origin), ["warm", "ticket"], "../x")

    assert {:ok, _dir, %{source: "clone"}} = Workspace.prepare_command(evil, root, @direct)
    refute File.exists?(Path.join(root, "volumes/x"))
  end

  test "an agent job's prepare never looks at the command copies", %{origin: origin, root: root} do
    leave_a_copy(origin, root)

    assert {:ok, dir} = Workspace.prepare(command(origin), root, @direct)
    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "a copy that cannot be snapshotted is a colder start, not a failure",
       %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    Application.put_env(:forge_worker, :refuse_snapshot, "volumes/command")

    assert {:ok, dir, %{source: "clone"}} =
             Workspace.prepare_command(command(origin), root, @direct)

    refute File.exists?(Path.join(dir, "_build/x"))
  end

  test "a worktree a dead attempt left is discarded, not refreshed and resumed",
       %{origin: origin, root: root} do
    job = command(origin)
    {:ok, dir, _source} = Workspace.prepare_command(job, root, @direct)
    File.write!(Path.join(dir, "left-behind.txt"), "dead attempt")

    assert {:ok, ^dir, _source} = Workspace.prepare_command(job, root, @direct)
    refute File.exists?(Path.join(dir, "left-behind.txt"))
  end

  # With a copy to start from, a leftover worktree would make the snapshot land inside it.
  test "a leftover worktree does not stop a copy being used", %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    job = command(origin)
    File.mkdir_p!(Workspace.dir(job, root))

    assert {:ok, dir, %{source: "copy"}} = Workspace.prepare_command(job, root, @direct)
    assert File.read!(Path.join(dir, "_build/x")) == "built"
  end

  test "without a copy it starts from the ticket's volume, which a command never writes",
       %{origin: origin, root: root} do
    job = command(origin)
    template = Workspace.template(job, root)
    File.mkdir_p!(Path.dirname(template))
    git!(nil, ["clone", "--quiet", origin, template])

    assert {:ok, _dir, %{source: "ticket"}} = Workspace.prepare_command(job, root, @direct)
  end

  test "sweeping the ticket volumes sweeps the command copies too, and counts both as volumes",
       %{origin: origin, root: root} do
    leave_a_copy(origin, root)
    {:ok, key} = CommandCopy.key(command(origin))
    File.touch!(CommandCopy.path(root, key), {{2020, 1, 1}, {0, 0, 0}})

    Workspace.sweep(root, :timer.hours(48))

    refute File.exists?(CommandCopy.path(root, key))
    refute File.exists?(CommandCopy.marker_path(root, key))
  end
end
