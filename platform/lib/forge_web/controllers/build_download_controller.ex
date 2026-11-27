defmodule ForgeWeb.BuildDownloadController do
  @moduledoc """
  A download out of a ticket's kept command copy, for a member of its project
  (`docs/design/ui.md` § The explorer, criterion 16): the whole copy or one folder as one archive,
  one file as itself. **Nothing is stored**: the machine packs it and `Forge.Explore.download/4`
  passes it to the browser as it is packed, so there is no size limit and a download cut off
  halfway starts again.

  The copy is reached only through its own ticket: a copy of another ticket, or of another
  project, answers as one that does not exist, and so does a project the viewer is not in. The
  path is checked for its shape here and again by the machine against its own disk. When the
  machine cannot answer, the answer is the sentence for why, with the status the JSON API gives
  the same refusal (`ForgeCore.Explore`).

  Nothing is recorded about who downloaded (`ui.md` § The explorer, criterion 37).
  """

  use ForgeWeb, :controller

  alias Forge.{Jobs, Tickets, WarmBuilds}
  alias ForgeCore.Explore, as: Limits
  alias ForgeWeb.BuildViews

  def show(conn, %{"project" => name, "number" => number, "job_id" => job_id} = params) do
    {ticket, project} = Tickets.fetch!(name, number)
    ForgeWeb.Access.project_scope!(conn.assigns.current_scope, project)

    with {:ok, uuid} <- Ecto.UUID.cast(job_id),
         {:ok, copy} <- WarmBuilds.copy(ticket, uuid) do
      download(conn, copy, BuildViews.path_param(params))
    else
      _not_this_tickets -> raise Ecto.NoResultsError, queryable: Jobs.Job
    end
  end

  defp download(conn, copy, path) do
    if is_binary(path) and Limits.path_ok?(path) do
      Application.get_env(:forge, :explore_module, Forge.Explore).download(conn, copy, path,
        error: &refuse/2
      )
    else
      refuse(conn, :path_refused)
    end
  end

  @doc false
  # The status each way of not answering has, the API's (`docs/design/api-and-ui.md` § JSON API).
  def refuse(conn, code) do
    conn
    |> put_status(status(code))
    |> text(Limits.sentence(code) <> ".")
  end

  defp status(:machine_not_answering), do: 504
  defp status(:machine_not_connected), do: 503
  defp status(:machine_outdated), do: 409
  defp status(code) when code in [:copy_gone, :no_copy, :path_not_found], do: 404
  defp status(:path_refused), do: 400
  defp status(code) when code in [:not_a_folder, :not_a_file], do: 409
  defp status(:not_text), do: 422
  defp status(_other), do: 502
end
