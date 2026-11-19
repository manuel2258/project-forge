defmodule ForgeCore.CronTest do
  @moduledoc """
  `ForgeCore.Cron`: the dialect it accepts and refuses, the day rule, and `next_after/3` and
  `latest_at_or_before/3` against a brute-force walk over minutes, which is what catches an
  off-by-one at the edge of a day, a month or a year.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Cron

  defp cron!(line) do
    {:ok, cron} = Cron.parse(line)
    cron
  end

  describe "parse/1 accepts" do
    for line <- [
          "* * * * *",
          "0 6 * * MON",
          "*/15 * * * *",
          "0,30 9-17 * * 1-5",
          "0 0 1 JAN,jul *",
          "0 0 * * 7",
          "0 0 * * 0",
          "0 0 29 2 *",
          "10-50/10 0 1-7 * 1",
          "  0   6 *   * sun "
        ] do
      test "#{inspect(line)}" do
        assert {:ok, %Cron{}} = Cron.parse(unquote(line))
      end
    end

    test "0 and 7 are both Sunday, and a range through 7 wraps into it" do
      assert cron!("0 0 * * 7").dows == MapSet.new([0])
      assert cron!("0 0 * * 5-7").dows == MapSet.new([5, 6, 0])
      assert cron!("0 0 * * */2").dows == MapSet.new([0, 2, 4, 6])
    end

    test "a range of one value is that value" do
      assert cron!("5-5 * * * *").minutes == MapSet.new([5])
    end

    test "names are read in any case" do
      assert cron!("0 0 * jan-mar mon-wed").months == MapSet.new([1, 2, 3])
      assert cron!("0 0 * JAN-MAR MON-WED").dows == MapSet.new([1, 2, 3])
    end

    test "the source is normalised to single spaces" do
      assert cron!("  0   6 *   * sun ").source == "0 6 * * sun"
    end
  end

  describe "parse/1 refuses, naming the field" do
    for {line, fragment} <- [
          {"", "five fields"},
          {"* * * *", "not 4"},
          {"* * * * * *", "not 6"},
          {"60 * * * *", "minute: 60 is out of range 0-59"},
          {"* 24 * * *", "hour: 24 is out of range 0-23"},
          {"* * 0 * *", "day of month: 0 is out of range 1-31"},
          {"* * 32 * *", "day of month: 32 is out of range"},
          {"* * * 13 *", "month: 13 is out of range 1-12"},
          {"* * * * 8", "day of week: 8 is out of range 0-7"},
          {"*/0 * * * *", "step of 0"},
          {"*/x * * * *", "step that is not a whole number"},
          {"*/-1 * * * *", "step that is not a whole number"},
          {"1/2/3 * * * *", "more than one /"},
          {"5/15 * * * *", "no range to step through"},
          {"30-10 * * * *", "runs backwards"},
          {"* * * * SAT-SUN", "runs backwards"},
          {"@weekly * * * *", "is not a number"},
          {"* * * FOO *", "is not a number or a name"},
          {"* * L * *", "is not a number"},
          {"* * * * 1#2", "is not a number"},
          {"? * * * *", "is not a number"},
          {"1-2-3 * * * *", "not a value or a range"},
          {"0 0 30 2 *", "never comes due"},
          {"0 0 31 4,6,9,11 *", "never comes due"}
        ] do
      test "#{inspect(line)}" do
        assert {:error, message} = Cron.parse(unquote(line))
        assert message =~ unquote(fragment)
      end
    end

    test "a value that is not text" do
      assert {:error, "must be a string of five fields"} = Cron.parse(nil)
      assert {:error, _} = Cron.parse(5)
    end

    test "a leap day is a date that exists, even on a rare weekday" do
      assert {:ok, cron} = Cron.parse("0 0 29 2 6")
      assert Cron.next_after(cron, ~U[2026-11-19 00:00:00Z]) == ~U[2048-02-29 00:00:00Z]
    end
  end

  describe "both day fields restricted: a day must match both" do
    test "0 9 1-7 * 1 is the first Monday of the month" do
      cron = cron!("0 9 1-7 * 1")
      assert Cron.next_after(cron, ~U[2026-11-01 00:00:00Z]) == ~U[2026-11-02 09:00:00Z]
      assert Cron.next_after(cron, ~U[2026-11-02 09:00:00Z]) == ~U[2026-12-07 09:00:00Z]
    end

    test "only one restricted is that one alone" do
      assert Cron.next_after(cron!("0 9 15 * *"), ~U[2026-11-16 00:00:00Z]) ==
               ~U[2026-12-15 09:00:00Z]

      assert Cron.next_after(cron!("0 9 * * 3"), ~U[2026-11-19 09:00:00Z]) ==
               ~U[2026-11-25 09:00:00Z]
    end
  end

  describe "next_after/3" do
    test "is strictly after, and the minute resolution holds" do
      cron = cron!("0 6 * * *")
      assert Cron.next_after(cron, ~U[2026-11-19 05:59:59Z]) == ~U[2026-11-19 06:00:00Z]
      assert Cron.next_after(cron, ~U[2026-11-19 06:00:00Z]) == ~U[2026-11-20 06:00:00Z]
      assert Cron.next_after(cron, ~U[2026-11-19 06:00:01Z]) == ~U[2026-11-20 06:00:00Z]
    end

    test "crosses a month and a year" do
      assert Cron.next_after(cron!("59 23 31 12 *"), ~U[2026-12-31 23:59:00Z]) ==
               ~U[2027-12-31 23:59:00Z]

      assert Cron.next_after(cron!("0 0 1 * *"), ~U[2026-12-31 23:59:59Z]) ==
               ~U[2027-01-01 00:00:00Z]
    end

    test "February 29 waits for a leap year" do
      assert Cron.next_after(cron!("0 0 29 2 *"), ~U[2026-03-01 00:00:00Z]) ==
               ~U[2028-02-29 00:00:00Z]
    end

    test "is nil beyond its horizon" do
      assert Cron.next_after(cron!("0 0 29 2 6"), ~U[2026-11-19 00:00:00Z], 5) == nil
    end
  end

  describe "latest_at_or_before/3" do
    test "is at or before, and the minute resolution holds" do
      cron = cron!("0 6 * * *")
      assert Cron.latest_at_or_before(cron, ~U[2026-11-19 06:00:00Z]) == ~U[2026-11-19 06:00:00Z]
      assert Cron.latest_at_or_before(cron, ~U[2026-11-19 05:59:59Z]) == ~U[2026-11-18 06:00:00Z]
      assert Cron.latest_at_or_before(cron, ~U[2026-11-19 23:00:00Z]) == ~U[2026-11-19 06:00:00Z]
    end

    test "crosses a month and a year" do
      assert Cron.latest_at_or_before(cron!("0 0 31 12 *"), ~U[2027-01-05 00:00:00Z]) ==
               ~U[2026-12-31 00:00:00Z]

      assert Cron.latest_at_or_before(cron!("0 0 31 * *"), ~U[2026-12-01 00:00:00Z]) ==
               ~U[2026-10-31 00:00:00Z]
    end

    test "is nil beyond its horizon" do
      assert Cron.latest_at_or_before(cron!("0 0 29 2 6"), ~U[2026-11-19 00:00:00Z], 5) == nil
    end
  end

  describe "against a walk over every minute" do
    @lines [
      "* * * * *",
      "*/7 * * * *",
      "0 * * * *",
      "59 23 * * *",
      "0 0 * * *",
      "0 6 * * MON",
      "30 2 1,15 * *",
      "0 9 1-7 * 1",
      "15 3 29 2 *",
      "0 0 31 * *",
      "0 0 1 1,7 *",
      "5,10 8-9 * * 1-5",
      "0 0 * * 0",
      "45 23 28-31 * *",
      "0 12 * 2 SUN",
      "*/20 */6 10-12 3-5 *",
      "0 0 29 2 *",
      "7 7 7 7 *",
      "0 0 13 * 5",
      "59 23 31 12 *"
    ]

    # Two windows, in unix minutes: thirty-five days over a year end, and eight over the leap day of 2028,
    # so a month, a year and February 29 are each inside one.
    @windows [{~U[2027-12-10 00:00:00Z], 35}, {~U[2028-02-24 00:00:00Z], 8}]

    for line <- @lines do
      test "#{line}" do
        cron = cron!(unquote(line))

        for {from, days} <- @windows do
          start = DateTime.to_unix(from)

          times =
            for n <- 0..(days * 24 * 60),
                at = DateTime.from_unix!(start + n * 60),
                Cron.matches?(cron, at),
                do: start + n * 60

          samples = for n <- 0..(days * 24 * 60)//1499, do: start + n * 60

          for at <- samples do
            dt = DateTime.from_unix!(at)

            expected_next = Enum.find(times, &(&1 > at))
            expected_next = expected_next && DateTime.from_unix!(expected_next)

            if expected_next,
              do: assert(Cron.next_after(cron, dt) == expected_next, "next_after #{dt}")

            expected_latest = times |> Enum.filter(&(&1 <= at)) |> List.last()

            if expected_latest do
              assert Cron.latest_at_or_before(cron, dt) == DateTime.from_unix!(expected_latest),
                     "latest_at_or_before #{dt}"
            end
          end

          for time <- Enum.take_every(times, 5) do
            dt = DateTime.from_unix!(time)
            assert Cron.next_after(cron, DateTime.add(dt, -60)) == dt
            assert Cron.latest_at_or_before(cron, dt) == dt
          end
        end
      end
    end
  end

  describe "describe/1" do
    for {line, words} <- [
          {"0 6 * * MON", "every Monday at 06:00 UTC"},
          {"*/15 * * * *", "every 15 minutes"},
          {"* * * * *", "every minute"},
          {"0 3 * * *", "every day at 03:00 UTC"},
          {"0 9 1-7 * 1", "at 09:00 UTC on a Monday that is day 1-7 of the month"},
          {"0 0 1 JAN,JUL *", "at 00:00 UTC on day 1 of the month in January and July"},
          {"30 2 1,15 * *", "at 02:30 UTC on days 1 and 15 of the month"},
          {"0 6 * * 1-5", "every Monday to Friday at 06:00 UTC"},
          {"0 6 * * MON,WED,FRI", "every Monday, Wednesday and Friday at 06:00 UTC"},
          {"0 6 * * 0", "every Sunday at 06:00 UTC"},
          {"15 * * * *", "every hour at minute 15"},
          {"0 * * * *", "every hour on the hour"},
          {"0,20,45 * * * *", "every hour at minutes 0, 20 and 45"},
          {"0,30 * * * *", "every 30 minutes"},
          {"*/10 * * * 1", "every 10 minutes, every Monday"},
          {"0 6,18 * * *", "every day at 06:00 and 18:00 UTC"},
          {"0,30 9-17 * * *", "every day at minute 0 and 30 of hours 9-17 UTC"},
          {"0 0 * * 5-7", "every Friday to Sunday at 00:00 UTC"},
          {"0 12 * 2 SUN", "every Sunday at 12:00 UTC in February"}
        ] do
      test "#{line}" do
        assert Cron.describe(cron!(unquote(line))) == unquote(words)
      end
    end

    test "every line the walk above covers has a sentence" do
      for line <- ["7 7 7 7 *", "*/20 */6 10-12 3-5 *", "5,10 8-9 * * 1-5", "0 0 13 * 5"] do
        assert is_binary(Cron.describe(cron!(line)))
      end
    end
  end
end
