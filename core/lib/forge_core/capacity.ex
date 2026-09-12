defmodule ForgeCore.Capacity do
  @moduledoc """
  Consumption as consumed capacity rather than money.

  One unit is one percent of a five-hour window, and quantities are stated in **windows** to two
  significant figures. This is the unit that stays true when a ticket's work spans four windows
  and a week, which a percentage cannot.

  The conversion from what the harness reports (a client-side cost estimate) to windows needs
  one calibration constant, the cost of a whole window. The provider reports window *utilization*
  but never a per-job share, so this is the only bridge. It is uncalibrated until dogfooding sets
  it — see `docs/design/capacity.md`. Nothing schedules, caps or refuses on it; it is display only.
  """

  @doc """
  Windows consumed by `cost`, given the cost of one whole window.

  A window cost of zero or less means the constant is not configured, in which case there is no
  honest conversion and the answer is `nil` rather than a guess.
  """
  @spec windows(number() | nil, number()) :: float() | nil
  def windows(nil, _window_cost), do: nil
  def windows(_cost, window_cost) when not is_number(window_cost) or window_cost <= 0, do: nil
  def windows(cost, window_cost) when is_number(cost), do: cost / window_cost

  @doc """
  A window count at two significant figures: `1.4 windows`, `0.67 windows`, `12 windows`.

  Returns `nil` when there is nothing truthful to say, so callers render nothing rather than a
  zero that looks like a measurement.
  """
  @spec format(float() | nil) :: String.t() | nil
  def format(nil), do: nil
  def format(windows) when windows == 0, do: "0 windows"

  def format(windows) when is_number(windows) and windows > 0 do
    decimals = max(0, 1 - floor(:math.log10(windows)))
    "#{:erlang.float_to_binary(windows / 1, decimals: decimals)} windows"
  end

  def format(_windows), do: nil

  @doc """
  A percentage of the current window, as the provider reports it, drawn as a count of ticks.

  Twenty ticks, one per five percent. The caller decides whether there is a utilization figure
  to draw at all: below the provider's warning threshold there is none, and inventing one would
  be worse than drawing nothing.
  """
  @spec ticks(float(), pos_integer()) :: non_neg_integer()
  def ticks(utilization, total \\ 20) when is_number(utilization) do
    utilization |> Kernel.*(total) |> round() |> min(total) |> max(0)
  end
end
