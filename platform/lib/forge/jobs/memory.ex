defmodule Forge.Jobs.Memory do
  @moduledoc """
  Whether memory was a job's trouble, and the words for it (`docs/design/capacity.md` § Memory,
  which a job holds rather than spends). One place, so the header, the timeline and a
  conversation's now line cannot disagree.

  Read from the job's events: its `job.harness.memory` events (`docs/design/claude-code-events.md`
  § Memory), and the `memory` a run or a turn ended with — in a `job.finished`'s harness summary
  and on a `chat.turn`. **The worker wrote every figure**, so one that is not a whole number of
  bytes is not a figure: it is left out, never raised on — a page that cannot mount because a
  machine sent a string is a page nobody can read the job on.
  """

  alias ForgeCore.Workflow.Resources

  @typedoc """
  What memory did to a job, at its worst: a process killed for it, the job thrashing at its
  ceiling, or only reaching it — with every OOM kill it counted, the highest peak and its ceiling.
  """
  @type trouble :: %{
          what: :oom_kill | :pressure | :ceiling,
          oom_kills: non_neg_integer(),
          peak: non_neg_integer() | nil,
          ceiling: pos_integer() | nil
        }

  @whats %{"oom_kill" => :oom_kill, "pressure" => :pressure, "ceiling" => :ceiling}

  @doc """
  The job's memory trouble from its events, or nil when there was none — which is every job whose
  memory was fine, and every job on a machine with nothing to read (`Slice.Direct`). A job is in
  trouble when a memory event says so, or when a run or a turn ended having counted an OOM kill no
  event reported.
  """
  @spec trouble([map()]) :: trouble() | nil
  def trouble(events) do
    readings = Enum.flat_map(events, &readings/1)
    kills = readings |> Enum.map(fn {_what, figures} -> count(figures["oom_kills"]) end)
    kills = Enum.max(kills, fn -> 0 end)
    said = MapSet.new(readings, fn {what, _figures} -> what end)

    case what(kills, said) do
      nil ->
        nil

      what ->
        figures = Enum.map(readings, &elem(&1, 1))

        %{
          what: what,
          oom_kills: kills,
          peak: figures |> Enum.map(&bytes(&1["peak"])) |> Enum.reject(&is_nil/1) |> highest(),
          # The latest: which one is an equivalent mutant, since a job's ceiling is its slice's
          # and does not change between its readings.
          ceiling:
            figures |> Enum.map(&ceiling(&1["ceiling"])) |> Enum.reject(&is_nil/1) |> List.last()
        }
    end
  end

  defp highest([]), do: nil
  defp highest(values), do: Enum.max(values)

  # **Worst first.** A process killed outranks thrashing, and thrashing outranks only having
  # reached the ceiling — which a build that just fits does on every run.
  defp what(kills, _said) when kills > 0, do: :oom_kill

  defp what(_kills, said),
    do: Enum.find([:pressure, :ceiling], &MapSet.member?(said, &1))

  # A memory event is a kind and its figures; what a run or a turn ended with is figures alone.
  defp readings(%{type: "job.harness.memory", payload: %{} = payload}),
    do: [{@whats[payload["what"]], payload}]

  defp readings(%{type: "job.finished", payload: %{"harness" => %{"memory" => %{} = memory}}}),
    do: [{nil, memory}]

  defp readings(%{type: "chat.turn", payload: %{"memory" => %{} = memory}}), do: [{nil, memory}]
  defp readings(_event), do: []

  @doc """
  The header's line: *2 OOM kills · peak 2.0 GiB of 2 GiB*, *thrashing at its ceiling · peak …*,
  or *reached its ceiling · peak …*.
  """
  @spec words(trouble()) :: String.t()
  def words(%{what: what} = trouble), do: join([headline(what, trouble), figures(trouble)])

  defp headline(:oom_kill, trouble), do: kills(trouble.oom_kills)
  defp headline(:pressure, _trouble), do: "thrashing at its ceiling"
  defp headline(:ceiling, _trouble), do: "reached its ceiling"

  @doc """
  One memory event as a sentence — its row in the timeline (`Forge.Events.summary/1`) and a
  conversation's now line: *a process was killed for memory (1 OOM kill · peak 2.0 GiB of 2 GiB)*.
  """
  @spec sentence(map()) :: String.t()
  def sentence(payload) do
    figures = figures(%{peak: bytes(payload["peak"]), ceiling: ceiling(payload["ceiling"])})

    case payload["what"] do
      "oom_kill" ->
        "a process was killed for memory (#{join([kills(count(payload["oom_kills"])), figures])})"

      "ceiling" ->
        "reached its memory ceiling" <> parenthesised(figures)

      "pressure" ->
        "thrashing at its memory ceiling" <>
          parenthesised(join([pressure(payload["pressure"]), figures]))

      other ->
        "memory: #{if is_binary(other), do: String.slice(other, 0, 40), else: "?"}" <>
          parenthesised(figures)
    end
  end

  @doc """
  A `starting` event's memory, when the worker could read it: what the job holds against its
  ceiling, and the pressure when there is any — so a harness that has not started says whether
  memory is why (`docs/design/claude-code-events.md` § Memory). Nil with nothing read.
  """
  @spec snapshot(term()) :: String.t() | nil
  def snapshot(%{} = memory) do
    held =
      figures(%{peak: bytes(memory["current"]), ceiling: ceiling(memory["ceiling"])}, "memory")

    pressure = if positive?(memory["pressure"]), do: pressure(memory["pressure"])
    kills = if count(memory["oom_kills"]) > 0, do: kills(count(memory["oom_kills"]))

    case join([held, pressure, kills]) do
      "" -> nil
      said -> said
    end
  end

  def snapshot(_none), do: nil

  defp figures(figures, label \\ "peak")

  defp figures(%{peak: peak, ceiling: ceiling}, label)
       when is_integer(peak) and is_integer(ceiling),
       do: "#{label} #{Resources.gib(peak)} of #{Resources.size(ceiling)}"

  defp figures(%{peak: peak}, label) when is_integer(peak), do: "#{label} #{Resources.gib(peak)}"
  defp figures(_figures, _label), do: nil

  defp kills(1), do: "1 OOM kill"
  defp kills(n), do: "#{n} OOM kills"

  defp pressure(value) when is_number(value),
    do: "full pressure #{:erlang.float_to_binary(value / 1, decimals: 1)}%"

  defp pressure(_value), do: nil

  defp positive?(value), do: is_number(value) and value > 0

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp parenthesised(nil), do: ""
  defp parenthesised(""), do: ""
  defp parenthesised(said), do: " (#{said})"

  # A size is a whole number of bytes, and a ceiling a positive one (`Resources.size/1`).
  defp bytes(value) when is_integer(value) and value >= 0, do: value
  defp bytes(_value), do: nil

  defp ceiling(value) when is_integer(value) and value > 0, do: value
  defp ceiling(_value), do: nil

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: 0
end
