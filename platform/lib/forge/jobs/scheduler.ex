defmodule Forge.Jobs.Scheduler do
  @moduledoc """
  Starts pending jobs on the running node, up to the configured concurrency, and records
  their results. Jobs are rows, so anything may enqueue one; only this process runs them.
  On boot, jobs left running by a previous node are re-queued.
  """

  use GenServer

  alias Forge.Jobs
  alias ForgeWorker.Job.Runner

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs one scheduling pass now. Returns how many jobs were started."
  @spec tick() :: non_neg_integer()
  def tick, do: GenServer.call(__MODULE__, :tick)

  @impl true
  def init(_opts) do
    recovered = Jobs.recover()
    if recovered > 0, do: Logger.info("re-queued #{recovered} interrupted job(s)")
    schedule()
    {:ok, %{running: %{}}}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    {started, state} = start_pending(state)
    {:reply, started, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_started, state} = start_pending(state)
    schedule()
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | running: Map.delete(state.running, pid)}}
  end

  defp start_pending(state) do
    capacity = Jobs.config(:max_concurrent, 2) - map_size(state.running)

    if capacity > 0 do
      Enum.reduce(Jobs.pending(capacity), {0, state}, &start_one/2)
    else
      {0, state}
    end
  end

  defp start_one(job, {count, state}) do
    case Jobs.start(job) do
      {:ok, runner} ->
        {:ok, task} =
          Task.Supervisor.start_child(Forge.TaskSupervisor, fn -> finish(job.id, runner) end)

        Process.monitor(task)
        {count + 1, %{state | running: Map.put(state.running, task, job.id)}}

      {:error, reason} ->
        Logger.error("could not start job #{job.id}: #{inspect(reason)}")
        {count, state}
    end
  end

  # A runner that dies, or a result that cannot be recorded, must not leave the job
  # `running` forever: it is failed, which also lets the engine decide what follows.
  defp finish(job_id, runner) do
    {:ok, result} = Runner.await(runner)

    case Jobs.complete(job_id, result) do
      {:ok, _job} -> :ok
      {:error, reason} -> Jobs.fail(job_id, {:record_failed, reason})
    end
  catch
    kind, reason ->
      Logger.error(
        "job #{job_id} runner failed: #{Exception.format(kind, reason, __STACKTRACE__)}"
      )

      Jobs.fail(job_id, {kind, reason})
  end

  defp schedule, do: Process.send_after(self(), :tick, Jobs.config(:poll_ms, 2_000))
end
