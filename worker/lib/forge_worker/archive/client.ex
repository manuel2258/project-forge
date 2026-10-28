defmodule ForgeWorker.Archive.Client do
  @moduledoc """
  The archive door from the worker's side: two listings and one download, authorised by the job's
  own git token as a bearer header (`docs/design/archive.md` § The door and its grant).

  **Every failure is a word the agent can act on** — an errno, because the kernel hands it to the
  agent's `open` — and **a download is bounded**: connecting takes at most `:archive_connect_ms`
  (10 s; the one bound with no test) and the transfer may not go silent for `:archive_receive_ms`
  (30 s). That is no progress,
  not total size, so a gigabyte is not cut short while a stalled one is. A body is written to a
  file of its own, checked against the size and the hash the listing promised, and only then moved
  to where a read will find it: a failed or short fetch leaves nothing that looks complete.
  """

  @type config :: %{url: String.t(), token: (-> String.t())}
  @type errno :: :enoent | :eacces | :eio | :etimedout

  @doc "The root listing (`:root`) or one ticket's (`{:ticket, number}`)."
  @spec listing(config(), :root | {:ticket, String.t()}) :: {:ok, map()} | {:error, errno()}
  def listing(config, key) do
    path = if key == :root, do: "/archive", else: "/archive/tickets/" <> elem(key, 1)

    case get(config, path, []) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: 200}} -> {:error, :eio}
      {:ok, response} -> {:error, errno(response)}
      {:error, reason} -> {:error, transport(reason)}
    end
  end

  @doc """
  Downloads version `ref` of ticket `number` to `destination`, which is only written when the bytes
  are what the listing said they would be (`entry` carries `size` and `sha256`).
  """
  @spec fetch(config(), String.t(), entry :: map(), Path.t()) :: :ok | {:error, errno()}
  def fetch(config, number, %{"ref" => ref} = entry, destination) do
    partial = destination <> ".partial"
    File.mkdir_p!(Path.dirname(destination))

    try do
      case get(config, "/archive/tickets/#{number}/#{ref}", into: File.stream!(partial)) do
        {:ok, %{status: 200}} -> settle(partial, entry, destination)
        {:ok, response} -> {:error, errno(response)}
        {:error, reason} -> {:error, transport(reason)}
      end
    after
      File.rm(partial)
    end
  end

  defp settle(partial, entry, destination) do
    with {:ok, %File.Stat{size: size}} <- File.stat(partial),
         true <- size == entry["size"],
         true <- hash_matches?(partial, entry["sha256"]),
         :ok <- File.rename(partial, destination) do
      :ok
    else
      _damaged -> {:error, :eio}
    end
  end

  defp hash_matches?(_path, nil), do: true

  defp hash_matches?(path, sha256) do
    digest =
      path
      |> File.stream!(1024 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    digest == sha256
  end

  defp get(%{url: url, token: token}, path, opts) do
    options =
      [
        url: String.trim_trailing(url, "/") <> path,
        headers: [{"authorization", "Bearer " <> token.()}],
        retry: false,
        redirect: false,
        # **The connect bound is untested**: a plug has no connection to time out, and a real one
        # would need a route that swallows packets. Removing it or setting it to 1 ms fails nothing.
        # The transfer bound below is tested against a socket that accepts and says nothing.
        connect_options: [
          timeout: Application.get_env(:forge_worker, :archive_connect_ms, 10_000)
        ],
        receive_timeout: Application.get_env(:forge_worker, :archive_receive_ms, 30_000)
      ] ++ opts

    Req.get(Keyword.merge(options, Application.get_env(:forge_worker, :req_options, [])))
  end

  defp errno(%{status: status}) when status in [401, 403], do: :eacces
  defp errno(%{status: 404}), do: :enoent
  defp errno(_response), do: :eio

  # A platform that is not answering, or stopped answering, is a timeout to the agent whether the
  # socket refused, closed or went quiet: it will be there later, and it should try later.
  defp transport(_reason), do: :etimedout
end
