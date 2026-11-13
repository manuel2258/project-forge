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
  `ago/2` as a phrase a sentence can carry: `just now` under a minute, else `4m ago`. Every
  "… ago" the pages write is this, so none says `now ago`.
  """
  @spec ago_phrase(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def ago_phrase(at, now \\ DateTime.utc_now()) do
    case ago(at, now) do
      "now" -> "just now"
      age -> age <> " ago"
    end
  end

  @doc """
  How long something has lasted, as a sentence carries it after the word for it — `waiting 4m`,
  `stuck 2h`, `suspended 3d` — and `<1m` under a minute, so that none says `stuck now`. Bare
  `ago/2` is for a cell or a `·`-separated segment of its own, where `now` is the whole of it;
  a point in time inside a sentence is `ago_phrase/2`.
  """
  @spec lasted(DateTime.t() | NaiveDateTime.t(), DateTime.t()) :: String.t()
  def lasted(at, now \\ DateTime.utc_now()) do
    case ago(at, now) do
      "now" -> "<1m"
      age -> age
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
  `until/2` as a phrase a sentence can carry: `in 1h 12m`, and `in under a minute` for anything
  less than a minute off, so that none says `in now`.
  """
  @spec until_phrase(DateTime.t(), DateTime.t()) :: String.t()
  def until_phrase(%DateTime{} = at, now \\ DateTime.utc_now()) do
    case until(at, now) do
      "now" -> "in under a minute"
      left -> "in " <> left
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
  A count with its noun, the noun plural but for one: `1 turn`, `3 turns`, `0 jobs`. Every count
  drawn with a word goes through this, so none says `1 turns` (UX pass, B19).
  """
  @spec counted(integer() | nil, String.t()) :: String.t()
  def counted(1, noun), do: "1 " <> noun
  def counted(n, noun), do: "#{n || 0} #{noun}s"

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
  What something used, as `windows/1` draws it, or nil when it used nothing: a row leaves a zero
  out rather than print `0 windows` beside every job that has not started (UX pass, A11).
  """
  @spec spent(number() | nil) :: String.t() | nil
  def spent(tokens) when is_number(tokens) and tokens > 0, do: windows(tokens)
  def spent(_nothing), do: nil

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
  defdelegate window_tokens, to: Forge.Usage
end
