defmodule ForgeWorker.Disk do
  @moduledoc """
  What fills this machine's disk, and when each cleanup rule last ran and what it freed
  (`docs/design/worker-tier.md` § Updating a permanent machine, criterion 14 of ticket 54): the
  Nix store, the ticket volumes, the seeds, the job directories, and the rest. Every worker
  reports it, managed or permanent.

  **Measured at intervals and after a cleanup, never with the five-second `stats`**: sizing the
  store walks a very large tree. One minute after the first join, then every 30 minutes
  (`:disk_report_ms`), and one minute after a cleanup that freed something
  (`:disk_after_cleanup_ms`).

  **A directory is sized without following a link and without leaving its filesystem** —
  `du -s -x -P -B1`. A job owns its own directory and could plant a link to somewhere large or
  private; `-P` counts the link itself, and `-x` keeps a mount (a job's archive) out of the figure.

  **A btrfs subvolume is a device of its own to `du`**, and on the image every ticket volume and
  every seed is one, so `du -x` of `volumes/ticket` stops at each and reads about nothing. The two
  directories are therefore sized one entry at a time (`size_each/2`), each entry with its own
  `-x`: the same way the sweeps size what they remove, and the filesystem is still not left.

  The records of cleanups live in `/run/forge-worker/cleanups.json` (`:cleanups_path`), which
  survives a restart of the worker and is gone after a reboot — which is what *not run since
  boot* means. **Nix's own `min-free` collection happens inside the daemon and is not seen
  here**, so the store's record is only the collections the worker ran (an update's).
  """

  use GenServer

  alias ForgeCore.WorkerUpdate
  alias ForgeWorker.{Config, Stats}

  @first_ms :timer.minutes(1)
  @every_ms :timer.minutes(30)
  @after_cleanup_ms :timer.minutes(1)

  # -- the callers' side ------------------------------------------------------------------------

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Records that cleanup `rule` (one of `ForgeCore.WorkerUpdate.rules/0`) ran just now and freed
  `freed` bytes, and schedules a measurement. Nothing when the process is not running.
  """
  @spec cleaned(String.t(), non_neg_integer(), GenServer.server()) :: :ok
  def cleaned(rule, freed, server \\ __MODULE__) do
    if alive?(server), do: GenServer.cast(server, {:cleaned, rule, freed})
    :ok
  end

  @doc "The link has joined: the first measurement is due, and the last report is sent again."
  @spec joined(GenServer.server()) :: :ok
  def joined(server \\ __MODULE__) do
    if alive?(server), do: GenServer.cast(server, :joined)
    :ok
  end

  @doc "The last report this process made, or an empty map before its first."
  @spec report(GenServer.server()) :: map()
  def report(server \\ __MODULE__), do: GenServer.call(server, :report)

  defp alive?(server), do: GenServer.whereis(server) != nil

  @doc """
  The size in bytes of everything under `path`, 0 when it is not there. **`du -s -x -P -B1`**: one
  filesystem, no link followed (`argv/1`).
  """
  @spec size(String.t(), (String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          non_neg_integer()
  def size(path, run \\ &System.cmd/3) do
    case run.("du", argv(path), stderr_to_stdout: false) do
      {out, status} when status in [0, 1] -> first_number(out)
      _failed -> 0
    end
  rescue
    _error in ErlangError -> 0
  end

  @doc """
  The sum of `size/2` over each entry directly under `path`, 0 when it is not there. For a
  directory whose entries are btrfs subvolumes, which `du -x` of the directory itself would not
  enter.
  """
  @spec size_each(String.t(), (String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          non_neg_integer()
  def size_each(path, run \\ &System.cmd/3) do
    case File.ls(path) do
      {:ok, names} -> names |> Enum.map(&size(Path.join(path, &1), run)) |> Enum.sum()
      {:error, _reason} -> 0
    end
  end

  # The same bound the platform's record applies, said once, in core.
  @max_folders ForgeCore.WarmBuild.max_folders()

  @doc """
  The size of a kept copy in one walk, and of each folder git ignores in it
  (`docs/design/worker-tier.md` § Looking into a copy, folder sizes): `{:ok, total, folders}` with
  `folders` as `ForgeCore.WarmBuild.folders/1` takes it, or `:error` when `du` could not be run.

  `entries` is `Checkout.ignored/2`'s: paths relative to `dir`, each a folder or a loose file.
  **One `du -x -P -B1 -s -0 --files0-from=<list>`**, the entries first and `.` last: GNU du counts
  each inode once across its arguments, so `.` reports what the entries did not, and the figures add
  up to the total (a test pins that, because the whole design rests on it). The list is a file in
  the worker's temporary directory, and `dir` is `du`'s working directory, so the names in it are
  relative.

  **A path that crosses a link is dropped before `du` sees it**, and what it holds is counted in
  `rest`: each component is `lstat`ed in the copy, every one before the last must be a real
  directory, and a folder's last must be one too — `du` is told not to follow a link
  (`-P`), but a trailing slash on a link would, which is why it is never given one. The folders are
  the #{@max_folders} largest, largest first; the rest are `more`, and the loose files one total
  (`loose`), so a project that ignores files one by one cannot make the record huge.
  """
  @spec sizes(String.t(), [{String.t(), :dir | :file}], (String.t(), [String.t()], keyword() ->
                                                           {String.t(), integer()})) ::
          {:ok, non_neg_integer(), map()} | :error
  def sizes(dir, entries, run \\ &System.cmd/3) do
    kept = entries |> Enum.filter(fn {path, kind} -> inside?(dir, path, kind) end) |> Enum.uniq()

    list =
      Path.join(System.tmp_dir!(), "forge-du-" <> Base.url_encode64(:crypto.strong_rand_bytes(6)))

    File.write!(list, Enum.map(kept ++ [{".", :dir}], fn {path, _kind} -> [path, 0] end))

    try do
      case run.("du", ["-s", "-x", "-P", "-B1", "-0", "--files0-from=" <> list],
             cd: dir,
             stderr_to_stdout: false
           ) do
        {out, status} when status in [0, 1] ->
          {total, folders} = measured(out, kept)
          {:ok, total, folders}

        _failed ->
          :error
      end
    after
      File.rm(list)
    end
  rescue
    # Anything: a temporary directory that is full or gone raises `File.Error`, and a sizing that
    # fails is no sizing (the keep goes on with the copy's total and no folders), never a command
    # that failed after its copy was in place.
    _error -> :error
  end

  # `{:ok, total, folders}` from du's records: `<bytes>\t<name>` each ended by a NUL. By name and
  # not by position, because an argument inside an earlier one is counted there and left out.
  defp measured(out, kept) do
    bytes =
      for record <- String.split(out, <<0>>, trim: true), into: %{} do
        [size, name] = String.split(record, "\t", parts: 2)
        {name, first_number(size)}
      end

    sized = for {path, kind} <- kept, do: {path, kind, Map.get(bytes, path, 0)}
    {folders, loose} = Enum.split_with(sized, fn {_path, kind, _bytes} -> kind == :dir end)
    {shown, more} = folders |> Enum.sort_by(&elem(&1, 2), :desc) |> Enum.split(@max_folders)

    total = bytes |> Map.values() |> Enum.sum()

    {total,
     %{
       "folders" => Enum.map(shown, fn {path, _kind, size} -> named(path, size) end),
       "more" => counted(more),
       "loose" => counted(loose),
       "rest" => Map.get(bytes, ".", 0)
     }}
  end

  defp counted(entries),
    do: %{"count" => length(entries), "bytes" => entries |> Enum.map(&elem(&1, 2)) |> Enum.sum()}

  defp named(path, size) do
    if String.valid?(path),
      do: %{"path" => path, "bytes" => size},
      else: %{"path_base64" => Base.encode64(path), "bytes" => size}
  end

  # Every component before the last is a directory and not a link, and the last exists: the same
  # resolution the kernel then does for `du`, and not a string check in front of it. Nothing writes
  # into a kept copy, so nothing changes between this and the walk (`CLAUDE.md` § Rules).
  defp inside?(dir, path, kind) do
    parts = Path.split(path)

    path != "" and Path.type(path) == :relative and ".." not in parts and "." not in parts and
      not String.contains?(path, <<0>>) and walk(dir, parts, kind)
  end

  defp walk(_dir, [], _kind), do: true

  # A folder's last component is a real directory too, and a file's is anything that is there.
  defp walk(dir, [last], kind) do
    case {File.lstat(Path.join(dir, last)), kind} do
      {{:ok, %File.Stat{type: :directory}}, _kind} -> true
      {{:ok, _stat}, :file} -> true
      _missing_or_not_a_folder -> false
    end
  end

  defp walk(dir, [part | rest], kind) do
    next = Path.join(dir, part)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :directory}} -> walk(next, rest, kind)
      _link_or_missing -> false
    end
  end

  @doc "What `size/2` runs `du` with. A link is not followed, and no mount is entered."
  @spec argv(String.t()) :: [String.t()]
  def argv(path), do: ["-s", "-x", "-P", "-B1", "--", path]

  defp first_number(out) do
    case Integer.parse(out) do
      {bytes, _rest} -> bytes
      :error -> 0
    end
  end

  @doc """
  A report for the machine: each kind's size, and `cleanups` as recorded. `rest` is what the
  filesystem holds beyond the four, floored at 0 — `du` and `df` count a little differently, and
  a negative figure would be a lie that an owner reads.
  """
  @spec measure(String.t(), map(), keyword()) :: map()
  def measure(root, cleanups, opts \\ []) do
    run = Keyword.get(opts, :run, &System.cmd/3)
    store = Keyword.get(opts, :store, Config.nix_store())

    kinds = %{
      "nix_store" => size(store, run),
      "volumes" =>
        size_each(Path.join([root, "volumes", "ticket"]), run) +
          size_each(Path.join([root, "volumes", "command"]), run) +
          size_each(Path.join([root, "volumes", "held"]), run),
      "seeds" => size_each(Path.join([root, "volumes", "seed"]), run),
      "jobs" => size(Path.join(root, "jobs"), run)
    }

    used = Map.get(Stats.disk(root), "disk_used", 0)
    rest = max(used - Enum.sum(Map.values(kinds)), 0)

    WorkerUpdate.normalise_disk(%{
      "at" => System.os_time(:millisecond),
      "kinds" => Map.put(kinds, "rest", rest),
      "cleanups" => cleanups
    })
  end

  # -- the process ------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :cleanups_path, Config.cleanups_path())

    state = %{
      path: path,
      cleanups: read(path),
      report: %{},
      timer: nil,
      measuring: false,
      first: false,
      link: Keyword.get(opts, :link, ForgeWorker.Link),
      measure: Keyword.get(opts, :measure, &measure/3),
      root: Keyword.get(opts, :root, Config.root()),
      every_ms: Keyword.get(opts, :every_ms, setting(:disk_report_ms, @every_ms)),
      first_ms: Keyword.get(opts, :first_ms, setting(:disk_first_ms, @first_ms)),
      after_cleanup_ms:
        Keyword.get(opts, :after_cleanup_ms, setting(:disk_after_cleanup_ms, @after_cleanup_ms))
    }

    {:ok, state}
  end

  defp setting(key, default), do: Application.get_env(:forge_worker, key, default)

  @impl true
  def handle_call(:report, _from, state), do: {:reply, state.report, state}

  @impl true
  def handle_cast(:joined, %{first: false} = state),
    do: {:noreply, schedule(%{state | first: true}, state.first_ms)}

  def handle_cast(:joined, state) do
    send_report(state)
    {:noreply, state}
  end

  def handle_cast({:cleaned, rule, freed}, state) do
    if rule in WorkerUpdate.rules() and is_integer(freed) and freed >= 0 do
      record = %{"at" => System.os_time(:millisecond), "freed" => freed}
      cleanups = Map.put(state.cleanups, rule, record)
      write(state.path, cleanups)
      state = %{state | cleanups: cleanups}

      # A sweep that removed nothing ran, and says so, and has changed nothing worth walking the
      # store again for: it runs at the end of every job.
      if freed > 0,
        do: {:noreply, schedule(state, state.after_cleanup_ms)},
        else: {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:measure, %{measuring: true} = state), do: {:noreply, state}

  def handle_info(:measure, state) do
    me = self()
    {root, cleanups, measure} = {state.root, state.cleanups, state.measure}

    Task.Supervisor.start_child(ForgeWorker.TaskSupervisor, fn ->
      send(me, {:measured, measure.(root, cleanups, [])})
    end)

    {:noreply, %{state | measuring: true, timer: nil}}
  end

  def handle_info({:measured, report}, state) do
    state = %{state | report: report, measuring: false}
    send_report(state)
    {:noreply, schedule(state, state.every_ms)}
  end

  # A measurement that was in flight when a cleanup asked for another: replaced, not stacked.
  defp schedule(%{timer: timer} = state, ms) do
    if timer, do: Process.cancel_timer(timer)
    %{state | timer: Process.send_after(self(), :measure, ms)}
  end

  defp send_report(%{report: report}) when map_size(report) == 0, do: :ok

  defp send_report(state) do
    case Process.whereis(state.link) do
      nil -> :ok
      link -> send(link, {:disk_report, state.report})
    end

    :ok
  end

  defp read(path) do
    with {:ok, text} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(text) do
      WorkerUpdate.normalise_disk(%{"kinds" => %{"rest" => 0}, "cleanups" => map})
      |> Map.get("cleanups", %{})
    else
      _unreadable -> %{}
    end
  end

  defp write(path, cleanups) do
    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(cleanups))
  end
end
