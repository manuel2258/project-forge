defmodule ForgeWorker.RecordingMount do
  @moduledoc """
  A `ForgeWorker.Archive.Mount` that mounts nothing and tells the test that asked what it was
  asked — for the folders under the root that test registered with `watch/2`, and for no others.

  **Why a root and not the application environment.** The mount in use and the process to tell
  used to be two keys of `:forge_worker`'s environment, set by whichever test wanted them and
  deleted when it ended. The tests that do are `async`, so one test's `on_exit` took the mount
  from another's runner mid-job (its lifecycle came up short: `[:slice]`, or `[]`), and one
  runner's unmount reached another test (`[:slice, :unmounted, :unmounted, …]`). Nothing is
  written to the environment now: `test_helper.exs` sets this module once, and every test's job
  directory is under a root of its own, which is all the routing there needs.

  A folder under no registered root is treated as `ForgeWorker.Archive.Mount.None` treats it,
  which is what every job did before a test asked for anything else.

  `watch/2` options: `mount:` what `mount/2` answers (`:ok` by default), and `serves:` whether
  there is a server to start (`true`).
  """

  @behaviour ForgeWorker.Archive.Mount

  alias ForgeWorker.Archive.Mount.None

  @table __MODULE__

  @doc """
  Starts the table, once, in a process of its own that outlives the file that asked: a table
  belongs to the process that makes it, and the helper's is gone by the time a test runs.
  """
  def start do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        :ets.new(@table, [:named_table, :public, :set])
        send(parent, :started)

        receive do
          :stop -> :ok
        end
      end)

      receive do
        :started -> :ok
      end
    end

    :ok
  end

  @doc """
  The calling test hears of every mount and unmount under `root`, as `{:mounted, socket, folder}`
  and `{:unmounted, folder}`, until it ends. A second call for the same root changes the options.
  """
  def watch(root, opts \\ []) do
    :ets.insert(@table, {root, self(), opts})
    ExUnit.Callbacks.on_exit(fn -> :ets.delete(@table, root) end)
    :ok
  end

  @doc "Stops telling: the folders under `root` are `Mount.None`'s again."
  def unwatch(root) do
    :ets.delete(@table, root)
    :ok
  end

  @impl true
  def serves?(dir) do
    case lookup(dir) do
      nil -> None.serves?(dir)
      {_pid, opts} -> Keyword.get(opts, :serves, true)
    end
  end

  @impl true
  def mount(socket, dir) do
    case lookup(dir) do
      nil ->
        None.mount(socket, dir)

      {pid, opts} ->
        send(pid, {:mounted, socket, dir})
        Keyword.get(opts, :mount, :ok)
    end
  end

  @impl true
  def unmount(dir) do
    case lookup(dir) do
      nil ->
        None.unmount(dir)

      {pid, _opts} ->
        send(pid, {:unmounted, dir})
        :ok
    end
  end

  @doc "Sends `message` to the test that watches the root `dir` is under, if any."
  def tell(dir, message) do
    case lookup(dir) do
      nil -> :ok
      {pid, _opts} -> send(pid, message)
    end

    :ok
  end

  defp lookup(dir) do
    Enum.find_value(:ets.tab2list(@table), fn {root, pid, opts} ->
      if String.starts_with?(dir, root <> "/"), do: {pid, opts}
    end)
  end
end
