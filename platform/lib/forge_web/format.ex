defmodule ForgeWeb.Format do
  @moduledoc """
  Figures the operator reads: relative ages and capacity.

  The waiting figure is the queue's sort key made visible — it is set large and right-aligned so
  the age of the whole queue reads down one edge. It was already loaded and discarded before this
  existed. See `docs/design/ui.md`.
  """

  alias ForgeCore.Capacity

  @doc """
  A compact relative age: `4m`, `19h`, `3d`. Seconds are `now`, because a queue item that just
  arrived does not need a number ticking on it.
  """
  @spec ago(DateTime.t() | NaiveDateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def ago(at, now \\ DateTime.utc_now())
  def ago(nil, _now), do: nil

  def ago(%NaiveDateTime{} = at, now),
    do: at |> DateTime.from_naive!("Etc/UTC") |> ago(now)

  def ago(%DateTime{} = at, now) do
    case DateTime.diff(now, at, :second) do
      s when s < 60 -> "now"
      s when s < 3_600 -> "#{div(s, 60)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h"
      s -> "#{div(s, 86_400)}d"
    end
  end

  @doc """
  A cost rendered as the capacity it consumed, or `nil` when the calibration constant is not
  configured. Dollars do not appear on an operator surface.
  """
  @spec windows(number() | Decimal.t() | nil) :: String.t() | nil
  def windows(%Decimal{} = cost), do: cost |> Decimal.to_float() |> windows()

  def windows(cost) do
    cost |> Capacity.windows(window_cost()) |> Capacity.format()
  end

  @doc "The configured cost of one five-hour window. See `docs/design/capacity.md`."
  @spec window_cost() :: number()
  def window_cost do
    :forge |> Application.get_env(:capacity, []) |> Keyword.get(:window_cost_usd, 0)
  end
end
