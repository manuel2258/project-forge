defmodule ForgeWorker.Job.StepsTest do
  @moduledoc """
  The clock a command's steps are timed by (`docs/design/worker-tier.md` § Looking into a copy).
  Time is driven by the test: `:clock` is an Agent holding the milliseconds, and nothing waits.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.CommandSteps
  alias ForgeWorker.Job.Steps

  setup do
    {:ok, now} = Agent.start_link(fn -> 1_000 end)
    clock = fn -> Agent.get(now, & &1) end
    advance = fn ms -> Agent.update(now, &(&1 + ms)) end
    {:ok, steps} = Steps.start_link(clock: clock, wall: 5_000_000)
    %{steps: steps, advance: advance}
  end

  test "a step is timed from where it began, and the steps and the remainder add up to the total",
       %{steps: steps, advance: advance} do
    advance.(10)
    Steps.time(steps, "fetch", fn -> advance.(30) end)
    advance.(5)
    Steps.time(steps, "script", fn -> advance.(200) end)
    advance.(7)

    {listed, total} = Steps.finish(steps)

    assert total == 252

    assert listed == [
             %{"name" => "fetch", "at" => 5_000_010, "ms" => 30},
             %{"name" => "script", "at" => 5_000_045, "ms" => 200},
             %{"name" => "other", "at" => 5_000_000, "ms" => 22}
           ]

    assert Enum.sum(Enum.map(listed, & &1["ms"])) == total
    assert List.last(listed)["name"] == "other"
  end

  test "a step timed in pieces is the sum of them, and begins where the first did",
       %{steps: steps, advance: advance} do
    Steps.time(steps, "fetch", fn -> advance.(4) end)
    advance.(100)
    Steps.time(steps, "fetch", fn -> advance.(6) end)

    assert {[%{"name" => "fetch", "at" => 5_000_000, "ms" => 10}, _other], 110} =
             Steps.finish(steps)
  end

  test "a step that did not happen is recorded as skipped and never as a zero",
       %{steps: steps, advance: advance} do
    Steps.skip(steps, "snapshot", "no_source")
    Steps.skip(steps, "keep", "status")
    advance.(9)

    {listed, 9} = Steps.finish(steps)

    assert %{"name" => "snapshot", "skipped" => "no_source"} = Enum.at(listed, 0)
    assert %{"name" => "keep", "skipped" => "status"} = Enum.at(listed, 1)
    refute Enum.any?(Enum.take(listed, 2), &Map.has_key?(&1, "ms"))
    assert %{"name" => "other", "ms" => 9} = List.last(listed)
  end

  test "time spent on a step that was skipped before is a time, not a skip",
       %{steps: steps, advance: advance} do
    Steps.skip(steps, "devshell", "unmeasured")
    Steps.record(steps, "devshell", 5_000_100, 40)
    advance.(50)

    assert {[%{"name" => "devshell", "at" => 5_000_100, "ms" => 40} = devshell, _other], 50} =
             Steps.finish(steps)

    refute Map.has_key?(devshell, "skipped")
  end

  test "a step skipped after it was timed is a skip, and keeps no time", %{steps: steps} do
    Steps.record(steps, "keep", 5_000_100, 40)
    Steps.skip(steps, "keep", "status")

    assert {[%{"name" => "keep", "skipped" => "status"} = keep, _other], _total} =
             Steps.finish(steps)

    refute Map.has_key?(keep, "ms")
  end

  test "a fact noted on a step neither timed nor skipped is not a step", %{steps: steps} do
    Steps.note(steps, "snapshot", "source", "copy")

    assert {[%{"name" => "other"}], _total} = Steps.finish(steps)
  end

  test "the snapshot says where it started from", %{steps: steps, advance: advance} do
    Steps.time(steps, "snapshot", fn -> advance.(3) end)
    Steps.note(steps, "snapshot", "source", "copy")

    assert {[%{"name" => "snapshot", "source" => "copy", "ms" => 3}, _other], 3} =
             Steps.finish(steps)
  end

  test "the steps come in the order a command takes them, whatever order they were timed in",
       %{steps: steps, advance: advance} do
    for name <- Enum.reverse(CommandSteps.names()), name != "other" do
      Steps.time(steps, name, fn -> advance.(1) end)
    end

    {listed, _total} = Steps.finish(steps)
    assert Enum.map(listed, & &1["name"]) == CommandSteps.names()
  end

  test "a step whose function raises is still timed", %{steps: steps, advance: advance} do
    assert_raise RuntimeError, fn ->
      Steps.time(steps, "reset", fn ->
        advance.(8)
        raise "boom"
      end)
    end

    assert {[%{"name" => "reset", "ms" => 8}, _other], 8} = Steps.finish(steps)
  end

  test "the remainder is never negative", %{steps: steps, advance: advance} do
    advance.(10)
    Steps.record(steps, "script", 5_000_000, 500)

    assert {[_script, %{"name" => "other", "ms" => 0}], 10} = Steps.finish(steps)
  end

  test "elapsed is the time since the origin", %{steps: steps, advance: advance} do
    assert Steps.elapsed(steps) == 0
    advance.(250)
    assert Steps.elapsed(steps) == 250
  end

  test "no steps is a clock that does nothing, and a function that still runs" do
    assert Steps.time(nil, "fetch", fn -> :ran end) == :ran
    assert Steps.skip(nil, "keep", "status") == :ok
    assert Steps.note(nil, "snapshot", "source", "copy") == :ok
    assert Steps.record(nil, "script", 1, 1) == :ok
    assert Steps.tick(nil) == nil
    assert Steps.stop(nil, "fetch", nil) == :ok
    assert Steps.elapsed(nil) == 0
    assert Steps.finish(nil) == {nil, 0}
    assert Steps.close(nil) == :ok
  end

  test "what it reports is what core accepts", %{steps: steps, advance: advance} do
    Steps.time(steps, "fetch", fn -> advance.(3) end)
    Steps.skip(steps, "keep", "timeout")
    {listed, _total} = Steps.finish(steps)

    assert CommandSteps.sanitize(listed) == listed
  end

  test "closing it twice is nothing", %{steps: steps} do
    assert Steps.close(steps) == :ok
    assert Steps.close(steps) == :ok
  end
end
