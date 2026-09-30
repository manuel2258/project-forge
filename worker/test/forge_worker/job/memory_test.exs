defmodule ForgeWorker.Job.MemoryTest do
  @moduledoc """
  What a job's memory readings are worth saying (`docs/design/claude-code-events.md` § Memory):
  one event per OOM kill, one the first time the ceiling binds, one per episode of pressure — and
  what a run ends with. Each rule is the one a mutation would break, so each is asked both ways.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Job.Memory

  @gib 1024 ** 3

  defp reading(fields) do
    Map.merge(
      %{
        ceiling: 2 * @gib,
        current: @gib,
        peak: @gib,
        max_events: 0,
        oom_kills: 0,
        pressure: 0.0
      },
      Map.new(fields)
    )
  end

  # Readings in order, and every event they made, in order.
  defp run(watch, readings) do
    Enum.reduce(readings, {watch, []}, fn reading, {watch, said} ->
      {watch, events} = Memory.observe(watch, reading)
      {watch, said ++ events}
    end)
  end

  defp whats(events), do: Enum.map(events, & &1.what)

  describe "OOM kills" do
    test "one event for each increase, saying by how many and how many in all" do
      {_watch, events} =
        run(Memory.new(2 * @gib), [
          reading(oom_kills: 0),
          reading(oom_kills: 1, peak: 2 * @gib),
          reading(oom_kills: 1),
          reading(oom_kills: 3)
        ])

      assert [first, second] = Enum.filter(events, &(&1.what == "oom_kill"))
      assert %{new_kills: 1, oom_kills: 1, ceiling: 2_147_483_648, peak: 2_147_483_648} = first
      # What the job holds at the moment, beside the highest it has held.
      assert first.current == @gib
      assert %{new_kills: 2, oom_kills: 3} = second
    end

    test "no kill, no event" do
      {_watch, events} = run(Memory.new(2 * @gib), [reading([]), reading([])])
      assert events == []
    end

    # A correction round runs in a cgroup of its own, whose counter starts at nought again: its
    # first kill is news, and the run's count is the rounds' added up.
    test "a new round counts from nought and the run adds its rounds up" do
      {watch, _events} = run(Memory.new(2 * @gib), [reading(oom_kills: 2)])
      watch = Memory.new_round(watch)

      {watch, events} = run(watch, [reading(oom_kills: 1)])

      assert [%{what: "oom_kill", new_kills: 1, oom_kills: 3}] = events
      assert Memory.oom_kills(watch) == 3
      assert Memory.summary(watch)["oom_kills"] == 3
    end
  end

  describe "the ceiling" do
    # `max` counts every reclaim at the ceiling — thousands a minute for a build that just fits.
    test "is said the first time it binds, and never again in the run" do
      {watch, events} =
        run(Memory.new(2 * @gib), [
          reading(max_events: 0),
          reading(max_events: 1),
          reading(max_events: 5000)
        ])

      assert whats(events) == ["ceiling"]

      # Not per round either: a correction that binds again is the same news.
      {_watch, events} = run(Memory.new_round(watch), [reading(max_events: 1)])
      assert events == []
    end
  end

  describe "pressure" do
    # Two samples at or above the threshold start an episode; one does not.
    test "is an episode only on two samples in a row, and said once per episode" do
      {_watch, events} =
        run(Memory.new(2 * @gib, threshold: 20.0), [
          reading(pressure: 25.0),
          reading(pressure: 5.0),
          reading(pressure: 25.0),
          reading(pressure: 20.0),
          reading(pressure: 90.0),
          reading(pressure: 90.0)
        ])

      assert [%{what: "pressure", pressure: 20.0}] = events
    end

    test "the first sample below the threshold ends the episode, and the next one is said" do
      {_watch, events} =
        run(Memory.new(2 * @gib, threshold: 20.0), [
          reading(pressure: 30.0),
          reading(pressure: 30.0),
          reading(pressure: 19.99),
          reading(pressure: 30.0),
          reading(pressure: 30.0)
        ])

      assert whats(events) == ["pressure", "pressure"]
    end

    # The threshold is the node's to move (`:memory_pressure_full`); twenty percent is only the
    # default.
    test "is measured against the threshold it was given" do
      high = [reading(pressure: 30.0), reading(pressure: 30.0)]

      {_watch, events} = run(Memory.new(2 * @gib, threshold: 50.0), high)
      assert events == []

      {_watch, events} = run(Memory.new(2 * @gib), high)
      assert whats(events) == ["pressure"]
    end

    # A correction round's cgroup is a new one: an episode or one bad sample left by the round
    # before is not this round's, and two of its own are needed again.
    test "a new round counts its samples from nought" do
      {watch, [_said]} =
        run(Memory.new(2 * @gib, threshold: 20.0), [
          reading(pressure: 30.0),
          reading(pressure: 30.0)
        ])

      {_watch, events} =
        run(Memory.new_round(watch), [reading(pressure: 30.0), reading(pressure: 30.0)])

      assert whats(events) == ["pressure"]

      {watch, []} = run(Memory.new(2 * @gib, threshold: 20.0), [reading(pressure: 30.0)])
      {_watch, events} = run(Memory.new_round(watch), [reading(pressure: 30.0)])
      assert events == []
    end

    # The unit's last reading has no pressure figure, and says nothing either way.
    test "a reading with no pressure figure neither starts nor ends an episode" do
      {_watch, events} =
        run(Memory.new(2 * @gib, threshold: 20.0), [
          reading(pressure: 30.0),
          reading(pressure: nil),
          reading(pressure: 30.0),
          reading(pressure: nil),
          reading(pressure: 30.0)
        ])

      assert whats(events) == ["pressure"]
    end
  end

  describe "what a run ends with" do
    test "the ceiling it was given, the highest it reached and every kill" do
      {watch, _events} =
        run(Memory.new(2 * @gib), [
          reading(peak: @gib, oom_kills: 0),
          reading(peak: 2 * @gib, oom_kills: 1),
          reading(peak: nil, current: @gib)
        ])

      assert Memory.summary(watch) ==
               %{"ceiling" => 2 * @gib, "peak" => 2 * @gib, "oom_kills" => 1}
    end

    # Nothing read is nothing to report — every run under `Slice.Direct` — and a run that was
    # read and never bound still says what it peaked at.
    test "is nil when nothing was read, and a peak when something was" do
      assert Memory.summary(Memory.new(2 * @gib)) == nil

      {watch, _events} = Memory.observe(Memory.new(2 * @gib), nil)
      assert Memory.summary(watch) == nil

      {watch, []} = Memory.observe(Memory.new(nil), reading(peak: 100, ceiling: 4 * @gib))
      assert Memory.summary(watch) == %{"ceiling" => nil, "peak" => 100, "oom_kills" => 0}
    end

    # A kernel before 5.19 has no `memory.peak`; what the job holds now is then the highest seen.
    test "is the current figure where the kernel has no peak" do
      {watch, _events} =
        run(Memory.new(2 * @gib), [
          reading(peak: nil, current: 700),
          reading(peak: nil, current: 300)
        ])

      assert Memory.summary(watch)["peak"] == 700
    end

    # A kill counted with nothing else read — a unit's last reading on such a kernel — is still
    # what the run ends with.
    test "is the kills when there is no peak at all" do
      {watch, _events} = Memory.observe(Memory.new(2 * @gib), %{oom_kills: 1})
      assert Memory.summary(watch) == %{"ceiling" => 2 * @gib, "peak" => nil, "oom_kills" => 1}
    end

    # An event names the ceiling the slice was given, and the cgroup's own where there was none.
    test "an event's ceiling is the job's, else the cgroup's" do
      {_watch, [event]} = Memory.observe(Memory.new(nil), reading(oom_kills: 1, ceiling: 3))
      assert event.ceiling == 3
    end
  end

  describe "a starting event's snapshot" do
    test "is the reading with string keys, and nil for none" do
      assert Memory.snapshot(nil) == nil

      assert Memory.snapshot(reading(current: 2, ceiling: 2, max_events: 7, pressure: 99.5)) ==
               %{
                 "ceiling" => 2,
                 "current" => 2,
                 "peak" => @gib,
                 "max_events" => 7,
                 "oom_kills" => 0,
                 "pressure" => 99.5
               }
    end
  end
end
