defmodule ForgeWeb.ArtifactController do
  @moduledoc """
  The exact bytes of one artifact version, to an authenticated operator.

  `docs/design/ui.md` § Addressable artifact versions: this is what every artifact name in the
  product links to. It serves raw bytes today and that is the route's behaviour rather than its
  meaning — when the margin-questions view lands it takes the HTML representation of this same
  address and raw moves behind a parameter.

  What is sent, and how, is `ForgeWeb.ArtifactBytes`'s, which the JSON API's raw route shares.
  """

  use ForgeWeb, :controller

  alias Forge.{Artifacts, Conversations, Projects, Tickets}

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

  defp serve(conn, artifact, {:ok, version}) do
    case ForgeWeb.ArtifactBytes.send_version(conn, artifact, version) do
      {:error, reason} -> serve(conn, artifact, {:error, reason})
      conn -> conn
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
end
