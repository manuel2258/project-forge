defmodule ForgeWorker.Job.WorkspaceVolumeTest.Fussy do
  @moduledoc """
  A volume implementation that can tell its own volumes from a plain directory, which is what
  real btrfs does and `ForgeWorker.Volume.Copy` cannot: `btrfs subvolume snapshot` refuses a
  source that is not a subvolume, while `cp -a` copies whatever it is handed.

  **Volume-ness is the directory's own inode here, as btrfs's is.** It travels with a
  `File.rename`, which is the last step of a promotion, and it leaves the directory empty — a
  mark written *inside* the volume would not, and `git clone` refuses a destination that exists
  and is not empty, so a volume carrying a marker file could not be cloned into at all.
  """

  @behaviour ForgeWorker.Volume

  alias ForgeWorker.Volume.Copy

  @doc "Starts the register of what this made, linked to the test that starts it."
  def start_link, do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  @doc "Whether `path` is a volume this made — the question `snapshot/2` asks of its source."
  def volume?(path) do
    case File.stat(path) do
      {:ok, stat} -> Agent.get(__MODULE__, &MapSet.member?(&1, stat.inode))
      {:error, _enoent} -> false
    end
  end

  @impl ForgeWorker.Volume
  def create(path) do
    with :ok <- Copy.create(path), do: mark(path)
  end

  @impl ForgeWorker.Volume
  def snapshot(source, dest) do
    if volume?(source) do
      # A snapshot of a subvolume is itself one.
      with :ok <- Copy.snapshot(source, dest), do: mark(dest)
    else
      {:error, {:not_a_volume, source}}
    end
  end

  @impl ForgeWorker.Volume
  def delete(path) do
    # Before the directory goes, while its inode can still be read, and because the next `mkdir`
    # on this filesystem may be handed the same one.
    unmark(path)
    Copy.delete(path)
  end

  defp mark(path), do: Agent.update(__MODULE__, &MapSet.put(&1, File.stat!(path).inode))

  defp unmark(path) do
    case File.stat(path) do
      {:ok, stat} -> Agent.update(__MODULE__, &MapSet.delete(&1, stat.inode))
      {:error, _enoent} -> :ok
    end
  end
end

defmodule ForgeWorker.Job.WorkspaceVolumeTest do
  @moduledoc """
  **A job's worktree is a volume however it was made, a cold clone included**, which is what
  lets the finished tree become the ticket's template (`docs/design/worker-tier.md` § The ticket
  volume).

  `ForgeWorker.Job.WorkspaceTest` runs the whole mechanism on `Volume.Copy`, where `cp -a`
  snapshots any directory at all and a worktree that was never made a volume looks exactly like
  one that was. On the image it does not: production logged `volume.unkept` 148 times in three
  days because every cold clone's worktree was a plain directory.

  Not async: which implementation is in force is one application environment key for the node.
  """

  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Workspace
  alias ForgeWorker.Job.WorkspaceVolumeTest.Fussy

  # The development slice's user, as in `ForgeWorker.Job.WorkspaceTest`: who runs git is
  # `ForgeWorker.Job.WorkspaceUserTest`'s subject, not this one's.
  @direct {ForgeWorker.Slice.Direct, %{kind: :direct}}

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

    {:ok, _register} = Fussy.start_link()
    Application.put_env(:forge_worker, :volume, Fussy)
    on_exit(fn -> Application.delete_env(:forge_worker, :volume) end)

    %{origin: origin, root: tmp_dir("root")}
  end

  defp assignment(origin) do
    %{
      "job_id" => uuid(),
      "spec" => %{"state" => "planning", "attempt" => 1},
      "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil}
    }
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  # The production failure end to end: with no template and no seed the job cloned into a plain
  # directory, promotion's snapshot was refused, no template was kept, and the ticket's next job
  # cloned cold again — for the whole life of the ticket.
  test "a cold clone leaves the ticket a template its next job starts from", context do
    %{origin: origin, root: root} = context
    first = assignment(origin)

    assert {:ok, dir} = Workspace.prepare(first, root, @direct)
    assert Fussy.volume?(dir), "a cold clone's worktree is not a volume"

    File.write!(Path.join(dir, ".gitignore"), "build/\n")
    File.mkdir_p!(Path.join(dir, "build"))
    File.write!(Path.join(dir, "build/warm.o"), "first")
    {:ok, _head} = Workspace.commit_and_push(first, dir, "first", @direct)
    :ok = Workspace.promote(first, root, dir)
    :ok = Workspace.discard(first, root)

    template = Workspace.template(first, root)
    assert File.dir?(template), "the cold clone was never kept as the ticket's template"
    assert Fussy.volume?(template), "the template is not a volume the next job can snapshot"

    # Which is the whole point of keeping it: the next job starts warm instead of cloning.
    assert {:ok, second} = Workspace.prepare(assignment(origin), root, @direct)
    assert File.read!(Path.join(second, "build/warm.o")) == "first"
  end
end
