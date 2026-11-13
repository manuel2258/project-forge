defmodule ForgeCore.UsageTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Usage

  describe "weigh/1" do
    test "weights each kind: input 1, cache write 1.25, cache read 0.1, output 5" do
      assert Usage.weigh(%{input: 1000}) == 1000
      assert Usage.weigh(%{cache_write: 1000}) == 1250
      assert Usage.weigh(%{cache_read: 1000}) == 100
      assert Usage.weigh(%{output: 1000}) == 5000
    end

    test "rounds once over the sum, half up" do
      # 5 cache reads are 50 hundredths: half a weighted token, rounded up.
      assert Usage.weigh(%{cache_read: 5}) == 1
      assert Usage.weigh(%{cache_read: 4}) == 0
      # Rounded once over the sum, not per kind: three cache reads (30) and one cache write (125)
      # are 155 hundredths, which is 2; rounded per kind they would be 0 and 1.
      assert Usage.weigh(%{cache_read: 3, cache_write: 1}) == 2
    end

    test "an absent kind counts as zero and string keys are read" do
      assert Usage.weigh(%{}) == 0
      assert Usage.weigh(%{"output" => 10, "input" => 5}) == 55
    end

    test "something that is not a count is zero" do
      assert Usage.weigh(%{input: -5, output: "x", cache_read: 1.5}) == 0
    end
  end

  test "add/2 adds kind by kind and returns every kind" do
    assert Usage.add(%{input: 1, output: 2}, %{"input" => 3, cache_read: 4}) ==
             %{input: 4, cache_write: 0, cache_read: 4, output: 2}
  end

  test "normalize/1 keeps the four kinds, drops the rest" do
    assert Usage.normalize(%{"input" => 1, "bogus" => 9}) == %{
             input: 1,
             cache_write: 0,
             cache_read: 0,
             output: 0
           }

    assert Usage.normalize(nil) == Usage.empty()
  end

  test "from_dollars/1 converts at the placeholder rate" do
    assert Usage.per_dollar() == 200_000
    assert Usage.from_dollars(4.0) == 800_000
    assert Usage.from_dollars(421) == 84_200_000
    assert Usage.from_dollars(0.5) == 100_000
  end

  describe "parse/1 and format/1" do
    test "read the notation" do
      assert Usage.parse("800k") == {:ok, 800_000}
      assert Usage.parse("4M") == {:ok, 4_000_000}
      assert Usage.parse("84.2M") == {:ok, 84_200_000}
      assert Usage.parse("12345") == {:ok, 12_345}
      assert Usage.parse(12_345) == {:ok, 12_345}
      assert Usage.parse(" 1.5k ") == {:ok, 1500}
    end

    test "refuse what is not a number of tokens" do
      for bad <- ["", "k", "-5", "4G", "4 M", "abc", nil, 1.5, -1, "4m"] do
        assert {:error, _} = Usage.parse(bad), inspect(bad)
      end
    end

    # `1e308M` raised an ArithmeticError from the multiplication, and a figure past what a `bigint`
    # holds overflowed the insert it was going to.
    test "refuse a figure no column can hold, and do not raise for one" do
      for huge <- ["1e308M", "1e400", "1e20", "1e19k", "2000000000000000", 10_000_000_000_000_000] do
        assert {:error, _} = Usage.parse(huge), inspect(huge)
      end

      # Under the bound before the suffix and over it after: the multiplier is part of the check.
      for scaled <- ["1e13M", "2000000000M", "1e10M", "1000000001000k"] do
        assert {:error, _} = Usage.parse(scaled), inspect(scaled)
      end

      assert Usage.parse("1000000000M") == {:ok, Usage.max()}

      assert Usage.parse("1000000000000000") == {:ok, Usage.max()}
      assert Usage.parse("1e9k") == {:ok, 1_000_000_000_000}
      assert Usage.from_dollars(1.0e308) == Usage.max()
      assert Usage.from_dollars(1.0e300) == Usage.max()
    end

    test "format what parse reads, losing no digit" do
      assert Usage.format(800_000) == "800k"
      assert Usage.format(4_000_000) == "4M"
      assert Usage.format(84_200_000) == "84.2M"
      assert Usage.format(1_500_000) == "1.5M"
      assert Usage.format(12_345) == "12345"
      assert Usage.format(1_234_567) == "1234567"
      assert Usage.format(0) == "0"
    end

    test "format and parse round trip" do
      for n <- [0, 7, 999, 1000, 10_000, 800_000, 1_000_000, 1_100_000, 84_200_000, 1_234_567] do
        assert Usage.parse(Usage.format(n)) == {:ok, n}
      end
    end
  end
end
