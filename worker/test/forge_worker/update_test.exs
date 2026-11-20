defmodule ForgeWorker.UpdateTest do
  @moduledoc """
  A machine bringing itself up to the platform's worker, against a script that only records what
  it was asked (`docs/design/worker-tier.md` § Updating a permanent machine). The test process is
  the link: it receives what the update would send it and answers as the link would.

  What the script does with a disk is `ForgeWorker.SystemUpdateScriptTest`'s.
  """

  use ExUnit.Case, async: false

  alias ForgeWorker.Update

  @target %{
    "build" => "newnewnewnew",
    "version" => "0.23.0",
    "repository" => "ghcr.io/example/forge-worker-image",
    "digest" => "sha256:" <> String.duplicate("a", 64),
    "raw_sha256" => String.duplicate("b", 64),
    "raw_size" => 1000
  }
  @other %{@target | "build" => "othrothrothr", "version" => "0.24.0"}

  setup do
    dir = Path.join(System.tmp_dir!(), "update-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "layout"), "2\n")
    update_dir = Path.join(dir, "update")
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, clock} = Agent.start_link(fn -> 1_700_000_000_000 end)
    :persistent_term.erase({Update, :snapshot})

    %{dir: dir, update_dir: update_dir, calls: calls, clock: clock}
  end

  # The script, as a function: each command is recorded, and answers what `script` says.
  defp start(context, opts \\ []) do
    test = self()
    script = Keyword.get(opts, :script, fn _args -> {:ok, ""} end)

    run = fn args ->
      Agent.update(context.calls, &(&1 ++ [args]))
      send(test, {:ran, args})
      script.(args)
    end

    name = :"update_#{System.unique_integer([:positive])}"

    options =
      [
        name: name,
        dir: context.update_dir,
        script: "stand-in",
        run: run,
        link: self(),
        own_build: fn -> Keyword.get(opts, :own_build, "oldoldoldold") end,
        reboot: Keyword.get(opts, :reboot, fn -> send(test, :rebooted) && :ok end),
        running: fn -> "/nix/store/running" end,
        layout: Keyword.get(opts, :layout, Path.join(context.dir, "layout")),
        now: fn -> Agent.get(context.clock, & &1) end,
        pause_ms: Keyword.get(opts, :pause_ms, 60_000)
      ]

    pid = start_supervised!(%{id: name, start: {Update, :start_link, [options]}})
    %{name: name, pid: pid}
  end

  defp calls(context), do: Agent.get(context.calls, & &1)

  defp report(step, timeout \\ 2_000) do
    receive do
      {:update_report, %{"step" => ^step} = snapshot} -> snapshot
      {:update_report, _other} -> report(step, timeout)
    after
      timeout -> flunk("no report of #{step}; had #{inspect(Process.info(self(), :messages))}")
    end
  end

  defp flush_reports(acc) do
    receive do
      {:update_report, report} -> flush_reports(acc ++ [report])
    after
      200 -> acc
    end
  end

  defp no_report(step) do
    receive do
      {:update_report, %{"step" => ^step}} -> flunk("reported #{step}")
    after
      100 -> :ok
    end
  end

  # Time passes for the update's own clock, and its retry timer is answered by hand: the real one
  # is 15 minutes away.
  defp retry(context, name, ms) do
    Agent.update(context.clock, &(&1 + ms))
    send(name, :retry)
  end

  defp state_file(context) do
    context.update_dir |> Path.join("state.json") |> File.read!() |> Jason.decode!()
  end

  describe "a target that is not its build" do
    test "downloads, installs, then pauses before it arms anything", context do
      %{name: name} = start(context)
      Update.told(@target, [], name)

      # Stamped with the machine's own clock, which the platform dates what it shows by.
      assert %{"target_version" => "0.23.0", "at" => 1_700_000_000_000} = report("downloading")
      report("installing")
      assert_receive {:update_pause, nil}, 2_000

      # The link says `pausing`, with the ids; this process only keeps it for a join.
      assert %{"step" => "pausing"} = Update.snapshot()
      refute_received {:update_report, %{"step" => "pausing"}}

      # The order is the guard: space, then the download and its checks, then the install, and
      # nothing that touches a boot entry until the work has stopped.
      assert [
               ["space", "1000"],
               ["fetch", "ghcr.io/example/forge-worker-image", "0.23.0", _digest, _sha, "1000"],
               ["install", "newnewnewnew"]
             ] =
               calls(context)

      Update.drained(name)
      report("restarting")
      assert_receive :rebooted
      assert List.last(calls(context)) == ["arm", "newnewnewnew"]
    end

    test "records a collection of the Nix store the script had to run, for the disk report",
         context do
      File.rm(ForgeWorker.Config.cleanups_path())

      script = fn
        ["space" | _rest] -> {:ok, "forge-update: short of room\nforge-update: collected 12345\n"}
        _other -> {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      report("installing")

      _sync = ForgeWorker.Disk.report()
      cleanups = ForgeWorker.Config.cleanups_path() |> File.read!() |> Jason.decode!()
      assert %{"nix_store" => %{"freed" => 12_345}} = cleanups
    end

    test "says to whom it owes the press when the owner asked", context do
      %{name: name} = start(context)
      Update.told(@target, [requested_by: "ada"], name)
      assert_receive {:update_pause, "ada"}, 2_000
    end

    test "does nothing on its own build, or with no target", context do
      %{name: name} = start(context, own_build: "newnewnewnew")
      Update.told(@target, [], name)
      Update.told(nil, [], name)
      refute_receive {:ran, _args}, 200
    end

    test "treats a target that is not what a release publishes as no target", context do
      %{name: name} = start(context)
      Update.told(%{@target | "repository" => "https://elsewhere.example/x"}, [], name)
      Update.told("nonsense", [], name)
      refute_receive {:ran, _args}, 200
    end

    test "restarts after the pause timeout when something would not stop", context do
      %{name: name} = start(context, pause_ms: 50)
      Update.told(@target, [], name)
      assert_receive {:update_pause, nil}, 2_000
      report("restarting")
      assert_receive :rebooted
    end

    test "restarting is not asked for before the link has said nothing is running", context do
      %{name: name} = start(context)
      Update.told(@target, [], name)
      assert_receive {:update_pause, nil}, 2_000
      refute_receive {:ran, ["arm" | _rest]}, 200
    end
  end

  describe "the target is checked again after the install" do
    test "a build that moved discards the new system, counts no failure, and starts again",
         context do
      test = self()

      script = fn
        ["install", "newnewnewnew"] ->
          send(test, {:installing, self()})
          receive do: (:go -> {:ok, ""})

        _other ->
          {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      assert_receive {:installing, task}, 2_000
      Update.told(@other, [], name)
      send(task, :go)

      assert_receive {:ran, ["discard"]}, 2_000
      assert_receive {:ran, ["install", "othrothrothr"]}, 2_000
      assert state_file(context)["failures"] == 0
      no_report("failed")
    end

    test "what it last says, after dropping a system for a new build, is that it is downloading that one",
         context do
      test = self()

      script = fn
        ["install", "newnewnewnew"] ->
          send(test, {:installing, self()})
          receive do: (:go -> {:ok, ""})

        ["fetch", _repository, "0.24.0" | _rest] ->
          send(test, {:fetching_other, self()})
          receive do: (:go -> {:ok, ""})

        _other ->
          {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      assert_receive {:installing, task}, 2_000
      Update.told(@other, [], name)
      send(task, :go)
      assert_receive {:fetching_other, task_other}, 2_000

      # The second attempt is blocked in its download, so nothing it does can report after the
      # discard has. An empty report from the discard, when a new attempt began, would read as
      # nothing under way while a download runs.
      reports = flush_reports([])
      assert %{"step" => "downloading", "target_build" => "othrothrothr"} = List.last(reports)
      send(task_other, :go)
    end

    test "a platform that now asks for nothing drops the new system and stops", context do
      test = self()

      script = fn
        ["install", _build] ->
          send(test, {:installing, self()})
          receive do: (:go -> {:ok, ""})

        _other ->
          {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      assert_receive {:installing, task}, 2_000
      Update.told(nil, [], name)
      send(task, :go)

      assert_receive {:ran, ["discard"]}, 2_000
      refute_receive {:update_pause, _who}, 200

      # What it says of itself now is nothing: an `installing` left standing would read as an update
      # under way on the platform's row, and in every join this worker makes until it restarts.
      assert_receive {:update_report, report} when not is_map_key(report, "step"), 2_000
      refute Map.has_key?(Update.snapshot(), "step")
    end

    test "a link that went down waits for the next word instead of pausing", context do
      test = self()

      script = fn
        ["install", _build] ->
          send(test, {:installing, self()})
          receive do: (:go -> {:ok, ""})

        _other ->
          {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      assert_receive {:installing, task}, 2_000
      Update.link_down(name)
      send(task, :go)

      refute_receive {:update_pause, _who}, 300
      Update.told(@target, [], name)
      assert_receive {:update_pause, nil}, 2_000
    end
  end

  describe "failing" do
    defp fail_fetch(_context) do
      fn
        ["fetch" | _rest] -> {:error, "the download is not sha256:…"}
        _other -> {:ok, ""}
      end
    end

    test "says where and why, and when it tries again: 15 minutes, then an hour, then it stops",
         context do
      %{name: name} = start(context, script: fail_fetch(context))
      now = Agent.get(context.clock, & &1)

      Update.told(@target, [], name)

      assert %{
               "failed_step" => "downloading",
               "reason" => "the download" <> _,
               "attempt" => 2,
               "next_at" => first
             } = report("failed")

      assert first == now + 15 * 60_000

      retry(context, name, 15 * 60_000)
      assert %{"attempt" => 3, "next_at" => second} = report("failed")
      assert second == now + 15 * 60_000 + 60 * 60_000

      retry(context, name, 60 * 60_000)
      assert %{"attempt" => 3} = report("gave_up")
      retry(context, name, 60 * 60_000)
      refute_receive {:update_report, _any}, 200

      # No pause was asked for by any of it: a failed download costs no job anything.
      refute_received {:update_pause, _who}
    end

    test "an owner's request tries a build the machine stopped trying", context do
      %{name: name} = start(context, script: fail_fetch(context))
      Update.told(@target, [], name)
      report("failed")
      retry(context, name, 15 * 60_000)
      report("failed")
      retry(context, name, 60 * 60_000)
      report("gave_up")

      Update.told(@target, [requested_by: "ada"], name)
      report("downloading")
      # Started from nothing: this is the first failure of a new count, not the fourth.
      assert %{"attempt" => 2} = report("failed")
    end

    test "a retry after an owner's press is automatic, and no one is named for it", context do
      %{name: name} = start(context, script: fail_fetch(context))
      Update.told(nil, [], name)
      Update.told(@target, [requested_by: "ada"], name)
      assert %{"automatic" => false} = report("downloading")
      report("failed")
      assert :sys.get_state(name).requested_by == "ada"

      # The switch turned on: the next try is a retry of the machine's own, not the owner's.
      Update.told(@target, [], name)
      retry(context, name, 15 * 60_000)
      assert %{"automatic" => true} = report("downloading")
      assert :sys.get_state(name).requested_by == nil
    end

    test "a failed press with the switch off is not retried by itself", context do
      %{name: name} = start(context, script: fail_fetch(context))
      Update.told(nil, [], name)
      Update.told(@target, [requested_by: "ada"], name)
      assert %{"next_at" => _at} = report("failed")
      assert :sys.get_state(name).retry_timer == nil
    end

    test "standing down cancels a retry that was waiting", context do
      %{name: name} = start(context, script: fail_fetch(context))
      Update.told(@target, [], name)
      report("failed")
      assert :sys.get_state(name).retry_timer != nil

      Update.told(nil, [], name)
      assert :sys.get_state(name).retry_timer == nil
    end

    test "a failed arm puts the machine back to work", context do
      script = fn
        ["arm" | _rest] -> {:error, "the running system has no boot entry to fall back to"}
        _other -> {:ok, ""}
      end

      %{name: name} = start(context, script: script)
      Update.told(@target, [], name)
      assert_receive {:update_pause, nil}, 2_000
      Update.drained(name)

      assert_receive :update_resume, 2_000
      assert %{"failed_step" => "restarting"} = report("failed")
      refute_received :rebooted
    end

    test "a link that says it is drained while nothing is pausing arms nothing", context do
      test = self()

      script = fn
        ["install", _build] ->
          send(test, {:installing, self()})
          receive do: (:go -> {:ok, ""})

        _other ->
          {:ok, ""}
      end

      # Idle: there is no attempt to arm.
      %{name: name, pid: pid} = start(context, script: script)
      Update.drained(name)
      refute_receive {:ran, ["arm" | _rest]}, 200
      assert Process.alive?(pid)

      # Installing: the link's word is about a stop that has not been asked for yet, and an `arm`
      # now would put a trial entry in front of a system nobody has paused for.
      Update.told(@target, [], name)
      assert_receive {:installing, task}, 2_000
      Update.drained(name)
      refute_receive {:ran, ["arm" | _rest]}, 300
      refute_received :rebooted
      send(task, :go)
    end

    test "a reboot that fails takes the trial entry back out", context do
      %{name: name} = start(context, reboot: fn -> {:error, "no systemd"} end)
      Update.told(@target, [], name)
      assert_receive {:update_pause, nil}, 2_000
      Update.drained(name)

      assert_receive :update_resume, 2_000
      assert_receive {:ran, ["fallback", "the reboot failed: no systemd"]}, 2_000
    end
  end

  describe "a machine that cannot update itself" do
    test "on the old layout says so and runs nothing", context do
      %{name: name} = start(context, layout: Path.join(context.dir, "missing"))
      assert Update.snapshot() == %{"unable" => "layout"}

      Update.told(@target, [], name)
      refute_receive {:ran, _args}, 200
    end

    test "without a script is not on the image", context do
      name = :"update_bare_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: name,
        start:
          {Update, :start_link,
           [
             [
               name: name,
               dir: context.update_dir,
               script: nil,
               link: self(),
               layout: Path.join(context.dir, "layout")
             ]
           ]}
      })

      assert Update.snapshot() == %{"unable" => "not_an_image"}
    end
  end

  describe "the new system, on trial" do
    defp trial(context, system) do
      File.mkdir_p!(context.update_dir)

      File.write!(
        Path.join(context.update_dir, "trial"),
        "id=abc\nsystem=#{system}\nprevious=/nix/store/old\nprevious_id=def\nbuild=newnewnewnew\n"
      )
    end

    test "is kept when the platform accepts a worker that is the build it was updating to",
         context do
      trial(context, "/nix/store/running")
      %{name: name} = start(context, own_build: "newnewnewnew")
      report("trying")
      assert %{"step" => "trying"} = Update.snapshot()
      refute Enum.any?(calls(context), &(&1 == ["keep"]))

      Update.accepted(name)
      assert_receive {:ran, ["keep"]}, 2_000
      report("kept")
    end

    test "is not kept for a worker that is some other build, however it was accepted", context do
      trial(context, "/nix/store/running")
      %{name: name} = start(context, own_build: "oldoldoldold")
      Update.accepted(name)
      refute_receive {:ran, ["keep"]}, 300
    end

    test "is not kept when it is not accepted at all", context do
      trial(context, "/nix/store/running")
      start(context, own_build: "newnewnewnew")
      refute_receive {:ran, ["keep"]}, 300
    end

    test "that the machine is no longer running is cleared, saying why", context do
      trial(context, "/nix/store/another")
      start(context)
      assert_receive {:ran, ["fallback", reason]}, 2_000
      assert reason =~ "did not come up"
    end

    test "a fallback that rebooted leaves a result, which becomes a failure and a line",
         context do
      File.mkdir_p!(context.update_dir)

      File.write!(
        Path.join(context.update_dir, "result"),
        "outcome=fell_back\nbuild=newnewnewnew\nreason=not accepted within 15 minutes\n"
      )

      start(context)

      assert %{
               "failed_step" => "trying",
               "reason" => "not accepted within 15 minutes",
               "attempt" => 2
             } =
               report("fell_back")

      refute File.exists?(Path.join(context.update_dir, "result"))
      assert state_file(context)["failures"] == 1
    end
  end

  describe "with no link to tell" do
    # The link is started after this process, and not at all on a machine with no platform
    # configured. A `send/2` to a name nobody holds raises, and the settle at start-up did that.
    defp start_unlinked(context) do
      name = :"update_unlinked_#{System.unique_integer([:positive])}"

      options = [
        name: name,
        dir: context.update_dir,
        script: "stand-in",
        run: fn _args -> {:ok, ""} end,
        link: :"no_such_link_#{System.unique_integer([:positive])}",
        running: fn -> "/nix/store/running" end,
        layout: Path.join(context.dir, "layout"),
        now: fn -> Agent.get(context.clock, & &1) end
      ]

      pid = start_supervised!(%{id: name, start: {Update, :start_link, [options]}})
      # `handle_continue(:settle)` has run once a call has been answered.
      _ = :sys.get_state(pid)
      pid
    end

    test "a result left by a fallback is settled, and the join can still carry it", context do
      File.mkdir_p!(context.update_dir)

      File.write!(
        Path.join(context.update_dir, "result"),
        "outcome=fell_back\nbuild=newnewnewnew\nreason=not accepted\n"
      )

      pid = start_unlinked(context)

      assert Process.alive?(pid)
      assert %{"step" => "fell_back", "reason" => "not accepted"} = Update.snapshot()
    end

    test "a trial this system is on is settled, and the join can still carry it", context do
      File.mkdir_p!(context.update_dir)

      File.write!(
        Path.join(context.update_dir, "trial"),
        "id=abc\nsystem=/nix/store/running\nprevious=/nix/store/old\nprevious_id=def\nbuild=newnewnewnew\n"
      )

      pid = start_unlinked(context)

      assert Process.alive?(pid)
      assert %{"step" => "trying"} = Update.snapshot()
    end
  end

  test "an attempt cut off by the worker stopping counts as a failure", context do
    File.mkdir_p!(context.update_dir)

    File.write!(
      Path.join(context.update_dir, "state.json"),
      Jason.encode!(%{"phase" => "pausing", "target_build" => "newnewnewnew", "failures" => 0})
    )

    start(context)

    assert %{"failed_step" => "pausing", "reason" => "the worker stopped while it was updating"} =
             report("failed")
  end

  # The script itself, not a function standing in for it: what the worker makes of how the real one
  # fails. A refusal is `forge-update: <code>: <why>` as the last line it prints, and the reason is
  # the `<why>` (`nix/system-update.sh`); anything else is its last line as it stands.
  describe "the script on disk" do
    defp start_script(context, script) do
      name = :"update_script_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: name,
        start:
          {Update, :start_link,
           [
             [
               name: name,
               dir: context.update_dir,
               script: script,
               link: self(),
               own_build: fn -> "oldoldoldold" end,
               running: fn -> "/nix/store/running" end,
               layout: Path.join(context.dir, "layout"),
               now: fn -> Agent.get(context.clock, & &1) end
             ]
           ]}
      })

      name
    end

    defp script(context, body) do
      path = Path.join(context.dir, "system-update")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      path
    end

    test "a refusal is said in the script's own words", context do
      script =
        script(context, """
        echo "checking room for $2 bytes"
        echo "forge-update: no_room: not enough room for the download, even after collecting" >&2
        exit 1
        """)

      Update.told(@target, [], start_script(context, script))

      assert %{
               "failed_step" => "downloading",
               "reason" => "not enough room for the download, even after collecting"
             } = report("failed")
    end

    test "a failure that is not a refusal is its last line", context do
      script =
        script(context, """
        echo "starting"
        echo "something broke" >&2
        exit 3
        """)

      Update.told(@target, [], start_script(context, script))
      assert %{"failed_step" => "downloading", "reason" => "something broke"} = report("failed")
    end

    test "a script that cannot be run says so", context do
      missing = Path.join(context.dir, "no-such-script")
      Update.told(@target, [], start_script(context, missing))

      assert %{"failed_step" => "downloading", "reason" => "could not run " <> rest} =
               report("failed")

      assert rest =~ missing
    end
  end
end
