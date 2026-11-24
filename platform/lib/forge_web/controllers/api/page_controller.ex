defmodule ForgeWeb.Api.PageController do
  @moduledoc """
  A ticket's pages and the live stores they keep, over the JSON API for a person's token and a
  project's (`docs/design/pages.md` § How a running job reaches the store). A project chat's
  pages are not here: the API has no chat routes.

  - `GET .../pages` — the pages that have a version, each with its latest version and file names.
  - `GET .../pages/:name/data` — the store: every key with its value and counter.
  - `GET`, `PUT` and `DELETE .../pages/:name/data/:key` — one key.

  **A project token's write names the counter it expects**, like a job's: the key's counter, or
  `null` for a key it expects not to be there, and one that omits it is a `400`. A stale one is a
  `409` carrying the key as it is now, so a script never overwrites typing it has not seen. A
  person's token may name one and otherwise writes last-write-wins, as a person does in the page.

  What a write may do — a ticket that is done or cancelled refuses it, and so do the limits — is
  `Forge.Pages`', asked under the page's row lock. Reads need the same reach as the ticket, a token
  read access; a write goes through `Forge.Operator.write_page/5`, which asks `:use` — a token holds
  it only with write access, and `ForgeWeb.Plugs.ApiAccess` refuses a read token before anything is
  looked up. A value is never
  logged (`ForgeWeb.PageData`).
  """

  use ForgeWeb, :controller

  alias Forge.{Operator, Pages, Projects, Tickets}
  alias ForgeWeb.PageData

  plug ForgeWeb.Plugs.ApiAccess, :writable when action in [:put, :delete]
  plug :load_ticket

  def index(conn, _params),
    do: json(conn, %{pages: PageData.pages({:ticket, conn.assigns.ticket.id})})

  def data(conn, %{"name" => name}) do
    case page(conn, name) do
      {:ok, page} ->
        json(conn, PageData.data(page, Pages.entries(page), Pages.read_only(Pages.scope(page))))

      {:error, reason} ->
        PageData.error(conn, reason)
    end
  end

  def show(conn, %{"name" => name, "key" => key}) do
    with {:ok, page} <- page(conn, name),
         %{} = entry <- Pages.entry(page, key) do
      json(conn, PageData.entry(entry))
    else
      nil -> PageData.error(conn, :not_found)
      {:error, reason} -> PageData.error(conn, reason)
    end
  end

  def put(conn, %{"name" => name, "key" => key} = params) do
    with {:ok, page} <- page(conn, name),
         {:ok, opts} <- counter(params),
         {:ok, value} <- PageData.value(params),
         {:ok, entry} <- Operator.write_page(page, actor(conn), key, {:set, value}, opts) do
      json(conn, PageData.entry(entry))
    else
      {:error, reason} -> PageData.error(conn, reason)
    end
  end

  def delete(conn, %{"name" => name, "key" => key} = params) do
    with {:ok, page} <- page(conn, name),
         {:ok, opts} <- counter(params),
         {:ok, deleted} <- Operator.write_page(page, actor(conn), key, :delete, opts) do
      json(conn, %{deleted: deleted != nil, key: key})
    else
      {:error, reason} -> PageData.error(conn, reason)
    end
  end

  # A page of this ticket, and no other: the scope is the ticket this request already reached.
  defp page(conn, name) do
    case Pages.get({:ticket, conn.assigns.ticket.id}, name) do
      nil -> {:error, :not_found}
      page -> {:ok, page}
    end
  end

  # The counter a write names. Left out, a person's write is last-write-wins and a token's is
  # refused by `Forge.Operator.write_page/5` (`:counter_required`), which asks for it of a token only.
  defp counter(params) do
    case PageData.counter(params) do
      {:ok, counter} -> {:ok, counter: counter}
      :missing -> {:ok, []}
      :invalid -> {:error, :bad_counter}
    end
  end

  defp actor(%{assigns: %{current_scope: %{token: %{} = token}}}), do: token
  defp actor(conn), do: conn.assigns.current_scope.user

  defp load_ticket(%{params: %{"project" => name, "number" => number}} = conn, _opts) do
    # Not a member and does not exist are the same 404 (`docs/design/identity.md` § Projects and
    # members).
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

  # A project token is a member of exactly the project it was issued for.
  defp member?(%{assigns: %{current_scope: %{token: %{} = token}}}, project),
    do: token.project_id == project.id

  defp member?(conn, project), do: Projects.member?(project, conn.assigns.current_scope.user)
end
