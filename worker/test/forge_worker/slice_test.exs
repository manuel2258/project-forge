defmodule ForgeWorker.SliceTest do
  @moduledoc """
  The unit the worker image runs jobs in, as far as a machine without systemd can check it:
  the command it builds. That the ceiling actually binds is what `measure/`'s M3 measures and
  what milestone 3's demo has to show.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Slice
  alias ForgeWorker.Slice.{Direct, Systemd}

  @job "d7cf4946-0e0d-177c-11c8-f66c8966e9f0"

  describe "the systemd slice" do
    test "asks for a ceiling that kills rather than swaps, and a share rather than a quota" do
      {:ok, context} =
        prepared(%{
          job_id: @job,
          worktree: "/var/lib/forge/worktrees/#{@job}",
          memory_max: 2_317_352_960,
          cpu_weight: 100
        })

      flags = Systemd.flags(context)

      assert "--property=MemoryMax=2317352960" in flags
      assert "--property=MemorySwapMax=0" in flags
      assert "--property=CPUWeight=100" in flags
      # A process the kernel kills for memory dies alone, rather than taking the agent with it.
      assert "--property=OOMPolicy=continue" in flags
      refute Enum.any?(flags, &String.contains?(&1, "CPUQuota"))
    end

    test "runs as the job's own user, in the job's own worktree" do
      {:ok, context} = prepared(%{job_id: @job, worktree: "/w", memory_max: nil, cpu_weight: nil})
      flags = Systemd.flags(context)

      assert "--uid=forge-job-d7cf49460e0d177c" in flags
      assert "--property=WorkingDirectory=/w" in flags
      assert "--unit=forge-job-d7cf49460e0d177c" in flags
      # A limit nobody set is not a limit of zero.
      refute Enum.any?(flags, &String.starts_with?(&1, "--property=MemoryMax"))
    end

    test "keeps the runner's stdio and waits for the process" do
      {:ok, context} = prepared(%{job_id: @job, worktree: "/w"})

      assert {"systemd-run", args} = Systemd.wrap("claude", ["-p", "--verbose"], context)
      assert "--pipe" in args
      assert "--wait" in args
      assert "--collect" in args
      # Not quiet: `Running as unit:` is what shows the unit came to exist, which is what lets a
      # bus error in its output be believed.
      refute "--quiet" in args
      assert List.last(args) == "--verbose"
      assert Enum.at(args, Enum.find_index(args, &(&1 == "--")) + 1) == "claude"
    end

    test "the unit and the user are the same short name, so a stuck one is findable" do
      assert Systemd.unit_name(@job) == Systemd.user_name(@job)
      assert Systemd.unit_name(@job) == "forge-job-d7cf49460e0d177c"
    end

    # The name carries 16 hex characters of the id, not the 8 of its first segment: at 8, two
    # concurrent jobs colliding there shared a Unix user — and `create_user/1` reads "already
    # exists" as success, so the collision was silent and one job's cleanup deleted the other's
    # user and files. Mutate `short/1` back to the first segment and this fails.
    test "distinct ids that share a first segment get distinct users" do
      a = "d7cf4946-0e0d-177c-11c8-f66c8966e9f0"
      b = "d7cf4946-aaaa-4bbb-8ccc-ddddeeeeffff"
      assert Systemd.user_name(a) != Systemd.user_name(b)
    end

    test "the user name stays within the 31-character limit useradd enforces" do
      assert byte_size(Systemd.user_name("d7cf4946-0e0d-177c-11c8-f66c8966e9f0")) <= 31
    end

    test "carries the runner's environment across, and its secrets as a file it never names" do
      {:ok, context} =
        prepared(%{
          job_id: @job,
          worktree: "/w",
          env: [{"PATH", "/run/current-system/sw/bin"}, {"HOME", "/var/lib/forge/jobs/x/home"}],
          secrets_file: "/var/lib/forge/jobs/x.worker/secrets.env"
        })

      flags = Systemd.flags(context)

      # systemd hands the unit its own default environment, not systemd-run's, so a variable
      # nobody named is a variable the harness does not get. Without PATH it cannot find `nix`.
      assert "--setenv=PATH=/run/current-system/sw/bin" in flags
      assert "--setenv=HOME=/var/lib/forge/jobs/x/home" in flags

      # A secret is not in the unit's environment at all, by value or by name: systemd shows a
      # unit's `Environment=` to every user on the machine. The unit is handed the file, which
      # systemd reads as root and gives the job's user alone a copy of.
      assert "--property=LoadCredential=forge-secrets:/var/lib/forge/jobs/x.worker/secrets.env" in flags

      assert Enum.filter(flags, &String.starts_with?(&1, "--setenv=")) == [
               "--setenv=PATH=/run/current-system/sw/bin",
               "--setenv=HOME=/var/lib/forge/jobs/x/home"
             ]

      {:ok, none} = prepared(%{job_id: @job, worktree: "/w", env: []})
      refute Enum.any?(Systemd.flags(none), &(&1 =~ "LoadCredential"))
    end
  end

  # `docs/design/worker-tier.md` § The job slice: the unit's own last reading, written by a stop
  # command systemd runs as root once the main process has ended and before the cgroup is gone.
  describe "the unit's last reading" do
    @describetag :tmp_dir

    test "is asked for as a stop command, as root, whose failure fails nothing", %{tmp_dir: dir} do
      job_dir = Path.join(dir, "jobs/#{@job}")
      {:ok, context} = prepared(%{job_id: @job, worktree: "/w", job_dir: job_dir})

      assert "--property=ExecStopPost=-+#{job_dir}.worker/at-exit" in Systemd.flags(context)

      # With no job directory there is nowhere to put it, and nothing is asked for.
      {:ok, bare} = prepared(%{job_id: @job, worktree: "/w"})
      refute Enum.any?(Systemd.flags(bare), &String.contains?(&1, "ExecStopPost"))
    end

    # The script itself, run the way systemd would run it: against a directory standing in for
    # the cgroup, with the variables systemd hands a stop command.
    test "writes the cgroup's counters and how the main process ended", %{tmp_dir: dir} do
      cgroup = Path.join(dir, "forge-job-x.service")
      File.mkdir_p!(cgroup)

      File.write!(
        Path.join(cgroup, "memory.events"),
        "low 0\nhigh 0\nmax 17\noom 2\noom_kill 2\n"
      )

      File.write!(Path.join(cgroup, "memory.peak"), "2147483648\n")
      File.write!(Path.join(cgroup, "memory.max"), "2147483648\n")

      reading = Path.join(dir, "at-exit.reading")
      script = Path.join(dir, "at-exit")
      File.write!(script, Systemd.at_exit_script(cgroup, reading))

      env = [{"EXIT_CODE", "killed"}, {"EXIT_STATUS", "KILL"}, {"SERVICE_RESULT", "signal"}]
      assert {_out, 0} = System.cmd("/bin/sh", [script], env: env)

      assert Systemd.parse_at_exit(File.read!(reading)) ==
               {%{
                  ceiling: 2_147_483_648,
                  current: nil,
                  peak: 2_147_483_648,
                  max_events: 17,
                  oom_kills: 2,
                  pressure: nil
                }, %{code: "killed", status: "KILL", result: "signal"}}
    end

    # `memory.peak` is from 5.19 on, and a stop command that failed would fail the unit a job had
    # finished cleanly in: what is missing is left out, and it still exits 0.
    test "leaves out what the cgroup does not have, and still exits 0", %{tmp_dir: dir} do
      reading = Path.join(dir, "at-exit.reading")
      script = Path.join(dir, "at-exit")
      File.write!(script, Systemd.at_exit_script(Path.join(dir, "no-such-cgroup"), reading))

      assert {_out, 0} = System.cmd("/bin/sh", [script], env: [{"EXIT_CODE", "exited"}])

      assert {%{peak: nil, oom_kills: nil, ceiling: nil}, %{code: "exited", status: nil}} =
               Systemd.parse_at_exit(File.read!(reading))

      # Nor does nowhere to write it fail anything.
      File.write!(script, Systemd.at_exit_script(dir, Path.join(dir, "gone/at-exit.reading")))
      assert {_out, 0} = System.cmd("/bin/sh", [script])
    end

    # Read once and removed: a correction round's unit has the same name, and one that never got
    # as far as existing would otherwise be handed the last round's reading.
    test "is read when the process has ended, and removed", %{tmp_dir: dir} do
      job_dir = Path.join(dir, "jobs/#{@job}")
      File.mkdir_p!(job_dir <> ".worker")
      reading = Path.join(job_dir <> ".worker", "at-exit.reading")
      File.write!(reading, "events oom_kill 1\npeak 900\nexit_code killed\nexit_status KILL\n")

      context = %{job_id: @job, job_dir: job_dir, cgroup_root: dir}
      output = Path.join(dir, "stderr.log")
      File.write!(output, "Running as unit: forge-job-x.service\nsomething the harness said\n")

      ending = Systemd.ended(context, output)
      assert %{memory: %{oom_kills: 1, peak: 900}, exit: %{code: "killed"}} = ending
      refute File.exists?(reading)

      assert %{memory: nil, exit: nil} = Systemd.ended(context, output)
    end
  end

  # What the cgroup says while the job runs: plain files, read here from a directory standing in
  # for `/sys/fs/cgroup/system.slice/<unit>`.
  describe "reading a running job's memory" do
    @describetag :tmp_dir

    test "the ceiling, now, the peak, the counters and full pressure", %{tmp_dir: dir} do
      cgroup = Path.join(dir, Systemd.unit_name(@job) <> ".service")
      File.mkdir_p!(cgroup)
      File.write!(Path.join(cgroup, "memory.events"), "low 0\nhigh 0\nmax 3\noom 1\noom_kill 1\n")
      File.write!(Path.join(cgroup, "memory.current"), "1073741824\n")
      File.write!(Path.join(cgroup, "memory.peak"), "2147483648\n")
      File.write!(Path.join(cgroup, "memory.max"), "2147483648\n")

      File.write!(
        Path.join(cgroup, "memory.pressure"),
        "some avg10=40.12 avg60=10.00 avg300=2.00 total=123\n" <>
          "full avg10=35.50 avg60=9.00 avg300=1.00 total=100\n"
      )

      assert Systemd.memory(%{job_id: @job, cgroup_root: dir}) == %{
               ceiling: 2_147_483_648,
               current: 1_073_741_824,
               peak: 2_147_483_648,
               max_events: 3,
               oom_kills: 1,
               pressure: 35.5
             }
    end

    test "no ceiling is nil, not a number, and a cgroup not there is nothing", %{tmp_dir: dir} do
      cgroup = Path.join(dir, Systemd.unit_name(@job) <> ".service")
      File.mkdir_p!(cgroup)
      File.write!(Path.join(cgroup, "memory.events"), "max 0\noom_kill 0\n")
      File.write!(Path.join(cgroup, "memory.max"), "max\n")

      assert %{ceiling: nil, current: nil, pressure: nil, oom_kills: 0} =
               Systemd.memory(%{job_id: @job, cgroup_root: dir})

      assert Systemd.memory(%{job_id: "0000aaaa-0000-4000-8000-000000000000", cgroup_root: dir}) ==
               nil
    end

    test "full avg10 is the figure, not some" do
      assert Systemd.parse_pressure("some avg10=9.00 avg60=0 avg300=0 total=0\n") == nil
      assert Systemd.parse_pressure("full avg10=0.00 avg60=0 avg300=0 total=0\n") == 0.0
      assert Systemd.parse_pressure(nil) == nil
    end
  end

  # `docs/design/worker-tier.md` § How a machine finds out: what `systemd-run` prints when it
  # could not reach PID 1, and why that is believed only when the unit never existed.
  describe "a systemd-run that could not reach PID 1" do
    @describetag :tmp_dir

    test "is each of the lines systemd prints for it" do
      for line <- [
            "Failed to start transient service unit: Connection timed out",
            "Failed to start transient service unit: Transport endpoint is not connected",
            "Failed to start transient service unit: Connection reset by peer",
            "Failed to connect to system scope bus via local transport: Connection timed out",
            "Failed to connect to bus: Transport endpoint is not connected"
          ] do
        assert Systemd.bus_error("some noise\n  #{line}\n") == line, line
      end
    end

    # PID 1 answering no is not PID 1 not answering.
    test "is not an answer that said no, nor a timeout said by anybody else" do
      for text <- [
            "Failed to start transient service unit: Unit forge-job-x.service already exists.",
            "Failed to start transient service unit: Invalid argument",
            "curl: (28) Connection timed out",
            "Failed to fetch https://cache.nixos.org: Connection timed out after 30s",
            ""
          ] do
        assert Systemd.bus_error(text) == nil, text
      end
    end

    test "is the machine's failure only when the unit never existed", %{tmp_dir: dir} do
      output = Path.join(dir, "stderr.log")
      context = %{job_id: @job}

      File.write!(output, "Failed to start transient service unit: Connection timed out\n")

      assert Systemd.ended(context, output).unreachable ==
               "systemd-run could not reach PID 1: " <>
                 "Failed to start transient service unit: Connection timed out"

      # A job can print anything once its unit exists — a flake's `shellHook` among it — and a
      # line it printed is not systemd-run's, however it reads.
      File.write!(
        output,
        "Running as unit: forge-job-x.service; invocation ID: 1\n" <>
          String.duplicate("x\n", 5000) <>
          "Failed to start transient service unit: Connection timed out\n"
      )

      assert Systemd.ended(context, output).unreachable == nil
    end

    # **Found by review**: with `--pipe` the job's stderr is this very file, and a process holding
    # it may truncate it and write a bus error where `Running as unit:` was. The unit's last
    # reading is root's, in a directory the job cannot reach, and only a unit that existed leaves
    # one: with it, no line in the output is believed.
    test "is not believed when the unit left a last reading, whatever the output says", %{
      tmp_dir: dir
    } do
      job_dir = Path.join(dir, "jobs/#{@job}")
      File.mkdir_p!(job_dir <> ".worker")
      reading = Path.join(job_dir <> ".worker", "at-exit.reading")
      File.write!(reading, "events oom_kill 0\nexit_code exited\nexit_status 1\n")

      # What a job that truncated its stderr leaves: its own bus error, then systemd-run's summary.
      output = Path.join(dir, "stderr.log")

      File.write!(
        output,
        "Failed to connect to bus: Connection timed out\n" <>
          "Finished with result: exit-code\nMain processes terminated with: code=exited/status=1\n"
      )

      assert Systemd.ended(%{job_id: @job, job_dir: job_dir}, output).unreachable == nil

      # The same output with no reading is what a unit that never existed leaves, and is believed.
      assert Systemd.ended(%{job_id: @job, job_dir: job_dir}, output).unreachable ==
               "systemd-run could not reach PID 1: Failed to connect to bus: Connection timed out"
    end

    test "a missing output is not a started unit, and says nothing" do
      refute Systemd.started?("/nonexistent/stderr.log")
      assert Systemd.ended(%{job_id: @job}, "/nonexistent/stderr.log").unreachable == nil
    end
  end

  describe "the process's last line" do
    @describetag :tmp_dir

    # `systemd-run`'s summary names nothing; the line before it is the one that does.
    test "is not one of systemd-run's own", %{tmp_dir: dir} do
      output = Path.join(dir, "stderr.log")

      File.write!(output, """
      Running as unit: forge-job-x.service; invocation ID: 1
      error: flake 'git+file:///w' does not provide attribute 'devShells.x86_64-linux.env'
                 Finished with result: exit-code
      Main processes terminated with: code=exited, status=1/FAILURE
                      Service runtime: 1.021s
                    CPU time consumed: 812ms
                          Memory peak: 30.1M (swap: 0B)
                             IO Bytes: read 0B, written 0B
                           IP Traffic: received 0B, sent 0B
      """)

      assert Systemd.ended(%{job_id: @job}, output).last_line ==
               "error: flake 'git+file:///w' does not provide attribute 'devShells.x86_64-linux.env'"

      assert Systemd.own_line?("Running as unit: forge-job-x.service")
      refute Systemd.own_line?("Memory peaked at 3G in my build")
    end
  end

  describe "leaving" do
    @tag :tmp_dir
    test "never raises, whatever it could not undo", %{tmp_dir: tmp_dir} do
      # `leave/2` is on every job's exit path, including the ones where something has already
      # gone wrong, and one that raised would turn a finished job into a crashed one. Both of its
      # commands are made to fail here, whatever this test runs as: a path that is not there,
      # and a name `userdel` refuses as an option.
      import ExUnit.CaptureLog

      owner = %{job_id: @job, kind: :systemd, user: "--not-a-user", gid: "0"}

      log =
        capture_log(fn ->
          assert Systemd.leave(owner, [Path.join(tmp_dir, "nothing-here")]) == :ok
        end)

      assert log =~ "files back"
      assert log =~ "could not remove"
    end

    # A second `leave/2` — the net under every ending — finds the user already gone. That is
    # `userdel`'s 6, and it is not a failure worth a line on every job that ever finished.
    # About this user and nothing else: the log is the whole node's, and another test running
    # beside this one — a machine going unhealthy — writes to it too.
    test "a user that is already gone is not a failure" do
      import ExUnit.CaptureLog

      owner = %{job_id: @job, kind: :systemd, user: "forge-job-does-not-exist", gid: "0"}
      refute capture_log(fn -> assert Systemd.leave(owner, []) == :ok end) =~ owner.user
    end
  end

  describe "running as the job's user" do
    # What can be checked without making a user. That git then runs as it — and a hook the job
    # wrote with it — is `ForgeWorker.JobUserTest`'s, which needs root.
    test "is setpriv to its uid and gid, with no supplementary groups and no home" do
      owner = %{job_id: @job, kind: :systemd, user: "forge-job-abc", gid: "991"}

      assert Systemd.run_as(owner, "git", ["status"]) ==
               {"setpriv",
                [
                  "--reuid=forge-job-abc",
                  "--regid=991",
                  "--clear-groups",
                  "--",
                  "env",
                  "HOME=/nonexistent",
                  "git",
                  "status"
                ]}
    end

    test "leaves the unit alone: the user is the job owner's to remove" do
      assert Systemd.cleanup(%{job_id: @job, kind: :systemd, user: "forge-job-abc"}) == :ok
    end
  end

  describe "the direct slice" do
    test "runs the command as it is" do
      {:ok, context} = Direct.prepare(%{job_id: @job, worktree: "/w"})

      assert {"claude", ["-p"]} = Direct.wrap("claude", ["-p"], context)
      assert :ok = Direct.cleanup(context)
    end

    test "is what a machine without systemd gets, and it is the default" do
      assert Slice.impl() == Direct
    end

    # No cgroup of the job's own and no supervisor to ask: what the process wrote last is all.
    @tag :tmp_dir
    test "says only the process's last line, and has nothing to probe", %{tmp_dir: dir} do
      output = Path.join(dir, "stderr.log")
      File.write!(output, "first\nthe last thing it said\n\n")

      assert Direct.memory(%{job_id: @job}) == nil
      assert Direct.probe() == :none

      assert Direct.ended(%{job_id: @job}, output) ==
               %{memory: nil, exit: nil, unreachable: nil, last_line: "the last thing it said"}
    end
  end

  # `prepare/1` makes a Unix user, which needs a machine willing to have one made. The flags
  # are what can be checked here, so the context is built the way prepare would leave it.
  defp prepared(opts) do
    {:ok, Map.merge(opts, %{kind: :systemd, user: Systemd.user_name(opts.job_id)})}
  end
end
