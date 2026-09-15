defmodule ForgeWorker.Store do
  @moduledoc """
  The platform's blob store, from the worker's side: one key, one verb, one short-lived token,
  which is what the assignment carries. See `docs/design/storage.md` § Serving.

  A body is streamed from a file rather than read into memory — a seed is hundreds of
  megabytes, and the transcript is on disk anyway.
  """

  require Logger

  @doc "Uploads the file at `path` to `key`. Returns what the store recorded."
  @spec put(String.t(), String.t(), String.t(), Path.t()) ::
          {:ok, map()} | {:error, term()}
  def put(platform_url, key, token, path) do
    url = URI.parse(platform_url) |> URI.append_path("/store/" <> key) |> URI.to_string()

    Req.put(
      url,
      options(
        headers: [{"content-type", "application/octet-stream"} | bearer(token)],
        body: File.stream!(path, 1024 * 1024),
        retry: :transient
      )
    )
    |> case do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # In a header and not the query string: a URL reaches every proxy log on the path. The rule is
  # `docs/design/storage.md` § The token is a header, and it is the channel's rule too.
  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  # Tests point Req at a plug instead of the network; nothing else sets this.
  defp options(opts),
    do: Keyword.merge(opts, Application.get_env(:forge_worker, :req_options, []))

  @doc "Downloads `key` to `path`. Used for the seed at cold start."
  @spec fetch(String.t(), String.t(), String.t(), Path.t()) :: :ok | {:error, term()}
  def fetch(platform_url, key, token, path) do
    url = URI.parse(platform_url) |> URI.append_path("/store/" <> key) |> URI.to_string()
    File.mkdir_p!(Path.dirname(path))

    Req.get(url, options(headers: bearer(token), into: File.stream!(path), retry: :transient))
    |> case do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
