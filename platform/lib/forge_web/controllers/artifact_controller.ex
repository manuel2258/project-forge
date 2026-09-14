defmodule ForgeWeb.ArtifactController do
  @moduledoc """
  The exact bytes of one artifact version, to an authenticated operator.

  `docs/design/ui.md` § Addressable artifact versions: this is what every artifact name in the
  product links to. It serves raw bytes today and that is the route's behaviour rather than its
  meaning — when the margin-questions view lands it takes the HTML representation of this same
  address and raw moves behind a parameter.

  Everything here is served `text/plain` and inline. The content was written by an agent, so it
  is never served as a type a browser will execute or lay out: `X-Content-Type-Options: nosniff`
  is what stops a `.md` full of markup being treated as HTML in the operator's own session.
  """

  use ForgeWeb, :controller

  alias Forge.{Artifacts, Tickets}

  def show(conn, %{"project" => name, "number" => number, "name" => artifact} = params) do
    {ticket, _project} = Tickets.fetch!(name, number)

    with {:ok, version} <- version(ticket.id, artifact, params["version"]),
         {:ok, bytes} <- Artifacts.content(version) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{filename(artifact, version)}")
      )
      |> send_resp(200, bytes)
    else
      {:error, :not_a_file} ->
        # A changeset is a commit, and the diff is its rendering.
        redirect(conn, to: ~p"/tickets/#{name}/#{number}/review")

      {:error, _reason} ->
        conn
        |> put_status(:not_found)
        |> put_view(html: ForgeWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp version(ticket_id, name, requested) do
    with {n, ""} when n > 0 <- Integer.parse(requested),
         %{} = version <- Enum.find(Artifacts.versions(ticket_id, name), &(&1.version == n)) do
      {:ok, version}
    else
      _other -> {:error, :not_found}
    end
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
