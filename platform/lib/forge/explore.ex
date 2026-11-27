defmodule Forge.Explore do
  @moduledoc """
  Looking into a ticket's **command copy**, asked live of the machine that holds it
  (`docs/design/worker-tier.md` § Looking into a copy, ticket 84): a folder's listing, a file's
  facts and content, its hash, and a download that is packed on the machine and passed through to
  the browser or the API client as it is packed. **Nothing of a copy is stored here**, a download
  included.

  A request is a message to the worker's channel (`ForgeWeb.WorkerChannel`) carrying a `ref`; the
  machine answers with the same `ref` (`ok`, `error`, or `progress` while it hashes or packs), and
  only the connection that was asked may answer. **Fifteen seconds without any word for a ref is
  *did not answer*** (`:explore_answer_ms`, which `ForgeCore.Explore.answer_ms/0` defaults), and
  progress resets it.

  **The platform does not decide what is in a copy**: it asks about a ticket's copy by the
  ticket's id and the id of the command that kept it, and the machine checks both against its own
  disk before a path is built (`ForgeWorker.Explore`). A `t:Forge.WarmBuilds.copy/0` is only ever
  made by `Forge.WarmBuilds.copy/2` — of *this* ticket — so a request for another ticket's copy
  never gets as far as a machine.

  Paths are the raw bytes of a name and need not be text, so they cross the channel in base64
  (`path_b64`). **A path with `..`, an absolute one or one with a NUL is refused here too**
  (`ForgeCore.Explore.path_ok?/1`), which is the shape; the machine resolves each component with
  `lstat` and never follows a link, which is the guard.

  Not recorded as anything: nobody's looking is an event (`refinement.md` criterion 37).
  """

  alias Forge.Workers
  alias Forge.Workers.Worker
  alias ForgeCore.Explore, as: Shared

  require Logger

  @explore_protocol 18
  @streams Forge.Explore.Streams
  # The longest download name, in bytes (`disposition_name/1`).
  @name_bytes 200

  # The words the machine answers with, as atoms, from `ForgeCore.Explore.worker_errors/0`; a word it
  # does not know is `:failed`.
  @worker_codes Map.new(Shared.worker_errors(), &{&1, String.to_atom(&1)})

  @kinds %{"dir" => :dir, "file" => :file, "link" => :link}

  @type code :: atom()
  @type on_progress :: (non_neg_integer(), non_neg_integer() | nil -> any()) | nil

  @doc "The first worker protocol that answers an `explore`."
  @spec explore_protocol() :: pos_integer()
  def explore_protocol, do: @explore_protocol

  @doc "The name of the registry a download waits in, for the stream door."
  @spec streams() :: module()
  def streams, do: @streams

  @doc """
  Whether a machine can be asked now: `:ok`, `{:error, :machine_outdated}` for a release below
  protocol 18 (which takes every job as before and cannot explore), or `{:error,
  :machine_not_connected}`. The release is asked first: a machine that is not connected and is old
  will not answer when it is back either.
  """
  @spec status(Worker.t()) :: :ok | {:error, :machine_outdated | :machine_not_connected}
  def status(%Worker{protocol: protocol})
      when not is_integer(protocol) or protocol < @explore_protocol,
      do: {:error, :machine_outdated}

  def status(%Worker{id: id}) do
    if Workers.connected?(id), do: :ok, else: {:error, :machine_not_connected}
  end

  # -- asking ------------------------------------------------------------------------------------

  @doc """
  One page of a folder: `{:ok, %{entries: [entry], total: n, offset: n}}` — at most
  `ForgeCore.Explore.page_size/0` entries from `offset`, folders first and then files, by name —
  or `{:error, code}`.
  """
  @spec list(map(), binary(), non_neg_integer()) ::
          {:ok, %{entries: [map()], total: non_neg_integer(), offset: non_neg_integer()}}
          | {:error, code()}
  def list(copy, path, offset) when is_integer(offset) and offset >= 0 do
    with {:ok, answer} <- request(copy, "list", path, %{"offset" => offset}, nil) do
      entries = for entry <- List.wrap(answer["entries"]), decoded = entry(entry), do: decoded

      {:ok,
       %{
         entries: entries,
         total: integer(answer["total"], length(entries)),
         offset: integer(answer["offset"], offset)
       }}
    end
  end

  @doc """
  A file's facts and, for text, its first `ForgeCore.Explore.text_limit/0` bytes:
  `{:ok, %{kind:, size:, mtime:, text?:, content:, truncated?:, target:, entries:}}`. A link has its
  `target` as text and is never followed; a folder has its `entries`.
  """
  @spec file(map(), binary()) :: {:ok, map()} | {:error, code()}
  def file(copy, path) do
    with {:ok, answer} <- request(copy, "file", path, %{}, nil) do
      {:ok,
       %{
         kind: Map.get(@kinds, answer["kind"], :other),
         size: integer(answer["size"], nil),
         mtime: integer(answer["mtime"], nil),
         text?: answer["text"] == true,
         content: base64(answer["content_b64"]),
         truncated?: answer["truncated"] == true,
         target: base64(answer["target_b64"]),
         entries: integer(answer["entries"], nil)
       }}
    end
  end

  @doc """
  A regular file's SHA-256, as lower-case hex, by reading it on the machine. `on_progress` is called
  with the bytes read and the file's size while it goes, so a page can say how far it is.
  """
  @spec hash(map(), binary(), on_progress()) ::
          {:ok, %{sha256: String.t(), size: non_neg_integer() | nil}} | {:error, code()}
  def hash(copy, path, on_progress \\ nil) do
    with {:ok, answer} <- request(copy, "hash", path, %{}, on_progress) do
      case answer["sha256"] do
        hex when is_binary(hex) -> {:ok, %{sha256: hex, size: integer(answer["size"], nil)}}
        _none -> {:error, :failed}
      end
    end
  end

  # Entries the machine could not name are left out rather than shown wrong.
  defp entry(%{"name_b64" => name} = entry) when is_binary(name) do
    case Base.decode64(name) do
      {:ok, name} ->
        %{
          name: name,
          kind: Map.get(@kinds, entry["kind"], :other),
          mtime: integer(entry["mtime"], nil),
          size: integer(entry["size"], nil),
          entries: integer(entry["entries"], nil),
          target: base64(entry["target_b64"])
        }

      :error ->
        nil
    end
  end

  defp entry(_other), do: nil

  defp base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end

  defp base64(_other), do: nil

  defp integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp integer(_value, default), do: default

  defp request(copy, op, path, extra, on_progress) do
    with :ok <- path_ok(path),
         :ok <- status(copy.worker),
         {:ok, ref, channel} <- send_request(copy, op, path, extra) do
      monitor = Process.monitor(channel)
      result = await(ref, monitor, on_progress)
      Process.demonitor(monitor, [:flush])
      done(copy.worker.id, ref)
      result
    end
  end

  defp path_ok(path), do: if(Shared.path_ok?(path), do: :ok, else: {:error, :path_refused})

  defp send_request(copy, op, path, extra) do
    ref = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    payload =
      Map.merge(
        %{
          "op" => op,
          "ticket" => copy.job.ticket_id,
          "copy" => copy.job.id,
          "path_b64" => Base.encode64(path)
        },
        extra
      )

    with pid when is_pid(pid) <- Workers.whereis(copy.worker.id),
         :ok <- Workers.push(copy.worker.id, {:explore, ref, self(), payload}) do
      {:ok, ref, pid}
    else
      _not_connected -> {:error, :machine_not_connected}
    end
  end

  defp answer_ms,
    do: Application.get_env(:forge, :explore_answer_ms, Shared.answer_ms())

  defp await(ref, monitor, on_progress) do
    receive do
      {:explored, ^ref, %{"ok" => ok}} when is_map(ok) ->
        {:ok, ok}

      {:explored, ^ref, %{"error" => code}} ->
        {:error, Map.get(@worker_codes, code, :failed)}

      {:explored, ^ref, %{"progress" => progress}} ->
        progressed(on_progress, progress)
        await(ref, monitor, on_progress)

      {:explored, ^ref, _unreadable} ->
        {:error, :failed}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :machine_not_connected}
    after
      answer_ms() -> {:error, :machine_not_answering}
    end
  end

  defp progressed(fun, %{"done" => done} = progress)
       when is_function(fun, 2) and is_integer(done),
       do: fun.(done, integer(progress["total"], nil))

  defp progressed(_fun, _progress), do: :ok

  # The channel forgets a ref once it is answered; one that is not (a timeout) is told to, so a late
  # answer is not sent to a process that has moved on, and what already arrived is flushed.
  defp done(worker_id, ref) do
    Workers.push(worker_id, {:explore_cancel, ref})

    receive do
      {:explored, ^ref, _late} -> done(worker_id, ref)
    after
      0 -> :ok
    end
  end

  # -- refusals ----------------------------------------------------------------------------------

  @doc """
  What an answer's error is, with what a client needs to act on it, as `{:explore, code, extra}`
  (`ForgeWeb.Api.FallbackController` turns it into a status and a body): a machine that is not
  connected says until when its copy can be explored once it is back, and a copy the machine does
  not have says whether a later command replaced it, or it was swept.
  """
  @spec refusal(Forge.Tickets.Ticket.t(), map(), atom()) :: {:explore, atom(), map()}
  def refusal(ticket, copy, :machine_not_connected) do
    {:explore, :machine_not_connected,
     %{explorable_until: Forge.WarmBuilds.explorable_until(ticket, copy.worker.id)}}
  end

  def refusal(ticket, copy, code) when code in [:no_copy, :copy_gone],
    do: gone(ticket, copy.job.id, copy.worker.id)

  def refusal(_ticket, _copy, code), do: {:explore, code, %{}}

  @doc """
  The refusal for a copy `Forge.WarmBuilds.copy/2` did not find: `:not_found` for an id that is no
  command of this ticket that kept a build (another ticket's included, which must not be told
  apart), else *the copy is gone* with why.
  """
  @spec missing(Forge.Tickets.Ticket.t(), term()) :: :not_found | {:explore, atom(), map()}
  def missing(ticket, job_id) do
    case Forge.WarmBuilds.kept_command(ticket, job_id) do
      nil -> :not_found
      %{worker_id: nil} -> :not_found
      job -> gone(ticket, job.id, job.worker_id)
    end
  end

  defp gone(ticket, job_id, worker_id) do
    %{why: why, replaced_by: replaced_by} = Forge.WarmBuilds.gone(ticket, job_id, worker_id)
    {:explore, :copy_gone, %{why: why, replaced_by: replaced_by && replaced_by.id}}
  end

  # -- downloading -------------------------------------------------------------------------------

  @doc """
  Streams a copy, a folder of it or one file to `conn`: the machine packs a tar (a file is sent as
  itself) and POSTs it to the stream door (`ForgeWeb.WorkerStreamController`), which hands each
  chunk to this process and waits for it to be written before reading the next. **A slow client
  slows `tar` through TCP, and nothing here holds more than a chunk.** Stored nowhere.

  `opts`: `:error` (required) — `fn conn, code -> conn` that answers a refusal before anything was
  sent; `:filename` — the name offered, else the machine's.

  A failure after the response has begun cannot be a status any more: the connection is ended
  without the last chunk, which a client reads as a download that did not finish, and a client
  starts again from the beginning (`refinement.md` criterion 6).
  """
  @spec download(Plug.Conn.t(), map(), binary(), keyword()) :: Plug.Conn.t()
  def download(conn, copy, path, opts) do
    error = Keyword.fetch!(opts, :error)

    with :ok <- path_ok(path),
         :ok <- status(copy.worker),
         {:ok, id, secret} <- register_stream(),
         {:ok, ref, channel} <- send_download(copy, path, id, secret) do
      monitor = Process.monitor(channel)

      try do
        stream(conn, ref, monitor, opts, %{door: nil, done?: false, answered?: false}, error)
      after
        Registry.unregister(@streams, id)
        Process.demonitor(monitor, [:flush])
        done(copy.worker.id, ref)
      end
    else
      {:error, code} -> error.(conn, code)
    end
  end

  defp register_stream do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    case Registry.register(@streams, id, secret) do
      {:ok, _owner} -> {:ok, id, secret}
      {:error, _taken} -> {:error, :failed}
    end
  end

  defp send_download(copy, path, id, secret) do
    case send_request(copy, "download", path, %{"stream" => id, "secret" => secret}) do
      {:ok, ref, channel} -> {:ok, ref, channel}
      {:error, code} -> {:error, code}
    end
  end

  # One loop for the whole download, since three senders talk to this process: the machine's
  # channel (`explored`), the stream door (open, chunk, done) and the monitors. Every word resets the
  # silence timer, which is what makes progress keep a long pack alive.
  defp stream(conn, ref, monitor, opts, state, error) do
    receive do
      {:stream_open, door_ref, door, kind, name} when is_nil(state.door) ->
        Process.monitor(door)
        conn = start_response(conn, kind, name, opts)
        send(door, {:stream_accepted, door_ref})
        stream(conn, ref, monitor, opts, %{state | door: {door_ref, door}}, error)

      {:stream_open, door_ref, door, _kind, _name} ->
        send(door, {:stream_refused, door_ref})
        stream(conn, ref, monitor, opts, state, error)

      {:stream_chunk, door_ref, data}
      when state.door != nil and elem(state.door, 0) == door_ref ->
        {_ref, door} = state.door

        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} ->
            send(door, {:stream_ack, door_ref})
            stream(conn, ref, monitor, opts, state, error)

          {:error, _closed} ->
            send(door, {:stream_abort, door_ref})
            conn
        end

      {:stream_done, door_ref} when state.door != nil and elem(state.door, 0) == door_ref ->
        settled(conn, ref, monitor, opts, %{state | done?: true}, error)

      {:explored, ^ref, %{"progress" => _progress}} ->
        stream(conn, ref, monitor, opts, state, error)

      {:explored, ^ref, %{"ok" => _bytes}} ->
        settled(conn, ref, monitor, opts, %{state | answered?: true}, error)

      {:explored, ^ref, %{"error" => code}} ->
        failed(conn, state, Map.get(@worker_codes, code, :failed), error)

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        failed(conn, state, :machine_not_connected, error)

      {:DOWN, _door_monitor, :process, door, _reason}
      when state.door != nil and elem(state.door, 1) == door and not state.done? ->
        failed(conn, state, :failed, error)

      {:DOWN, _other, :process, _pid, _reason} ->
        stream(conn, ref, monitor, opts, state, error)
    after
      answer_ms() ->
        # A download whose bytes all arrived and whose answer did not is a download: the answer is
        # only the machine saying how many.
        if state.done?, do: conn, else: failed(conn, state, :machine_not_answering, error)
    end
  end

  # The download is over when its bytes have all arrived and the machine has said how many.
  defp settled(conn, _ref, _monitor, _opts, %{done?: true, answered?: true}, _error), do: conn

  defp settled(conn, ref, monitor, opts, state, error),
    do: stream(conn, ref, monitor, opts, state, error)

  defp failed(conn, %{door: nil}, code, error), do: error.(conn, code)

  defp failed(_conn, _state, code, _error) do
    Logger.warning("a download of a command copy failed after it began: #{code}")
    raise Forge.Explore.DownloadFailed, code: code
  end

  defp start_response(conn, kind, name, opts) do
    type = if kind == "tar", do: "application/x-tar", else: "application/octet-stream"
    filename = disposition_name(opts[:filename] || name)

    conn
    |> Plug.Conn.put_resp_content_type(type, nil)
    |> Plug.Conn.put_resp_header("content-disposition", disposition(filename))
    |> Plug.Conn.put_resp_header("x-accel-buffering", "no")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_chunked(200)
  end

  @doc """
  A file name that is safe in a `content-disposition` header: valid text, no path separator, no
  control character, no quote, at most 200 bytes; `download` for a name that leaves nothing.
  """
  @spec disposition_name(term()) :: String.t()
  def disposition_name(name) when is_binary(name) do
    clean =
      name
      |> String.replace_invalid("")
      |> String.replace(~r/[\x00-\x1f\x7f\/\\":;]/u, "_")
      |> cut_bytes(@name_bytes)
      |> String.trim()

    if clean == "" or clean == "." or clean == "..", do: "download", else: clean
  end

  def disposition_name(_other), do: "download"

  # By bytes, since it is bytes a header has: `String.slice/3` counts graphemes, and one letter with
  # two thousand combining marks is one. Cut at the last whole character.
  defp cut_bytes(text, max) when byte_size(text) <= max, do: text
  defp cut_bytes(text, max), do: text |> binary_part(0, max) |> whole_characters()

  defp whole_characters(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: whole_characters(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  defp disposition(name) do
    ascii = String.replace(name, ~r/[^\x20-\x7e]/, "_")

    encoded = URI.encode(name, &URI.char_unreserved?/1)
    "attachment; filename=\"" <> ascii <> "\"; filename*=UTF-8''" <> encoded
  end
end

defmodule Forge.Explore.DownloadFailed do
  @moduledoc """
  A download that failed after its response had begun: nothing can be said to the client any more,
  so the connection is ended without the last chunk (`Forge.Explore.download/4`).
  """

  defexception [:code]

  @impl true
  def message(%{code: code}), do: "a download of a command copy failed after it began: #{code}"
end
