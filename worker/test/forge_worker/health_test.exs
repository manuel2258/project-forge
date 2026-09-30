defmodule ForgeWorker.HealthTest do
  @moduledoc """
  Whether a machine can still run anything, and what it does when it cannot
  (`docs/design/worker-tier.md` § A machine whose systemd stops answering): the two signals, the
  two-in-a-row rule, and the two keys a reboot needs. Every instance here has a probe and a reboot
  of the test's own — no test asks a real PID 1 anything, and none reboots the machine it runs on.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ForgeWorker.Health

  # A health process of the test's own, telling the test what it does: `{:probed, n}` each time it
  # asks, `:rebooted` if it reboots, and the link's `{:unhealthy, reason}`.
  defp start(opts) do
    test = self()
    name = :"health-#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      link: test,
      probe_ms: nil,
      reboot: fn ->
        send(test, :rebooted)
        :ok
      end,
      managed: fn -> true end
    ]

    {:ok, pid} = Health.start_link(Keyword.merge(defaults, opts))

    {name, pid}
  end

  # A probe answering in turn from `answers`, the last one for ever.
  defp probe(answers) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn ->
      answer =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [next | rest] -> {next, rest}
        end)

      send(test, {:probed, answer})
      if is_function(answer), do: answer.(), else: answer
    end
  end

  describe "the probe" do
    test "two failures in a row make the machine unhealthy, and say why" do
      {name, _pid} = start(probe: probe([{:error, "timed out"}]), probe_ms: 10)

      assert_receive {:unhealthy, reason}, 2_000
      assert reason == "PID 1 did not answer twice in a row: timed out"
      assert Health.unhealthy(name) == reason
    end

    # One missed answer on a loaded machine is not a wedge.
    test "a failure followed by an answer is not two in a row" do
      answers = [{:error, "slow"}, :ok, {:error, "slow"}, :ok, {:error, "slow"}, :ok]
      {name, _pid} = start(probe: probe(answers), probe_ms: 10)

      for _answer <- answers, do: assert_receive({:probed, _}, 2_000)
      refute_received {:unhealthy, _}
      assert Health.unhealthy(name) == nil
    end

    # The probe runs in a task of its own, and one that hangs is abandoned at its deadline and
    # counted a failure: it never holds up anything else the worker does.
    test "a probe that does not come back is a failure at its deadline" do
      test = self()

      hang = fn ->
        send(test, {:hanging, self()})
        Process.sleep(:infinity)
      end

      {name, _pid} =
        start(probe: probe([hang]), probe_ms: 10, probe_deadline_ms: 50)

      # Asked while its probe hangs, it answers at once.
      assert_receive {:hanging, first}, 2_000
      assert Health.unhealthy(name) == nil

      assert_receive {:unhealthy, "PID 1 did not answer twice in a row: " <> why}, 2_000
      assert why =~ "did not return within 50ms"

      # And the one given up on is ended, not left hanging for the life of the worker.
      refute Process.alive?(first)
    end

    test "a probe that crashes is a failure" do
      crash = fn -> raise "no systemctl" end

      capture_log(fn ->
        {_name, _pid} = start(probe: probe([crash]), probe_ms: 10)

        assert_receive {:unhealthy,
                        "PID 1 did not answer twice in a row: the probe crashed" <> _},
                       2_000
      end)
    end

    # `Slice.Direct` has no systemd to ask.
    test "a slice with nothing to ask is asked once and never again" do
      {_name, _pid} = start(probe: probe([:none]), probe_ms: 10)

      assert_receive {:probed, :none}, 2_000
      refute_receive {:probed, _}, 200
    end

    test "an unhealthy machine is asked nothing more" do
      {name, _pid} = start(probe: probe([{:error, "gone"}]), probe_ms: 10)

      assert_receive {:unhealthy, _}, 2_000
      assert_receive {:probed, _}, 100
      flush_probes()
      refute_receive {:probed, _}, 200
      assert Health.unhealthy(name) =~ "gone"
    end
  end

  describe "a run whose systemd-run could not reach PID 1" do
    test "makes the machine unhealthy at once, and the first reason stands" do
      {name, _pid} = start([])

      assert Health.unreachable("systemd-run could not reach PID 1: first", name) == :ok
      assert_received {:unhealthy, "systemd-run could not reach PID 1: first"}

      assert Health.unreachable("systemd-run could not reach PID 1: second", name) == :ok
      refute_received {:unhealthy, _}
      assert Health.unhealthy(name) == "systemd-run could not reach PID 1: first"
    end

    # A shell, or a machine whose health process has gone: the run is still over, and says so in
    # the journal rather than crashing on the way out.
    test "with nothing watching, is a line in the journal" do
      log = capture_log(fn -> assert Health.unreachable("gone", :nobody_is_here) == :ok end)
      assert log =~ "nothing is watching this machine's health: gone"
      assert Health.unhealthy(:nobody_is_here) == nil
    end
  end

  # Two keys: the platform's yes, and the machine being one a driver made
  # (`docs/design/worker-tier.md` § What happens then).
  describe "the reboot" do
    test "happens on the platform's yes, on a machine a driver made" do
      {name, _pid} = start([])
      Health.answered({:ok, %{"reboot" => true, "why" => "told to reboot"}}, name)
      assert_receive :rebooted, 1_000
    end

    # **The guard that matters most here.** A machine somebody provisioned by hand is their own
    # computer, whatever the platform says.
    test "never happens on a machine a driver did not make, whatever the platform says" do
      {name, _pid} = start(managed: fn -> false end)

      log =
        capture_log(fn ->
          Health.answered({:ok, %{"reboot" => true}}, name)
          :sys.get_state(name)
        end)

      refute_received :rebooted
      assert log =~ "was not made by it: its owner decides"
    end

    test "does not happen when the platform says no, or would not take the report" do
      {name, _pid} = start([])

      log =
        capture_log(fn ->
          Health.answered({:ok, %{"reboot" => false, "why" => "rebooted within the hour"}}, name)
          Health.answered({:ok, %{"reboot" => "yes"}}, name)
          Health.answered({:error, %{"reason" => "unknown_message"}}, name)
          :sys.get_state(name)
        end)

      refute_received :rebooted
      assert log =~ "not rebooting: rebooted within the hour"
      assert log =~ "not rebooting: the platform said not to"
      assert log =~ "would not take the report"
    end

    test "that fails says so" do
      test = self()

      {name, _pid} =
        start(
          reboot: fn ->
            send(test, :tried)
            {:error, "systemctl exited 1: permission denied"}
          end
        )

      log =
        capture_log(fn ->
          Health.answered({:ok, %{"reboot" => true}}, name)
          assert_receive :tried, 1_000
          :sys.get_state(name)
        end)

      assert log =~ "the reboot itself failed: systemctl exited 1: permission denied"
    end
  end

  defp flush_probes do
    receive do
      {:probed, _} -> flush_probes()
    after
      50 -> :ok
    end
  end
end
