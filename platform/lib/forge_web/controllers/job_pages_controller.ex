defmodule ForgeWeb.JobPagesController do
  @moduledoc """
  A running job's door to the live store of its ticket's pages (`docs/design/pages.md` § How a
  running job reaches the store), beside `/archive` and authorised as it is.

  **The grant is the job's own git token** (`Forge.Git.Tokens.authorise_job/1`), the one the agent
  already holds as `$FORGE_GIT_TOKEN`. **Which pages it reaches is the token's job row's, never the
  path's**: a workflow job and a ticket's chat reach their ticket's pages, a project chat its own,
  and a command none (`Forge.Pages.scope_of_job/1`). Every failure of the token is the same `401`,
  and the grant ends with the job.

  - `GET /job/pages` — the pages that have a version, and whether each can be written now.
  - `GET /job/pages/:name/data` — a page's whole store: every key with its value and counter.
  - `GET`, `PUT` and `DELETE /job/pages/:name/data/:key` — one key. A write **names the counter it
    expects** (`counter` in the body, or `?counter=` on a delete): the key's, or `null` for a key it
    expects not to be there. One that is left out is a `400`, and one that is stale a `409` carrying
    what the key is now. `ForgeWeb.PageData` has the rest of the answers.
  """

  use ForgeWeb, :controller

  alias Forge.Git.Tokens
  alias Forge.Jobs.Job
  alias Forge.{Pages, Repo}
  alias ForgeWeb.PageData

  def index(conn, _params) do
    with {:ok, job} <- authorise(conn),
         {:ok, scope} <- scope(job) do
      json(conn, %{pages: PageData.pages(scope)})
    else
      {:error, reason} -> reply(conn, reason)
    end
  end

  def data(conn, %{"name" => name}) do
    with {:ok, job} <- authorise(conn),
         {:ok, page} <- Pages.job_page(job, name) do
      json(conn, PageData.data(page, Pages.entries(page), Pages.read_only(Pages.scope(page))))
    else
      {:error, reason} -> reply(conn, reason)
    end
  end

  def show(conn, %{"name" => name, "key" => key}) do
    with {:ok, job} <- authorise(conn),
         {:ok, page} <- Pages.job_page(job, name),
         %{} = entry <- Pages.entry(page, key) do
      json(conn, PageData.entry(entry))
    else
      nil -> reply(conn, :not_found)
      {:error, reason} -> reply(conn, reason)
    end
  end

  def put(conn, %{"name" => name, "key" => key} = params) do
    with {:ok, job} <- authorise(conn),
         {:ok, counter} <- counter(params),
         {:ok, value} <- PageData.value(params),
         {:ok, entry} <- Pages.job_write(job, name, {:set, key, value}, counter: counter) do
      json(conn, PageData.entry(entry))
    else
      {:error, reason} -> reply(conn, reason)
    end
  end

  def delete(conn, %{"name" => name, "key" => key} = params) do
    with {:ok, job} <- authorise(conn),
         {:ok, counter} <- counter(params),
         {:ok, deleted} <- Pages.job_write(job, name, {:delete, key}, counter: counter) do
      json(conn, %{deleted: deleted != nil, key: key})
    else
      {:error, reason} -> reply(conn, reason)
    end
  end

  # -- the grant --------------------------------------------------------------------------------

  defp authorise(conn) do
    with ["Bearer " <> secret] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Tokens.authorise_job(secret),
         %Job{} = job <- Repo.get(Job, token.job_id) do
      {:ok, job}
    else
      _other -> {:error, :unauthorized}
    end
  end

  defp scope(job) do
    case Pages.scope_of_job(job) do
      nil -> {:error, :forbidden}
      scope -> {:ok, scope}
    end
  end

  defp counter(params) do
    case PageData.counter(params) do
      {:ok, counter} -> {:ok, counter}
      :missing -> {:error, :counter_required}
      :invalid -> {:error, :bad_counter}
    end
  end

  defp reply(conn, :unauthorized),
    do: conn |> put_status(:unauthorized) |> json(%{error: %{reason: "unauthorized"}})

  defp reply(conn, reason), do: PageData.error(conn, reason)
end
