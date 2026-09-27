defmodule ForgeWorker.StatsTest do
  @moduledoc """
  How full the machine is, read from the text its sources give. Fixture text rather than the
  suite's own machine, because what these assert is arithmetic about that text, and the machine
  running the suite could make any figure plausible (`docs/design/worker-channel.md` § Live
  figures).
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Stats

  # A four-core machine's `/proc/stat`, trimmed: the aggregate line and one per core.
  @stat_before """
  cpu  1000 100 500 8000 400 50 50 0 300 0
  cpu0 250 25 125 2000 100 12 12 0 75 0
  intr 123456 0 0
  """

  # A second later. 1000 more jiffies of time passed on the aggregate line: 300 of it busy in
  # user, 100 in system, 50 waiting on I/O and 550 idle.
  @stat_after """
  cpu  1300 100 600 8550 450 50 50 0 900 0
  cpu0 325 25 150 2137 112 12 12 0 225 0
  intr 123999 0 0
  """

  describe "CPU" do
    test "is the busy share of the time between two samples" do
      before = Stats.parse_cpu(@stat_before)
      now = Stats.parse_cpu(@stat_after)

      # 400 busy of 1000: iowait is idle, and `guest` (the ninth field, which moved by 600) is
      # already inside `user` and must not be counted again.
      assert Stats.cpu_percent(before, now) == 40.0
    end

    test "reads the aggregate line, not a core's" do
      # busy = user + nice + system + irq + softirq + steal; total adds idle and iowait.
      assert Stats.parse_cpu(@stat_before) == {1700, 10_100}
    end

    test "a kernel that prints only the first four fields is read with the rest as zero" do
      assert Stats.parse_cpu("cpu  10 0 5 85\n") == {15, 100}
    end

    # Fewer than the four every kernel has since 2.5 is not a CPU line this can read.
    test "a line with fewer than four fields is unreadable" do
      assert Stats.parse_cpu("cpu  10 0 5\n") == nil
    end

    # Busy time cannot fall while total time rises; a pair of readings that says it did is read
    # as nothing busy rather than as a negative share.
    test "busy time that went backwards is not a negative share" do
      assert Stats.cpu_percent({500, 1_000}, {400, 2_000}) == 0.0
    end

    test "one sample is not an interval, and neither is a counter that did not move" do
      sample = Stats.parse_cpu(@stat_before)

      assert Stats.cpu_percent(nil, sample) == nil
      assert Stats.cpu_percent(sample, nil) == nil
      assert Stats.cpu_percent(sample, sample) == nil
    end

    # Across a reboot the counters start again from nothing.
    test "a counter that went backwards is not an interval either" do
      assert Stats.cpu_percent(Stats.parse_cpu(@stat_after), Stats.parse_cpu(@stat_before)) ==
               nil
    end

    test "text with no aggregate line is unreadable, not zero" do
      assert Stats.parse_cpu("cpu0 1 2 3 4\n") == nil
      assert Stats.parse_cpu("") == nil
      assert Stats.parse_cpu(nil) == nil
    end
  end

  describe "memory" do
    test "used is total less what the kernel could hand out, not less what is free" do
      meminfo = """
      MemTotal:       16000000 kB
      MemFree:          500000 kB
      MemAvailable:   12000000 kB
      Buffers:          100000 kB
      """

      assert Stats.parse_meminfo(meminfo) == %{
               "memory_total" => 16_000_000 * 1024,
               "memory_used" => 4_000_000 * 1024
             }
    end

    # Omitted, never zero: a zero draws an empty bar, which says nothing is used.
    test "a figure that is not there is left out" do
      assert Stats.parse_meminfo("MemTotal:       16000000 kB\n") == %{
               "memory_total" => 16_000_000 * 1024
             }

      assert Stats.parse_meminfo("MemAvailable:   12000000 kB\n") == %{}
      assert Stats.parse_meminfo(nil) == %{}
    end

    # A kernel reports available above total only in a race between the two lines; used is then
    # nothing, not a negative number of bytes.
    test "more available than there is, is none used" do
      assert Stats.parse_meminfo("MemTotal: 1000 kB\nMemAvailable: 1200 kB\n") == %{
               "memory_total" => 1_024_000,
               "memory_used" => 0
             }
    end
  end

  describe "disk" do
    test "total is what is used plus what a job could still write, as df's capacity counts" do
      df = """
      Filesystem        1-blocks        Used    Available Capacity Mounted on
      /dev/vda1     100000000000 60000000000  35000000000      64% /var/lib/forge
      """

      # 5 GB are reserved for root: in the size, and not space a job can have.
      assert Stats.parse_df(df) == %{
               "disk_used" => 60_000_000_000,
               "disk_total" => 95_000_000_000
             }
    end

    test "a device whose name has a space is still read from the end of its line" do
      df = """
      Filesystem       1-blocks  Used Available Capacity Mounted on
      my disk            1000   400       600      40% /mnt/a b
      """

      assert Stats.parse_df(df) == %{"disk_used" => 400, "disk_total" => 1000}
    end

    test "output that is not a filesystem line is unreadable" do
      assert Stats.parse_df("df: /nowhere: No such file or directory\n") == %{}
      assert Stats.parse_df(nil) == %{}
    end
  end

  describe "a sample of this machine" do
    # The one part that touches `/proc` and runs `df`. What it can assert about a machine it does
    # not know is only the shape: the first sample has no CPU, the second does, and every figure
    # is a number rather than a zero standing in for one it could not read.
    test "the first has no CPU and the second does" do
      root = System.tmp_dir!()

      {first, cpu} = Stats.sample(root, nil)
      refute Map.has_key?(first, "cpu")

      Process.sleep(50)
      {second, _cpu} = Stats.sample(root, cpu)

      assert is_float(second["cpu"])
      assert Enum.all?(Map.values(second), &is_number/1)
      assert second["memory_used"] <= second["memory_total"]
      assert second["disk_used"] <= second["disk_total"]
    end

    test "a root that does not exist has no disk figures rather than failing" do
      {stats, _cpu} = Stats.sample("/nonexistent/forge-root", nil)

      refute Map.has_key?(stats, "disk_used")
      refute Map.has_key?(stats, "disk_total")
    end
  end
end
