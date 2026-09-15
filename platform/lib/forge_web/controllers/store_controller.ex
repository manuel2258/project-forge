defmodule ForgeWeb.StoreController do
  @moduledoc """
  The worker's door to the store: one key, one verb, one short-lived token. The operator's
  door is the authenticated routes, which serve blobs through the platform rather than
  redirecting anywhere. See `docs/design/storage.md` § Serving.

  A body is streamed to a temporary file and handed to the store as a path. A seed is
  hundreds of megabytes; reading one into a binary to write it straight back out is the thing
  the behaviour's path form exists to avoid.
  """

  use ForgeWeb, :controller

  alias Forge.Storage
  alias Forge.Storage.Token

  require Logger

  @chunk 1024 * 1024

  def show(conn, %{"key" => segments}) do
    key = Enum.join(segments, "/")

    with {:ok, token} <- bearer(conn),
         :ok <- Token.verify(token, :get, key),
         {:ok, content} <- Storage.get(key) do
      # No charset: these are bytes, and the only reader is a worker writing them to a file.
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> send_resp(:ok, content)
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update(conn, %{"key" => segments}) do
    key = Enum.join(segments, "/")

    with {:ok, token} <- bearer(conn),
         :ok <- Token.verify(token, :put, key),
         {:ok, temp} <- temp_file(),
         {:ok, conn} <- stream_body(conn, temp),
         {:ok, info} <- put(key, temp) do
      json(conn, %{key: key, size: info.size, hash: info.hash})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  # In a header, never the query string: a URL reaches every proxy log between the worker and
  # here. See docs/design/storage.md § The token is a header.
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _other -> {:error, :unauthorized}
    end
  end

  defp put(key, temp) do
    Storage.put(key, {:file, temp})
  after
    File.rm(temp)
  end

  defp temp_file do
    dir = Path.join(System.tmp_dir!(), "forge-upload")
    File.mkdir_p!(dir)
    {:ok, Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))}
  end

  defp stream_body(conn, path) do
    file = File.open!(path, [:write, :binary])

    try do
      copy(conn, file, 0)
    after
      File.close(file)
    end
  end

  defp copy(conn, file, written) do
    max = Storage.config(:max_upload_bytes, 8 * 1024 * 1024 * 1024)

    case Plug.Conn.read_body(conn, length: @chunk) do
      {:ok, chunk, conn} ->
        IO.binwrite(file, chunk)
        if written + byte_size(chunk) > max, do: {:error, :too_large}, else: {:ok, conn}

      {:more, chunk, conn} ->
        IO.binwrite(file, chunk)

        if written + byte_size(chunk) > max,
          do: {:error, :too_large},
          else: copy(conn, file, written + byte_size(chunk))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fail(conn, reason) do
    {status, name} = status(reason)

    if status == :internal_server_error do
      Logger.error("store request failed: #{inspect(reason)}")
    end

    conn |> put_status(status) |> json(%{error: %{reason: name, detail: nil}})
  end

  defp status(:unauthorized), do: {:unauthorized, "missing_token"}
  defp status(:invalid), do: {:unauthorized, "invalid_token"}
  defp status(:expired), do: {:unauthorized, "expired_token"}
  defp status(:wrong_key), do: {:forbidden, "wrong_key"}
  defp status(:invalid_key), do: {:bad_request, "invalid_key"}
  defp status(:not_found), do: {:not_found, "not_found"}
  defp status(:exists), do: {:conflict, "exists"}
  defp status(:too_large), do: {:request_entity_too_large, "too_large"}
  defp status(_reason), do: {:internal_server_error, "internal"}
end
