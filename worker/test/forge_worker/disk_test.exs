defmodule ForgeWorker.DiskTest do
  @moduledoc """
  What fills the disk and what each cleanup freed (`docs/design/worker-tier.md` § The disk
  report): sized without following a link or leaving the filesystem, measured on a schedule and
  after a cleanup, the cleanups remembered across a restart of the worker.
  """

  use ExUnit.Case, async: false

  alias ForgeWorker.Disk

  setup do
    base = Path.join(System.tmp_dir!(), "disk-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, path: Path.join(base, "cleanups.json")}
  end

  describe "size/2" do
    test "asks du for one filesystem and no link followed", %{base: base} do
      test = self()

      run = fn "du", argv, _opts ->
        send(test, {:du, argv})
        {"4096\t#{base}\n", 0}
      end

      assert Disk.size(base, run) == 4096

      # `-x` keeps a mount out of the figure and `-P` counts a link as the link: a job owns its own
      # directory and could plant one to somewhere large or private.
      assert_received {:du, ["-s", "-x", "-P", "-B1", "--", ^base]}
    end

    test "does not count what a link points at", %{base: base} do
      big = Path.join(base, "big")
      File.write!(big, :binary.copy("x", 4_000_000))
      planted = Path.join(base, "job")
      File.mkdir_p!(planted)
      File.ln_s!(base, Path.join(planted, "everything"))
      File.ln_s!(big, Path.join(planted, "file"))

      assert Disk.size(planted) < 100_000
      assert Disk.size(big) >= 4_000_000
    end

    test "counts what it could read when some of a tree was unreadable, which du answers with 1" do
      assert Disk.size("/tmp", fn _cmd, _argv, _opts -> {"500\t/tmp\n", 1} end) == 500
      assert Disk.size("/tmp", fn _cmd, _argv, _opts -> {"500\t/tmp\n", 2} end) == 0
    end

    test "is nothing for a path that is not there, or a du that is not" do
      assert Disk.size("/nonexistent/forge-disk-test") == 0

      assert Disk.size("/tmp", fn _cmd, _argv, _opts -> raise ErlangError, original: :enoent end) ==
               0

      assert Disk.size("/tmp", fn _cmd, _argv, _opts -> {"", 127} end) == 0
    end
  end

  describe "measure/3" do
    test "names each kind, and the rest is what the four leave", %{base: base} do
      File.mkdir_p!(Path.join(base, "volumes/ticket/1"))
      File.mkdir_p!(Path.join(base, "volumes/ticket/2"))
      File.mkdir_p!(Path.join(base, "volumes/seed/p"))

      run = fn "du", argv, _opts ->
        {"#{if List.last(argv) =~ "volumes/ticket", do: 15, else: 10}\t.\n", 0}
      end

      report = Disk.measure(base, %{}, run: run, store: "/nix/store")

      assert %{"kinds" => %{"nix_store" => 10, "volumes" => 30, "seeds" => 10, "jobs" => 10}} =
               report

      assert report["kinds"]["rest"] >= 0
      assert is_integer(report["at"])
    end

    test "sizes the ticket volumes and the seeds one entry at a time, since each is a subvolume",
         %{base: base} do
      File.mkdir_p!(Path.join(base, "volumes/ticket/54"))
      File.mkdir_p!(Path.join(base, "volumes/seed/proj"))

      # `du -x` of a directory stops at a subvolume, which is a device of its own: the directory
      # reads nothing, the subvolume inside it reads what it holds. Asked of the directory itself
      # this stand-in answers 0, as the real thing does.
      run = fn "du", argv, _opts ->
        path = List.last(argv)
        {"#{if path =~ ~r{/(ticket|seed)/[^/]+$}, do: 20_971_520, else: 0}\t.\n", 0}
      end

      assert %{"kinds" => %{"volumes" => 20_971_520, "seeds" => 20_971_520}} =
               Disk.measure(base, %{}, run: run)
    end

    # A ticket's command copy is a volume like the ticket volume it is swept with, and the report
    # has one line for both (`docs/design/worker-tier.md` § The command copy).
    test "counts the command copies under volumes, with the ticket volumes", %{base: base} do
      File.mkdir_p!(Path.join(base, "volumes/ticket/1"))
      File.mkdir_p!(Path.join(base, "volumes/command/5f0a6d1e-0000-4000-8000-000000000001"))

      run = fn "du", argv, _opts ->
        path = List.last(argv)

        {"#{cond do
           path =~ "volumes/ticket/" -> 100
           path =~ "volumes/command/" -> 7
           true -> 0
         end}\t.\n", 0}
      end

      assert %{"kinds" => %{"volumes" => 107}} = Disk.measure(base, %{}, run: run)
    end

    test "never reports a negative rest, however the two tools count", %{base: base} do
      huge = fn "du", _argv, _opts -> {"#{1_000_000_000_000_000}\t.\n", 0} end
      assert %{"kinds" => %{"rest" => 0}} = Disk.measure(base, %{}, run: huge)
    end
  end

  defp forward(test) do
    receive do
      message -> send(test, message)
    end

    forward(test)
  end

  describe "the process" do
    defp start(context, opts \\ []) do
      name = :"disk_#{System.unique_integer([:positive])}"
      link = :"disk_link_#{System.unique_integer([:positive])}"
      test = self()

      # The link, as a name that forwards to the test: a process has one name, and a test that
      # restarts the disk process needs two links.
      relay = spawn_link(fn -> forward(test) end)
      Process.register(relay, link)

      options =
        [
          name: name,
          link: link,
          cleanups_path: context.path,
          root: context.base,
          measure: fn root, cleanups, _opts ->
            %{"at" => 1, "kinds" => %{"rest" => 7}, "cleanups" => cleanups, "root" => root}
          end,
          first_ms: 20,
          every_ms: 10_000,
          after_cleanup_ms: 20
        ] ++ opts

      start_supervised!(%{id: name, start: {Disk, :start_link, [options]}})
      name
    end

    test "measures after the first join and sends it to the link", context do
      name = start(context)
      assert Disk.report(name) == %{}
      Disk.joined(name)
      assert_receive {:disk_report, %{"at" => 1, "kinds" => %{"rest" => 7}}}, 2_000
      assert %{"kinds" => _kinds} = Disk.report(name)
    end

    test "records a cleanup, measures again after it, and says so in the next report", context do
      name = start(context)
      Disk.joined(name)
      assert_receive {:disk_report, _first}, 2_000

      Disk.cleaned("volumes", 3_000, name)

      assert_receive {:disk_report,
                      %{"cleanups" => %{"volumes" => %{"freed" => 3_000, "at" => at}}}},
                     2_000

      assert is_integer(at)
    end

    test "remembers a cleanup across a restart of the worker", context do
      first = start(context)
      Disk.cleaned("jobs", 42, first)
      # A call after the cast, so the write has happened.
      _report = Disk.report(first)
      stop_supervised!(first)

      second = start(context)
      Disk.joined(second)
      assert_receive {:disk_report, %{"cleanups" => %{"jobs" => %{"freed" => 42}}}}, 2_000
    end

    test "ignores a rule it does not know and a figure that is not a size", context do
      name = start(context)
      Disk.cleaned("secrets", 1, name)
      Disk.cleaned("jobs", -1, name)
      Disk.cleaned("jobs", "lots", name)
      Disk.joined(name)
      assert_receive {:disk_report, %{"cleanups" => cleanups}}, 2_000
      assert cleanups == %{}
      refute File.exists?(context.path)
    end

    # `LinkTest` joins a link whose socket answers only what the test tells it to, and a report
    # pushed to it by the application's own disk process is a call nobody answers: it times out
    # and takes the link with it. So the one the application starts must not report within a suite.
    test "the application's own disk process measures nothing within the length of a suite" do
      state = :sys.get_state(Disk)

      for key <- [:first_ms, :every_ms, :after_cleanup_ms],
          do: assert(Map.fetch!(state, key) >= :timer.hours(1))
    end

    test "says nothing when it is not running", _context do
      assert Disk.cleaned("jobs", 1, :no_such_disk_process) == :ok
      assert Disk.joined(:no_such_disk_process) == :ok
    end
  end
end
