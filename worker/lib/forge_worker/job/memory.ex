defmodule ForgeWorker.Job.Memory do
  @moduledoc """
  What a job's memory readings mean: which of them are worth a `job.harness.memory` event, and
  what the run ends with (`docs/design/claude-code-events.md` § Memory).

  Pure. The slice reads the cgroup (`ForgeWorker.Slice` `memory/1` and `ended/2`) and the runner
  hands each reading here with what came before it, so the rules — one event per OOM kill, one
  the first time the ceiling binds, one per episode of pressure — are tested without a cgroup.

  A reading is what the cgroup said, any of it nil where it could not be read: `ceiling`
  (`memory.max`, nil for `max`), `current`, `peak`, `max_events` and `oom_kills` (`memory.events`'
  `max` and `oom_kill`), and `pressure` (`memory.pressure`'s `full avg10`, a percentage).
  """

  # `full avg10` at or above this, on two samples in a row, is an episode of pressure. A guess —
  # nothing has measured an agent at its ceiling — which the runner takes from the node's
  # `:memory_pressure_full` when it is set (`docs/design/worker-tier.md` § What the slice reads
  # while a job runs).
  @default_pressure 20.0

  defstruct ceiling: nil,
            peak: nil,
            # The OOM kills of the rounds before this one, whose cgroups are gone, and of this one.
            kills_before: 0,
            kills: 0,
            said_ceiling: false,
            above: 0,
            episode: false,
            threshold: @default_pressure

  @type reading :: ForgeWorker.Slice.reading()
  @type t :: %__MODULE__{}

  @doc """
  A watch for one run. `ceiling` is the one the slice was given — what the job asked for, and
  what a person reads its peak against.
  """
  @spec new(pos_integer() | nil, keyword()) :: t()
  def new(ceiling, opts \\ []),
    do: %__MODULE__{
      ceiling: ceiling,
      threshold: Keyword.get(opts, :threshold) || @default_pressure
    }

  @doc """
  A correction round starts. Its process runs in a cgroup of its own whose counters start at
  nought, so what this round counted is kept and the next is counted from zero. The ceiling, once
  said, stays said: that is once per run, not per round.
  """
  @spec new_round(t()) :: t()
  def new_round(%__MODULE__{} = watch) do
    %{watch | kills_before: watch.kills_before + watch.kills, kills: 0, above: 0, episode: false}
  end

  @doc """
  What a reading adds: the watch as it now stands, and the events it is worth, each a
  `job.harness.memory` payload. A nil reading — nothing to read, or nothing yet — adds nothing.
  """
  @spec observe(t(), reading() | nil) :: {t(), [map()]}
  def observe(%__MODULE__{} = watch, nil), do: {watch, []}

  def observe(%__MODULE__{} = watch, reading) do
    watch = %{watch | peak: highest(watch.peak, reading[:peak] || reading[:current])}

    {watch, []}
    |> kills(reading)
    |> ceiling(reading)
    |> pressure(reading)
    |> then(fn {watch, events} -> {watch, Enum.reverse(events)} end)
  end

  # **One event per increase**, however large: its `new_kills` says by how many, and a job whose
  # builds are killed one after another hears of each rather than of the lot at the end.
  defp kills({watch, events}, reading) do
    count = reading[:oom_kills] || 0

    if count > watch.kills do
      new = count - watch.kills
      watch = %{watch | kills: count}
      {watch, [event("oom_kill", watch, reading, %{new_kills: new}) | events]}
    else
      {watch, events}
    end
  end

  # **Once per run.** `max` counts every time the kernel had to reclaim at the ceiling, which is
  # thousands of times a minute for a build that only just fits: the first is news, the rest are
  # the same news.
  defp ceiling({%{said_ceiling: false} = watch, events}, reading) do
    if (reading[:max_events] || 0) > 0 do
      watch = %{watch | said_ceiling: true}
      {watch, [event("ceiling", watch, reading, %{}) | events]}
    else
      {watch, events}
    end
  end

  defp ceiling(acc, _reading), do: acc

  # **Once per episode.** Two samples in a row at or above the threshold start one, and the first
  # below it ends it; one bad sample is not an episode, and a long one is not a line a sample.
  defp pressure({watch, events}, reading) do
    case reading[:pressure] do
      pressure when is_number(pressure) and pressure >= watch.threshold ->
        above = watch.above + 1

        if above >= 2 and not watch.episode do
          watch = %{watch | above: above, episode: true}
          {watch, [event("pressure", watch, reading, %{}) | events]}
        else
          {%{watch | above: above}, events}
        end

      # A reading with no pressure figure says nothing either way, so an episode survives it.
      nil ->
        {watch, events}

      _below ->
        {%{watch | above: 0, episode: false}, events}
    end
  end

  defp event(what, watch, reading, extra) do
    Map.merge(
      %{
        what: what,
        ceiling: watch.ceiling || reading[:ceiling],
        current: reading[:current],
        peak: watch.peak,
        oom_kills: oom_kills(watch),
        pressure: reading[:pressure]
      },
      extra
    )
  end

  @doc """
  The words for a process killed at its memory ceiling — *killed at its 2 GiB memory ceiling* —
  or nil. One rule for a run and a command alike (`docs/design/claude-code-events.md` § Memory):
  the unit's own last reading (`ForgeWorker.Slice` `ended/2`) says its main process ended on
  `SIGKILL` and its cgroup counted an OOM kill. Only that reading says how the main process ended
  — the exit status the port sees is `systemd-run`'s — so under `Slice.Direct` this is never
  said. The signal alone, not the `killed` beside it: a status of `KILL` is only ever `killed`,
  since a SIGKILL dumps no core. The ceiling is named when the slice had one.
  """
  @spec killed(map() | nil, pos_integer() | nil) :: String.t() | nil
  def killed(%{exit: %{status: "KILL"}, memory: %{oom_kills: kills}}, ceiling)
      when is_integer(kills) and kills > 0,
      do: "killed at its #{size(ceiling)}memory ceiling"

  def killed(_ending, _ceiling), do: nil

  defp size(bytes) when is_integer(bytes) and bytes > 0,
    do: ForgeCore.Workflow.Resources.size(bytes) <> " "

  defp size(_none), do: ""

  @doc "Every OOM kill the run has counted, over all its rounds."
  @spec oom_kills(t()) :: non_neg_integer()
  def oom_kills(%__MODULE__{} = watch), do: watch.kills_before + watch.kills

  @doc """
  What the run ends with, for its harness summary: the ceiling, the peak and the OOM kills. String
  keys, because it crosses the channel as JSON. Nil when nothing was ever read, which is every
  run under `Slice.Direct`.
  """
  @spec summary(t()) :: map() | nil
  def summary(%__MODULE__{peak: nil, kills_before: 0, kills: 0}), do: nil

  def summary(%__MODULE__{} = watch),
    do: %{"ceiling" => watch.ceiling, "peak" => watch.peak, "oom_kills" => oom_kills(watch)}

  @doc """
  A reading as a `starting` event carries it, so a harness that has not said it started says
  whether memory is why. Nil for no reading.
  """
  @spec snapshot(reading() | nil) :: map() | nil
  def snapshot(nil), do: nil

  def snapshot(reading) do
    Map.new(
      [:ceiling, :current, :peak, :max_events, :oom_kills, :pressure],
      &{Atom.to_string(&1), reading[&1]}
    )
  end

  defp highest(nil, value), do: value
  defp highest(value, nil), do: value
  defp highest(a, b), do: max(a, b)
end
