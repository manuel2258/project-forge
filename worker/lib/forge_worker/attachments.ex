defmodule ForgeWorker.Attachments do
  @moduledoc """
  The files people attached, as a folder of a job directory (`docs/design/attachments.md`
  § The folder): `$FORGE_JOB/attachments/`, read-only to the job.

  **Two directories, so that the job never writes where the worker does.**

  - `<job>.worker/attachment-cache/<version id>` holds each version's bytes once, downloaded
    through a `.partial` whose size and sha256 are checked, in the worker's own directory, which no
    other user can enter.
  - `<job>.worker/attachments/` holds the names the pool spells, each a link to a cached file. This
    is what is shown to the job — a read-only bind mount at `$FORGE_JOB/attachments/` where the
    image sets `FORGE_ATTACHMENTS=bind`, a copy of it elsewhere — so a conversation can bring it up
    to date between turns without the job being able to swap the folder for a link to anywhere
    between a check and a write.

  **A name is never a path.** The platform checks it, and this checks it again: a name that is not
  `ForgeCore.Workflow.valid_name?/1`, or an entry that is not shaped as the platform makes one, is
  left out and counted as failed. **Nothing here touches `ForgeWorker.Job.Secrets`**: people's files
  are not masked (`docs/design/secrets.md`).
  """

  alias ForgeCore.Workflow
  alias ForgeWorker.Archive.Mount
  alias ForgeWorker.{Config, Log, Store}
  alias ForgeWorker.Job.Dir

  require Logger

  @version_id ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @key ~r/\Aupload\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @hash ~r/\Asha256:[0-9a-f]{64}\z/

  @doc "The folder the job sees."
  @spec dir(Path.t()) :: Path.t()
  def dir(job_dir), do: Path.join(job_dir, Workflow.attachments_dir())

  @doc "The directory the worker keeps the names in, and the bind mount shows."
  @spec source_dir(Path.t()) :: Path.t()
  def source_dir(job_dir), do: Path.join(Dir.worker_dir(job_dir), "attachments")

  defp cache_dir(job_dir), do: Path.join(Dir.worker_dir(job_dir), "attachment-cache")

  @doc """
  Brings the folder to `entries`, the pool as the assignment (or a message) carries it: downloads
  what is not cached, removes what is no longer in the pool — a withdrawn file's bytes leave this
  machine with the next sync — and places each name. The names, as a list, that could not be
  had.
  """
  @spec sync(Path.t(), [map()] | nil) :: [String.t()]
  def sync(job_dir, entries) do
    entries = entries |> List.wrap() |> Enum.filter(&is_map/1)
    source = source_dir(job_dir)
    cache = cache_dir(job_dir)
    Dir.worker_dir!(job_dir)
    File.mkdir_p!(cache)
    File.chmod!(cache, 0o700)
    File.mkdir_p!(source)
    # Read by the job's user through the mount: the directory is the worker's and 0755, the files
    # in it 0444, and the worker's own directory above it is closed to everyone else. **The chmod
    # is an equivalent mutant under the usual umask**, which makes the directory 0755 already; it
    # is here for a machine whose umask is not the usual one.
    File.chmod!(source, 0o755)

    {valid, invalid} = entries |> unique() |> Enum.split_with(&valid?/1)
    {placed, failed} = fetch_all(job_dir, cache, valid)

    drop_cache(cache, Enum.map(valid, & &1["version_id"]))
    place(source, cache, placed)

    Enum.map(invalid, &name_of/1) ++ failed
  end

  # The first of a name wins: two files of one name would be one path.
  defp unique(entries), do: Enum.uniq_by(entries, & &1["file"])

  defp name_of(entry), do: to_string(entry["file"])

  # The shape checks of `sized?/1`, `@hash` and a regular file in `cached?/2` are equivalent mutants:
  # `verify/2` compares the downloaded bytes' size and sha256 with the entry's, and the cache is a
  # directory only the worker can enter. They refuse an entry early, with the name in the log.
  defp valid?(entry) do
    Workflow.valid_name?(entry["file"]) and shaped?(entry["version_id"], @version_id) and
      shaped?(entry["key"], @key) and is_binary(entry["token"]) and sized?(entry["size"]) and
      shaped?(entry["hash"], @hash)
  end

  defp shaped?(value, pattern), do: is_binary(value) and Regex.match?(pattern, value)
  defp sized?(size), do: is_integer(size) and size >= 0

  defp fetch_all(job_dir, cache, entries) do
    results = Enum.map(entries, &{&1, fetch(job_dir, cache, &1)})

    {for({entry, :ok} <- results, do: entry),
     for({entry, {:error, _reason}} <- results, do: entry["file"])}
  end

  defp fetch(job_dir, cache, entry) do
    path = Path.join(cache, entry["version_id"])

    if cached?(path, entry) do
      :ok
    else
      download(job_dir, path, entry)
    end
  end

  defp cached?(path, %{"size" => want}) do
    match?({:ok, %File.Stat{type: :regular, size: ^want}}, File.lstat(path))
  end

  defp download(job_dir, path, entry) do
    partial = path <> ".partial"
    File.rm_rf!(partial)

    with :ok <- Store.fetch(Config.platform_url(), entry["key"], entry["token"], partial),
         :ok <- verify(partial, entry) do
      File.chmod!(partial, 0o444)
      File.rename!(partial, path)
      :ok
    else
      {:error, reason} ->
        File.rm_rf(partial)

        Log.line(
          "attachments.unfetched",
          :warning,
          "could not fetch #{inspect(entry["file"])}: #{inspect(reason)}",
          job_id: Path.basename(job_dir)
        )

        {:error, reason}
    end
  end

  # What arrived is the file the platform named: its size and its hash, which is what makes a file
  # that was cut short, or that the platform's store served as something else, no file at all.
  defp verify(path, entry) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         true <- size == entry["size"] || {:error, :size},
         true <- hash(path) == entry["hash"] || {:error, :hash} do
      :ok
    end
  end

  defp hash(path) do
    digest =
      path
      |> File.stream!(1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp drop_cache(cache, keep) do
    for name <- File.ls!(cache), name not in keep, do: File.rm_rf(Path.join(cache, name))
    :ok
  end

  # The names the pool spells, as links to cached files, and nothing else: a name the pool no
  # longer has is removed, and one whose file is another version now is placed again.
  defp place(source, cache, placed) do
    wanted = Map.new(placed, &{&1["file"], Path.join(cache, &1["version_id"])})

    for name <- File.ls!(source),
        not Map.has_key?(wanted, name),
        do: File.rm_rf(Path.join(source, name))

    for {name, from} <- wanted do
      target = Path.join(source, name)

      unless same_file?(from, target) do
        File.rm_rf!(target)
        link_or_copy(from, target)
      end
    end

    :ok
  end

  defp same_file?(from, target) do
    with {:ok, %File.Stat{inode: inode, type: :regular}} <- File.lstat(from),
         {:ok, %File.Stat{inode: ^inode, type: :regular}} <- File.lstat(target) do
      true
    else
      _other -> false
    end
  end

  defp link_or_copy(from, target) do
    case File.ln(from, target) do
      :ok ->
        :ok

      {:error, _reason} ->
        File.cp!(from, target)
        File.chmod!(target, 0o444)
    end
  end

  @doc """
  What a run's spec says of the pool once the downloads are known: a file that could not be
  fetched is no longer one the agent is told it can read, and is named as not received instead, with
  the reason. A spec with no attachments is as it was.
  """
  @spec account(ForgeCore.Job.Spec.t(), [String.t()]) :: ForgeCore.Job.Spec.t()
  def account(%ForgeCore.Job.Spec{attachments: nil} = spec, _failed), do: spec
  def account(%ForgeCore.Job.Spec{} = spec, []), do: spec

  def account(%ForgeCore.Job.Spec{attachments: %{"files" => files} = attached} = spec, failed) do
    {lost, kept} = Enum.split_with(files, &(&1["file"] in failed))

    missing =
      Enum.map(lost, fn file ->
        file
        |> Map.take(["original", "to", "by", "at"])
        |> Map.put("why", "it could not be downloaded to this machine")
      end)

    %{
      spec
      | attachments: %{
          attached
          | "files" => kept,
            "not_received" => (attached["not_received"] || []) ++ missing
        }
    }
  end

  @doc """
  The run's spec, with the pool downloaded for it: before anything is written for the agent to read,
  so the manifest names no file the folder lacks. `root` is the worker's jobs directory.
  """
  @spec prepare(Path.t(), ForgeCore.Job.Spec.t(), [map()] | nil) :: ForgeCore.Job.Spec.t()
  def prepare(_root, spec, nil), do: spec

  def prepare(root, %ForgeCore.Job.Spec{job_id: job_id} = spec, entries) do
    Dir.check_id!(job_id)
    account(spec, sync(Path.join(root, job_id), entries))
  end

  @doc """
  Shows the worker's directory at the job's folder, read-only. Whatever an earlier run left at the
  path is released first. `:ok`, or the mount's reason.
  """
  @spec start(Path.t()) :: :ok | {:error, term()}
  def start(job_dir) do
    release(job_dir)
    folder = dir(job_dir)
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    File.mkdir_p!(source_dir(job_dir))

    Mount.attachments_impl().bind_ro(source_dir(job_dir), folder)
  end

  @doc "Makes a conversation's folder show what was just synced: a copy is made again."
  @spec refresh(Path.t()) :: :ok | {:error, term()}
  def refresh(job_dir), do: Mount.attachments_impl().refresh(source_dir(job_dir), dir(job_dir))

  @doc "Unmounts the folder. Idempotent."
  @spec release(Path.t()) :: :ok
  def release(job_dir) do
    case Mount.attachments_impl().unmount(dir(job_dir)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not unmount #{dir(job_dir)}: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Unmounts every attachments mount under `root`, from `/proc/self/mountinfo`: what a worker that was
  killed left behind, before anything removes or walks a job directory under it.
  """
  @spec sweep(Path.t(), String.t() | nil) :: non_neg_integer()
  def sweep(root, mountinfo \\ nil) do
    case mountinfo || read_mountinfo() do
      nil ->
        0

      text ->
        prefix = Path.expand(root) <> "/"

        text
        |> Mount.mountpoints()
        |> Enum.filter(&(String.starts_with?(&1, prefix) and Path.basename(&1) == "attachments"))
        |> Enum.count(fn mountpoint -> Mount.attachments_impl().unmount(mountpoint) == :ok end)
    end
  end

  defp read_mountinfo do
    case File.read("/proc/self/mountinfo") do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end
end
