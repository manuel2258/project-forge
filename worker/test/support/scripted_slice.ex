defmodule ForgeWorker.ScriptedSlice do
  @moduledoc """
  `Slice.Direct`, saying what a test scripts a unit's cgroup and its last reading to have said:
  `readings` is an agent holding the readings `memory/1` hands out in turn, the last one again once
  they run out; `ending` is merged over what `Slice.Direct` says of a process that ended. A caller
  that makes the slice's options itself — the link, a conversation — cannot be handed an agent, so
  `:scripted_readings` in the application's environment stands in for `readings` there.
  """

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts), do: {:ok, opts}

  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  def memory(context) do
    readings = context[:readings] || Application.fetch_env!(:forge_worker, :scripted_readings)

    Agent.get_and_update(readings, fn
      [last] -> {last, [last]}
      [next | rest] -> {next, rest}
      [] -> {nil, []}
    end)
  end

  @impl ForgeWorker.Slice
  def ended(context, output),
    do: Map.merge(ForgeWorker.Slice.Direct.ended(context, output), context[:ending] || %{})

  @impl ForgeWorker.Slice
  def probe, do: :none

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct
end
