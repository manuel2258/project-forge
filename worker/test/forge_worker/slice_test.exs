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

    test "carries the runner's environment across, and a secret by name only" do
      {:ok, context} =
        prepared(%{
          job_id: @job,
          worktree: "/w",
          env: [{"PATH", "/run/current-system/sw/bin"}, {"HOME", "/var/lib/forge/jobs/x/home"}],
          secret_names: ["CLAUDE_CODE_OAUTH_TOKEN"]
        })

      flags = Systemd.flags(context)

      # systemd hands the unit its own default environment, not systemd-run's, so a variable
      # nobody named is a variable the harness does not get. Without PATH it cannot find `nix`.
      assert "--setenv=PATH=/run/current-system/sw/bin" in flags
      assert "--setenv=HOME=/var/lib/forge/jobs/x/home" in flags

      # The value is not here: systemd-run reads it from its own environment and passes it to
      # systemd over the bus, so it never sits in an argument vector for the job's lifetime.
      assert "--setenv=CLAUDE_CODE_OAUTH_TOKEN" in flags
      refute Enum.any?(flags, &String.starts_with?(&1, "--setenv=CLAUDE_CODE_OAUTH_TOKEN="))
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
    test "a user that is already gone is not a failure" do
      import ExUnit.CaptureLog

      owner = %{job_id: @job, kind: :systemd, user: "forge-job-does-not-exist", gid: "0"}
      assert capture_log(fn -> assert Systemd.leave(owner, []) == :ok end) == ""
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
  end

  # `prepare/1` makes a Unix user, which needs a machine willing to have one made. The flags
  # are what can be checked here, so the context is built the way prepare would leave it.
  defp prepared(opts) do
    {:ok, Map.merge(opts, %{kind: :systemd, user: Systemd.user_name(opts.job_id)})}
  end
end
