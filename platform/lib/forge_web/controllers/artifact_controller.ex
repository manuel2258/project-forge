defmodule ForgeWeb.ArtifactController do
  @moduledoc """
  The exact bytes of one artifact version, to an authenticated operator.

  `docs/design/ui.md` § Addressable artifact versions: this is what every artifact name in the
  product links to. It serves raw bytes today and that is the route's behaviour rather than its
  meaning — when the margin-questions view lands it takes the HTML representation of this same
  address and raw moves behind a parameter.

  Text is served `text/plain` and inline, and anything else as an attachment: bytes, or an
  Android app's own type. The content was written by an agent, so it is never served as a type a
  browser will execute or lay out: `X-Content-Type-Options: nosniff` is what stops a `.md` full of
  markup being treated as HTML in the operator's own session.
  """

  use ForgeWeb, :controller

  alias Forge.{Artifacts, Conversations, Projects, Tickets}
  alias ForgeWeb.FileType

  def show(conn, %{"project" => name, "number" => number, "name" => artifact} = params) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(conn.assigns.current_scope, project)

    case version(ticket.id, artifact, params["version"]) do
      # A changeset is a commit, and the diff is its rendering.
      {:error, :not_a_file} -> redirect(conn, to: ~p"/tickets/#{name}/#{number}/review")
      found -> serve(conn, artifact, found)
    end
  end

  @doc """
  A version scoped to a conversation — a project chat's documents, and every chat's proposals —
  at `/chats/:id/artifacts/:name/:version`.

  Guarded as the conversation's own page is: a member of its project, and a miss for anyone
  else. The name is resolved in the conversation's scope and no other, so the same name on a
  ticket, or in another conversation, is not reachable through this address. A ticket chat's
  documents are the ticket's and live under the ticket's route.
  """
  def chat(conn, %{"id" => id, "name" => artifact} = params) do
    chat = Conversations.get!(id)
    ForgeWeb.Access.project_scope!(conn.assigns.current_scope, Projects.get!(chat.project_id))

    serve(conn, artifact, version({:job, chat.id}, artifact, params["version"]))
  end

  # Text is shown; anything else is a download, never laid out: `nosniff` on both, and the bytes of
  # something that is not text are `attachment`, so the browser saves them rather than guessing
  # what they are (`docs/design/ui.md` § Addressable artifact versions). An Android app keeps its
  # own type, which a phone's browser hands to the package installer (§ Artifact types).
  defp serve(conn, artifact, {:ok, version}) do
    case Artifacts.served(version, Path.join(System.tmp_dir!(), "forge-download")) do
      {:text, bytes} ->
        conn |> headers("text/plain", "inline", artifact, version) |> send_resp(200, bytes)

      {:bytes, bytes} ->
        conn
        |> headers(FileType.download_type(artifact), "attachment", artifact, version)
        |> send_resp(200, bytes)

      {:file, path} ->
        try do
          conn
          |> headers(FileType.download_type(artifact), "attachment", artifact, version)
          |> send_file(200, path)
        after
          File.rm(path)
        end

      {:error, reason} ->
        serve(conn, artifact, {:error, reason})
    end
  end

  defp serve(conn, _artifact, {:error, _reason}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: ForgeWeb.ErrorHTML)
    |> render(:"404")
  end

  # The version, or why not. `:not_a_file` is a changeset, which only a ticket has.
  defp version(scope, name, requested) do
    with {n, ""} when n > 0 <- Integer.parse(requested),
         %{} = version <- Enum.find(Artifacts.versions(scope, name), &(&1.version == n)) do
      if Artifacts.commit(version), do: {:error, :not_a_file}, else: {:ok, version}
    else
      _other -> {:error, :not_found}
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
