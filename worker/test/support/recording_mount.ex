defmodule ForgeWorker.RecordingMount do
  @moduledoc """
  A `ForgeWorker.Archive.Mount` that mounts nothing and says what it was asked, to the process in
  `:archive_test_pid`. `:archive_test_mount` is what `mount/2` answers (`:ok` by default), and
  `:archive_test_serves` whether there is a server to start.
  """

  @behaviour ForgeWorker.Archive.Mount

  @impl true
  def serves?, do: Application.get_env(:forge_worker, :archive_test_serves, true)

  @impl true
  def mount(socket, dir) do
    tell({:mounted, socket, dir})
    Application.get_env(:forge_worker, :archive_test_mount, :ok)
  end

  @impl true
  def unmount(dir) do
    tell({:unmounted, dir})
    :ok
  end

  # Nobody, once the test that set this is over: a runner of another test that ends meanwhile
  # unmounts through the same module.
  defp tell(message) do
    case Application.get_env(:forge_worker, :archive_test_pid) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
