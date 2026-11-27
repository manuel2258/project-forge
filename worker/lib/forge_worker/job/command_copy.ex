defmodule ForgeWorker.Job.CommandCopy do
  @moduledoc """
  A ticket's **command copy**: the tree its last command that kept its build left on this machine,
  which the ticket's next command snapshots instead of the ticket's volume
  (`docs/design/worker-tier.md` § The command copy: warmth between a ticket's commands).

  `volumes/command/<ticket id>` is the copy and `volumes/command/<ticket id>.json` its marker:
  `epoch`, `job_id`, `command`, `commit`. **A copy without a marker is no copy**, and a marker
  whose epoch is not the assignment's is not this ticket's any more (the platform's *Clear* adds
  one to the ticket's epoch, which makes every older copy on every machine stop matching without
  a message to any of them).

  **Keyed by the ticket's id, not its branch.** `ticket/<n>` is per project and one machine serves
  several, so a path built from the branch would hand one project's copy to another's ticket of the
  same number. The id travels in the assignment (`"warm" => %{"ticket", "epoch"}`) and is matched as
  a UUID before it becomes a path, and the branch is matched against `ticket/<n>` as the ticket
  volume's is: a conversation's command neither keeps nor uses a copy.

  **One lock per ticket on this machine** (`:global.trans/4`: the worker is one BEAM) covers reading
  the marker and snapshotting the copy, keeping a new one, and sweeping, so a reader never sees a
  copy half replaced. A keep snapshots to a sibling, deletes the marker, deletes the old copy,
  renames the sibling into place and writes the marker last, so a crash at any step leaves the old
  copy or none.

  **A copy someone is looking at is held** (`docs/design/worker-tier.md` § Looking into a copy,
  ticket 84). Opening a copy (`open/3`) writes `volumes/hold/<ticket>.<job>`, whose mtime is the last
  action anyone took on it, and the copy is held while that is under ten minutes old
  (`ForgeCore.Explore.hold_ms/0`, `:hold_ms`). **A keep that replaces a held copy moves it aside** to
  `volumes/held/<ticket>.<job>` — one rename, on btrfs and on a plain directory alike, and outside
  `volumes/command/*`, which the sweep's wildcard would take for a ticket — and the person goes on
  looking at the copy they opened, while the ticket's next command starts from the new one. **The
  two-day sweep leaves a held copy**, and `release_holds/1` removes a moved-aside copy once its hold
  has lapsed. Holds are files, so they survive a restart of the worker.

  Everything here is best effort in the caller's hands: a copy that cannot be kept or used costs
  the ticket's next command a colder start and never fails a command.
  """

  alias ForgeWorker.{Disk, Log, Volume}

  require Logger

  @ticket_branch ~r{\Aticket/\d+\z}
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type key :: %{ticket: String.t(), epoch: integer()}

  @doc """
  The ticket and epoch this assignment may keep or use a copy for, or `:none`: not a `ticket/<n>`
  branch, no `warm` in the assignment (a platform that does not send one), an id that is not a
  UUID, an epoch that is not a whole number.
  """
  @spec key(map()) :: {:ok, key()} | :none
  def key(assignment) do
    branch = get_in(assignment, ["git", "branch"])
    warm = assignment["warm"]

    with true <- is_binary(branch) and Regex.match?(@ticket_branch, branch),
         %{"ticket" => ticket, "epoch" => epoch} when is_binary(ticket) and is_integer(epoch) <-
           warm,
         true <- Regex.match?(@uuid, ticket) do
      {:ok, %{ticket: String.downcase(ticket), epoch: epoch}}
    else
      _other -> :none
    end
  end

  @doc "The exit statuses the assignment's command keeps its build for; anything malformed keeps none."
  @spec statuses(map()) :: [0..255]
  def statuses(assignment) do
    case get_in(assignment, ["spec", "command", "keep_build"]) do
      [_ | _] = list -> if Enum.all?(list, &(is_integer(&1) and &1 in 0..255)), do: list, else: []
      _other -> []
    end
  end

  @doc "Whether the command starts from the copy: unless its definition turns it off."
  @spec warm_start?(map()) :: boolean()
  def warm_start?(assignment),
    do: get_in(assignment, ["spec", "command", "warm_start"]) != false

  @doc "Where a ticket's copy lives."
  @spec path(String.t(), key()) :: String.t()
  def path(root, %{ticket: ticket}), do: Path.join([root, "volumes", "command", ticket])

  @doc "Where the marker beside it is."
  @spec marker_path(String.t(), key()) :: String.t()
  def marker_path(root, key), do: path(root, key) <> ".json"

  @doc """
  The marker of the copy this ticket's next command would start from, or `nil`: no copy, no marker,
  an unreadable one, or one kept under another epoch.
  """
  @spec marker(String.t(), key()) :: map() | nil
  def marker(root, key) do
    epoch = key.epoch

    with {:ok, text} <- File.read(marker_path(root, key)),
         {:ok, %{"epoch" => ^epoch} = marker} <- Jason.decode(text),
         # A marker whose copy is gone reads as no copy here. Without this, `take/3`'s snapshot of the
         # missing directory fails instead and the command logs `copy.unused`: the same start with
         # a different log line, and no test asserts which.
         true <- File.dir?(path(root, key)) do
      marker
    else
      _other -> nil
    end
  end

  @doc """
  Snapshots the ticket's copy to `dest`, under the lock. `{:ok, marker}` when there is one to use,
  `:none` when there is not (not an error: the first command of a ticket has none), `{:error, why}`
  when the snapshot failed.
  """
  @spec take(String.t(), key(), String.t()) :: {:ok, map()} | :none | {:error, term()}
  def take(root, key, dest) do
    locked(key, fn -> snapshot_copy(root, key, dest, marker(root, key)) end)
  end

  defp snapshot_copy(_root, _key, _dest, nil), do: :none

  defp snapshot_copy(root, key, dest, marker) do
    with :ok <- Volume.impl().snapshot(path(root, key), dest), do: {:ok, marker}
  end

  @doc """
  Makes `worktree` the ticket's copy, replacing the one there, under the lock; `{:ok, bytes,
  folders}` or `{:error, why}`. The old copy and its marker are untouched when the first step fails,
  which is the one that fails on a machine that cannot snapshot.

  `ignored` is what git ignores in the tree (`Checkout.ignored/2`), listed before the tree was
  handed back: with it the tree is sized by one walk, outside the lock, that also says how big each
  ignored folder is (`Disk.sizes/3`), and `folders` is `ForgeCore.WarmBuild.folders/1`'s shape.
  Without it (`nil`: the listing failed) `folders` is nil and the size is the whole tree's.
  """
  @spec keep(String.t(), key(), String.t(), map(), [{String.t(), :dir | :file}] | nil) ::
          {:ok, non_neg_integer(), map() | nil} | {:error, term()}
  def keep(root, key, worktree, facts, ignored \\ nil) do
    # **Sized before the lock is taken**, from the tree the copy is about to be snapshotted from: a
    # walk of a large `target/` takes minutes, and every `open/3` waits for the same lock, so sizing
    # inside it left a person looking at the old copy with an *Asking…* that never answered. The
    # copy is the tree, byte for byte, so the figures are the same ones.
    sizer = Application.get_env(:forge_worker, :copy_sizer, &sized/2)
    sizes = sizer.(worktree, ignored)
    locked(key, fn -> replace(root, key, worktree, facts, sizes) end)
  end

  defp replace(root, key, worktree, facts, {size, folders}) do
    volume = Volume.impl()
    copy = path(root, key)
    marker = marker_path(root, key)
    sibling = copy <> ".keeping." <> Base.url_encode64(:crypto.strong_rand_bytes(6))

    with :ok <- not_superseded(marker, key),
         :ok <- volume.snapshot(worktree, sibling),
         # The marker goes before the old copy so that a crash between the two leaves no copy and
         # never a marker over another tree; no test stages a crash between steps, so the order
         # is not covered. Nor is the `touch` below, which no test asserts.
         old = marked_job(marker),
         :ok <- remove(marker),
         :ok <- retire(root, key, copy, old),
         :ok <- File.rename(sibling, copy),
         :ok <- write_marker(marker, Map.put(facts, "epoch", key.epoch)) do
      File.touch(copy)
      {:ok, size, folders}
    else
      {:error, reason} ->
        volume.delete(sibling)
        {:error, reason}
    end
  end

  defp sized(copy, nil), do: {Disk.size(copy), nil}

  defp sized(copy, ignored) do
    case Disk.sizes(copy, ignored) do
      {:ok, total, folders} -> {total, folders}
      :error -> {Disk.size(copy), nil}
    end
  end

  # The job that kept the copy the marker describes: the name its hold and its moved-aside copy
  # go by.
  defp marked_job(marker) do
    with {:ok, text} <- File.read(marker),
         {:ok, %{"job_id" => job}} when is_binary(job) <- Jason.decode(text) do
      job
    else
      _no_marker -> nil
    end
  end

  # A copy someone is looking at is moved aside and not deleted: the keep that replaces it is not
  # the reader's to wait for, and the reader is not to lose what they opened. Anything that stops
  # the move is the old way, the deletion, which is a colder world for the reader and never a
  # failed keep.
  defp retire(root, key, copy, old) do
    if is_binary(old) and uuid?(old) and File.dir?(copy) and held?(root, key.ticket, old) do
      aside = held_path(root, key.ticket, old)
      File.mkdir_p(Path.dirname(aside))

      case File.rename(copy, aside) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("could not move held copy #{copy} aside: #{inspect(reason)}")
          Volume.impl().delete(copy)
      end
    else
      Volume.impl().delete(copy)
    end
  end

  # A command assigned before a Clear can finish after one that was assigned after it, and its
  # epoch-0 tree would replace the newer copy, which the platform still names: the next command would
  # wait for a machine whose copy it cannot use. The copy of a later epoch stays.
  defp not_superseded(marker, key) do
    with {:ok, text} <- File.read(marker),
         {:ok, %{"epoch" => epoch}} when is_integer(epoch) and epoch > key.epoch <-
           Jason.decode(text) do
      {:error, :superseded}
    else
      _no_newer_copy -> :ok
    end
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A temporary file and a rename, so a reader sees the whole marker or none.
  defp write_marker(marker, facts) do
    temporary = marker <> ".tmp"

    with :ok <- File.write(temporary, Jason.encode!(facts)), do: File.rename(temporary, marker)
  end

  # -- a copy someone is looking at ---------------------------------------------------------------

  @doc "Where a held copy that a keep replaced is moved to."
  @spec held_path(String.t(), String.t(), String.t()) :: String.t()
  def held_path(root, ticket, job), do: Path.join([root, "volumes", "held", ticket <> "." <> job])

  @doc "The file whose mtime is the last action on a copy."
  @spec hold_path(String.t(), String.t(), String.t()) :: String.t()
  def hold_path(root, ticket, job), do: Path.join([root, "volumes", "hold", ticket <> "." <> job])

  defp hold_ms, do: Application.get_env(:forge_worker, :hold_ms, ForgeCore.Explore.hold_ms())

  @doc """
  Whether the copy the job `job` kept for `ticket` is held: someone took an action on it less than
  ten minutes ago (`:hold_ms`). Not a copy that was never opened.
  """
  @spec held?(String.t(), String.t(), String.t()) :: boolean()
  def held?(root, ticket, job) do
    cutoff = System.os_time(:second) - div(hold_ms(), 1000)

    match?(
      {:ok, %File.Stat{mtime: mtime}} when mtime >= cutoff,
      File.stat(hold_path(root, ticket, job), time: :posix)
    )
  end

  @doc """
  The directory of the copy `job` kept for `ticket` — the ticket's current copy, or one a keep moved
  aside — and the hold on it taken or renewed, in one step under the ticket's lock. `:error` when
  the machine has no such copy: the marker names another job, or the directory is gone.

  **Both ids are matched as UUIDs before either becomes a path**, and the copy found is the
  ticket's by construction: `ticket` is the directory's name. A copy another epoch left (a cleared
  one) is found too; it is looked at and never used.
  """
  @spec open(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def open(root, ticket, job) do
    if uuid?(ticket) and uuid?(job),
      do: open_held(root, String.downcase(ticket), String.downcase(job)),
      else: :error
  end

  defp open_held(root, ticket, job) do
    locked(%{ticket: ticket}, fn ->
      with {:ok, dir} <- find(root, ticket, job) do
        touch_hold(root, ticket, job)
        {:ok, dir}
      end
    end)
  end

  defp find(root, ticket, job) do
    current = path(root, %{ticket: ticket})
    aside = held_path(root, ticket, job)

    cond do
      marked_job(current <> ".json") == job and File.dir?(current) -> {:ok, current}
      File.dir?(aside) -> {:ok, aside}
      true -> :error
    end
  end

  @doc """
  Says someone took an action on the copy now: a download still running does this every minute, so
  a 60 GB download that outlasts ten minutes is not cut off. Does not take the ticket's lock, which
  a keep holds while it sizes a copy.
  """
  @spec touch_hold(String.t(), String.t(), String.t()) :: :ok
  def touch_hold(root, ticket, job) do
    hold = hold_path(root, ticket, job)
    File.mkdir_p(Path.dirname(hold))

    case File.touch(hold) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not hold #{hold}: #{inspect(reason)}")
    end
  end

  @doc """
  Removes the copies a keep moved aside whose hold has lapsed, and the holds that have, and returns
  the bytes freed. Every minute (`ForgeWorker.Explore.Holds`) and at each end-of-job sweep.
  """
  @spec release_holds(String.t()) :: non_neg_integer()
  def release_holds(root) do
    freed =
      [root, "volumes", "held", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&release(root, &1))
      |> Enum.sum()

    [root, "volumes", "hold", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(&drop_lapsed_hold/1)

    freed
  end

  defp release(root, aside) do
    with [ticket, job] <- aside |> Path.basename() |> String.split(".", parts: 2),
         true <- uuid?(ticket) and uuid?(job) do
      # Looked at again under the lock: an explore may have renewed the hold since the listing.
      locked(%{ticket: ticket}, fn -> release_unless_held(root, aside, ticket, job) end)
    else
      _not_one_of_ours -> 0
    end
  end

  defp release_unless_held(root, aside, ticket, job),
    do: if(held?(root, ticket, job), do: 0, else: delete_aside(root, aside, ticket, job))

  defp delete_aside(root, aside, ticket, job) do
    size = Disk.size(aside)

    case Volume.impl().delete(aside) do
      :ok ->
        File.rm(hold_path(root, ticket, job))
        Logger.info("released held command copy #{Path.basename(aside)}")
        size

      {:error, reason} ->
        Log.line(
          "hold.unreleased",
          :warning,
          "could not remove the held command copy #{Path.basename(aside)}, so it stays and is tried " <>
            "again: #{inspect(reason)}"
        )

        0
    end
  end

  # A lapsed hold is only a file: the copy it was for has been released above, or is current and
  # held by no one. One whose copy could not be deleted is released again by the next call, which
  # finds no hold for it.
  defp drop_lapsed_hold(hold) do
    cutoff = System.os_time(:second) - div(hold_ms(), 1000)

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(hold, time: :posix),
         true <- mtime < cutoff do
      File.rm(hold)
    else
      _kept -> :ok
    end
  end

  @doc """
  Says the ticket ran a command here, so the sweep counts two days from now: the copy's mtime. A
  snapshot carries the mtime of the tree it came from, which says when its root last changed and
  not when this ticket last ran.
  """
  @spec touch(String.t(), key()) :: :ok
  def touch(root, key) do
    locked(key, fn ->
      copy = path(root, key)
      if File.dir?(copy), do: File.touch(copy)
      :ok
    end)
  end

  @doc """
  Removes copies (and their markers) whose root has not been touched for `older_than_ms`, and
  returns the bytes freed, for the disk report. A keep in flight is a sibling under the same ticket's
  lock, which a sweep takes before it deletes anything, and which it checks again once it has it.
  """
  @spec sweep(String.t(), non_neg_integer()) :: non_neg_integer()
  def sweep(root, older_than_ms) do
    cutoff = System.os_time(:second) - div(older_than_ms, 1000)

    [root, "volumes", "command", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&remove_if_stale(root, &1, cutoff))
    |> Enum.sum()
  end

  defp remove_if_stale(root, path, cutoff) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- mtime < cutoff do
      [ticket | _rest] = path |> Path.basename() |> String.split(".")

      # Looked at again under the lock: a keep may have replaced the copy between the stat above
      # and the lock, and a fresh copy is not this sweep's to free.
      free = fn -> free_if_stale(root, path, cutoff) end

      # The lock and the re-check in `free/0` guard a race with a keep that replaces this copy between
      # the stat above and the delete. No test holds the ticket's lock around a sweep, so neither
      # is covered.
      under_lock(ticket, free)
    else
      _fresh -> 0
    end
  end

  defp under_lock(ticket, fun) do
    if uuid?(ticket), do: locked(%{ticket: ticket}, fun), else: fun.()
  end

  defp uuid?(id), do: is_binary(id) and Regex.match?(@uuid, id)

  # **A held copy is not stale**, whatever its age: someone is looking at it, and the sweep that
  # takes it is the one that would cut a download off.
  defp free_if_stale(root, path, cutoff),
    do: if(stale?(path, cutoff) and not held_copy?(root, path), do: free(path), else: 0)

  defp held_copy?(root, path) do
    [ticket | _rest] = path |> Path.basename() |> String.split(".")
    job = marked_job(path <> ".json")

    is_binary(job) and uuid?(ticket) and uuid?(job) and held?(root, ticket, job)
  end

  defp stale?(path, cutoff) do
    match?({:ok, %File.Stat{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix))
  end

  defp free(path) do
    size = Disk.size(path)

    # The marker first: a copy without one is already no copy.
    File.rm(path <> ".json")

    case Volume.impl().delete(path) do
      :ok ->
        Logger.info("swept command copy #{Path.basename(path)}")
        size

      {:error, reason} ->
        Logger.warning("could not sweep #{path}: #{inspect(reason)}")
        0
    end
  end

  # `:global.trans/4`'s id is `{resource, requester}`; the requester is the caller so two keeps of
  # one ticket in one BEAM contend and a nested call by the same process would not deadlock.
  defp locked(%{ticket: ticket}, fun) do
    case :global.trans({{__MODULE__, ticket}, self()}, fun, [node()], :infinity) do
      :aborted -> {:error, :lock}
      result -> result
    end
  end

  @doc "Logs why a copy was not used, as a warning: a colder start, never a failed command."
  @spec unused(map(), term()) :: :ok
  def unused(assignment, reason) do
    Log.line(
      "copy.unused",
      :warning,
      "could not start from the ticket's warm build, so it starts colder: #{inspect(reason)}",
      job_id: assignment["job_id"]
    )
  end

  @doc "Logs why a build was not kept."
  @spec unkept(map(), term()) :: :ok
  def unkept(assignment, reason) do
    Log.line(
      "copy.unkept",
      :warning,
      "could not keep the build as the ticket's warm build, so the next command starts colder: " <>
        inspect(reason),
      job_id: assignment["job_id"]
    )
  end
end
