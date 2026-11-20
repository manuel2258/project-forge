defmodule ForgeWorker.Update.StateTest do
  @moduledoc """
  The retry rules of a machine's self-update (`docs/design/worker-tier.md` § Updating a
  permanent machine, § Retries): three tries per platform build, 15 minutes and then an hour
  apart, a different build starting again, the owner's request lifting a stop.
  """

  use ExUnit.Case, async: true

  alias ForgeWorker.Update.State

  @now 1_700_000_000_000
  @minute 60_000

  defp context(overrides \\ []) do
    Map.merge(
      %{build: "newnewnewnew", own: "oldoldoldold", now: @now, automatic: true, requested: false},
      Map.new(overrides)
    )
  end

  describe "decide/2" do
    test "starts on a build that is not its own" do
      assert State.decide(State.new(), context()) == :start
    end

    test "has nothing to do without a target, or on the target's own build" do
      assert State.decide(State.new(), context(build: nil)) == :idle
      assert State.decide(State.new(), context(build: "oldoldoldold")) == :idle
    end

    test "waits for a retry that is not due" do
      {state, {:retry, at}} = State.failure(State.new(), "downloading", "no route", @now)
      assert State.decide(state, context(now: @now + 14 * @minute)) == {:wait, at}
      assert State.decide(state, context(now: @now + 15 * @minute)) == :start
    end

    test "does not retry by itself when the switch is off, however much time passed" do
      {state, _next} = State.failure(State.new(), "downloading", "no route", @now)
      assert State.decide(state, context(automatic: false, now: @now + 99 * @minute)) == :idle
    end

    test "an owner's request starts it, switch or no switch, even after it stopped trying" do
      state = give_up(State.new())
      assert State.decide(state, context()) == :idle
      assert State.decide(state, context(requested: true, automatic: false)) == :start
    end
  end

  describe "failure/4" do
    test "15 minutes after the first, an hour after the second, and then it gives up" do
      {one, {:retry, first}} = State.failure(State.new(), "downloading", "a", @now)
      assert first == @now + 15 * @minute

      {two, {:retry, second}} = State.failure(one, "installing", "b", @now)
      assert second == @now + 60 * @minute

      {three, :gave_up} = State.failure(two, "installing", "c", @now)
      assert three.gave_up
      assert three.failures == 3
      assert three.next_at == nil
    end

    test "remembers where and why, clipped" do
      long = String.duplicate("x", 900)
      {state, _next} = State.failure(State.new(), "installing", long, @now)
      assert %{"step" => "installing", "at" => @now, "reason" => reason} = state.last
      assert String.length(reason) == 500
    end
  end

  test "a different build forgets every failure, and the same one keeps them" do
    state = %{give_up(State.new()) | target_build: "oldbuildbuil"}
    assert State.for_target(state, "oldbuildbuil") == state

    fresh = State.for_target(state, "newbuildbuil")
    assert fresh.failures == 0
    refute fresh.gave_up
    assert fresh.target_build == "newbuildbuil"
  end

  test "requested/1 lifts a stop and clears the count" do
    state = State.requested(give_up(State.new()))
    assert {state.failures, state.gave_up, state.next_at} == {0, false, nil}
  end

  describe "interrupted/2" do
    test "is nothing for a machine that was not mid-attempt" do
      assert State.interrupted(State.new(), @now) == :nothing
    end

    test "counts an attempt cut off while pausing as a failure" do
      state = State.phase(State.new(), "pausing")

      assert {%{failures: 1, phase: "idle"} = after_it, {:retry, _at}} =
               State.interrupted(state, @now)

      assert after_it.last["step"] == "pausing"
    end
  end

  describe "dump/1 and load/1" do
    test "round-trip what a failure left" do
      {state, _next} =
        State.failure(%{State.new() | target_build: "abc"}, "installing", "no room", @now)

      assert state |> State.dump() |> Jason.encode!() |> Jason.decode!() |> State.load() == state
    end

    test "a file that is not what dump/1 wrote is a machine that has tried nothing" do
      assert State.load("nonsense") == State.new()

      assert State.load(%{"failures" => "many", "phase" => "exploding", "next_at" => "soon"}) ==
               State.new()

      assert State.load(%{"failures" => -4}).failures == 0
    end
  end

  defp give_up(state) do
    Enum.reduce(1..3, state, fn _i, state ->
      {state, _next} = State.failure(state, "downloading", "no route", @now)
      state
    end)
  end
end
