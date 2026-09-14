defmodule ForgeWorker.Job.Seed do
  @moduledoc """
  The warm starting point a job's worktree is snapshotted from: a full clone of the project
  plus its build directory, fetched once per machine and kept.

  `docs/design/worker-tier.md` § Volumes and the seed settles what it is and why. Two things
  from there matter here:

    * **It is a maintained blob, not a derived one.** The worker downloads it and unpacks it;
      nothing on this machine knows how to make one. `mix forge.seed.publish` does, on the
      platform's side, and refreshing it is an operator's action.
    * **A worker with no seed still works.** A project that has never had one published, or a
      fetch that fails, leaves the job to clone and build cold. That is slow, not wrong, and a
      first run for a project must not be an error.

  The fetch is done under a temporary name and renamed into place, so two jobs assigned at the
  same moment cannot see a half-unpacked seed: the loser's rename fails and it deletes its own
  copy. Nothing is locked, because the only thing being raced for is a download.
  """

  alias ForgeWorker.{Config, Store, Volume}

  require Logger

  @doc """
  The path to this assignment's seed on this machine, fetching it if it is not here yet, or
  `nil` when there is no seed to have. A caller that gets `nil` clones.
  """
  @spec ensure(map(), Path.t()) :: Path.t() | nil
  def ensure(assignment, root) do
    case assignment["seed"] do
      %{"key" => key, "token" => token} when is_binary(key) and is_binary(token) ->
        path = path(root, key)
        if File.dir?(path), do: path, else: fetch(key, token, path)

      _no_seed ->
        nil
    end
  end

  @doc "Where a seed key lives on this machine. The key is already a safe relative path."
  @spec path(Path.t(), String.t()) :: Path.t()
  def path(root, key), do: Path.join([root, "volumes", key])

  @doc "The seed keys this machine has, which is what the join payload reports."
  @spec present(Path.t()) :: [String.t()]
  def present(root) do
    base = Path.join(root, "volumes")

    base
    |> Path.join("seed/*/*")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, base))
    |> Enum.sort()
  end

  defp fetch(key, token, path) do
    volume = Volume.impl()
    staging = path <> ".fetching." <> Base.url_encode64(:crypto.strong_rand_bytes(6))
    tarball = staging <> ".tar.gz"

    started = System.monotonic_time(:millisecond)

    case unpack(volume, key, token, staging, tarball) do
      :ok ->
        install(volume, staging, path, key, started)

      {:error, reason} ->
        Logger.warning("no seed for #{key} (#{inspect(reason)}); this job builds cold")
        volume.delete(staging)
        File.rm(tarball)
        nil
    end
  end

  defp unpack(volume, key, token, staging, tarball) do
    with :ok <- Volume.recreate(volume, staging),
         :ok <- Store.fetch(Config.platform_url(), key, token, tarball),
         :ok <- extract(tarball, staging) do
      File.rm(tarball)
      :ok
    end
  end

  # `--no-same-owner` because the worker unpacks as root, and tar as root restores the owners
  # the archive recorded — which are whoever made the seed on the platform's host. A checkout
  # owned by a uid that means nothing here is one git refuses to touch as dubiously owned, and
  # the seed is a blob rather than a backup: its contents belong to whoever unpacks it.
  defp extract(tarball, into) do
    args = ["-xzf", tarball, "--no-same-owner", "-C", into]

    case System.cmd("tar", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:tar, code, out}}
    end
  end

  # The rename is the commit. A second job that fetched the same seed concurrently finds the
  # directory occupied, throws its own copy away and uses the one that got there first.
  defp install(volume, staging, path, key, started) do
    File.mkdir_p!(Path.dirname(path))

    case File.rename(staging, path) do
      :ok ->
        Logger.info("fetched seed #{key} in #{System.monotonic_time(:millisecond) - started}ms")
        superseded(volume, path)
        path

      {:error, _reason} ->
        volume.delete(staging)
        if File.dir?(path), do: path
    end
  end

  # `fetch/1` stages into `<path>.fetching.<rand>` and downloads to `<staging>.tar.gz`, both
  # siblings of the installed seed. Sweeping them would delete another job's fetch mid-flight —
  # two jobs assigned at the same moment both miss the seed, the winner installs, and the loser's
  # tar then fails and it builds cold. Degradation only, but at exactly the busiest moment.
  defp in_flight?(entry), do: String.contains?(Path.basename(entry), ".fetching.")

  # A worker needs one seed per project: the current one. The others are what the project's
  # `seed_id` used to be, at a few hundred megabytes each, and on a machine that is never
  # destroyed they are for ever. A job already holding a snapshot of one is unaffected — a btrfs
  # snapshot is not a child of its source, and the extents live as long as anything references
  # them.
  defp superseded(volume, path) do
    path
    |> Path.dirname()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.reject(&(&1 == path or in_flight?(&1)))
    |> Enum.each(fn stale ->
      Logger.info("removing superseded seed #{Path.basename(stale)}")
      volume.delete(stale)
    end)
  end
end
