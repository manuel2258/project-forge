defmodule ForgeWeb.WorkerStreamController do
  @moduledoc """
  The worker's door for a download of a command copy: `POST /worker-streams/:id`, chunked, the
  secret of the stream as its bearer (`docs/design/worker-tier.md` § Looking into a copy).

  **No session and no pipeline**, like the store's door: the secret authorises exactly one stream,
  which a person's request made and registered (`Forge.Explore.download/4`), and nothing else here
  does. It is compared in constant time (`Forge.Explore.Door`); a wrong one is a 403, a stream that
  is unknown, used or no longer waited for a 404. **The body is never stored**: each chunk is read,
  handed to the waiting request and acknowledged before the next is read, so a slow browser slows
  the machine through TCP and the platform holds one chunk.

  The worker says what it sends in two headers: `x-forge-kind` (`tar` or `file`) and
  `x-forge-name-b64`, the name it suggests (the underscore spelling is read too). Both are only hints for the response's headers, which
  the request process makes safe (`Forge.Explore.disposition_name/1`).
  """

  use ForgeWeb, :controller

  alias Forge.Explore.Door

  # A chunk of the body held at a time.
  @chunk 1024 * 1024

  def create(conn, %{"id" => id}) do
    with {:ok, secret} <- bearer(conn),
         {:ok, stream} <- Door.open(id, secret, kind(conn), name(conn)) do
      pump(conn, stream)
    else
      {:error, :forbidden} -> reply(conn, :forbidden, "forbidden")
      {:error, _not_found} -> reply(conn, :not_found, "not_found")
    end
  end

  defp pump(conn, stream) do
    case Plug.Conn.read_body(conn, length: @chunk, read_length: @chunk) do
      {:ok, data, conn} ->
        case hand_over(stream, data) do
          :ok ->
            Door.finish(stream)
            conn |> put_status(:ok) |> json(%{ok: true})

          :aborted ->
            reply(conn, :gone, "gone")
        end

      {:more, data, conn} ->
        case hand_over(stream, data) do
          :ok -> pump(conn, stream)
          :aborted -> reply(conn, :gone, "gone")
        end

      {:error, _reason} ->
        # The machine's connection broke: the owner finds out from the machine's own answer, or from
        # its silence.
        reply(conn, :bad_request, "interrupted")
    end
  end

  defp hand_over(_stream, <<>>), do: :ok

  defp hand_over(stream, data) do
    case Door.send_chunk(stream, data) do
      :ok -> :ok
      {:error, :aborted} -> :aborted
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> {:ok, secret}
      _none -> {:error, :forbidden}
    end
  end

  defp kind(conn) do
    case get_req_header(conn, "x-forge-kind") do
      ["tar"] -> "tar"
      _file -> "file"
    end
  end

  defp name(conn) do
    # With a hyphen, which is what the worker sends: a proxy may drop a header with an underscore in
    # its name (nginx does by default). The underscore form is read too, for a worker that spells it so.
    headers = get_req_header(conn, "x-forge-name-b64") ++ get_req_header(conn, "x-forge-name_b64")

    with [encoded | _rest] <- headers,
         {:ok, name} <- Base.decode64(encoded) do
      name
    else
      _none -> "download"
    end
  end

  defp reply(conn, status, reason) do
    conn |> put_status(status) |> json(%{error: %{reason: reason, detail: nil}})
  end
end
