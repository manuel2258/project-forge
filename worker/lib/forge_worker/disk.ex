defmodule ForgeWorker.Disk do
  @moduledoc """
  What fills this machine's disk, and when each cleanup rule last ran and what it freed
  (`docs/design/worker-tier.md` § Updating a permanent machine, criterion 14 of ticket 54): the
  Nix store, the ticket volumes, the seeds, the job directories, and the rest. Every worker
  reports it, managed or permanent.

  **Measured at intervals and after a cleanup, never with the five-second `stats`**: sizing the
  store walks a very large tree. One minute after the first join, then every 30 minutes
  (`:disk_report_ms`), and one minute after a cleanup that freed something.

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
      "volumes" => size_each(Path.join([root, "volumes", "ticket"]), run),
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
      after_cleanup_ms: Keyword.get(opts, :after_cleanup_ms, @after_cleanup_ms)
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
