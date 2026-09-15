defmodule ForgeWeb.WorkerSocket do
  @moduledoc """
  Where workers dial in. The worker dials out because the platform is then the only process
  that listens: a worker has no inbound port, no certificate, no stable address, and is
  destroyed several times a day. See `docs/design/worker-channel.md`.

  The token authenticates the machine and nothing else. Everything a worker may touch beyond
  this socket — a store key, a git ref — is its own short-lived scoped token, minted per
  assignment.

  **It arrives in a header, never the query string.** A URL is recorded by every proxy, access
  log and tracing span between the worker and the platform, and this token is long lived and
  grants the channel for the life of the machine — a copy in a reverse proxy's access log is an
  identity anyone with read access can replay. `worker_id` stays in the query string because it
  is an identifier rather than a secret, and it keeps a failed connection legible in a log.
  There is no query-parameter fallback: see `docs/design/worker-channel.md` § Authentication.
  """

  use Phoenix.Socket

  alias Forge.Workers

  channel "worker:*", ForgeWeb.WorkerChannel

  @impl true
  def connect(%{"worker_id" => worker_id}, socket, connect_info) do
    with token when is_binary(token) <- header_token(connect_info),
         {:ok, worker} <- Workers.authenticate(worker_id, token) do
      {:ok, assign(socket, :worker_id, worker.id)}
    else
      _other -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # `x-forge-worker-token` and not `authorization`: Phoenix's socket transport forwards only
  # `x-` prefixed headers to `connect/3` — `:x_headers` means exactly that. The store is an
  # ordinary request rather than a handshake, so it uses `Authorization: Bearer`.
  defp header_token(%{x_headers: headers}) do
    Enum.find_value(headers, fn
      {"x-forge-worker-token", token} when token != "" -> token
      _other -> nil
    end)
  end

  defp header_token(_connect_info), do: nil

  @impl true
  def id(socket), do: "worker:#{socket.assigns.worker_id}"
end
