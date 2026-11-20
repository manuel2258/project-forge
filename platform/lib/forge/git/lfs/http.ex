defmodule Forge.Git.Lfs.Http do
  @moduledoc """
  The Git LFS requests under a project's `info/lfs`, served for a token `ForgeWeb.Plugs.GitHttp`
  has already authorised: the batch, an object's download and its upload, and locking's `501`.
  Always returns a sent conn, or `:unauthorised` for a batch that asks to upload with a token that
  may not push — the plug sends that 401 as it sends every other.

  `docs/design/git-hosting.md` § Git LFS. Nothing here logs a header, and no response carries a
  token anywhere but in the `Authorization` header the request itself arrived with.
  """

  import Plug.Conn

  alias Forge.Git.{Lfs, Tokens, Url}
  alias Forge.Git.Lfs.Batch
  alias Forge.Git.Token
  alias Forge.Projects
  alias Forge.Projects.Project

  require Logger

  @chunk 1_000_000
  @content_type "application/vnd.git-lfs+json"

  @spec serve(Plug.Conn.t(), Project.t(), [String.t()], Token.t()) ::
          Plug.Conn.t() | :unauthorised
  def serve(
        %Plug.Conn{method: "POST"} = conn,
        project,
        ["info", "lfs", "objects", "batch"],
        token
      ),
      do: batch(conn, project, token)

  def serve(%Plug.Conn{method: "GET"} = conn, project, ["info", "lfs", "objects", oid], _token),
    do: download(conn, project, oid)

  def serve(%Plug.Conn{method: "PUT"} = conn, project, ["info", "lfs", "objects", oid], _token),
    do: upload(conn, project, oid)

  # Locking is not built: 501 is what a client reads as "this server has none", and carries on.
  def serve(conn, _project, ["info", "lfs", "locks" | _rest], _token),
    do: json(conn, 501, %{"message" => "forge does not serve LFS file locking"})

  def serve(conn, _project, _tail, _token), do: json(conn, 404, %{"message" => "not found"})

  # --- The batch -----------------------------------------------------------------------------

  defp batch(conn, project, token) do
    case read_limited(conn, Batch.max_body_bytes()) do
      {:ok, body, conn} -> batch(conn, project, token, Jason.decode(body))
      {:error, :too_large, conn} -> json(conn, 413, %{"message" => "the request is too large"})
      {:error, _reason, conn} -> json(conn, 400, %{"message" => "the request could not be read"})
    end
  end

  defp batch(conn, _project, _token, {:error, _reason}),
    do: json(conn, 422, %{"message" => "the body is not JSON"})

  defp batch(conn, project, token, {:ok, request}) do
    if Batch.operation(request) == {:ok, :upload} and not Tokens.permits?(token, :write) do
      :unauthorised
    else
      repo = Projects.repo_path(project)
      base = base_url(project, token)

      env = %{
        held?: &Lfs.held?(repo, &1),
        limit: Lfs.max_object_bytes(),
        download_href: &"#{base}/info/lfs/objects/#{&1}",
        upload_href: &"#{base}/info/lfs/objects/#{&1}?size=#{&2}",
        authorization: List.first(get_req_header(conn, "authorization"))
      }

      case Batch.respond(request, env) do
        {:ok, body, touch} ->
          Enum.each(touch, &Lfs.touch(repo, &1))
          json(conn, 200, body)

        {:error, status, message} ->
          json(conn, status, %{"message" => message})
      end
    end
  end

  # The address that holder was handed: a job dials from its machine, a person from wherever they
  # are, and the two are not the same address (`Forge.Git.Url`).
  defp base_url(project, %Token{job_id: nil}), do: Url.for(project)
  defp base_url(project, %Token{}), do: Url.for_worker(project)

  # --- Download ------------------------------------------------------------------------------

  defp download(conn, project, oid) do
    with {:ok, path} <- Lfs.path(Projects.repo_path(project), oid),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      _missing -> json(conn, 404, %{"message" => "object not found"})
    end
  end

  # --- Upload --------------------------------------------------------------------------------

  defp upload(conn, project, oid) do
    repo = Projects.repo_path(project)

    with {:ok, _path} <- Lfs.path(repo, oid),
         {:ok, size} <- declared_size(conn),
         :ok <- length_matches(conn, size),
         :ok <- within_limit(size) do
      case Lfs.put(repo, oid, size, &read_chunk/1, {conn, false}) do
        {:ok, {conn, _done}} ->
          send_resp(conn, 200, "")

        {{:error, reason}, {conn, _done}} ->
          refuse(conn, reason)
      end
    else
      :error -> json(conn, 404, %{"message" => "object not found"})
      {:error, status, message} -> json(conn, status, %{"message" => message})
    end
  end

  # A size is up to 19 digits, so what is parsed is an integer of a size a request cannot choose to be
  # large; a longer one is a 400 here, where it would otherwise be a 413 or a 400 further on.
  defp declared_size(conn) do
    with %{"size" => size} <- Plug.Conn.Query.decode(conn.query_string),
         true <- is_binary(size) and Regex.match?(~r/\A[0-9]{1,19}\z/, size) do
      {:ok, String.to_integer(size)}
    else
      _none -> {:error, 400, "an upload names its size"}
    end
  end

  # **Dropping the comparison is an equivalent mutant**: a body that is not `size` bytes is refused
  # when it has been counted (`Forge.Git.Lfs.put/5`), with the same 400. This is the early refusal,
  # before a byte is read, for a client that says its length.
  defp length_matches(conn, size) do
    case get_req_header(conn, "content-length") do
      [] ->
        :ok

      [value | _rest] ->
        if value == Integer.to_string(size),
          do: :ok,
          else: {:error, 400, "the body's length is not the size the batch declared"}
    end
  end

  defp within_limit(size) do
    limit = Lfs.max_object_bytes()

    if size > limit,
      do:
        {:error, 413,
         "object is #{size} bytes; this forge accepts at most #{limit} bytes per LFS object"},
      else: :ok
  end

  # One chunk at a time, so memory stays at one chunk however large the object. The final chunk
  # arrives with `{:ok, ...}`, so `done` is what turns the next call into the end.
  defp read_chunk({conn, true}), do: {:eof, {conn, true}}

  defp read_chunk({conn, false}) do
    case read_body(conn, length: @chunk, read_timeout: 60_000) do
      {:ok, chunk, conn} -> {:ok, chunk, {conn, true}}
      {:more, chunk, conn} -> {:ok, chunk, {conn, false}}
      {:error, reason} -> {:error, reason, {conn, false}}
    end
  end

  defp refuse(conn, :size),
    do: json(conn, 400, %{"message" => "the body is not the size the batch declared"})

  defp refuse(conn, :hash),
    do: json(conn, 400, %{"message" => "the body does not hash to the object's oid"})

  defp refuse(conn, {:read, reason}) do
    Logger.warning("could not read an LFS upload: #{inspect(reason)}")
    json(conn, 400, %{"message" => "the upload was interrupted"})
  end

  defp refuse(conn, reason) do
    Logger.error("could not keep an LFS object: #{inspect(reason)}")
    json(conn, 500, %{"message" => "the object could not be kept"})
  end

  # --- Plumbing ------------------------------------------------------------------------------

  # At most `max` bytes: one byte more is read to tell a body of exactly `max` from a longer one.
  defp read_limited(conn, max) do
    case read_body(conn, length: max + 1, read_timeout: 15_000) do
      {:ok, body, conn} when byte_size(body) <= max -> {:ok, body, conn}
      {:ok, _body, conn} -> {:error, :too_large, conn}
      {:more, _body, conn} -> {:error, :too_large, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, Jason.encode!(body))
  end
end
