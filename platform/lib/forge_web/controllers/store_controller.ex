defmodule ForgeWeb.StoreController do
  @moduledoc """
  The worker's door to the store: one key, one verb, one short-lived token. The operator's
  door is the authenticated routes, which serve blobs through the platform rather than
  redirecting anywhere. See `docs/design/storage.md` § Serving.

  A body is streamed to a temporary file and handed to the store as a path, and a blob is served
  from a file the store fetched it to. A seed is hundreds of megabytes; reading one into a binary
  to write it straight back out is the thing the behaviour's path form exists to avoid.
  """

  use ForgeWeb, :controller

  alias Forge.Storage
  alias Forge.Storage.Token

  require Logger

  def show(conn, %{"key" => segments}) do
    key = Enum.join(segments, "/")

    with {:ok, token} <- bearer(conn),
         :ok <- Token.verify(token, :get, key),
         {:ok, path} <- Plug.Upload.random_file("forge-store") do
      # Streamed from a file, as `ForgeWeb.ArtifactBytes` serves one: a seed or a person's upload is
      # hundreds of megabytes and never passes through a binary. The file is removed after it is
      # sent, and Plug removes it if the request dies first.
      try do
        case Storage.fetch(key, path) do
          {:ok, _info} ->
            # No charset: these are bytes, and the only reader is a worker writing them to a file.
            conn
            |> put_resp_content_type("application/octet-stream", nil)
            |> send_file(200, path)

          {:error, reason} ->
            fail(conn, reason)
        end
      after
        Plug.Upload.delete(path)
      end
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update(conn, %{"key" => segments}) do
    key = Enum.join(segments, "/")

    with {:ok, token} <- bearer(conn),
         :ok <- Token.verify(token, :put, key) do
      # The temporary file goes whatever the body did: a body past the limit or a connection cut
      # off leaves nothing behind.
      ForgeWeb.BodyFile.with_temp(&store(conn, key, &1))
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp store(conn, key, temp) do
    max = Storage.config(:max_upload_bytes, 8 * 1024 * 1024 * 1024)

    with {:ok, conn, _size} <- ForgeWeb.BodyFile.write(conn, temp, max),
         {:ok, info} <- Storage.put(key, {:file, temp}) do
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
