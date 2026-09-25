defmodule ForgeWeb.FormatTest do
  @moduledoc """
  The relative age on every queue row and every chat row.

  It is one `case` of four clauses and the unit is only implied by the letter after the number, so
  a clause that divides by the wrong constant produces a figure that is still short, still plausible
  and still monotonic — `90m` for an hour and a half reads as fine, and so does `1h` for ninety
  seconds. Nothing downstream can catch it: the queue's sort key is the timestamp, not this. So
  each boundary is pinned here with a duration whose answer is different in every clause.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.Format

  defp ago(seconds) do
    now = ~U[2026-09-15 12:00:00Z]
    Format.ago(DateTime.add(now, -seconds, :second), now)
  end

  # `docs/design/ui.md`: the waiting figure is the queue's sort key made visible, set large and
  # right-aligned so the age of the whole queue reads down one edge. A column of figures in
  # inconsistent units is worse than no column.
  test "each unit covers its own span" do
    # Seconds are "now", because a queue item that has just arrived does not need a number
    # ticking on it.
    assert ago(0) == "now"
    assert ago(59) == "now"

    assert ago(60) == "1m"
    assert ago(90) == "1m"
    assert ago(59 * 60) == "59m"

    assert ago(3_600) == "1h"
    assert ago(90 * 60) == "1h"
    assert ago(23 * 3_600) == "23h"

    assert ago(86_400) == "1d"
    assert ago(30 * 3_600) == "1d"
    assert ago(3 * 86_400) == "3d"
  end

  # `inserted_at` on a schema without a timezone is a `NaiveDateTime`, and every row this figure
  # is drawn on hands it one. Read as anything other than UTC it is hours out.
  test "a naive timestamp is read as UTC" do
    now = ~U[2026-09-15 12:00:00Z]

    assert Format.ago(~N[2026-09-15 09:00:00], now) == "3h"
  end

  # The countdown to a window's reset, `docs/design/capacity.md`'s `1h 12m`. Each span pinned with
  # a duration whose answer differs in every clause, for the reason the moduledoc gives.
  test "a countdown is minutes, then hours and minutes, then days and hours" do
    now = ~U[2026-09-15 12:00:00Z]
    until = &Format.until(DateTime.add(now, &1, :second), now)

    assert until.(-5) == "now"
    assert until.(59) == "now"
    assert until.(60) == "1m"
    assert until.(59 * 60 + 59) == "59m"
    assert until.(3_600) == "1h 0m"
    assert until.(72 * 60) == "1h 12m"
    assert until.(23 * 3_600 + 59 * 60) == "23h 59m"
    assert until.(86_400) == "1d 0h"
    assert until.(2 * 86_400 + 3 * 3_600 + 59) == "2d 3h"
  end

  # A job that never started has no started_at, and the column simply has nothing in it rather
  # than an age counted from the epoch.
  test "nothing is not a time" do
    assert Format.ago(nil, ~U[2026-09-15 12:00:00Z]) == nil
  end
end
