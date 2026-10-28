defmodule Forge.MergeQueue.Runner do
  @moduledoc """
  Works each project's merge queue, one task per project, so that a merge is never in the request
  that asked for it and two projects never wait for each other (`docs/design/workflow-grammar-v1.md`
  § The merge queue).

  A task loops `Forge.Engine.advance_queue/1` until the line is idle or busy. The runner is kicked
  when a person approves a ticket onto a line or takes one out, and polls for the rest — an
  engine's own enqueue, a return from integration, a stick, a cancel — so those wait up to one poll
  (5 s). The database says what is next, so a runner that restarts loses nothing. Started only
  where jobs run (`Forge.Application`).

  **A project has one task at a time on a node (the registry is local), and that is what makes recovery safe.** A task
  registers itself under its project (`Forge.MergeQueue.Registry`) before it touches the line, and
  a second one finds the name taken and stops. Its tasks are not linked, so they outlive a
  restarted runner; the registration is how a new runner's task knows whether a live one owns the
  `merging` row. Holding the name, a task knows any `merging` row of its project belongs to a task
  that is gone — a crash of the platform, of the runner, of the task — and recovers it first
  (`Forge.Engine.recover_queue/1`), in the task and not in this process. A project with only a
  `merging` row is polled for the same reason as one with a `waiting` row. A task that dies is
  started again after `:merge_queue_retry_ms`, so a row that kills its task every time does not
  spin.
  """

  use GenServer

  require Logger

  @poll_ms 5_000
  @retry_ms 2_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for the project's line to be worked; a no-op where the runner is not running."
  @spec kick(String.t()) :: :ok
  def kick(project_id) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:kick, project_id})
    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, %{running: %{}, again: MapSet.new()}, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    schedule()
    {:noreply, poll(state)}
  end

  @impl true
  def handle_cast({:kick, project_id}, state), do: {:noreply, start(state, project_id)}

  @impl true
  def handle_info(:poll, state) do
    schedule()
    {:noreply, poll(state)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.error("merge queue task stopped: #{inspect(reason)}")
    # The row it was merging is left `merging`, which the next task for the project recovers.
    {project_id, running} = Map.pop(state.running, ref)

    if project_id do
      retry = Application.get_env(:forge, :merge_queue_retry_ms, @retry_ms)
      Process.send_after(self(), {:retry, project_id}, retry)
    end

    {:noreply, %{state | running: running}}
  end

  def handle_info({:retry, project_id}, state), do: {:noreply, start(state, project_id)}

  defp poll(state), do: Enum.reduce(Forge.MergeQueue.working_projects(), state, &start(&2, &1))

  defp schedule,
    do:
      Process.send_after(
        self(),
        :poll,
        Application.get_env(:forge, :merge_queue_poll_ms, @poll_ms)
      )

  # One task per project; a kick while it runs asks for another pass when it is done, because what
  # it kicked for may have arrived after its last look.
  defp start(%{running: running} = state, project_id) do
    if Enum.any?(running, fn {_ref, id} -> id == project_id end) do
      %{state | again: MapSet.put(state.again, project_id)}
    else
      task = Task.Supervisor.async_nolink(Forge.TaskSupervisor, fn -> work(project_id) end)

      %{state | running: Map.put(running, task.ref, project_id)}
    end
  end

  defp finished(state, ref) do
    {project_id, running} = Map.pop(state.running, ref)
    state = %{state | running: running}

    if MapSet.member?(state.again, project_id) do
      start(%{state | again: MapSet.delete(state.again, project_id)}, project_id)
    else
      state
    end
  end

  # Takes the project's name, recovers what a task that is gone left, and loops the line until it
  # is idle. A name that is taken means either a task from before a restart that is still working,
  # or one that has just returned its result and not yet exited (the runner starts the next pass
  # on the result): so it is asked for a few times before it is given up on, and given up on, the
  # task leaves it to the one holding it and to the next poll. **No test** makes two real tasks
  # meet here — the registry settles it and the tests hold the name with a stand-in — so the
  # waiting is unobserved.
  defp work(project_id, tries \\ Application.get_env(:forge, :merge_queue_name_tries, 20)) do
    case Registry.register(Forge.MergeQueue.Registry, project_id, nil) do
      {:ok, _owner} ->
        Forge.Engine.recover_queue(project_id)
        loop(project_id)

      {:error, {:already_registered, _pid}} when tries > 0 ->
        Process.sleep(100)
        work(project_id, tries - 1)

      {:error, {:already_registered, _pid}} ->
        :ok
    end
  end

  defp loop(project_id) do
    case Forge.Engine.advance_queue(project_id) do
      idle when idle in [:idle, :busy] -> :ok
      _handled -> loop(project_id)
    end
  end
end
