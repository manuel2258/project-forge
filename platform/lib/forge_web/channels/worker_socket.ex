defmodule ForgeWeb.WorkerSocket do
  @moduledoc """
  Where workers dial in. The worker dials out because the platform is then the only process
  that listens: a worker has no inbound port, no certificate, no stable address, and is
  destroyed several times a day. See `docs/design/worker-channel.md`.

  The token authenticates the machine and nothing else. Everything a worker may touch beyond
  this socket — a store key, a git ref — is its own short-lived scoped token, minted per
  assignment.
  """

  use Phoenix.Socket

  alias Forge.Workers

  channel "worker:*", ForgeWeb.WorkerChannel

  @impl true
  def connect(%{"worker_id" => worker_id, "token" => token}, socket, _connect_info) do
    case Workers.authenticate(worker_id, token) do
      {:ok, worker} -> {:ok, assign(socket, :worker_id, worker.id)}
      :error -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "worker:#{socket.assigns.worker_id}"
end
