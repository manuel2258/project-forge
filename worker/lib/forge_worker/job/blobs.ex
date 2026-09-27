defmodule ForgeWorker.Job.Blobs do
  @moduledoc """
  A run's groups of files, from `out/<group>/` to the store (`docs/design/job-prompt.md` § Groups
  of files): staged when the run ends — copied out through the guarded read `ForgeWorker.Job.Dir`
  makes — and uploaded by the link under the prefix the assignment carries a token for, the
  result then naming each file's key and size.

  Neither step fails the job. A file that cannot be kept is in the result's `invalid_blobs` with
  why, and one that was staged but could not be uploaded joins it there.
  """

  alias ForgeCore.Job.Result
  alias ForgeWorker.{Config, Store}
  alias ForgeWorker.Job.Dir

  require Logger

  @max_bytes 1024 * 1024 * 1024
  @max_files 100

  @doc """
  Stages the files of `groups` for upload, into the worker's own directory (`Dir.blobs_dir/1`).
  No groups stages nothing.
  """
  @spec stage(Result.t(), String.t(), [String.t()]) :: Result.t()
  def stage(%Result{} = result, job_dir, groups) do
    %{staged: staged, invalid: invalid} =
      Dir.stage_groups(job_dir, groups, Dir.blobs_dir(job_dir),
        max_bytes: Application.get_env(:forge_worker, :max_blob_bytes, @max_bytes),
        max_files: Application.get_env(:forge_worker, :max_blob_files, @max_files)
      )

    %{
      result
      | blobs: Map.new(staged, fn {name, path} -> {name, %{"path" => path}} end),
        invalid_blobs: Map.merge(result.invalid_blobs, invalid)
    }
  end

  @doc """
  Uploads what `stage/3` staged, each to `<prefix><n>` with the assignment's prefix token, and
  replaces each staged path with the key and size — so no path on this machine leaves it. Removes
  `staging` afterwards, whatever happened.
  """
  @spec upload(Result.t(), map(), String.t()) :: Result.t()
  def upload(%Result{blobs: blobs} = result, _assignment, staging) when map_size(blobs) == 0 do
    File.rm_rf(staging)
    result
  end

  def upload(%Result{} = result, assignment, staging) do
    outputs = assignment["outputs"] || %{}

    {kept, failed} =
      result.blobs
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, %{}}, fn {{name, %{"path" => path}}, n}, {kept, failed} ->
        case put(outputs, n, path) do
          {:ok, key} ->
            {Map.put(kept, name, %{"key" => key, "size" => File.stat!(path).size}), failed}

          {:error, reason} ->
            {kept, Map.put(failed, name, reason)}
        end
      end)

    File.rm_rf(staging)
    %{result | blobs: kept, invalid_blobs: Map.merge(result.invalid_blobs, failed)}
  end

  defp put(%{"prefix" => prefix, "token" => token}, n, path)
       when is_binary(prefix) and is_binary(token) do
    key = prefix <> Integer.to_string(n)

    case Store.put(Config.platform_url(), key, token, path) do
      {:ok, _info} ->
        {:ok, key}

      {:error, reason} ->
        Logger.warning("could not upload #{key}: #{inspect(reason)}")
        {:error, "could not be uploaded: #{inspect(reason)}"}
    end
  end

  defp put(_outputs, _n, _path), do: {:error, "the assignment named nowhere to upload it"}
end
