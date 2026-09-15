defmodule ForgeCore.CapacityTest do
  @moduledoc """
  The arithmetic behind every consumption figure the operator sees.

  `docs/design/capacity.md` is a standard named in `CLAUDE.md`, and this module is where its two
  rules live: a quantity is stated in windows to two significant figures, and an uncalibrated
  constant produces no figure at all rather than a guess. Both were unasserted until this file —
  the module's only caller is `ForgeWeb.Format.windows/1`, so every capacity number on every
  operator surface rested on them.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Capacity

  describe "windows/2" do
    test "is the cost as a share of one whole window" do
      assert Capacity.windows(1.0, 4.0) == 0.25
      assert Capacity.windows(4.0, 4.0) == 1.0
      assert Capacity.windows(8.0, 4.0) == 2.0
    end

    # The note calls `window_cost_usd` "the one number in this note that is not evidence" and says
    # it is a placeholder until dogfooding calibrates it. Until then it is zero, and zero must not
    # divide: the answer is nothing to say, not an ArithmeticError raised inside a LiveView render.
    test "an unconfigured window cost has no honest answer, and says nothing rather than guessing" do
      assert Capacity.windows(1.0, 0) == nil
      assert Capacity.windows(1.0, 0.0) == nil
      assert Capacity.windows(1.0, -1) == nil
      assert Capacity.windows(1.0, nil) == nil
    end

    test "no cost is no figure" do
      assert Capacity.windows(nil, 4.0) == nil
      assert Capacity.windows(nil, 0) == nil
    end

    test "a zero cost is a real measurement of zero, not a missing one" do
      assert Capacity.windows(0, 4.0) == 0.0
    end
  end

  describe "format/1" do
    # The three examples are the moduledoc's own and the note's headline unit. Two significant
    # figures is the contract: `1.4`, not `1`; `0.67`, not `0.7`; `12`, not `12.0`.
    test "states a window count to two significant figures" do
      assert Capacity.format(1.4) == "1.4 windows"
      assert Capacity.format(0.67) == "0.67 windows"
      assert Capacity.format(12.0) == "12 windows"
    end

    test "keeps two figures however small the quantity" do
      assert Capacity.format(0.067) == "0.067 windows"
      assert Capacity.format(0.0067) == "0.0067 windows"
    end

    # "Returns nil when there is nothing truthful to say, so callers render nothing rather than a
    # zero that looks like a measurement." A `nil` in must not become a `0 windows` out.
    test "nothing to say is nothing drawn" do
      assert Capacity.format(nil) == nil
    end

    test "a measured zero is drawn, and is not the same as nothing" do
      assert Capacity.format(0) == "0 windows"
      refute Capacity.format(nil) == Capacity.format(0)
    end

    test "a negative quantity is not a quantity" do
      assert Capacity.format(-1.0) == nil
    end
  end

  describe "ticks/2" do
    # Twenty ticks, one per five percent — the gauge `docs/design/capacity.md` § Two objects
    # describes, drawn only once the provider has supplied a utilization figure at all.
    test "one tick per five percent of the window" do
      assert Capacity.ticks(0.0) == 0
      assert Capacity.ticks(0.05) == 1
      assert Capacity.ticks(0.5) == 10
      assert Capacity.ticks(1.0) == 20
    end

    test "the sample from the dev node draws nineteen of twenty" do
      # `utilization: 0.96` is the figure in the note's recorded `rate_limit_event`.
      assert Capacity.ticks(0.96) == 19
    end

    # A provider figure above 1.0 is not impossible — overage exists — and a gauge cannot draw
    # more ticks than it has. Neither end may escape the gauge.
    test "cannot draw more ticks than the gauge has, or fewer than none" do
      assert Capacity.ticks(1.2) == 20
      assert Capacity.ticks(99.0) == 20
      assert Capacity.ticks(-0.1) == 0
      assert Capacity.ticks(-99.0) == 0
    end

    test "the tick count is the caller's to choose, for the compressed top bar" do
      # The note compresses the same gauge to ten ticks in the top bar.
      assert Capacity.ticks(0.5, 10) == 5
      assert Capacity.ticks(1.0, 10) == 10
      assert Capacity.ticks(2.0, 10) == 10
    end
  end
end
