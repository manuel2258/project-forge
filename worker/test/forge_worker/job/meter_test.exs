defmodule ForgeWorker.Job.MeterTest do
  use ExUnit.Case, async: true

  alias ForgeWorker.Job.Meter

  defp call(meter, id, tokens), do: Meter.observe(meter, %{message_id: id, tokens: tokens})

  test "a call repeated across lines is counted once" do
    meter =
      Meter.new()
      |> call("a", %{input: 100, output: 10})
      |> call("a", %{input: 100, output: 10})
      |> call("a", %{input: 100, output: 10})

    assert Meter.tokens(meter) == %{input: 100, cache_write: 0, cache_read: 0, output: 10}
    assert Meter.usage(meter) == 150
  end

  test "a repeated call adds only its increase, and never takes tokens back" do
    meter =
      Meter.new()
      |> call("a", %{input: 100, output: 10})
      |> call("a", %{input: 100, output: 40})
      |> call("a", %{input: 50, output: 20})

    assert Meter.tokens(meter) == %{input: 100, cache_write: 0, cache_read: 0, output: 40}
  end

  # Taking the lesser line's figure as the new one made the total dip, and the next line that
  # repeated the call at its full size counted the difference again. Only the total *between* the
  # lines shows it: the last one lands on the same number either way.
  test "a shorter repeat leaves the total where it was, and a later full one adds nothing" do
    meter = Meter.new() |> call("a", %{output: 40}) |> call("a", %{output: 20})
    assert Meter.tokens(meter).output == 40

    meter = call(meter, "a", %{output: 40})
    assert Meter.tokens(meter).output == 40
    assert Meter.usage(meter) == 200
  end

  test "different calls add, whoever made them" do
    meter =
      Meter.new()
      |> call("a", %{input: 100})
      |> call("b", %{input: 200, cache_read: 1000})

    assert Meter.tokens(meter) == %{input: 300, cache_write: 0, cache_read: 1000, output: 0}
    assert Meter.usage(meter) == 400
  end

  test "a payload that names no call counts for nothing" do
    assert Meter.new() |> Meter.observe(%{tokens: %{input: 5}}) |> Meter.usage() == 0

    assert Meter.new() |> Meter.observe(%{message_id: nil, tokens: %{input: 5}}) |> Meter.usage() ==
             0
  end

  test "over? is past the budget, not at it, and never without one" do
    meter = call(Meter.new(), "a", %{input: 1000})

    refute Meter.over?(meter, nil)
    refute Meter.over?(meter, 1001)
    refute Meter.over?(meter, 1000)
    assert Meter.over?(meter, 999)
    refute Meter.over?(Meter.new(), 0)
  end
end
