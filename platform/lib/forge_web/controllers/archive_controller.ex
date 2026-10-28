defmodule ForgeWeb.ArchiveController do
  @moduledoc """
  The worker's door to the project's archive (`docs/design/archive.md`): what every earlier ticket
  produced, in every version, and the ledger of the jobs that ran. `GET` only, no session.

  **The grant is the job's own git token** (`Forge.Git.Tokens.authorise_job/1`), and the project is
  the one on that token's row. Nothing in the path chooses a project; a ticket number or a version
  id that is not this project's is the same `404` as one that does not exist, and every failure of
  the token is the same `401`.
  """

  use ForgeWeb, :controller

  action_fallback ForgeWeb.ArchiveFallback

  alias Forge.{Archive, Artifacts, Repo}
  alias Forge.Git.Tokens
  alias Forge.Jobs.Job
  alias Forge.Projects.Project

  def root(conn, _params) do
    with {:ok, _job, project} <- authorise(conn), do: json(conn, Archive.root(project))
  end

  def ticket(conn, %{"number" => number}) do
    with {:ok, _job, project} <- authorise(conn),
         {:ok, listing} <- found(Archive.ticket(project, number)) do
      json(conn, listing)
    end
  end

  def show(conn, %{"number" => number, "ref" => ref}) do
    with {:ok, job, project} <- authorise(conn),
         {:ok, version, facts} <- found(Archive.version(project, number, ref)),
         {:ok, body} <- body(version) do
      # Recorded once there are bytes to send: "what the job opened" is what it was given.
      Archive.record_read(job, version, facts)
      send_body(conn, body)
    end
  end

  defp found({:ok, _} = ok), do: ok
  defp found({:ok, _, _} = ok), do: ok
  defp found(:not_found), do: {:error, :not_found}

  defp authorise(conn) do
    with ["Bearer " <> secret] <- get_req_header(conn, "authorization"),
         {:ok, token} <- Tokens.authorise_job(secret),
         %Job{} = job <- Repo.get(Job, token.job_id),
         %Project{} = project <- Repo.get(Project, token.project_id) do
      {:ok, job, project}
    else
      _other -> {:error, :unauthorized}
    end
  end

  defp body(version) do
    case Artifacts.served(version, Path.join(System.tmp_dir!(), "forge-download")) do
      {kind, bytes} when kind in [:text, :bytes] -> {:ok, {:bytes, bytes}}
      {:file, path} -> {:ok, {:file, path}}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  # Bytes as stored, whatever they are: the only reader is a worker writing them to a file.
  defp send_body(conn, {:bytes, bytes}) do
    conn |> put_resp_content_type("application/octet-stream", nil) |> send_resp(200, bytes)
  end

  defp send_body(conn, {:file, path}) do
    conn |> put_resp_content_type("application/octet-stream", nil) |> send_file(200, path)
  after
    File.rm(path)
  end
end
