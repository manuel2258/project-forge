defmodule ForgeWorker.Archive.Server do
  @moduledoc """
  A read-only 9P2000.L server on a unix socket, which the kernel's own client mounts
  (`docs/design/archive.md` § The worker's side).

  It accepts **one** connection — the kernel's — and then stops listening. Everything it answers is
  decided here: the layout from `ForgeWorker.Archive.Tree`, the bytes from `ForgeWorker.Archive.Client`,
  the wire format from `ForgeWorker.Archive.P9`.

  A request that needs the network is not answered at once: it waits, in `waiting` by its tag, and
  is dispatched again — whole, because dispatch can safely be run twice — when what it
  waited for has arrived, or failed. Meanwhile the connection is served, and a `Tflush` removes the
  waiter, so an interrupted `open` does not keep a download's answer to send.

  - **Listings** are fetched on first need and again once `:archive_listing_ttl_ms` has passed;
    a refresh that fails keeps what there was.
  - **A file** is fetched when it is opened, into a cache keyed by the version's id, and a file in
    the cache is never fetched again. An open fid holds the file it opened, and an open folder the
    names it listed, so a refresh never tears a read.
  - **Nothing is writable.** Every message that would change anything is `EROFS`, a `lopen` that
    writes is `EROFS`, and the tree is only ever built from the platform's listings.
  """

  use GenServer

  alias ForgeWorker.Archive.{Client, P9, Tree}
  alias ForgeWorker.Log

  require Logger

  @default_ttl_ms 60_000
  @max_msize 524_288
  @header 11

  @doc """
  Starts a server. Options: `:path` (the socket), `:remove_dir` (a directory made for it, removed
  with it), `:cache_dir`, `:config` (`Client.config/0`), `:job_id`, `:name` (a `GenServer` name).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Stops the server, closing its socket and removing what it cached."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 15_000)
  catch
    :exit, _reason -> :ok
  end

  # -- GenServer ----------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :path)
    File.rm(path)

    # Not reachable by the job's user: the socket sits in a directory `ForgeWorker.Archive` made for
    # it, mode 0700 and named at random, which only this process's user enters.
    case :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, path}}, active: false, packet: :raw]) do
      {:ok, listener} -> {:ok, listening(listener, opts)}
      {:error, reason} -> {:stop, {:listen, reason}}
    end
  end

  defp listening(listener, opts) do
    cache_dir = Keyword.fetch!(opts, :cache_dir)
    File.rm_rf!(cache_dir)
    File.mkdir_p!(cache_dir)
    File.chmod!(cache_dir, 0o700)
    server = self()

    acceptor =
      spawn_link(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, :infinity),
             :ok <- :gen_tcp.controlling_process(socket, server) do
          send(server, {:accepted, socket})
        end
      end)

    %{
      path: Keyword.fetch!(opts, :path),
      remove_dir: Keyword.get(opts, :remove_dir),
      listener: listener,
      acceptor: acceptor,
      socket: nil,
      buffer: <<>>,
      msize: 65_536,
      config: Keyword.fetch!(opts, :config),
      job_id: Keyword.get(opts, :job_id),
      cache_dir: cache_dir,
      ttl_ms: Application.get_env(:forge_worker, :archive_listing_ttl_ms, @default_ttl_ms),
      time: System.os_time(:second),
      fids: %{},
      listings: %{},
      tasks: %{},
      waiting: %{},
      failed: %{}
    }
  end

  @impl true
  def handle_info({:accepted, socket}, state) do
    # One connection, the kernel's: nothing else is let in once it is made.
    :gen_tcp.close(state.listener)
    :inet.setopts(socket, active: true)
    {:noreply, %{state | socket: socket, listener: nil}}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case receive_data(%{state | buffer: state.buffer <> data}) do
      {:ok, state} -> {:noreply, state}
      :error -> {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info({:listed, key, result}, state), do: {:noreply, listed(state, key, result)}
  def handle_info({:fetched, ref, result}, state), do: {:noreply, fetched(state, ref, result)}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_wait, pid} -> Process.exit(pid, :kill) end)
    if state.listener, do: :gen_tcp.close(state.listener)
    if state.socket, do: :gen_tcp.close(state.socket)
    Enum.each(state.fids, fn {_fid, fid} -> close(fid) end)
    File.rm(state.path)
    if state.remove_dir, do: File.rm_rf(state.remove_dir)
    File.rm_rf(state.cache_dir)
  end

  # -- the connection -----------------------------------------------------------------------------

  defp receive_data(state) do
    case P9.frame(state.buffer) do
      :more ->
        {:ok, state}

      :error ->
        :error

      {:ok, message, rest} ->
        state = %{state | buffer: rest}

        case P9.decode(message) do
          :error -> :error
          {tag, request} -> receive_data(request(state, tag, request))
        end
    end
  end

  defp send_reply(state, reply), do: :gen_tcp.send(state.socket, reply)

  # A request is answered, or waits for something and is dispatched again when it arrives.
  defp request(state, tag, request) do
    case dispatch(request, state) do
      {:reply, reply, state} ->
        send_reply(state, reply_for(tag, reply))
        state

      {:wait, wait, state} ->
        wait(state, tag, request, wait)
    end
  end

  defp wait(state, tag, request, {kind, key, context}) do
    state = %{state | waiting: Map.put(state.waiting, tag, {{kind, key}, request})}
    start_task(state, kind, key, context)
  end

  # Replies are built without a tag, then given theirs.
  defp reply_for(tag, {:error, name}), do: P9.error(tag, name)
  defp reply_for(tag, fun) when is_function(fun, 1), do: fun.(tag)

  # -- fetching -----------------------------------------------------------------------------------

  defp start_task(%{tasks: tasks} = state, kind, key, context) do
    if Map.has_key?(tasks, {kind, key}) do
      state
    else
      server = self()
      config = state.config
      cache_dir = state.cache_dir

      pid = spawn_link(fn -> send(server, work(kind, key, config, cache_dir, context)) end)
      %{state | tasks: Map.put(tasks, {kind, key}, pid)}
    end
  end

  defp work(:listing, key, config, _cache_dir, _context) do
    {:listed, key, safely(fn -> Client.listing(config, key) end)}
  end

  defp work(:file, ref, config, cache_dir, {number, entry}) do
    destination = Path.join(cache_dir, ref)
    {:fetched, ref, safely(fn -> Client.fetch(config, number, entry, destination) end)}
  end

  # A task that crashes must still answer, or the request waiting on it waits for ever.
  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("archive fetch crashed: #{Exception.message(error)}")
      {:error, :eio}
  catch
    kind, reason ->
      Logger.warning("archive fetch #{kind}: #{inspect(reason)}")
      {:error, :eio}
  end

  defp listed(state, key, result) do
    state = %{state | tasks: Map.delete(state.tasks, {:listing, key})}

    state =
      case {result, state.listings} do
        {{:ok, body}, _listings} ->
          data = if key == :root, do: Tree.root(body), else: Tree.ticket(body)
          %{state | listings: Map.put(state.listings, key, %{data: data, at: now()})}

        # A refresh that failed keeps what there was, for another interval, rather than taking a
        # folder away because the platform blinked; a first fetch that failed is an error.
        {{:error, _errno}, %{^key => held}} ->
          %{state | listings: Map.put(state.listings, key, %{held | at: now()})}

        {{:error, errno}, _listings} ->
          log(state, "listing #{inspect(key)} failed: #{errno}")
          %{state | failed: Map.put(state.failed, {:listing, key}, errno)}
      end

    wake(state, {:listing, key})
  end

  defp fetched(state, ref, result) do
    state = %{state | tasks: Map.delete(state.tasks, {:file, ref})}

    state =
      case result do
        :ok ->
          state

        {:error, errno} ->
          log(state, "fetching #{ref} failed: #{errno}")
          %{state | failed: Map.put(state.failed, {:file, ref}, errno)}
      end

    wake(state, {:file, ref})
  end

  # Everything waiting on `wait` is dispatched again, in the order it arrived. A failure is read by
  # them once and then forgotten, so the next read tries again.
  defp wake(state, wait) do
    ready =
      state.waiting
      |> Enum.filter(fn {_tag, {waited, _request}} -> waited == wait end)
      |> Enum.sort_by(fn {tag, _} -> tag end)

    state = %{state | waiting: Map.drop(state.waiting, Enum.map(ready, &elem(&1, 0)))}

    state =
      Enum.reduce(ready, state, fn {tag, {_wait, request}}, state ->
        request(state, tag, request)
      end)

    %{state | failed: Map.delete(state.failed, wait)}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp log(state, text) do
    Log.line("archive.failed", :warning, text, job_id: state.job_id)
  end

  # Only what is within its interval counts as fetched, so that an old listing is asked for again.
  defp listings(state) do
    cutoff = now() - state.ttl_ms
    state.listings |> Enum.reject(fn {_key, %{at: at}} -> at < cutoff end) |> Map.new()
  end

  # -- dispatch -----------------------------------------------------------------------------------

  defp dispatch({:version, msize, version}, state) do
    if String.starts_with?(version, "9P2000.L") do
      msize = min(msize, @max_msize)
      {:reply, &P9.version(&1, msize, "9P2000.L"), %{state | msize: msize}}
    else
      {:reply, &P9.version(&1, 0, "unknown"), state}
    end
  end

  defp dispatch({:attach, fid}, state) do
    fids = Map.put(state.fids, fid, %{path: [], open: nil})
    {:reply, &P9.attach(&1, qid({:dir, []})), %{state | fids: fids}}
  end

  defp dispatch({:walk, fid, newfid, names}, state) do
    with_fid(state, fid, fn %{path: path} ->
      case walk(state, path, names, []) do
        {:need, key} ->
          need(state, key)

        {:ok, path, qids} ->
          fids = Map.put(state.fids, newfid, %{path: path, open: nil})
          {:reply, &P9.walk(&1, qids), %{state | fids: fids}}

        {:partial, []} ->
          error({:error, :enoent}, state)

        {:partial, qids} ->
          {:reply, &P9.walk(&1, qids), state}
      end
    end)
  end

  defp dispatch({:getattr, fid, _mask}, state) do
    with_fid(state, fid, fn %{path: path} ->
      case Tree.resolve(listings(state), path) do
        {:ok, {:dir, _path} = found} ->
          {:reply, &P9.getattr(&1, qid(found), :dir, 0, state.time), state}

        {:ok, {:file, _path, entry} = found} ->
          {:reply, &P9.getattr(&1, qid(found), :file, entry["size"], state.time), state}

        {:need, key} ->
          need(state, {:listing, key})

        :enoent ->
          error({:error, :enoent}, state)
      end
    end)
  end

  defp dispatch({:lopen, fid, flags}, state) do
    with_fid(state, fid, fn held ->
      if P9.writes?(flags), do: error({:error, :erofs}, state), else: lopen(state, fid, held)
    end)
  end

  defp dispatch({:read, fid, offset, count}, state) do
    case fid(state, fid) do
      {:ok, %{open: {:inline, bytes}}} ->
        {:reply, &P9.read(&1, slice(bytes, offset, limit(state, count))), state}

      {:ok, %{open: {:file, io}}} ->
        data =
          case :file.pread(io, offset, limit(state, count)) do
            {:ok, data} -> data
            _eof_or_error -> ""
          end

        {:reply, &P9.read(&1, data), state}

      {:ok, %{open: {:dir, _}}} ->
        error({:error, :eisdir}, state)

      _unopened ->
        error({:error, :ebadf}, state)
    end
  end

  defp dispatch({:readdir, fid, offset, count}, state) do
    case fid(state, fid) do
      {:ok, %{open: {:dir, entries}}} ->
        data = entries |> Enum.drop(offset) |> pack(offset + 1, limit(state, count), <<>>)
        {:reply, &P9.readdir(&1, data), state}

      {:ok, %{open: nil}} ->
        error({:error, :ebadf}, state)

      _file ->
        error({:error, :enotdir}, state)
    end
  end

  defp dispatch({:clunk, fid}, state) do
    case Map.pop(state.fids, fid) do
      {nil, _fids} ->
        {:reply, &P9.clunk/1, state}

      {held, fids} ->
        close(held)
        {:reply, &P9.clunk/1, %{state | fids: fids}}
    end
  end

  defp dispatch({:statfs, _fid}, state), do: {:reply, &P9.statfs/1, state}

  defp dispatch({:flush, oldtag}, state),
    do: {:reply, &P9.flush/1, %{state | waiting: Map.delete(state.waiting, oldtag)}}

  defp dispatch({:xattrwalk, _fid, _newfid}, state), do: error({:error, :enodata}, state)
  defp dispatch({:readlink}, state), do: error({:error, :einval}, state)
  defp dispatch({:unsupported, _type}, state), do: error({:error, :eopnotsupp}, state)
  defp dispatch({:mutating, _type}, state), do: error({:error, :erofs}, state)
  defp dispatch({:unknown, _type}, state), do: error({:error, :enosys}, state)

  defp error(reply, state), do: {:reply, reply, state}

  defp with_fid(state, fid, fun) do
    case fid(state, fid) do
      {:ok, held} -> fun.(held)
      :error -> error({:error, :ebadf}, state)
    end
  end

  defp lopen(state, fid, held) do
    case Tree.resolve(listings(state), held.path) do
      {:ok, {:dir, _} = found} -> open_dir(state, fid, held, found)
      {:ok, {:file, _, entry} = found} -> open_file(state, fid, held, found, entry)
      {:need, key} -> need(state, {:listing, key})
      :enoent -> error({:error, :enoent}, state)
    end
  end

  defp fid(state, fid) do
    case state.fids do
      %{^fid => held} -> {:ok, held}
      _none -> :error
    end
  end

  # What must be fetched, and with what: the listing of a folder, or a file's bytes.
  defp need(state, {:listing, key}), do: wait_for(state, {:listing, key, nil})
  defp need(state, {:file, ref, context}), do: wait_for(state, {:file, ref, context})

  defp wait_for(state, {kind, key, _context} = wait) do
    case state.failed do
      %{{^kind, ^key} => errno} -> {:reply, {:error, errno}, state}
      _ok -> {:wait, wait, state}
    end
  end

  # -- walking, opening, reading ------------------------------------------------------------------

  defp walk(_state, path, [], acc), do: {:ok, path, Enum.reverse(acc)}

  defp walk(state, path, [name | rest], acc) do
    cond do
      name == "." ->
        walk(state, path, rest, [qid({:dir, path}) | acc])

      name == ".." ->
        up = Tree.parent(path)
        walk(state, up, rest, [qid({:dir, up}) | acc])

      # Not an equivalent mutant: `Tree.resolve/2` joins the rest of a path with `/` to look a file up
      # in a ticket, so a single walk name `reports/out.bin` would resolve to a group's file if this
      # clause were gone. It is the first line of defence for names with a `/`, and the test below
      # walks one.
      not Tree.name?(name) ->
        {:partial, Enum.reverse(acc)}

      true ->
        case Tree.resolve(listings(state), path ++ [name]) do
          {:ok, found} -> walk(state, path ++ [name], rest, [qid(found) | acc])
          {:need, key} -> {:need, {:listing, key}}
          :enoent -> {:partial, Enum.reverse(acc)}
        end
    end
  end

  defp open_dir(state, fid, held, found) do
    case Tree.children(listings(state), held.path) do
      {:need, key} ->
        need(state, {:listing, key})

      {:ok, children} ->
        entries =
          [{".", :dir, held.path}, {"..", :dir, Tree.parent(held.path)}] ++
            Enum.map(children, fn {name, kind} -> {name, kind, held.path ++ [name]} end)

        opened(state, fid, held, {:dir, entries}, found)

      :enoent ->
        error({:error, :enoent}, state)
    end
  end

  defp open_file(state, fid, held, found, %{"inline" => bytes}) when is_binary(bytes),
    do: opened(state, fid, held, {:inline, bytes}, found)

  defp open_file(state, fid, held, found, %{"ref" => ref} = entry) do
    cached = Path.join(state.cache_dir, ref)

    if File.exists?(cached) do
      case File.open(cached, [:read, :raw, :binary]) do
        {:ok, io} -> opened(state, fid, held, {:file, io}, found)
        {:error, _reason} -> error({:error, :eio}, state)
      end
    else
      need(state, {:file, ref, {hd(held.path), entry}})
    end
  end

  defp opened(state, fid, held, open, found) do
    close(held)
    fids = Map.put(state.fids, fid, %{held | open: open})
    {:reply, &P9.lopen(&1, qid(found)), %{state | fids: fids}}
  end

  defp close(%{open: {:file, io}}), do: :file.close(io)
  defp close(_held), do: :ok

  defp limit(state, count), do: min(count, state.msize - @header)

  defp slice(bytes, offset, count) when offset >= byte_size(bytes) or count <= 0, do: ""

  defp slice(bytes, offset, count),
    do: binary_part(bytes, offset, min(count, byte_size(bytes) - offset))

  # Whole entries only, as many as fit in `count`; the client resumes at the offset of the last.
  defp pack([], _offset, _count, acc), do: acc

  defp pack([{name, kind, path} | rest], offset, count, acc) do
    entry = P9.dirent(qid({kind, path}), offset, kind, name)

    if byte_size(acc) + byte_size(entry) > count,
      do: acc,
      else: pack(rest, offset + 1, count, acc <> entry)
  end

  defp qid({:dir, path}), do: P9.qid(:dir, Tree.number(path))
  defp qid({:file, path}), do: P9.qid(:file, Tree.number(path))
  defp qid({:file, path, _entry}), do: P9.qid(:file, Tree.number(path))
end
