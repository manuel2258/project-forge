defmodule ForgeWorker.Job.Lines do
  @moduledoc """
  Tails a command's log while it runs, for the command's page
  (`docs/design/worker-tier.md` § Looking into a copy, ticket 84, criteria 2 and 3).

  **It only reads the file the shell already writes** (`>>"$log" 2>&1`, `ForgeWorker.Job.Command`),
  so the log a command produces is exactly what it was and carries no times. Every `poll_ms` it
  reads what was appended, cuts it into lines at each newline, masks each line for the job's
  secrets on its own and sends the batch to the link as `{:lines, job_id, from, [[ms, text], …]}`,
  `ms` being the clock's reading when the line was seen (the time since the job's task started: the link passes
  `ForgeWorker.Job.Steps.elapsed/1` as the clock).

  **A line is read whole.** A partial line waits for its newline, and `finish/1`'s last read
  delivers one that never got it.

  **Live text only**: bytes that are not UTF-8 are replaced and a line is cut at 4 KiB here and
  nowhere else — the log file keeps its bytes. **Masking a line at a time misses a value that
  contains a newline**, which the file's masking catches (`docs/design/secrets.md` § Masking).

  **What it keeps is bounded, apart from the times.** It keeps the last `ForgeCore.Explore.max_live_lines/0` lines it has
  sent, which is all the platform holds, so that after a reconnect `resend/1` says them again from
  the first it kept (the message is unacked, so a platform that restarted mid-command is told what
  it can hold). The time of every line is kept too, as runs of lines that were seen at one reading
  of the clock, which is what `finish/1` returns for the times blob beside the log (one entry per
  reading that saw lines, so it grows with the readings and not with each line's text, and `finish/1`
  expands it to one number a line). **A partial line is bounded**: past 64 KiB without a newline (a
  progress bar that rewrites itself with `\r`, a binary on standard output) only its first 64 KiB are
  held and the rest is not read into memory again; it is still one line when its newline comes, so
  the count of lines is the log's and the times line up with it.

  Options: `:job_id`, `:path`, `:link` (the process to send to), `:clock` (a function returning
  milliseconds), `:secrets` (`ForgeWorker.Job.Secrets`, or nil), `:poll_ms` and `:batch`.
  """

  use GenServer, restart: :temporary

  alias ForgeWorker.Job.Secrets

  @poll_ms 250
  @batch 200
  @read_bytes 4 * 1024 * 1024
  @line_bytes 4096
  # A line that has not ended is held to this many bytes.
  @partial_max 64 * 1024

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Reads what was appended and sends it now, instead of at the next tick."
  @spec poll(GenServer.server()) :: :ok
  def poll(server), do: GenServer.call(server, :poll)

  @doc "Sends again the lines it kept, from the first of them, as after a join."
  @spec resend(GenServer.server()) :: :ok
  def resend(server), do: GenServer.cast(server, :resend)

  @doc """
  Reads what is left, delivers a last line that has no newline, and stops: `{:ok, times}`, the
  millisecond of each line in the order of the log's lines (a line longer than 64 KiB counts once).
  """
  @spec finish(GenServer.server()) :: {:ok, [non_neg_integer()]}
  def finish(server), do: GenServer.call(server, :finish, :infinity)

  @doc "Stops a tailer that is still running, which the end of a run that failed before `finish/1` needs."
  @spec close(GenServer.server() | nil) :: :ok
  def close(nil), do: :ok

  def close(server) do
    GenServer.stop(server)
  catch
    :exit, _already_gone -> :ok
  end

  @doc "A log's lines as the tailer counts them: split at each newline, no empty one after the last."
  @spec count(String.t()) :: non_neg_integer()
  def count(contents) do
    case String.split(contents, "\n") do
      [""] -> 0
      parts -> if List.last(parts) == "", do: length(parts) - 1, else: length(parts)
    end
  end

  @doc "Makes a line (already masked) text and cuts it at 4 KiB. The log file is never given this."
  @spec live(String.t()) :: String.t()
  def live(text) do
    text |> String.replace_invalid() |> cut()
  end

  defp cut(text) when byte_size(text) <= @line_bytes, do: text
  defp cut(text), do: text |> binary_part(0, @line_bytes) |> valid_prefix()

  defp valid_prefix(binary),
    do:
      if(String.valid?(binary),
        do: binary,
        else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
      )

  @impl true
  def init(opts) do
    state = %{
      job_id: Keyword.fetch!(opts, :job_id),
      path: Keyword.fetch!(opts, :path),
      link: Keyword.fetch!(opts, :link),
      clock: Keyword.fetch!(opts, :clock),
      secrets: Keyword.get(opts, :secrets),
      poll_ms: Keyword.get(opts, :poll_ms, @poll_ms),
      batch: Keyword.get(opts, :batch, @batch),
      offset: 0,
      partial: "",
      # The last lines sent, newest first, and how many; `runs` is `{ms, lines}` for every line sent.
      lines: [],
      kept: 0,
      runs: [],
      count: 0
    }

    # Said to the link, which keeps it to tell to resend after a join, as it keeps a runner.
    send(state.link, {:tailer, state.job_id, self()})
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:poll, _from, state), do: {:reply, :ok, read(state, false)}

  def handle_call(:finish, _from, state) do
    state = read(state, true)
    runs = Enum.reverse(state.runs)
    times = Enum.flat_map(runs, fn {ms, n} -> List.duplicate(ms, n) end)
    {:stop, :normal, {:ok, times}, state}
  end

  @impl true
  def handle_cast(:resend, state) do
    send_all(state, Enum.reverse(state.lines), state.count - state.kept)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = read(state, false)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule(%{poll_ms: ms}) when is_integer(ms), do: Process.send_after(self(), :poll, ms)
  defp schedule(_state), do: :ok

  # Everything appended since the last read, in pieces of at most 4 MiB so that a command that
  # printed a gigabyte is not read into memory at once.
  defp read(state, last?) do
    {chunk, offset} = pread(state.path, state.offset)

    if chunk == "" do
      finish_read(state, last?)
    else
      state |> split(chunk) |> Map.put(:offset, offset) |> read(last?)
    end
  end

  defp finish_read(%{partial: ""} = state, _last?), do: state

  defp finish_read(state, true) do
    state |> take_lines([state.partial]) |> Map.put(:partial, "")
  end

  defp finish_read(state, false), do: state

  defp pread(path, offset) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case :file.pread(file, offset, @read_bytes) do
            {:ok, data} -> {data, offset + byte_size(data)}
            _eof_or_error -> {"", offset}
          end
        after
          File.close(file)
        end

      {:error, _no_file_yet} ->
        {"", offset}
    end
  end

  defp split(state, chunk) do
    parts = String.split(state.partial <> chunk, "\n")
    {complete, [partial]} = Enum.split(parts, -1)
    state |> take_lines(complete) |> hold(partial)
  end

  # What has no newline yet waits for it, up to a bound: past it the rest of that line is let go, and
  # the line is still one line, so the count of lines is the log's.
  defp hold(state, partial) when byte_size(partial) > @partial_max,
    do: %{state | partial: binary_part(partial, 0, @partial_max)}

  defp hold(state, partial), do: %{state | partial: partial}

  defp take_lines(state, []), do: state

  defp take_lines(state, raw) do
    ms = state.clock.()

    # Masked on the raw bytes, before they are made text: the value is what the secret says.
    masked = Secrets.mask(state.secrets, raw)
    lines = Enum.map(masked, fn text -> [ms, live(text)] end)

    send_all(state, lines, state.count)

    trim(%{
      state
      | lines: Enum.reverse(lines, state.lines),
        kept: state.kept + length(lines),
        runs: [{ms, length(lines)} | state.runs],
        count: state.count + length(lines)
    })
  end

  # Only the last lines the platform can hold are kept for a resend.
  defp trim(%{kept: kept} = state) do
    max = ForgeCore.Explore.max_live_lines()

    if kept > max,
      do: %{state | lines: Enum.take(state.lines, max), kept: max},
      else: state
  end

  # In batches, from index `from`.
  defp send_all(state, lines, from) do
    lines
    |> Enum.chunk_every(state.batch)
    |> Enum.with_index()
    |> Enum.each(fn {batch, n} -> send_lines(state, from + n * state.batch, batch) end)
  end

  defp send_lines(_state, _from, []), do: :ok

  defp send_lines(state, from, batch),
    do: send(state.link, {:lines, state.job_id, from, batch})
end
