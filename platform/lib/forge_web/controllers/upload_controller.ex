defmodule ForgeWeb.UploadController do
  @moduledoc """
  The page's way of sending a file: `POST /projects/:name/uploads` with the bytes as the body, and
  `DELETE /projects/:name/uploads/:id` to take one back (`docs/design/attachments.md` § Staging,
  claiming and the sweep).

  A member of the project, on a session with the CSRF header (the `:browser` pipeline), and a miss
  for anyone else. The file is **staged**, not attached: nothing counts it and no agent is handed
  it until the act it rides on claims it (`Forge.Attachments.claim/6`).

  **The body is read in chunks and counted as it arrives**, so the limit is on the bytes received
  and not on a header a client chose (`Plug.Parsers` passes an octet stream unread). A body past
  the limit stops being read and is `413`, with nothing kept. The name comes in a header,
  percent-encoded, because a body has no room for it.
  """

  use ForgeWeb, :controller

  alias Forge.Attachments

  @name_header "x-file-name"

  def create(conn, %{"name" => name}) do
    {project, scope} = ForgeWeb.Access.project_by_name!(conn.assigns.current_scope, name)
    original = original_name(conn)

    # The temporary file is the request's own and goes whatever the body did.
    ForgeWeb.BodyFile.with_temp(fn path ->
      case ForgeWeb.BodyFile.write(conn, path, Attachments.limits().file_bytes) do
        {:ok, conn, _size} ->
          stage(conn, project, scope.user, path, original)

        {:error, :too_large} ->
          refused(conn, Attachments.limit_text(:file_bytes))

        {:error, reason} ->
          conn |> put_status(:bad_request) |> json(%{error: %{reason: inspect(reason)}})
      end
    end)
  end

  def delete(conn, %{"name" => name, "id" => id}) do
    {project, scope} = ForgeWeb.Access.project_by_name!(conn.assigns.current_scope, name)
    Attachments.discard(project, scope.user, [id])
    send_resp(conn, :no_content, "")
  end

  defp stage(conn, project, user, path, original) do
    case Attachments.stage(project, user, {:file, path}, original) do
      {:ok, upload} ->
        json(conn, %{id: upload.id, name: upload.original_name, size: upload.size})

      {:error, {:attachments_refused, [{_name, limit}]}} ->
        refused(conn, Attachments.limit_text(limit))

      {:error, _reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: %{reason: "not_kept"}})
    end
  end

  # What the person's file was called, or `file` when it says nothing: percent-decoded, and cut to
  # what the staging row keeps. It is only ever a label: the artifact's name is made from it by
  # `Forge.Attachments.name/1`.
  defp original_name(conn) do
    with [encoded | _] <- get_req_header(conn, @name_header),
         decoded when is_binary(decoded) <- decode(encoded),
         true <- String.valid?(decoded) and decoded != "" do
      String.slice(decoded, 0, 255)
    else
      _other -> "file"
    end
  end

  defp decode(encoded) do
    URI.decode(encoded)
  rescue
    ArgumentError -> nil
  end

  defp refused(conn, limit) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{error: %{reason: "too_large", limit: limit}})
  end
end
