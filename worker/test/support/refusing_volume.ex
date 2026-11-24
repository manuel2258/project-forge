defmodule ForgeWorker.RefusingVolume do
  @moduledoc """
  Snapshots as `Copy` does, except where the test has said not to: `:refuse_snapshot` in the
  application environment names a fragment of a path whose snapshot is refused, which is what a
  machine that cannot snapshot looks like.
  """

  @behaviour ForgeWorker.Volume

  alias ForgeWorker.Volume.Copy

  @impl ForgeWorker.Volume
  defdelegate create(path), to: Copy

  @impl ForgeWorker.Volume
  def snapshot(source, dest) do
    fragment = Application.get_env(:forge_worker, :refuse_snapshot)

    if fragment && (String.contains?(source, fragment) or String.contains?(dest, fragment)),
      do: {:error, :refused},
      else: Copy.snapshot(source, dest)
  end

  # `:refuse_delete` names one whole path whose deletion is refused.
  @impl ForgeWorker.Volume
  def delete(path) do
    if path == Application.get_env(:forge_worker, :refuse_delete),
      do: {:error, :refused},
      else: Copy.delete(path)
  end
end
