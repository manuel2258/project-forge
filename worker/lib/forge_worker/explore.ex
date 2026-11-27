defmodule ForgeWorker.Explore do
  @moduledoc """
  Answers the platform's `explore` message: a person looking into a ticket's **command copy** on
  this machine (`docs/design/worker-tier.md` § Looking into a copy, ticket 84).

  `run/3` takes the message's payload, the worker's root and a function that sends one reply to the
  platform (`{"ref", "ok" | "error" | "progress"}`), answers, and returns. The link runs it in a task
  of `ForgeWorker.Explore.Tasks`, one per request and no cap: exploring and downloading are at
  normal priority and may slow the jobs on the machine (criterion 8).

  **Which copy is the machine's to say** (criterion 34): the ticket and the job that kept it are
  matched as UUIDs before either becomes a path, and `CommandCopy.open/3` finds the copy under the
  ticket's own directory name — the platform's word that a copy is this ticket's is not taken.
  Opening it also renews the hold on it (criterion 5).

  **Nothing outside the copy is reachable** (criterion 35). A path is refused for `..`, `.`, an empty
  component, a NUL or a leading `/` before any filesystem call, and then resolved from the copy's
  root **one component at a time with `lstat`** (`resolve/2`): every component before the last
  must be a real directory, never a link, and the last is looked at and never followed — a link is
  answered with its target as text. A file is opened once and the handle's own stat must be the
  regular file the `lstat` named. The BEAM has no `openat2`; this is the resolution the kernel then
  does, and nothing changes a kept copy in between (`CLAUDE.md` § Rules: the check and the read
  use the same model of the path, not a string check in front of a read). A folder goes to `tar`,
  which does not follow a link inside it.

  Paths, names and link targets are base64 on the wire, because a name need not be UTF-8 and the
  channel is JSON.
  """

  alias ForgeCore.Explore, as: Shared
  alias ForgeWorker.{Config, Store}
  alias ForgeWorker.Job.CommandCopy

  require Logger

  # How often a hash or a download says it is still going, and how often a download renews its hold.
  @progress_ms 2_000
  @hold_renew_ms 60_000
  @chunk 1024 * 1024

  @type reply :: (map() -> any())

  @doc """
  Answers one `explore` payload through `reply`. Never raises: a request that crashes is answered
  `failed`, because the platform waits for an answer and counts silence as the machine not
  answering.
  """
  @spec run(map(), String.t(), reply()) :: :ok
  def run(payload, root, reply) do
    ref = if is_map(payload), do: payload["ref"]
    if is_binary(ref), do: respond(payload, root, reply, ref)
    :ok
  rescue
    error ->
      Logger.warning("explore failed: #{Exception.message(error)}")

      if is_map(payload) and is_binary(payload["ref"]),
        do: reply.(%{"ref" => payload["ref"], "error" => "failed"})

      :ok
  end

  defp respond(payload, root, reply, ref) do
    case answer(payload, root, fn message -> reply.(Map.put(message, "ref", ref)) end) do
      {:ok, ok} -> reply.(%{"ref" => ref, "ok" => ok})
      {:error, code} -> reply.(%{"ref" => ref, "error" => Atom.to_string(code)})
    end
  end

  defp answer(payload, root, progress) do
    with {:ok, op} <- op(payload["op"]),
         {:ok, path} <- decode_path(payload["path_b64"]),
         true <- Shared.path_ok?(path) or {:error, :path_refused},
         {:ok, dir} <- open(root, payload["ticket"], payload["copy"]) do
      run_op(op, dir, path, payload, progress, root)
    end
  end

  defp op(op) when is_binary(op),
    do: if(op in Shared.ops(), do: {:ok, op}, else: {:error, :failed})

  defp op(_other), do: {:error, :failed}

  defp decode_path(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, path} -> {:ok, path}
      :error -> {:error, :path_refused}
    end
  end

  defp decode_path(_other), do: {:error, :path_refused}

  defp open(root, ticket, copy) do
    case CommandCopy.open(root, to_string(ticket), to_string(copy)) do
      {:ok, dir} -> {:ok, dir}
      :error -> {:error, :no_copy}
    end
  end

  defp run_op("list", dir, path, payload, _progress, _root) do
    with {:ok, abs, stat} <- resolve(dir, path), do: list(abs, stat, offset(payload["offset"]))
  end

  defp run_op("file", dir, path, _payload, _progress, _root) do
    with {:ok, abs, stat} <- resolve(dir, path), do: file(abs, stat)
  end

  defp run_op("hash", dir, path, _payload, progress, _root) do
    with {:ok, abs, stat} <- resolve(dir, path), do: hash(abs, stat, progress)
  end

  defp run_op("download", dir, path, payload, progress, root) do
    with {:ok, abs, stat} <- resolve(dir, path),
         {:ok, stream, secret} <- stream_target(payload) do
      download(abs, stat, path, stream, secret, progress, hold(root, payload))
    end
  end

  defp offset(offset) when is_integer(offset) and offset >= 0, do: offset
  defp offset(_other), do: 0

  # -- resolving a path -----------------------------------------------------------------------------

  @doc """
  The absolute path of `path` inside the copy at `dir`, and its `lstat`: `{:ok, absolute, stat}`.

  One component at a time: everything before the last must be a directory and **never a link**
  (`{:error, :path_refused}` — a path that goes through a link is not a path in the copy), a
  component that is not there is `:path_not_found`, and the last is looked at without being
  followed. `path` must already have passed `ForgeCore.Explore.path_ok?/1`; this is the check
  against the filesystem.
  """
  @spec resolve(String.t(), binary()) ::
          {:ok, String.t(), File.Stat.t()} | {:error, :path_refused | :path_not_found | :failed}
  def resolve(dir, path) do
    if Shared.path_ok?(path),
      do: walk(dir, Shared.components(path)),
      else: {:error, :path_refused}
  end

  defp walk(dir, []) do
    case File.lstat(dir, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} -> {:ok, dir, stat}
      _not_a_copy -> {:error, :failed}
    end
  end

  defp walk(dir, [last]), do: step(Path.join(dir, last))

  defp walk(dir, [part | rest]) do
    next = Path.join(dir, part)

    case File.lstat(next, time: :posix) do
      {:ok, %File.Stat{type: :directory}} -> walk(next, rest)
      {:ok, %File.Stat{type: :symlink}} -> {:error, :path_refused}
      {:ok, _a_file_or_other} -> {:error, :path_not_found}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, _other} -> {:error, :failed}
    end
  end

  defp step(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> {:ok, path, stat}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, _other} -> {:error, :failed}
    end
  end

  # -- list -------------------------------------------------------------------------------------------

  defp list(_abs, %File.Stat{type: type}, _offset) when type != :directory,
    do: {:error, :not_a_folder}

  defp list(abs, _stat, offset) do
    with {:ok, names} <- names(abs) do
      sorted =
        names
        |> Enum.flat_map(&lstat_entry(abs, &1))
        |> Enum.sort_by(fn {name, stat} ->
          {if(stat.type == :directory, do: 0, else: 1), name}
        end)

      entries =
        sorted
        |> Enum.drop(offset)
        |> Enum.take(Shared.page_size())
        |> Enum.map(fn {name, stat} -> entry(abs, name, stat) end)

      {:ok, %{"entries" => entries, "total" => length(sorted), "offset" => offset}}
    end
  end

  # A name that vanished between the listing and the stat is not an entry.
  defp lstat_entry(abs, name) do
    case File.lstat(Path.join(abs, name), time: :posix) do
      {:ok, stat} -> [{name, stat}]
      {:error, _vanished} -> []
    end
  end

  # `File.ls/1` leaves out a name that is not valid text, and a copy can hold one.
  defp names(abs) do
    case :file.list_dir_all(abs) do
      {:ok, names} -> {:ok, Enum.map(names, &raw/1)}
      {:error, :enoent} -> {:error, :path_not_found}
      {:error, _reason} -> {:error, :failed}
    end
  end

  defp raw(name) when is_binary(name), do: name
  defp raw(name) when is_list(name), do: :unicode.characters_to_binary(name)

  defp entry(abs, name, stat) do
    path = Path.join(abs, name)

    %{"name_b64" => Base.encode64(name), "kind" => kind(stat), "mtime" => stat.mtime}
    |> put_kind(stat, path)
  end

  defp put_kind(map, %File.Stat{type: :regular, size: size}, _path),
    do: Map.put(map, "size", size)

  defp put_kind(map, %File.Stat{type: :directory}, path),
    do: Map.put(map, "entries", count(path))

  defp put_kind(map, %File.Stat{type: :symlink}, path), do: put_target(map, path)
  defp put_kind(map, _other, _path), do: map

  defp put_target(map, path) do
    case File.read_link(path) do
      {:ok, target} -> Map.put(map, "target_b64", Base.encode64(target))
      {:error, _reason} -> map
    end
  end

  defp count(path) do
    case :file.list_dir_all(path) do
      {:ok, names} -> length(names)
      {:error, _reason} -> nil
    end
  end

  defp kind(%File.Stat{type: :directory}), do: "dir"
  defp kind(%File.Stat{type: :regular}), do: "file"
  defp kind(%File.Stat{type: :symlink}), do: "link"
  defp kind(_other), do: "other"

  # -- file and hash -----------------------------------------------------------------------------------

  defp file(abs, %File.Stat{type: :regular} = stat) do
    limit = Shared.text_limit()

    with {:ok, fd} <- open_regular(abs, stat) do
      try do
        case :file.pread(fd, 0, limit) do
          {:ok, data} -> {:ok, file_facts(stat, data, stat.size > limit)}
          :eof -> {:ok, file_facts(stat, "", false)}
          {:error, _reason} -> {:error, :failed}
        end
      after
        :file.close(fd)
      end
    end
  end

  defp file(abs, %File.Stat{type: :symlink} = stat),
    do:
      {:ok,
       %{"kind" => "link", "mtime" => stat.mtime, "text" => false, "truncated" => false}
       |> put_target(abs)}

  defp file(abs, %File.Stat{type: :directory} = stat),
    do:
      {:ok,
       %{
         "kind" => "dir",
         "mtime" => stat.mtime,
         "entries" => count(abs),
         "text" => false,
         "truncated" => false
       }}

  defp file(_abs, stat),
    do: {:ok, %{"kind" => "other", "mtime" => stat.mtime, "text" => false, "truncated" => false}}

  defp file_facts(stat, data, truncated?) do
    base = %{
      "kind" => "file",
      "size" => stat.size,
      "mtime" => stat.mtime,
      "truncated" => truncated?
    }

    if text?(data, truncated?),
      do: Map.merge(base, %{"text" => true, "content_b64" => Base.encode64(data)}),
      else: Map.put(base, "text", false)
  end

  @doc """
  Whether `data`, the start of a file, is text: no NUL, and valid UTF-8 — where `truncated?` says
  the read stopped at a limit, a sequence the limit cut in two at the very end is not a fault.
  """
  @spec text?(binary(), boolean()) :: boolean()
  def text?(data, truncated?) do
    not String.contains?(data, <<0>>) and
      case :unicode.characters_to_binary(data, :utf8) do
        converted when is_binary(converted) -> true
        {:incomplete, _converted, _rest} -> truncated?
        {:error, _converted, _rest} -> false
      end
  end

  defp hash(abs, %File.Stat{type: :regular} = stat, progress) do
    with {:ok, fd} <- open_regular(abs, stat) do
      try do
        state = :crypto.hash_init(:sha256)
        digest(fd, state, 0, stat.size, now(), progress)
      after
        :file.close(fd)
      end
    end
  end

  defp hash(_abs, _stat, _progress), do: {:error, :not_a_file}

  defp digest(fd, state, done, total, last, progress) do
    case :file.read(fd, @chunk) do
      {:ok, data} ->
        done = done + byte_size(data)
        state = :crypto.hash_update(state, data)
        digest(fd, state, done, total, ticked(last, done, total, progress), progress)

      :eof ->
        {:ok,
         %{
           "sha256" => state |> :crypto.hash_final() |> Base.encode16(case: :lower),
           "size" => done
         }}

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp ticked(last, done, total, progress) do
    now = now()

    if now - last >= progress_ms() do
      progress.(%{"progress" => %{"done" => done, "total" => total}})
      now
    else
      last
    end
  end

  defp hold_renew_ms,
    do: Application.get_env(:forge_worker, :explore_hold_renew_ms, @hold_renew_ms)

  defp progress_ms, do: Application.get_env(:forge_worker, :explore_progress_ms, @progress_ms)
  defp now, do: System.monotonic_time(:millisecond)

  # Opened once, and the handle's own stat must be the regular file `lstat` named: a name that
  # became something else between the two is refused, not read.
  defp open_regular(abs, %File.Stat{} = stat) do
    case :file.open(abs, [:read, :raw, :binary]) do
      {:ok, fd} ->
        if same_file?(fd, stat) do
          {:ok, fd}
        else
          :file.close(fd)
          {:error, :path_refused}
        end

      {:error, :enoent} ->
        {:error, :path_not_found}

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp same_file?(fd, stat) do
    with {:ok, info} <- :prim_file.read_handle_info(fd),
         %File.Stat{} = opened <- File.Stat.from_record(info) do
      opened.type == :regular and opened.inode == stat.inode and
        opened.major_device == stat.major_device
    else
      _unreadable -> false
    end
  end

  # -- download ---------------------------------------------------------------------------------------

  defp stream_target(%{"stream" => stream, "secret" => secret})
       when is_binary(stream) and is_binary(secret) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{8,128}\z/, stream),
      do: {:ok, stream, secret},
      else: {:error, :failed}
  end

  defp stream_target(_payload), do: {:error, :failed}

  defp hold(root, payload) do
    ticket = String.downcase(to_string(payload["ticket"]))
    copy = String.downcase(to_string(payload["copy"]))
    fn -> CommandCopy.touch_hold(root, ticket, copy) end
  end

  defp download(abs, stat, path, stream, secret, progress, renew) do
    with url when is_binary(url) <- Config.platform_url() || {:error, :failed},
         {:ok, source, kind, close} <- source(abs, stat, path) do
      counted = :counters.new(1, [])

      try do
        body = pacing(source, counted, renew, progress)

        headers = [
          {"x-forge-kind", kind},
          {"x-forge-name-b64", Base.encode64(Path.basename(path))}
        ]

        target = String.trim_trailing(url, "/") <> "/worker-streams/" <> stream

        case Store.stream_post(target, secret, body, headers) do
          {:ok, 200} -> {:ok, %{"bytes" => :counters.get(counted, 1)}}
          {:ok, _refused} -> {:error, :failed}
          {:error, _reason} -> {:error, :failed}
        end
      after
        close.()
      end
    end
  end

  # What the download says while it runs: the hold renewed each minute, so that a download that
  # outlasts ten minutes is not cut off by the release of the copy, and progress each two seconds,
  # so that the platform does not take a long pack for a silent machine.
  defp pacing(source, counted, renew, progress) do
    Stream.transform(source, {now(), now()}, fn chunk, {renewed, said} ->
      :counters.add(counted, 1, byte_size(chunk))

      renewed =
        if now() - renewed >= hold_renew_ms(),
          do:
            (
              renew.()
              now()
            ),
          else: renewed

      said =
        if now() - said >= progress_ms() do
          progress.(%{"progress" => %{"done" => :counters.get(counted, 1), "total" => nil}})
          now()
        else
          said
        end

      {[chunk], {renewed, said}}
    end)
  end

  # What is sent: the file as itself, or a tar of the folder, the link or the whole copy.
  defp source(abs, %File.Stat{type: :regular} = stat, _path) do
    with {:ok, fd} <- open_regular(abs, stat) do
      stream = Stream.resource(fn -> fd end, &read_chunk/1, fn _fd -> :ok end)

      {:ok, stream, "file", fn -> :file.close(fd) end}
    end
  end

  defp source(abs, _stat, path), do: tar(abs, path)

  defp read_chunk(fd) do
    case :file.read(fd, @chunk) do
      {:ok, data} -> {[data], fd}
      _eof_or_error -> {:halt, fd}
    end
  end

  # GNU tar writes to a FIFO that this process reads a megabyte at a time, and that is the whole
  # of the backpressure: tar blocks when the FIFO is full, so a browser that takes the bytes slowly
  # slows `tar` and nothing piles up in this process. A port would deliver everything tar writes
  # as messages, as fast as it writes, with no way to ask it to wait. **No `-h`**: a link goes in as
  # a link. `--one-file-system`: a mount in a copy is not part of it. Entries are named from
  # the directory that holds what is packed: `./…` for the whole copy, and the folder's own name
  # first for a folder.
  #
  # **A tar that fails halfway is not a download that ended**: when the FIFO reaches its end the
  # stream waits for tar's status and raises on one worse than "some files differ" (1), which
  # closes the request mid-body and so tells the platform, and through it the browser, that the
  # archive is not whole.
  defp tar(abs, path) do
    {cwd, member} = if path == "", do: {abs, "."}, else: {Path.dirname(abs), Path.basename(abs)}

    tmp =
      Path.join(System.tmp_dir!(), "forge-dl-" <> Base.url_encode64(:crypto.strong_rand_bytes(9)))

    fifo = Path.join(tmp, "tar")

    with :ok <- File.mkdir_p(tmp),
         :ok <- File.chmod(tmp, 0o700),
         {_out, 0} <- System.cmd("mkfifo", [fifo], stderr_to_stdout: true),
         {:ok, port} <- start_tar(fifo, cwd, member),
         {:ok, fd, opener} <- open_fifo(fifo, port) do
      {:ok, tar_stream(fd, port), "tar", fn -> close_tar(opener, port, tmp) end}
    else
      _failed ->
        File.rm_rf(tmp)
        {:error, :failed}
    end
  end

  defp close_tar(opener, port, tmp) do
    send(opener, :close)
    if Port.info(port), do: Port.close(port)
    File.rm_rf(tmp)
  end

  defp start_tar(fifo, cwd, member) do
    case System.find_executable("sh") do
      nil ->
        {:error, :no_shell}

      sh ->
        {:ok,
         Port.open({:spawn_executable, sh}, [
           :binary,
           :exit_status,
           {:args,
            [
              "-c",
              ~S(exec tar --format=posix --one-file-system -cf "$1" -C "$2" -- "$3"),
              "forge-tar",
              fifo,
              cwd,
              member
            ]}
         ])}
    end
  end

  # Opening a FIFO to read waits for a writer, and a tar that never started would be waited for
  # for ever (and the thread with it): the open is made by another process, and this one gives up
  # when tar has gone without connecting, unblocking the opener by being the writer it waits for.
  # The file is not raw, so that this process can read what the opener opened; the file process
  # lives as long as its opener, which is kept until the stream is closed.
  defp open_fifo(fifo, port) do
    parent = self()
    ref = make_ref()

    opener =
      spawn(fn ->
        case :file.open(fifo, [:read, :binary]) do
          {:ok, fd} ->
            send(parent, {ref, {:ok, fd}})

            receive do
              :close -> :file.close(fd)
            end

          error ->
            send(parent, {ref, error})
        end
      end)

    receive do
      {^ref, {:ok, fd}} ->
        {:ok, fd, opener}

      {^ref, {:error, reason}} ->
        {:error, reason}

      {^port, {:exit_status, status}} when status != 0 ->
        release_opener(fifo, opener)
    after
      30_000 ->
        release_opener(fifo, opener)
    end
  end

  # Being the writer the opener waits for lets it open; it is then told to close, which ends it. A
  # tar that never connected would otherwise leave it waiting for a `:close` that nothing sends. No
  # test starts a tar that dies before it connects (it needs `tar` or `sh` missing from the path).
  defp release_opener(fifo, opener) do
    with {:ok, writer} <- :file.open(fifo, [:write, :raw]), do: :file.close(writer)
    send(opener, :close)
    {:error, :tar_did_not_start}
  end

  defp tar_stream(fd, port) do
    Stream.resource(
      fn -> fd end,
      fn fd ->
        case :file.read(fd, @chunk) do
          {:ok, data} ->
            {[data], fd}

          _eof_or_error ->
            tar_status(port)
            {:halt, fd}
        end
      end,
      fn _fd -> :ok end
    )
  end

  defp tar_status(port) do
    receive do
      {^port, {:exit_status, status}} when status in [0, 1] -> :ok
      {^port, {:exit_status, status}} -> raise "tar ended with status #{status}"
    after
      30_000 -> raise "tar did not end"
    end
  end
end
