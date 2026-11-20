defmodule ForgeWorker.Update.State do
  @moduledoc """
  The retry rules of a machine's self-update, **pure**: what is remembered about the build it is
  trying to reach, and whether it may try now (`docs/design/worker-tier.md` § Updating a
  permanent machine, § Retries). `ForgeWorker.Update` keeps this in `state.json` and acts on what
  it says.

  A failed attempt is tried twice more for the same build, 15 minutes and then an hour after the
  failure before it (`ForgeCore.WorkerUpdate.retry_after_ms/1`); after the third the machine stops
  trying that build until the platform's build changes or its owner asks. **The platform's build
  is the identity**: a different one starts again from nothing.
  """

  alias ForgeCore.WorkerUpdate

  @type t :: %{
          target_build: String.t() | nil,
          failures: non_neg_integer(),
          next_at: integer() | nil,
          gave_up: boolean(),
          phase: String.t(),
          last: map() | nil
        }

  @phases ~w(idle working pausing restarting)

  @doc "A machine that has tried nothing."
  @spec new() :: t()
  def new,
    do: %{target_build: nil, failures: 0, next_at: nil, gave_up: false, phase: "idle", last: nil}

  @doc """
  The state as the file left it. Anything that is not what `dump/1` writes is a machine that has
  tried nothing: a corrupt file must cost a retry, never the update.
  """
  @spec load(term()) :: t()
  def load(%{} = raw) do
    %{
      target_build: text(raw["target_build"]),
      failures: count(raw["failures"]),
      next_at: if(is_integer(raw["next_at"]), do: raw["next_at"]),
      gave_up: raw["gave_up"] == true,
      phase: if(raw["phase"] in @phases, do: raw["phase"], else: "idle"),
      last: last(raw["last"])
    }
  end

  def load(_other), do: new()

  @doc "What `load/1` reads."
  @spec dump(t()) :: map()
  def dump(state) do
    %{
      "target_build" => state.target_build,
      "failures" => state.failures,
      "next_at" => state.next_at,
      "gave_up" => state.gave_up,
      "phase" => state.phase,
      "last" => state.last
    }
  end

  defp text(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp text(_other), do: nil

  defp count(value) when is_integer(value) and value >= 0 and value < 1000, do: value
  defp count(_other), do: 0

  defp last(%{"step" => step, "reason" => reason, "at" => at})
       when is_binary(step) and is_binary(reason) and is_integer(at),
       do: %{
         "step" => String.slice(step, 0, 64),
         "reason" => String.slice(reason, 0, 500),
         "at" => at
       }

  defp last(_other), do: nil

  @doc """
  Remembers which build the platform wants. **A different build forgets every failure**: three
  failures against 0.22.0 say nothing about 0.23.0.
  """
  @spec for_target(t(), String.t() | nil) :: t()
  def for_target(%{target_build: build} = state, build), do: state
  def for_target(state, build), do: %{new() | target_build: build, phase: state.phase}

  @doc "The owner asked: whatever stopped the machine trying that build no longer does."
  @spec requested(t()) :: t()
  def requested(state), do: %{state | failures: 0, next_at: nil, gave_up: false}

  @doc """
  May it try now? `:start`, `:idle` (nothing to do, or nothing it may do), or `{:wait, at}` — a
  retry is scheduled for a later moment, in milliseconds since the epoch.

  `automatic` is whether the platform's latest word was a target without anyone pressing a button:
  with the owner's switch off the platform sends a target only for *Update now*, and **a failed
  attempt of that kind is not retried by itself**.
  """
  @spec decide(t(), %{
          build: String.t() | nil,
          own: String.t() | nil,
          now: integer(),
          automatic: boolean(),
          requested: boolean()
        }) ::
          :start | :idle | {:wait, integer()}
  def decide(_state, %{build: nil}), do: :idle
  def decide(_state, %{build: build, own: build}), do: :idle
  def decide(_state, %{requested: true}), do: :start
  def decide(_state, %{automatic: false}), do: :idle
  def decide(%{gave_up: true}, _context), do: :idle
  def decide(%{next_at: at}, %{now: now}) when is_integer(at) and at > now, do: {:wait, at}
  def decide(_state, _context), do: :start

  @doc "An attempt began."
  @spec started(t()) :: t()
  def started(state), do: %{state | phase: "working", next_at: nil}

  @doc "The attempt reached a step that cannot be undone by starting over: work is paused."
  @spec phase(t(), String.t()) :: t()
  def phase(state, phase) when phase in @phases, do: %{state | phase: phase}

  @doc """
  An attempt failed at `step`, for `reason`, at `now`. Returns the new state and what happens
  next: `{:retry, at}` or `:gave_up`.
  """
  @spec failure(t(), String.t(), String.t(), integer()) :: {t(), {:retry, integer()} | :gave_up}
  def failure(state, step, reason, now) do
    failures = state.failures + 1
    last = %{"step" => step, "reason" => String.slice(reason, 0, 500), "at" => now}

    case WorkerUpdate.retry_after_ms(failures) do
      nil ->
        {%{state | failures: failures, gave_up: true, next_at: nil, phase: "idle", last: last},
         :gave_up}

      delay ->
        at = now + delay
        {%{state | failures: failures, next_at: at, phase: "idle", last: last}, {:retry, at}}
    end
  end

  @doc """
  The machine came back with an attempt unfinished and nothing to say what happened — the worker
  restarted while pausing — which is a failure like any other.
  """
  @spec interrupted(t(), integer()) :: {t(), {:retry, integer()} | :gave_up} | :nothing
  def interrupted(%{phase: "idle"}, _now), do: :nothing

  def interrupted(state, now),
    do: failure(state, state.phase, "the worker stopped while it was updating", now)

  @doc "The build was reached: nothing remembered about trying."
  @spec reached(t()) :: t()
  def reached(_state), do: new()
end
