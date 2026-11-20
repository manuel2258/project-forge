defmodule ForgeWorker.RecordingBind do
  @moduledoc """
  A `ForgeWorker.Archive.Mount` for the folder of attached files that binds nothing and tells the
  test that asked what it was asked — for the folders under the root that test registered with
  `watch/2`, and for no others, which are `Mount.None`'s: a copy. The same routing as
  `ForgeWorker.RecordingMount`, for the same reason (no test writes the mount to the application
  environment), and a module of its own because the attached files' mount is chosen by its own
  setting (`docs/design/attachments.md` § The folder).

  Messages: `{:bound, source, folder}`, `{:refreshed, source, folder}` and `{:unbound, folder}`.
  `watch/2` options: `bind:` what `bind_ro/2` answers (`:ok`).
  """

  @behaviour ForgeWorker.Archive.Mount

  alias ForgeWorker.Archive.Mount.None

  @table __MODULE__

  @doc "Starts the table, once, in a process that outlives the file that asked."
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

  @doc "The calling test hears of every bind, refresh and unbind under `root` until it ends."
  def watch(root, opts \\ []) do
    :ets.insert(@table, {root, self(), opts})
    ExUnit.Callbacks.on_exit(fn -> :ets.delete(@table, root) end)
    :ok
  end

  @impl true
  def serves?(_dir), do: false

  @impl true
  def mount(_socket, _dir), do: {:error, :not_an_archive_mount}

  @impl true
  def bind_ro(source, dir) do
    case lookup(dir) do
      nil ->
        None.bind_ro(source, dir)

      {pid, opts} ->
        send(pid, {:bound, source, dir})
        Keyword.get(opts, :bind, :ok)
    end
  end

  @impl true
  def refresh(source, dir) do
    case lookup(dir) do
      nil ->
        None.refresh(source, dir)

      {pid, _opts} ->
        send(pid, {:refreshed, source, dir})
        :ok
    end
  end

  @impl true
  def unmount(dir) do
    case lookup(dir) do
      nil ->
        None.unmount(dir)

      {pid, _opts} ->
        send(pid, {:unbound, dir})
        :ok
    end
  end

  defp lookup(dir) do
    Enum.find_value(:ets.tab2list(@table), fn {root, pid, opts} ->
      if String.starts_with?(dir, root <> "/"), do: {pid, opts}
    end)
  end
end
