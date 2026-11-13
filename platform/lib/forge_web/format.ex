defmodule ForgeWeb.Format do
  @moduledoc """
  Figures the operator reads: relative ages and capacity.

  The waiting figure is the queue's sort key made visible — it is set large and right-aligned so
  the age of the whole queue reads down one edge. It was already loaded and discarded before this
  existed. See `docs/design/ui.md`.
  """

  alias ForgeCore.Capacity

  @doc """
  How a version's or an event's author reads when it was not a person or the engine: `API · name`
  for a project token, named as it was when it wrote, so a token revoked since reads the same. Nil
  for everyone else, whose name no page draws today.
  """
  @spec author(map() | nil) :: String.t() | nil
  def author(%{"kind" => "api", "name" => name}) when is_binary(name), do: "API · " <> name
  def author(_actor), do: nil

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
  How long until `at`, compactly: `12m`, `1h 12m`, `2d 3h` — the countdown a window's reset is
  drawn with (`docs/design/capacity.md` § Two objects). A moment already here is `now`.
  """
  @spec until(DateTime.t(), DateTime.t()) :: String.t()
  def until(%DateTime{} = at, now \\ DateTime.utc_now()) do
    case DateTime.diff(at, now, :second) do
      s when s < 60 -> "now"
      s when s < 3_600 -> "#{div(s, 60)}m"
      s when s < 86_400 -> "#{div(s, 3_600)}h #{div(rem(s, 3_600), 60)}m"
      s -> "#{div(s, 86_400)}d #{div(rem(s, 86_400), 3_600)}h"
    end
  end

  @doc """
  Whether a worker build is the one this platform ships with, in the words both the workers and
  the templates pages use: `current` or `other build` — never "older", because a build is a hash
  with no order (`docs/design/ui.md` § The workers page). Nil when the platform knows no build of
  its own, which is a node built outside Nix, and then nothing is drawn.
  """
  @spec build_hint(String.t() | nil, String.t() | nil) :: String.t() | nil
  def build_hint(_build, nil), do: nil
  def build_hint(current, current), do: "current"
  def build_hint(_build, _current), do: "other build"

  @doc """
  How long a job ran, from its start to its finish: `42s`, `3m 5s`, `1h 12m`; `running` for one
  that has not finished and `—` for one that never started. One definition for the job page and
  a command's timeline row, which say the same thing about the same row.
  """
  @spec duration(%{started_at: DateTime.t() | nil, finished_at: DateTime.t() | nil}) :: String.t()
  def duration(%{started_at: nil}), do: "—"
  def duration(%{finished_at: nil}), do: "running"

  def duration(%{started_at: started, finished_at: finished}) do
    case DateTime.diff(finished, started, :second) do
      s when s < 60 -> "#{s}s"
      s when s < 3_600 -> "#{div(s, 60)}m #{rem(s, 60)}s"
      s -> "#{div(s, 3_600)}h #{div(rem(s, 3_600), 60)}m"
    end
  end

  @doc """
  Usage in weighted tokens rendered as the capacity it consumed, or `nil` when the calibration
  constant is not configured. Dollars do not appear on an operator surface.
  """
  @spec windows(number() | nil) :: String.t() | nil
  def windows(tokens) do
    tokens |> Capacity.windows(window_tokens()) |> Capacity.format()
  end

  @doc """
  The exact weighted tokens behind a figure, for a title: `1,234,567 weighted tokens`. The windows
  are an estimate on a placeholder constant; this is what was counted.
  """
  @spec exact(integer() | nil) :: String.t() | nil
  def exact(nil), do: nil

  def exact(tokens) when is_integer(tokens) do
    digits =
      tokens
      |> Integer.to_string()
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")

    "#{String.reverse(digits)} weighted tokens"
  end

  @kind_labels [
    input: "fresh input",
    cache_write: "cache write",
    cache_read: "cache read",
    output: "output"
  ]

  @doc """
  A run's or a day's tokens by kind, `120k fresh input · 0 cache write · 3M cache read · 90k
  output`, or `nil` when none were counted (a converted run has none: only its dollars were kept).
  Takes the map as stored (string keys) or as summed (atoms).
  """
  @spec kinds(map() | nil) :: String.t() | nil
  def kinds(tokens) when is_map(tokens) do
    counted = ForgeCore.Usage.normalize(tokens)

    if Enum.any?(counted, fn {_kind, n} -> n > 0 end) do
      Enum.map_join(@kind_labels, " · ", fn {kind, label} ->
        "#{ForgeCore.Usage.format(Map.fetch!(counted, kind))} #{label}"
      end)
    end
  end

  def kinds(_none), do: nil

  @doc "The configured weighted tokens of one five-hour window. See `docs/design/capacity.md`."
  @spec window_tokens() :: number()
  def window_tokens do
    :forge |> Application.get_env(:capacity, []) |> Keyword.get(:window_tokens, 0)
  end
end
