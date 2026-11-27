defmodule ForgeWorker.Explore.Holds do
  @moduledoc """
  Lets go of the command copies nobody is looking at any more
  (`docs/design/worker-tier.md` § Looking into a copy, criterion 5 of ticket 84).

  A keep that replaces a copy someone has open moves it aside instead of deleting it
  (`ForgeWorker.Job.CommandCopy`); this removes what it moved once ten minutes have passed since the
  last action on it, every minute (`:holds_ms`) and, through `Workspace.sweep/2`, at the end of every
  job. The holds are files, so a restart of the worker forgets nothing: the first tick after it
  starts finds the same ones.
  """

  use GenServer

  alias ForgeWorker.{Config, Disk}
  alias ForgeWorker.Job.CommandCopy

  @every_ms :timer.minutes(1)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      root: Keyword.get(opts, :root, Config.root()),
      every_ms:
        Keyword.get(opts, :every_ms, Application.get_env(:forge_worker, :holds_ms, @every_ms))
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:release, state) do
    freed = CommandCopy.release_holds(state.root)
    if freed > 0, do: Disk.cleaned("volumes", freed)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{every_ms: ms}) when is_integer(ms), do: Process.send_after(self(), :release, ms)
  defp schedule(_state), do: :ok
end
