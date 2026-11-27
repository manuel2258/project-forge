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

  describe "sizes/3" do
    defp kb(path, kilobytes), do: File.write!(path, :binary.copy("x", kilobytes * 1024))

    setup %{base: base} do
      copy = Path.join(base, "copy")
      File.mkdir_p!(Path.join(copy, "target/debug"))
      File.mkdir_p!(Path.join(copy, "sub/target"))
      File.mkdir_p!(Path.join(copy, "src"))
      kb(Path.join(copy, "target/debug/big"), 400)
      kb(Path.join(copy, "sub/target/small"), 40)
      kb(Path.join(copy, "src/m.o"), 8)
      kb(Path.join(copy, "src/main.rs"), 16)
      %{copy: copy}
    end

    test "sizes each ignored folder, the loose files and the rest in one walk that adds up",
         %{copy: copy} do
      entries = [{"target", :dir}, {"sub/target", :dir}, {"src/m.o", :file}]

      assert {:ok, total, folders} = Disk.sizes(copy, entries)

      assert [%{"path" => "target", "bytes" => big}, %{"path" => "sub/target", "bytes" => small}] =
               folders["folders"]

      assert big >= 400 * 1024 and big < 420 * 1024
      assert small >= 40 * 1024 and small < 60 * 1024
      assert %{"count" => 1, "bytes" => loose} = folders["loose"]
      assert loose >= 8 * 1024
      assert folders["more"] == %{"count" => 0, "bytes" => 0}

      # The whole design rests on this: du counts each inode once across its arguments, so the
      # entries and `.` add up to the total, and the rest is not the folders counted twice.
      assert total == big + small + loose + folders["rest"]
      assert folders["rest"] >= 16 * 1024
      assert folders["rest"] < big
      assert total == Disk.size(copy)
    end

    test "keeps the fifty largest folders and totals the others", %{copy: copy} do
      for n <- 1..52, do: File.mkdir_p!(Path.join(copy, "d#{n}"))
      # Spaced further apart than a disk block, which du rounds to.
      for n <- 1..52, do: kb(Path.join(copy, "d#{n}/f"), n * 8)

      entries = for n <- 1..52, do: {"d#{n}", :dir}
      assert {:ok, _total, folders} = Disk.sizes(copy, entries)

      assert length(folders["folders"]) == 50
      assert folders["more"]["count"] == 2

      assert folders["folders"] == Enum.sort_by(folders["folders"], & &1["bytes"], :desc)
      assert hd(folders["folders"])["path"] == "d52"
    end

    test "a path through a link is dropped before du sees it, and what it holds is the rest",
         %{base: base, copy: copy} do
      outside = Path.join(base, "outside")
      File.mkdir_p!(Path.join(outside, "secret"))
      kb(Path.join(outside, "secret/big"), 2_000)
      File.ln_s!(outside, Path.join(copy, "link"))

      entries = [{"link/secret", :dir}, {"link", :dir}, {"../outside", :dir}, {"/etc", :dir}]
      assert {:ok, total, folders} = Disk.sizes(copy, entries)

      assert folders["folders"] == []
      assert total < 1_000 * 1024
      assert total == folders["rest"]
    end

    test "a name that is not text travels as base64", %{copy: copy} do
      name = <<"odd", 255>>
      File.mkdir_p!(Path.join(copy, name))
      kb(Path.join([copy, name, "f"]), 4)

      assert {:ok, _total, %{"folders" => [folder]}} = Disk.sizes(copy, [{name, :dir}])
      assert folder["path_base64"] == Base.encode64(name)
      refute Map.has_key?(folder, "path")
    end

    test "is an error when du cannot be run", %{copy: copy} do
      assert :error = Disk.sizes(copy, [], fn _cmd, _argv, _opts -> {"", 2} end)

      assert :error =
               Disk.sizes(copy, [], fn _cmd, _argv, _opts ->
                 raise ErlangError, original: :enoent
               end)
    end

    # A full or missing temporary directory raises `File.Error` from the list file's write, not an
    # `ErlangError`, and a sizing that raised failed the keep after its copy was in place.
    test "is an error, and not a crash, for whatever the walk raises", %{copy: copy} do
      assert :error = Disk.sizes(copy, [], fn _cmd, _argv, _opts -> raise "du is gone" end)

      assert :error =
               Disk.sizes(copy, [], fn _cmd, _argv, _opts ->
                 raise File.Error, reason: :enospc, action: "write to file", path: "/tmp/x"
               end)
    end

    test "what it returns is what core keeps", %{copy: copy} do
      assert {:ok, _total, folders} = Disk.sizes(copy, [{"target", :dir}])
      assert ForgeCore.WarmBuild.folders(folders) == folders
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
