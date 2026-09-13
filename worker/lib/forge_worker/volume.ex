defmodule ForgeWorker.Volume do
  @moduledoc """
  Where a job's worktree and build directory come from. `docs/design/worker-tier.md` §
  Volumes and the seed settles the shape: a seed held once per project on the machine, and one
  copy-on-write snapshot of it per job, deleted when the job ends.

  Two implementations, and neither is a mock:

    * `ForgeWorker.Volume.Btrfs` snapshots a subvolume, which is what the worker image runs and
      what makes a snapshot cost nothing until it is written to.
    * `ForgeWorker.Volume.Copy` copies the tree with `cp -a`. It is correct — a job gets its own
      worktree and its own build directory — just without the sharing, and it is what a machine
      with no btrfs can run, which is every development machine and every container.

  `measure/` makes the same substitution for the same reason
  (`docs/design/measurement-harness.md`), and stamping which one ran is part of the record
  there and here.
  """

  @doc "A fresh, empty volume at `path`. Its parent is created if it is not there."
  @callback create(Path.t()) :: :ok | {:error, term()}

  @doc "A copy-on-write copy of `source` at `dest`."
  @callback snapshot(Path.t(), Path.t()) :: :ok | {:error, term()}

  @doc "Removes a volume. A path that is not there is already gone."
  @callback delete(Path.t()) :: :ok | {:error, term()}

  @doc "The implementation in force. `Copy` unless something says otherwise."
  @spec impl() :: module()
  def impl, do: Application.get_env(:forge_worker, :volume, ForgeWorker.Volume.Copy)

  @doc "A fresh, empty volume at `path`, whatever is there now."
  @spec recreate(module(), Path.t()) :: :ok | {:error, term()}
  def recreate(impl, path) do
    with :ok <- impl.delete(path), do: impl.create(path)
  end
end

defmodule ForgeWorker.Volume.Copy do
  @moduledoc """
  Volumes as plain directories: `cp -a` for a snapshot, `rm -rf` to delete. Correct but not
  cheap — every job pays for a full copy of the seed, and nothing is shared — which is why the
  image runs `ForgeWorker.Volume.Btrfs` and this is what a machine without btrfs falls back to.
  """

  @behaviour ForgeWorker.Volume

  @impl ForgeWorker.Volume
  def create(path) do
    File.mkdir_p(path)
  end

  @impl ForgeWorker.Volume
  def snapshot(source, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case System.cmd("cp", ["-a", "--", source, dest], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:copy, code, out}}
    end
  end

  @impl ForgeWorker.Volume
  def delete(path) do
    case File.rm_rf(path) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end
end

defmodule ForgeWorker.Volume.Btrfs do
  @moduledoc """
  Volumes as btrfs subvolumes. A snapshot of the seed costs its metadata and nothing else until
  the job writes, which is the whole reason the worker image has a btrfs root
  (`docs/design/worker-tier.md` § The worker image).

  Deleting falls back to `rm -rf`: a path that is a plain directory rather than a subvolume —
  left by a worker that ran `Copy` before, or by a half-finished fetch — still has to go.
  """

  @behaviour ForgeWorker.Volume

  require Logger

  @impl ForgeWorker.Volume
  def create(path) do
    File.mkdir_p!(Path.dirname(path))
    btrfs(["subvolume", "create", path])
  end

  @impl ForgeWorker.Volume
  def snapshot(source, dest) do
    File.mkdir_p!(Path.dirname(dest))
    btrfs(["subvolume", "snapshot", source, dest])
  end

  @impl ForgeWorker.Volume
  def delete(path) do
    if File.exists?(path) do
      case btrfs(["subvolume", "delete", path]) do
        :ok -> :ok
        {:error, _reason} -> ForgeWorker.Volume.Copy.delete(path)
      end
    else
      :ok
    end
  end

  defp btrfs(args) do
    case System.cmd("btrfs", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:btrfs, hd(args), code, out}}
    end
  end
end
