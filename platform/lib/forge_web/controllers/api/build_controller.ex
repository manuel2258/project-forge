defmodule ForgeWeb.Api.BuildController do
  @moduledoc """
  A ticket's kept command copies over the JSON API (`docs/design/api-and-ui.md` § JSON API,
  `docs/design/worker-tier.md` § Looking into a copy): the list, a folder, a file's facts, hash and
  text, and a download streamed from the machine and stored nowhere.

  **Every action is a read**, so a project token may do all of it with read or write API access alike,
  and a running job's token is refused by `ForgeWeb.Plugs.ApiAuth` as it is for the whole API. A
  caller who is no member of the ticket's project gets the answer of a ticket that does not exist, and
  a copy is reached only through its own ticket (`ForgeWeb.Api.Builds`). **Nothing is recorded about
  who looked.**

  The data is `ForgeWeb.Api.Builds`'; the refusals are `ForgeWeb.Api.FallbackController`'s, each with a
  code of its own (`machine_not_answering`, `machine_not_connected`, `machine_outdated`, `copy_gone`,
  `path_refused`, `path_not_found`, `not_a_folder`, `not_a_file`, `not_text`).
  """

  use ForgeWeb, :controller

  alias Forge.{Explore, Projects, Tickets}
  alias ForgeWeb.Api.Builds

  action_fallback ForgeWeb.Api.FallbackController

  plug :load_ticket

  def index(conn, _params), do: json(conn, Builds.list(conn.assigns.ticket))

  def folder(conn, %{"job_id" => job_id} = params) do
    with {:ok, folder} <- Builds.folder(conn.assigns.ticket, job_id, params),
         do: json(conn, folder)
  end

  def file(conn, %{"job_id" => job_id} = params) do
    opts = [hash: params["hash"] == "true", content: params["content"] == "true"]

    with {:ok, file} <- Builds.file(conn.assigns.ticket, job_id, params, opts),
         do: json(conn, file)
  end

  @doc """
  The copy, a folder of it or a file, as the browser's download is: a tar the machine packs (a file as
  itself), passed on as it is packed. A refusal before the first byte is the API's own; one after it
  ends the connection without the last chunk.
  """
  def download(conn, %{"job_id" => job_id} = params) do
    ticket = conn.assigns.ticket

    with {:ok, path} <- Builds.path(params),
         {:ok, copy} <- Builds.copy(ticket, job_id) do
      Explore.download(conn, copy, path,
        error: fn conn, code ->
          ForgeWeb.Api.FallbackController.call(
            conn,
            {:error, Explore.refusal(ticket, copy, code)}
          )
        end
      )
    end
  end

  # A project token is a member of exactly the project it was issued for; a ticket outside the
  # caller's reach is the same 404 as one that is not there.
  defp load_ticket(%{params: %{"project" => name, "number" => number}} = conn, _opts) do
    case Tickets.fetch(name, number) do
      {:ok, ticket, project} ->
        if member?(conn, project),
          do: conn |> assign(:project, project) |> assign(:ticket, ticket),
          else: missing(conn, name, number)

      :error ->
        missing(conn, name, number)
    end
  end

  defp missing(conn, name, number) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{reason: "not_found", detail: "no ticket #{name}##{number}"}})
    |> halt()
  end

  defp member?(%{assigns: %{current_scope: %{token: %{} = token}}}, project),
    do: token.project_id == project.id

  defp member?(conn, project), do: Projects.member?(project, conn.assigns.current_scope.user)
end
