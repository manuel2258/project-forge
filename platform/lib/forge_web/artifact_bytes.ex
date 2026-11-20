defmodule ForgeWeb.ArtifactBytes do
  @moduledoc """
  The exact bytes of one artifact version, sent. What `ForgeWeb.ArtifactController` (a session) and
  `ForgeWeb.Api.TicketController` (a bearer) both answer with, so that the two doors cannot
  disagree about what is served or how.

  Text is served `text/plain` and inline; a raster image blob (`FileType.raster?/2`, decided from
  the name before the bytes are looked at) as its `image/*` type, inline; and anything else as an
  attachment: bytes, an SVG, or an Android app's own type. The content was written by an agent, so
  it is never served as a type a browser will execute or lay out: `X-Content-Type-Options: nosniff`
  is what stops a `.md` full of markup being treated as HTML in the operator's own session, and
  every response carries `content-security-policy: default-src 'none'; sandbox`, so that if a
  browser ever did lay one out nothing in it would run. See `docs/design/ui.md`
  § Addressable artifact versions.
  """

  import Plug.Conn

  alias Forge.Artifacts
  alias ForgeWeb.FileType

  @doc """
  Sends `version` of `artifact`, or `{:error, reason}` from the store for the caller to answer.

  A large blob is fetched to a file that is not read into memory and is removed after it is sent;
  the path is a `Plug.Upload.random_file/1`, which Plug also deletes when the request process
  dies, so a client that hangs up mid-send leaves nothing behind either. (`random_file/1` creates
  the file, so every branch that does not use it deletes it at once rather than leaving an empty one
  for the life of the connection.)
  """
  @spec send_version(Plug.Conn.t(), String.t(), Forge.Artifacts.Version.t()) ::
          Plug.Conn.t() | {:error, term()}
  def send_version(conn, artifact, version) do
    case withdrawn(artifact, version) do
      nil -> send_live(conn, artifact, version)
      attachment -> gone(conn, attachment)
    end
  end

  # **A withdrawn file is answered before the store is asked** (`docs/design/attachments.md`
  # § Withdrawing): its bytes are gone, and a 404 would say a file never was. One place for both
  # doors — the session's and the API's bearer — so they cannot disagree. Only a person's file
  # (`attachments/<file>`) can be withdrawn, so no other artifact pays the query.
  defp withdrawn(artifact, version) do
    if ForgeCore.Workflow.attachment?(artifact) do
      case Forge.Attachments.for_version(version.id) do
        %Forge.Attachments.Attachment{withdrawn_at: at} = attachment when not is_nil(at) ->
          attachment

        _live_or_not_a_person_s_file ->
          nil
      end
    end
  end

  # `410 Gone`, saying by whom and when. Plain text for a page and the API's own error shape for a
  # bearer, both under the headers every other response here carries.
  defp gone(conn, attachment) do
    by = withdrawn_by(attachment)
    at = Calendar.strftime(attachment.withdrawn_at, "%Y-%m-%d %H:%M UTC")
    detail = "withdrawn by #{by} at #{at}"

    detail =
      if attachment.withdraw_reason,
        do: detail <> ": " <> attachment.withdraw_reason,
        else: detail

    # `nosniff` here is an equivalent mutant for the suite: the browser pipeline and the API's set it
    # on every response before this runs. Said again so a response built here is whole by itself.
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_status(:gone)

    if Phoenix.Controller.get_format(conn) == "json" do
      Phoenix.Controller.json(conn, %{
        error: %{
          reason: "withdrawn",
          detail: detail,
          withdrawn_by: by,
          withdrawn_at: DateTime.to_iso8601(attachment.withdrawn_at)
        }
      })
    else
      conn
      |> put_resp_content_type("text/plain", "utf-8")
      |> send_resp(:gone, "This file was " <> detail <> ".\n")
    end
  end

  defp withdrawn_by(%{withdrawn_user_id: id}) when is_binary(id) do
    case Forge.Repo.get(Forge.Accounts.User, id) do
      %{email: email} -> email
      nil -> "a person"
    end
  end

  defp withdrawn_by(_attachment), do: "a person"

  defp send_live(conn, artifact, version) do
    {:ok, path} = Plug.Upload.random_file("forge-download")

    # **A raster image is asked about before the text check**, so that a `.png` whose bytes happen
    # to be text is still an image: what the page draws and what this serves are one decision.
    {type, disposition} =
      if FileType.raster?(artifact, version),
        do: {FileType.image_type(artifact), "inline"},
        else: {FileType.download_type(artifact), "attachment"}

    # An SVG blob can carry script, so it is a download whatever it holds, small text included. (A
    # *document* with such a name is text, as every document is.)
    is_svg = FileType.svg?(artifact) and is_binary(version.blob_uri)

    case Artifacts.served(version, path) do
      {:text, bytes} when disposition == "attachment" and not is_svg ->
        Plug.Upload.delete(path)
        conn |> headers("text/plain", "inline", artifact, version) |> send_resp(200, bytes)

      {kind, bytes} when kind in [:text, :bytes] ->
        Plug.Upload.delete(path)
        conn |> headers(type, disposition, artifact, version) |> send_resp(200, bytes)

      {:file, path} ->
        try do
          conn |> headers(type, disposition, artifact, version) |> send_file(200, path)
        after
          Plug.Upload.delete(path)
        end

      {:error, reason} ->
        Plug.Upload.delete(path)
        {:error, reason}
    end
  end

  defp headers(conn, type, disposition, artifact, version) do
    conn
    |> put_resp_content_type(type, if(type == "text/plain", do: "utf-8"))
    |> put_resp_header("x-content-type-options", "nosniff")
    # No script, nothing loaded, sandboxed: if a browser ever lays a version out as a page,
    # nothing in it runs. An image drawn inside a page is unaffected.
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    |> put_resp_header(
      "content-disposition",
      ~s(#{disposition}; filename="#{filename(artifact, version)}")
    )
  end

  # The version is in the name a browser saves, because two versions of one artifact are two
  # different files and the product never lets "latest" stand in for a version.
  #
  # Scrubbed, because an artifact name is whatever a project's `produces:` says. A quote in it
  # injects a second `filename` parameter into the header and a newline makes Plug refuse the
  # value outright — a 500 on that artifact's route. The name is cosmetic here; the address is
  # what identifies the version.
  defp filename(artifact, version) do
    base = artifact |> Path.basename() |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

    case Path.extname(base) do
      "" -> "#{base}-v#{version.version}"
      ext -> "#{Path.rootname(base, ext)}-v#{version.version}#{ext}"
    end
  end
end
