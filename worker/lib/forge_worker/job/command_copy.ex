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
  Makes `worktree` the ticket's copy, replacing the one there, under the lock; `{:ok, bytes}` or
  `{:error, why}`. The old copy and its marker are untouched when the first step fails, which is
  the one that fails on a machine that cannot snapshot.
  """
  @spec keep(String.t(), key(), String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def keep(root, key, worktree, facts) do
    locked(key, fn -> replace(root, key, worktree, facts) end)
  end

  defp replace(root, key, worktree, facts) do
    volume = Volume.impl()
    copy = path(root, key)
    marker = marker_path(root, key)
    sibling = copy <> ".keeping." <> Base.url_encode64(:crypto.strong_rand_bytes(6))

    with :ok <- not_superseded(marker, key),
         :ok <- volume.snapshot(worktree, sibling),
         # The marker goes before the old copy so that a crash between the two leaves no copy and
         # never a marker over another tree; no test stages a crash between steps, so the order
         # is not covered. Nor is the `touch` below, which no test asserts.
         :ok <- remove(marker),
         :ok <- volume.delete(copy),
         :ok <- File.rename(sibling, copy),
         :ok <- write_marker(marker, Map.put(facts, "epoch", key.epoch)) do
      File.touch(copy)
      {:ok, Disk.size(copy)}
    else
      {:error, reason} ->
        volume.delete(sibling)
        {:error, reason}
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
    |> Enum.map(&remove_if_stale(&1, cutoff))
    |> Enum.sum()
  end

  defp remove_if_stale(path, cutoff) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- mtime < cutoff do
      [ticket | _rest] = path |> Path.basename() |> String.split(".")

      # Looked at again under the lock: a keep may have replaced the copy between the stat above
      # and the lock, and a fresh copy is not this sweep's to free.
      free = fn -> free_if_stale(path, cutoff) end

      # The lock and the re-check in `free/0` guard a race with a keep that replaces this copy between
      # the stat above and the delete. No test holds the ticket's lock around a sweep, so neither
      # is covered.
      under_lock(ticket, free)
    else
      _fresh -> 0
    end
  end

  defp under_lock(ticket, fun) do
    if Regex.match?(@uuid, ticket), do: locked(%{ticket: ticket}, fun), else: fun.()
  end

  defp free_if_stale(path, cutoff), do: if(stale?(path, cutoff), do: free(path), else: 0)

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
