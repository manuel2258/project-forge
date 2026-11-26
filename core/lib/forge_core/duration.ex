defmodule ForgeCore.Duration do
  @moduledoc """
  The one way a time is written in a workflow and shown to a person: a whole number and one unit
  — `90s`, `20m`, `3h` — or a bare positive number of seconds (`docs/design/workflow-grammar-v1.md`
  § Timeout). One unit only: `1h30m` is `90m`, and a second syntax for the same number is a second
  thing to get wrong.

  A command's `timeout` and an agent state's both read through `parse/2`; they differ only in how
  long a time they accept.
  """

  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000}

  # A thousand thousand hours, about 114 years. **A technical bound, not a policy**: the runtime's
  # timers raise past about 9.2e12 ms (about 292 years, measured on OTP 28), and a date that far
  # out breaks the git token's `expires_at`. Nothing a workflow writes needs to be near it; it
  # only keeps `99999999999h` from passing the grammar and failing out of sight later.
  @longest_ms 1_000_000 * 3_600_000

  @doc "The longest time forge will time: `1000000h`, a technical bound and not a limit of policy."
  @spec longest_ms() :: pos_integer()
  def longest_ms, do: @longest_ms

  @doc """
  Parses a duration into milliseconds, at most `max_ms`.

  `:error` is a value that is not a duration (malformed, zero, negative); `:too_long` is one that
  is, but past `max_ms`, so a caller can say which.
  """
  @spec parse(term(), pos_integer()) :: {:ok, pos_integer()} | :error | :too_long
  def parse(value, max_ms) when is_integer(value) and value > 0, do: within(value * 1_000, max_ms)

  def parse(value, max_ms) when is_binary(value) do
    case Regex.run(~r/^([0-9]+)([smh])$/, String.trim(value)) do
      [_all, count, unit] ->
        case String.to_integer(count) do
          0 -> :error
          n -> within(n * Map.fetch!(@units, unit), max_ms)
        end

      nil ->
        :error
    end
  end

  def parse(_value, _max_ms), do: :error

  @doc """
  Writes `ms` in the largest unit that divides it exactly: `2h`, `90m`, `45s`, so `1000h` stays
  `1000h` and is never turned into days. A figure that is not a whole second is written in
  seconds, rounded up, because nothing here is shorter than one.
  """
  @spec format(pos_integer()) :: String.t()
  def format(ms) when is_integer(ms) and ms > 0 do
    cond do
      rem(ms, 3_600_000) == 0 -> "#{div(ms, 3_600_000)}h"
      rem(ms, 60_000) == 0 -> "#{div(ms, 60_000)}m"
      true -> "#{div(ms + 999, 1_000)}s"
    end
  end

  defp within(ms, max_ms) when ms <= max_ms, do: {:ok, ms}
  defp within(_ms, _max_ms), do: :too_long
end
