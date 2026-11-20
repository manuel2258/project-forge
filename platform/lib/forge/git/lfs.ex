defmodule Forge.Git.Lfs do
  @moduledoc """
  The Git LFS objects of one repository, kept beside it — `<repo>/lfs/objects/<aa>/<bb>/<oid>`, the
  layout `git lfs` itself uses in a bare repository, so the hooks and the mirror run stock `git
  lfs` on the directory. **Never in `Forge.Storage`** (`docs/design/storage.md` § LFS objects are
  not in the store).

  Everything here takes the repository's path, built by the caller from the resolved project and
  never from a request; the one thing a request supplies is an oid, which `path/2` refuses unless it
  is exactly 64 lowercase hex characters. `docs/design/git-hosting.md` § Git LFS.

  `lfs/forge/` is this module's own: `incoming/` holds uploads being received, `lock` is what a
  push check and a deletion run take, and `sweep` is the record of when each unused object stopped
  being used.
  """

  alias Forge.Events
  alias Forge.Git
  alias Forge.Projects

  @default_max_object_bytes 2 * 1024 * 1024 * 1024
  @oid ~r/\A[0-9a-f]{64}\z/
  @day 86_400
  @retention 30 * @day
  @interval @day
  @incoming_ttl @day
  @lock_timeout 60_000

  @typedoc """
  What a reader gives `put/5`: given its state, one chunk at a time and the state to give it next,
  until `:eof`. A request's conn is the state in the plug, which is why it is threaded.
  """
  @type reader(state) ::
          (state -> {:ok, binary(), state} | {:eof, state} | {:error, term(), state})

  @doc "The per-object size limit, in bytes: `FORGE_LFS_MAX_OBJECT_BYTES`, else 2 GiB."
  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes, do: Forge.Jobs.config(:lfs_max_object_bytes, @default_max_object_bytes)

  @doc "Whether `oid` is a well-formed object id: exactly 64 lowercase hex characters."
  @spec oid?(term()) :: boolean()
  def oid?(oid), do: is_binary(oid) and Regex.match?(@oid, oid)

  @doc "The file an object is kept in, or `:error` for an oid that is not exactly 64 lowercase hex."
  @spec path(String.t(), term()) :: {:ok, String.t()} | :error
  def path(repo, oid) do
    if oid?(oid),
      do:
        {:ok, Path.join([objects_dir(repo), binary_part(oid, 0, 2), binary_part(oid, 2, 2), oid])},
      else: :error
  end

  @doc "Whether the repository holds the object."
  @spec held?(String.t(), term()) :: boolean()
  def held?(repo, oid) do
    case path(repo, oid) do
      {:ok, path} -> File.regular?(path)
      :error -> false
    end
  end

  @doc "The object's size in bytes, or `nil` when it is not held."
  @spec size(String.t(), term()) :: non_neg_integer() | nil
  def size(repo, oid) do
    with {:ok, path} <- path(repo, oid),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path) do
      size
    else
      _other -> nil
    end
  end

  @doc """
  Restarts the object's clock (its file's modification time). `:ok` whether or not it is held, and
  **it never makes a file**: `File.touch/1` creates a missing one, so an object a deletion run
  removed between a batch's `held?/2` and this would have come back as an empty file that every later
  upload batch called "already held" and every checkout failed on. `:file.change_time/2` only sets
  the times of a file that is there.
  """
  @spec touch(String.t(), term()) :: :ok
  def touch(repo, oid) do
    with {:ok, path} <- path(repo, oid), do: :file.change_time(path, :calendar.local_time())
    :ok
  end

  @doc "Where uploads are received before they are whole."
  @spec incoming_dir(String.t()) :: String.t()
  def incoming_dir(repo), do: Path.join([repo, "lfs", "forge", "incoming"])

  @doc """
  Receives one object from `reader` and keeps it only if it is whole.

  The chunks are written to a file in `lfs/forge/incoming/` as they arrive, hashed and counted, and
  never held together in memory. A body that runs past `size` is refused at once; the file is
  renamed into place — atomically, on the same filesystem — only when its length equals `size` and
  its sha256 equals `oid`. **Every other ending removes the file**, including a reader that fails
  or raises partway. Two uploads of one object at once rename identical bytes, so one correct copy
  is left. Returns the result and the reader's last state.
  """
  @spec put(String.t(), term(), non_neg_integer(), reader(state), state) ::
          {:ok
           | {:error,
              :size | :hash | :bad_oid | {:read, term()} | {:write, term()} | File.posix()},
           state}
        when state: var
  def put(repo, oid, size, reader, state) do
    case path(repo, oid) do
      {:ok, final} ->
        dir = incoming_dir(repo)
        File.mkdir_p!(dir)
        tmp = Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false))

        case File.open(tmp, [:write, :raw, :binary, :exclusive]) do
          {:ok, file} -> receive_into(file, tmp, final, oid, size, reader, state)
          {:error, reason} -> {{:error, {:write, reason}}, state}
        end

      :error ->
        {{:error, :bad_oid}, state}
    end
  end

  defp receive_into(file, tmp, final, oid, size, reader, state) do
    case copy(reader, state, file, :crypto.hash_init(:sha256), 0, size, oid) do
      {:ok, state} ->
        :ok = :file.close(file)
        File.mkdir_p!(Path.dirname(final))
        {File.rename(tmp, final), state}

      {error, state} ->
        {error, state}
    end
  after
    File.close(file)
    File.rm(tmp)
  end

  defp copy(reader, state, file, hash, count, size, oid) do
    case reader.(state) do
      {:ok, chunk, state} when count + byte_size(chunk) > size ->
        {{:error, :size}, state}

      {:ok, chunk, state} ->
        case :file.write(file, chunk) do
          :ok ->
            copy(
              reader,
              state,
              file,
              :crypto.hash_update(hash, chunk),
              count + byte_size(chunk),
              size,
              oid
            )

          {:error, reason} ->
            {{:error, {:write, reason}}, state}
        end

      {:eof, state} when count != size ->
        {{:error, :size}, state}

      {:eof, state} ->
        if Base.encode16(:crypto.hash_final(hash), case: :lower) == oid,
          do: {:ok, state},
          else: {{:error, :hash}, state}

      {:error, reason, state} ->
        {{:error, {:read, reason}}, state}
    end
  end

  @doc """
  Runs `fun` while holding the repository's LFS lock, `:shared` (a push check, which many may hold)
  or `:exclusive` (a deletion run, which none may share). The lock is `flock` on `lfs/forge/lock`,
  held by a child process until its port closes, so it is released however `fun` ends — and when the
  BEAM dies. `{:error, :lock_timeout}` when it could not be had in a minute.
  """
  @spec with_lock(String.t(), :shared | :exclusive, (-> result)) ::
          result | {:error, :lock_timeout | {:flock, integer()}}
        when result: var
  def with_lock(repo, mode, fun) when mode in [:shared, :exclusive] do
    dir = Path.join([repo, "lfs", "forge"])
    File.mkdir_p!(dir)
    flag = if mode == :exclusive, do: "-x", else: "-s"

    port =
      Port.open({:spawn_executable, System.find_executable("flock")}, [
        :binary,
        :exit_status,
        args: [flag, Path.join(dir, "lock"), "sh", "-c", "echo locked; cat >/dev/null"]
      ])

    receive do
      {^port, {:data, "locked\n"}} ->
        try do
          fun.()
        after
          Port.close(port)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:flock, status}}
    after
      @lock_timeout ->
        Port.close(port)
        {:error, :lock_timeout}
    end
  end

  @doc """
  The oids any commit reachable from any ref names, anywhere in its history — branches, tags and
  `refs/forge/*` — read from `git lfs ls-files --all --long`. **`{:error, _}` when git cannot say**
  (a dangling ref, say), which a caller deleting anything must treat as "everything is in use".
  """
  @spec in_use(String.t()) :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def in_use(repo) do
    with {:ok, out} <- Git.run(repo, ["lfs", "ls-files", "--all", "--long"]) do
      oids =
        for line <- String.split(out, "\n"),
            [_all, oid] <- [Regex.run(~r/\A([0-9a-f]{64}) [*-] /, line)],
            into: MapSet.new(),
            do: oid

      {:ok, oids}
    end
  end

  @doc "Every oid the repository holds."
  @spec objects(String.t()) :: [String.t()]
  def objects(repo) do
    objects_dir(repo)
    |> Path.join("*/*/*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.filter(&oid?/1)
  end

  @doc "Whether the repository has any LFS directory at all."
  @spec any?(String.t()) :: boolean()
  def any?(repo), do: File.dir?(objects_dir(repo))

  defp objects_dir(repo), do: Path.join([repo, "lfs", "objects"])
  defp state_path(repo), do: Path.join([repo, "lfs", "forge", "sweep"])

  # --- Deleting what nothing uses ------------------------------------------------------------

  @doc """
  Whether a repository is due a deletion run: it holds LFS objects and its record says the last run
  was a day or more before `now`, or says nothing.
  """
  @spec due?(String.t(), DateTime.t()) :: boolean()
  def due?(repo, now) do
    any?(repo) and
      case read_state(repo) do
        nil -> true
        %{at: at} -> DateTime.to_unix(now) - at >= @interval
      end
  end

  @doc """
  One deletion run for `project` as of `now`: records what stopped being used, and deletes the
  objects that have been unused for 30 days, the later of when forge first saw them unused and when
  they were last named by an upload batch or checked by a push. `docs/design/git-hosting.md` § Git LFS.

  **Deletes nothing when it cannot say what is in use**, and nothing at all on the first run in a
  repository with no record, which only records every unused object as unused from `now` — the safe
  reading of a lost record. Writes nothing in a repository with no `lfs/objects`. Records one
  `git.lfs.deleted` event when, and only when, it deleted something.
  """
  @spec sweep(Projects.Project.t(), DateTime.t()) ::
          {:ok, %{deleted: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def sweep(project, now \\ DateTime.utc_now()) do
    repo = Projects.repo_path(project)

    if any?(repo) do
      with {:ok, used} <- in_use(repo) do
        run(project, repo, used, DateTime.to_unix(now))
      end
    else
      {:ok, %{deleted: 0, bytes: 0}}
    end
  end

  defp run(project, repo, used, now) do
    state = read_state(repo)
    old = if state, do: state.entries, else: %{}
    present = objects(repo)

    entries =
      for oid <- present,
          entry = next_entry(oid, used, old, state, now),
          into: %{},
          do: {oid, entry}

    # `if state` is redundant with `next_entry/5`, which records every unused object as unused from
    # now when there is no record, so that none is yet due; it is kept so that "no record deletes
    # nothing" is read here and not inferred (an equivalent mutant: the test for it cannot tell).
    due =
      if state,
        do:
          Enum.filter(
            present,
            &(not MapSet.member?(used, &1) and due_at?(repo, &1, entries, now))
          ),
        else: []

    case with_lock(repo, :exclusive, fn -> delete(repo, due, entries, now) end) do
      {deleted, bytes, gone} ->
        write_state(repo, now, Map.drop(entries, gone))

        if deleted > 0 do
          Events.append("git.lfs.deleted", :system, %{
            project_id: project.id,
            payload: %{"project" => project.name, "objects" => deleted, "bytes" => bytes}
          })
        end

        sweep_incoming(repo, now)
        {:ok, %{deleted: deleted, bytes: bytes}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_entry(oid, used, old, state, now) do
    cond do
      MapSet.member?(used, oid) -> :in_use
      Map.get(old, oid) == :in_use -> {:unused, now}
      match?({:unused, _t}, Map.get(old, oid)) -> Map.fetch!(old, oid)
      # No record at all: every unused object is unused from now, and none is deleted.
      state == nil -> {:unused, now}
      # Listed nowhere: a new object, counted from its own clock.
      true -> nil
    end
  end

  defp due_at?(repo, oid, entries, now) do
    b =
      case entries[oid] do
        {:unused, t} -> t
        _none -> 0
      end

    case mtime(repo, oid) do
      nil -> false
      a -> now - max(a, b) >= @retention
    end
  end

  # Re-stat'd inside the exclusive lock: a push check that touched the object after the list was
  # made has restarted its clock, and that, not the list, decides.
  defp delete(repo, due, entries, now) do
    Enum.reduce(due, {0, 0, []}, fn oid, {n, bytes, gone} = acc ->
      with true <- due_at?(repo, oid, entries, now),
           size when is_integer(size) <- size(repo, oid),
           {:ok, path} <- path(repo, oid),
           :ok <- File.rm(path) do
        {n + 1, bytes + size, [oid | gone]}
      else
        _kept -> acc
      end
    end)
  end

  defp mtime(repo, oid) do
    with {:ok, path} <- path(repo, oid),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      mtime
    else
      _other -> nil
    end
  end

  defp sweep_incoming(repo, now) do
    dir = incoming_dir(repo)

    names =
      case File.ls(dir) do
        {:ok, names} -> names
        {:error, _reason} -> []
      end

    for name <- names,
        {:ok, %File.Stat{mtime: m}} <- [File.stat(Path.join(dir, name), time: :posix)],
        now - m >= @incoming_ttl,
        do: File.rm(Path.join(dir, name))

    :ok
  end

  # The record, beside the objects: a header with the time of the last run, then a line per object
  # that has one. Written only here, by rename, so a reader never sees half of it.
  defp read_state(repo) do
    with {:ok, text} <- File.read(state_path(repo)),
         ["forge-lfs-sweep 1 " <> at | lines] <- String.split(text, "\n", trim: true),
         {at, ""} <- Integer.parse(at) do
      %{at: at, entries: parse_lines(lines)}
    else
      _missing_or_damaged -> nil
    end
  end

  defp parse_lines(lines) do
    for line <- lines,
        [oid | rest] = String.split(line, " "),
        oid?(oid),
        entry = parse_entry(rest),
        into: %{},
        do: {oid, entry}
  end

  defp parse_entry(["in-use"]), do: :in_use

  defp parse_entry(["unused", t]) do
    case Integer.parse(t) do
      {t, ""} -> {:unused, t}
      _other -> nil
    end
  end

  defp parse_entry(_other), do: nil

  defp write_state(repo, now, entries) do
    path = state_path(repo)
    File.mkdir_p!(Path.dirname(path))

    body =
      for {oid, entry} <- Enum.sort(entries) do
        case entry do
          :in_use -> "#{oid} in-use\n"
          {:unused, t} -> "#{oid} unused #{t}\n"
        end
      end

    tmp = path <> ".tmp"
    File.write!(tmp, ["forge-lfs-sweep 1 #{now}\n" | body])
    File.rename!(tmp, path)
  end
end
