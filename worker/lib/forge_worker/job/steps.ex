defmodule ForgeWorker.Job.Steps do
  @moduledoc """
  Times the steps of a command's run on this machine (`ForgeCore.CommandSteps`,
  `docs/design/worker-tier.md` § Looking into a copy, ticket 84).

  One Agent per command, started by the link when the job's task starts, which is the origin of
  every time reported: a step's `at` is the wall clock at which it began, and `finish/1`'s total
  runs from the origin to the moment it is called, with `other` being what no step covers, so the
  steps add up to the total by construction.

  **A step may be timed in several pieces** — the fetch is a branch fetch and then the default
  branch's; the reset is a checkout and then the detach — and its duration is the sum of them, `at`
  that of the first. **A step that did not happen is `skip/3`ped and never timed**, so it is never
  a zero (`ForgeCore.CommandSteps`).

  Every function takes `nil` for the steps and then does nothing but run what it was given, which
  is what an agent job and a conversation, which time nothing, pass.

  The clock is injectable (`:clock`, monotonic milliseconds; `:wall`, the wall clock at the origin)
  so that a test drives time and does not wait for it.
  """

  use Agent

  alias ForgeCore.CommandSteps

  @type t :: pid() | nil

  @doc """
  Starts the clock. Options: `:clock` (a function returning monotonic milliseconds) and `:wall`
  (the wall clock in milliseconds at the origin).
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    wall = Keyword.get_lazy(opts, :wall, fn -> System.os_time(:millisecond) end)

    Agent.start_link(fn -> %{clock: clock, wall: wall, origin: clock.(), steps: %{}} end)
  end

  @doc "Stops the clock, when the run is over. Nil, or steps already stopped, is nothing."
  @spec close(t()) :: :ok
  def close(nil), do: :ok

  def close(steps) do
    Agent.stop(steps)
  catch
    :exit, _already_gone -> :ok
  end

  @doc "Milliseconds since the origin; 0 for no steps. The line times of a command use it."
  @spec elapsed(t()) :: non_neg_integer()
  def elapsed(nil), do: 0

  def elapsed(steps),
    do: Agent.get(steps, fn state -> max(state.clock.() - state.origin, 0) end)

  @doc "The monotonic reading to give `stop/3`, nil for no steps."
  @spec tick(t()) :: integer() | nil
  def tick(nil), do: nil
  def tick(steps), do: Agent.get(steps, fn state -> state.clock.() end)

  @doc "Adds the time since `started` (from `tick/1`) to `name`."
  @spec stop(t(), String.t(), integer() | nil) :: :ok
  def stop(nil, _name, _started), do: :ok

  def stop(steps, name, started) do
    Agent.update(steps, fn state ->
      now = state.clock.()
      add_to(state, name, at(state, started), max(now - started, 0))
    end)
  end

  @doc "Runs `fun`, adding the time it took to `name`, whatever way it ends."
  @spec time(t(), String.t(), (-> result)) :: result when result: term()
  def time(nil, _name, fun), do: fun.()

  def time(steps, name, fun) do
    started = tick(steps)

    try do
      fun.()
    after
      stop(steps, name, started)
    end
  end

  @doc "Records `name` as a step that did not happen, and why."
  @spec skip(t(), String.t(), String.t()) :: :ok
  def skip(nil, _name, _reason), do: :ok

  def skip(steps, name, reason) do
    Agent.update(steps, fn state ->
      entry = Map.get(state.steps, name, %{})
      put_in(state.steps[name], entry |> Map.drop(["ms"]) |> Map.put("skipped", reason))
    end)
  end

  @doc "Adds a fact to `name`'s entry: the snapshot's `source`."
  @spec note(t(), String.t(), String.t(), term()) :: :ok
  def note(nil, _name, _key, _value), do: :ok

  def note(steps, name, key, value) do
    Agent.update(steps, fn state ->
      update_in(state.steps[name], fn entry -> Map.put(entry || %{}, key, value) end)
    end)
  end

  @doc "Records a step that was timed elsewhere, from the wall clock: when it began and how long it took."
  @spec record(t(), String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def record(nil, _name, _at, _ms), do: :ok

  def record(steps, name, at, ms) do
    Agent.update(steps, fn state ->
      entry = state.steps |> Map.get(name, %{}) |> Map.drop(["skipped"])
      put_in(state.steps[name], entry |> Map.put("at", at) |> Map.put("ms", max(ms, 0)))
    end)
  end

  @doc """
  The steps in order, `other` last, and the total: `{steps, total_ms}`. A step with neither a time
  nor a skip is not in it. Nil steps give `{nil, 0}`, which is what a job that is not a command
  reports.
  """
  @spec finish(t()) :: {[map()] | nil, non_neg_integer()}
  def finish(nil), do: {nil, 0}

  def finish(steps) do
    Agent.get(steps, fn state ->
      total = max(state.clock.() - state.origin, 0)

      listed =
        for name <- CommandSteps.names(),
            name != "other",
            entry = Map.get(state.steps, name),
            Map.has_key?(entry, "ms") or Map.has_key?(entry, "skipped") do
          Map.put(entry, "name", name)
        end

      # Never negative: pieces timed by two clocks (the marker's, the agent's) could overlap by a
      # millisecond, and `other` is what is left, not a correction.
      covered = listed |> Enum.map(&Map.get(&1, "ms", 0)) |> Enum.sum()
      other = %{"name" => "other", "at" => state.wall, "ms" => max(total - covered, 0)}

      {listed ++ [other], total}
    end)
  end

  defp add_to(state, name, at, ms) do
    update_in(state.steps[name], fn
      %{"ms" => before} = entry -> %{entry | "ms" => before + ms}
      entry -> (entry || %{}) |> Map.drop(["skipped"]) |> Map.merge(%{"at" => at, "ms" => ms})
    end)
  end

  # The wall clock a monotonic reading was taken at.
  defp at(state, mono), do: state.wall + (mono - state.origin)
end
