defmodule ForgeWorker.Job.Blobs do
  @moduledoc """
  A run's groups of files, from `out/<group>/` to the store (`docs/design/job-prompt.md` § Groups
  of files): staged when the run ends — copied out through the guarded read `ForgeWorker.Job.Dir`
  makes — and uploaded by the link under the prefix the assignment carries a token for, the
  result then naming each file's key and size.

  **A page's files** (`docs/design/pages.md`) travel the same way, from `out/<page>/`, with three
  differences. Each reports its sha256 `hash` too. One whose hash the platform already holds — the
  assignment's `spec.pages` names it, or this same process uploaded it last turn — is not
  uploaded again and is reported as `%{"hash", "size"}` with no `"key"`, which the platform reads
  as "the version you have". And a page whose `index.html` was not kept is not kept at all, since
  a page without its entry is not a page.

  Neither step fails the job. A file that cannot be kept is in the result's `invalid_blobs` with
  why, and one that was staged but could not be uploaded joins it there.
  """

  alias ForgeCore.Job.Result
  alias ForgeWorker.{Config, Log, Store}
  alias ForgeWorker.Job.Dir

  @max_bytes 1024 * 1024 * 1024
  @max_files 100

  @doc """
  Stages the files of `groups` for upload, into the worker's own directory (`Dir.blobs_dir/1`).
  No groups stages nothing.
  """
  @spec stage(Result.t(), String.t(), [String.t()], [String.t()]) :: Result.t()
  def stage(%Result{} = result, job_dir, groups, pages \\ []) do
    %{staged: staged, invalid: invalid} =
      Dir.stage_groups(job_dir, groups ++ pages, Dir.blobs_dir(job_dir),
        max_bytes: Application.get_env(:forge_worker, :max_blob_bytes, @max_bytes),
        max_files: Application.get_env(:forge_worker, :max_blob_files, @max_files),
        pages: pages
      )

    {staged, invalid} = drop_entryless(staged, invalid, pages)

    %{
      result
      | blobs: Map.new(staged, fn {name, path} -> {name, staged_entry(name, path, pages)} end),
        invalid_blobs: Map.merge(result.invalid_blobs, invalid)
    }
  end

  # A page with files and no `index.html` among those kept is none of them: the files are
  # removed from staging and the page's entry is named as the reason.
  defp drop_entryless(staged, invalid, pages),
    do: Enum.reduce(pages, {staged, invalid}, &drop_page/2)

  defp drop_page(page, {staged, invalid}) do
    {mine, rest} = Enum.split_with(staged, fn {name, _path} -> page_of(name) == page end)
    entry = page <> "/index.html"

    if mine == [] or List.keymember?(mine, entry, 0) do
      {staged, invalid}
    else
      Enum.each(mine, fn {_name, path} -> File.rm(path) end)

      {rest,
       Map.put_new(
         invalid,
         entry,
         "is needed: a page without one is not kept, and none of its files were"
       )}
    end
  end

  defp staged_entry(name, path, pages) do
    if page_of(name) in pages,
      do: %{"path" => path, "hash" => sha256(path)},
      else: %{"path" => path}
  end

  defp page_of(name), do: name |> String.split("/", parts: 2) |> hd()

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Uploads what `stage/3` staged, each to `<prefix><n>` with the assignment's prefix token, and
  replaces each staged path with the key and size — so no path on this machine leaves it. Removes
  `staging` afterwards, whatever happened.

  Options, for a conversation, whose prefix is one for all its turns: `:known`, `%{name => hash}`
  of page files this process already uploaded (added to the assignment's `spec.pages`), and
  `keys: :hash`, which names an uploaded page file `<prefix><hash>-<random>` — a number would be
  reused by the next turn, or by the next process of a reopened chat, and the store refuses to
  overwrite a key. The hash alone would be reused too: by two pages that share a file in one turn,
  and by a file changed A→B→A, whose third upload names the first one's key. So each upload has a
  key of its own, and the platform records what a key holds by the hash it reports.
  """
  @spec upload(Result.t(), map(), String.t(), keyword()) :: Result.t()
  def upload(result, assignment, staging, opts \\ [])

  def upload(%Result{blobs: blobs} = result, _assignment, staging, _opts)
      when map_size(blobs) == 0 do
    File.rm_rf(staging)
    result
  end

  def upload(%Result{} = result, assignment, staging, opts) do
    outputs = assignment["outputs"] || %{}
    known = Map.merge(held_hashes(assignment), Keyword.get(opts, :known, %{}))
    keys = Keyword.get(opts, :keys, :number)

    {kept, failed} =
      result.blobs
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, %{}}, fn {{name, staged}, n}, acc ->
        upload_file(acc, name, staged, n, {assignment, outputs, known, keys})
      end)

    File.rm_rf(staging)
    %{result | blobs: kept, invalid_blobs: Map.merge(result.invalid_blobs, failed)}
  end

  defp upload_file({kept, failed}, name, %{"path" => path} = staged, n, ctx) do
    {assignment, outputs, known, keys} = ctx
    size = File.stat!(path).size

    # The platform has these bytes already: say so, send nothing.
    if staged["hash"] != nil and known[name] == staged["hash"] do
      {Map.put(kept, name, %{"hash" => staged["hash"], "size" => size}), failed}
    else
      suffix = suffix(keys, staged["hash"], n)

      case put(outputs, suffix, path, assignment["job_id"]) do
        {:ok, key} -> {Map.put(kept, name, uploaded(key, size, staged)), failed}
        {:error, reason} -> {kept, Map.put(failed, name, reason)}
      end
    end
  end

  # One key per upload. Lower case hex, so it is one valid segment of a storage key.
  defp suffix(:hash, hash, _n) when is_binary(hash),
    do: hash <> "-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp suffix(_keys, _hash, n), do: n

  defp uploaded(key, size, %{"hash" => hash}) when is_binary(hash),
    do: %{"key" => key, "size" => size, "hash" => hash}

  defp uploaded(key, size, _staged), do: %{"key" => key, "size" => size}

  @doc """
  `%{"<page>/<file>" => hash}` of every page file the assignment's spec says the platform holds:
  what an upload need not send again.
  """
  @spec held_hashes(map()) :: %{String.t() => String.t()}
  def held_hashes(assignment) do
    for page <- get_in(assignment, ["spec", "pages"]) || [],
        {file, %{"hash" => hash}} <- page["files"] || %{},
        into: %{},
        do: {page["name"] <> "/" <> file, hash}
  end

  defp put(%{"prefix" => prefix, "token" => token}, suffix, path, job_id)
       when is_binary(prefix) and is_binary(token) do
    key = prefix <> to_string(suffix)

    case Store.put(Config.platform_url(), key, token, path) do
      {:ok, _info} ->
        {:ok, key}

      {:error, reason} ->
        Log.line("upload.failed", :warning, "could not upload #{key}: #{inspect(reason)}",
          job_id: job_id
        )

        {:error, "could not be uploaded: #{inspect(reason)}"}
    end
  end

  defp put(_outputs, _suffix, _path, _job_id),
    do: {:error, "the assignment named nowhere to upload it"}
end
