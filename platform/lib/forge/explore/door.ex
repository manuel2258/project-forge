defmodule Forge.Explore.Door do
  @moduledoc """
  The stream door's half of a download (`Forge.Explore.download/4` is the other): the request
  process that waits for a machine's POST, and this, which the POST's own process runs.

  A download **meets in the middle**: the browser's request registered a random stream id with a
  secret in `Forge.Explore.Streams` and asked the machine, and the machine POSTs the packed bytes to
  `/worker-streams/:id` with the secret as its bearer. Nothing here stores them: `send_chunk/2` hands
  one chunk to the waiting request and returns only once that request has written it to its client,
  so the next is not read from the machine until the client has taken this one. A slow browser slows
  `tar` through TCP, and nothing piles up.

  **A stream is used once, and only with its secret.** `open/4` compares the secret in constant
  time, and the owner accepts the first opener only (`Forge.Explore`'s loop refuses a second).
  """

  alias Forge.Explore

  # How long the owner has to take the opener, and to write one chunk to a slow client. Generous:
  # a phone on a bad link is a real reader, and the owner's own silence timer is what ends a stream
  # whose machine went quiet.
  @accept_ms 5_000
  @chunk_ms 120_000

  @type stream :: %{ref: reference(), owner: pid(), monitor: reference()}

  @doc """
  Opens the stream `id` with its `secret`: `{:ok, stream}`, `{:error, :forbidden}` for a wrong
  secret, `{:error, :not_found}` for a stream that is not waiting or was used. `kind` is `"tar"`
  or `"file"` and `name` the machine's suggested file name; the owner decides the response from them.
  """
  @spec open(String.t(), String.t(), String.t(), binary()) :: {:ok, stream()} | {:error, atom()}
  def open(id, secret, kind, name) when is_binary(id) and is_binary(secret) do
    case Registry.lookup(Explore.streams(), id) do
      [{owner, expected}] ->
        if Plug.Crypto.secure_compare(secret, expected),
          do: ask_owner(owner, kind, name),
          else: {:error, :forbidden}

      [] ->
        {:error, :not_found}
    end
  end

  def open(_id, _secret, _kind, _name), do: {:error, :not_found}

  defp ask_owner(owner, kind, name) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:stream_open, ref, self(), kind, name})

    receive do
      {:stream_accepted, ^ref} ->
        {:ok, %{ref: ref, owner: owner, monitor: monitor}}

      {:stream_refused, ^ref} ->
        Process.demonitor(monitor, [:flush])
        {:error, :not_found}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :not_found}
    after
      @accept_ms ->
        Process.demonitor(monitor, [:flush])
        {:error, :not_found}
    end
  end

  @doc """
  Hands one chunk to the request that waits and returns when it has been written to its client:
  `:ok`, or `{:error, :aborted}` when the client went away or the request ended, which tells the
  caller to stop reading.
  """
  @spec send_chunk(stream(), binary()) :: :ok | {:error, :aborted}
  def send_chunk(%{ref: ref, owner: owner, monitor: monitor}, data) do
    send(owner, {:stream_chunk, ref, data})

    receive do
      {:stream_ack, ^ref} -> :ok
      {:stream_abort, ^ref} -> {:error, :aborted}
      {:DOWN, ^monitor, :process, _pid, _reason} -> {:error, :aborted}
    after
      @chunk_ms -> {:error, :aborted}
    end
  end

  @doc "Says the machine's body ended: every chunk was sent."
  @spec finish(stream()) :: :ok
  def finish(%{ref: ref, owner: owner, monitor: monitor}) do
    send(owner, {:stream_done, ref})
    Process.demonitor(monitor, [:flush])
    :ok
  end
end
