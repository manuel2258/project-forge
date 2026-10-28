defmodule ForgeWeb.ArtifactBytes do
  @moduledoc """
  The exact bytes of one artifact version, sent. What `ForgeWeb.ArtifactController` (a session) and
  `ForgeWeb.Api.TicketController` (a bearer) both answer with, so that the two doors cannot
  disagree about what is served or how.

  Text is served `text/plain` and inline, and anything else as an attachment: bytes, or an Android
  app's own type. The content was written by an agent, so it is never served as a type a browser
  will execute or lay out: `X-Content-Type-Options: nosniff` is what stops a `.md` full of markup
  being treated as HTML in the operator's own session. See `docs/design/ui.md`
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
    {:ok, path} = Plug.Upload.random_file("forge-download")

    case Artifacts.served(version, path) do
      {:text, bytes} ->
        Plug.Upload.delete(path)
        conn |> headers("text/plain", "inline", artifact, version) |> send_resp(200, bytes)

      {:bytes, bytes} ->
        Plug.Upload.delete(path)

        conn
        |> headers(FileType.download_type(artifact), "attachment", artifact, version)
        |> send_resp(200, bytes)

      {:file, path} ->
        try do
          conn
          |> headers(FileType.download_type(artifact), "attachment", artifact, version)
          |> send_file(200, path)
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
