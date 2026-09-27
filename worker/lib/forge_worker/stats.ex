defmodule ForgeWorker.Stats do
  @moduledoc """
  How full this machine is right now: CPU, memory, and the disk the job root lives on. The link
  pushes it as `stats` every few seconds for the workers page (`docs/design/worker-channel.md`
  § Live figures); the platform keeps the latest and writes it nowhere.

  **What cannot be read is left out, never reported as zero.** Zero draws an empty bar, which
  says *nothing is being used* — the opposite of *nothing could be read*. Every reader here
  returns only the keys it could fill.

  The parsing is pure and takes the text a source would give, so it is tested against fixture
  text rather than against whichever machine the suite happens to run on; `sample/2` is the only
  part that touches `/proc` or runs anything.
  """

  @typedoc "Cumulative busy and total jiffies from `/proc/stat`, or nil when unreadable."
  @type cpu_sample :: {busy :: non_neg_integer(), total :: non_neg_integer()} | nil

  @doc """
  Reads everything, returning the figures and the CPU sample to difference the next one against.

  The first call has no previous sample, so it has no `"cpu"`: a percentage is a share of the
  time between two readings, and one reading is not an interval.
  """
  @spec sample(String.t(), cpu_sample()) :: {map(), cpu_sample()}
  def sample(root, previous) do
    cpu = "/proc/stat" |> read() |> parse_cpu()

    stats =
      %{}
      |> put("cpu", cpu_percent(previous, cpu))
      |> Map.merge("/proc/meminfo" |> read() |> parse_meminfo())
      |> Map.merge(root |> df() |> parse_df())

    {stats, cpu}
  end

  @doc """
  The busy and total jiffies of the machine, from the aggregate `cpu` line of `/proc/stat`.

  **Idle is `idle` plus `iowait`**: a core waiting on a disk is not doing anything a job asked
  for. **Total is the first eight fields and not all ten**: the kernel already counts `guest` and
  `guest_nice` inside `user` and `nice`, so adding them would count a virtual machine's time
  twice. Older kernels print fewer fields; the ones missing are zero.
  """
  @spec parse_cpu(String.t() | nil) :: cpu_sample()
  def parse_cpu(nil), do: nil

  def parse_cpu(text) do
    with [_all, fields] <- Regex.run(~r/^cpu\s+([\d ]+)$/m, text),
         numbers when length(numbers) >= 4 <- fields |> String.split() |> Enum.map(&to_int/1) do
      [user, nice, system, idle, iowait, irq, softirq, steal] =
        numbers |> Enum.take(8) |> pad(8)

      waiting = idle + iowait
      total = user + nice + system + waiting + irq + softirq + steal
      {total - waiting, total}
    else
      _other -> nil
    end
  end

  @doc """
  The share of the time between two samples that the machine was busy, as a percentage of the
  whole machine, rounded to one decimal.

  Nil with no earlier sample, with no current one, or with no time between them — a counter that
  did not move, or one that went backwards across a reboot, is not an interval.
  """
  @spec cpu_percent(cpu_sample(), cpu_sample()) :: float() | nil
  def cpu_percent({busy_was, total_was}, {busy, total}) when total > total_was do
    Float.round(max(busy - busy_was, 0) * 100 / (total - total_was), 1)
  end

  def cpu_percent(_previous, _current), do: nil

  @doc """
  Memory used and total, from `/proc/meminfo`.

  **Used is `MemTotal - MemAvailable`**: what the kernel says it could not give a new process
  without swapping. `MemFree` would count the page cache as used, and a machine that has built
  anything has a page cache the size of whatever is left.
  """
  @spec parse_meminfo(String.t() | nil) :: map()
  def parse_meminfo(nil), do: %{}

  def parse_meminfo(text) do
    total = kib(text, "MemTotal")
    available = kib(text, "MemAvailable")

    %{}
    |> put("memory_total", total)
    |> put("memory_used", total && available && max(total - available, 0))
  end

  defp kib(text, field) do
    case Regex.run(~r/^#{field}:\s+(\d+) kB$/m, text) do
      [_all, value] -> to_int(value) * 1024
      nil -> nil
    end
  end

  @doc """
  Disk used and total for the filesystem holding the job root, from `df -P -B1` output.

  **Total is `Used + Available`, not the filesystem's size.** Blocks reserved for root are in the
  size and are not space a job can write, so a disk is full when used reaches that sum — which is
  how `df`'s own capacity column counts, and so the percentage drawn from these two agrees with
  the one an operator would see on the machine.

  `-P` keeps each filesystem on one line, and the four numbers are read from the end of it
  because a device name may contain spaces while the numbers never do.
  """
  @spec parse_df(String.t() | nil) :: map()
  def parse_df(nil), do: %{}

  def parse_df(text) do
    case Regex.run(~r/^\S.*?\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+\S.*$/m, text) do
      [_line, _size, used, available] ->
        used = to_int(used)
        %{"disk_used" => used, "disk_total" => used + to_int(available)}

      nil ->
        %{}
    end
  end

  # **`df`, because OTP has no `statfs`.** `:disksup` is the one thing in OTP that knows about
  # filesystems, and it gives a percentage per mount on a polling interval measured in minutes, no
  # byte counts, and needs `os_mon` started. `df -P -B1` is POSIX output in bytes from coreutils,
  # which the worker image already puts on the service's path.
  #
  # Nil on anything but success, so a root that does not exist yet or a `df` that is missing is a
  # machine with no disk figures rather than a crash of the link that samples it.
  #
  # **Passing the output on regardless of the status is an equivalent mutant**, and must not have
  # a test written for it: with one path, `df` either succeeds or prints only an error message,
  # which `parse_df/1` finds no filesystem line in. The status is read so that the meaning does
  # not rest on the wording of an error.
  defp df(root) do
    case System.cmd("df", ["-P", "-B1", "--", root], stderr_to_stdout: true) do
      {out, 0} -> out
      {_out, _status} -> nil
    end
  rescue
    _error in ErlangError -> nil
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _reason} -> nil
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp pad(list, n), do: list ++ List.duplicate(0, n - length(list))

  defp to_int(value), do: String.to_integer(value)
end
