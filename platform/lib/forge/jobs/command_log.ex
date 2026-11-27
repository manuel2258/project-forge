defmodule Forge.Jobs.CommandLog do
  @moduledoc """
  A command's log with the time of each line (`docs/design/worker-tier.md` § Looking into a copy).

  **While the command runs** its lines are the ones `Forge.Jobs.Lines` holds in memory. **After it
  ends** they are the log in the store, with the times that were uploaded beside it: a second blob
  of one decimal millisecond per line, named in the `job.finished` event's payload as `times`, and
  there only when the masked log had as many lines as there were times. The log itself is unchanged
  and carries no times, which is what agents read.

  A line's time is in milliseconds since the command's job task began on the machine, the origin the
  steps' `at` and total share.

  **Bounded when read**: a log up to `#{64 * 1024 * 1024}` bytes is read whole; a larger one only
  from its tail, `#{8 * 1024 * 1024}` bytes of it, which is all a page would show. The times blob
  is bounded too: one over `#{16 * 1024 * 1024}` bytes (a log of a great many short lines) is not
  read at all, and the page draws that log's lines without times, as it does a log stored before
  times were kept.
  """

  alias Forge.{Events, Storage}
  alias Forge.Jobs.{Job, Lines}

  @tail 1_000
  @whole_limit 64 * 1024 * 1024
  @tail_bytes 8 * 1024 * 1024
  # A line's time is a few bytes, so this is millions of lines; past it the blob is left unread.
  @times_limit 16 * 1024 * 1024

  @type line :: {non_neg_integer() | nil, binary()}
  @type t :: %{
          lines: [line()],
          total: non_neg_integer(),
          shown_from: non_neg_integer(),
          source: :live | :stored,
          held_from: non_neg_integer()
        }

  @doc "How many lines a page shows at first."
  @spec tail() :: pos_integer()
  def tail, do: @tail

  @doc """
  The last `tail` lines of a command's log (1,000 by default) plus `earlier` more when a person asked
  for them: `%{lines: [{ms | nil, text}], total: lines in all, shown_from: the index of the first
  shown, source: :live | :stored, held_from: the first line that is held at all}`. A running
  command's lines are the live ones, and `held_from` is above 0 only when the cap dropped the
  earliest. Text is valid UTF-8; the raw bytes are `raw/1`'s.
  """
  @spec read(Job.t(), keyword()) :: t()
  def read(%Job{status: :running, id: id}, opts) do
    case Lines.all(id) do
      nil -> %{lines: [], total: 0, shown_from: 0, source: :live, held_from: 0}
      held -> live(held, opts)
    end
  end

  def read(%Job{} = job, opts) do
    case stored(job) do
      {:ok, texts, times, first} ->
        show(texts, times, first, opts, :stored)

      :none ->
        %{lines: [], total: 0, shown_from: 0, source: :stored, held_from: 0}
    end
  end

  defp live(%{first: first, lines: lines, total_seen: seen}, opts) do
    count = length(lines)
    shown = min(count, shown(opts))
    from = first + count - shown

    %{
      lines:
        lines
        |> Enum.drop(count - shown)
        |> Enum.map(fn [ms, text] -> {ms, text} end),
      total: seen,
      shown_from: from,
      source: :live,
      held_from: first
    }
  end

  defp show(texts, times, first, opts, source) do
    times = times && List.to_tuple(times)
    count = length(texts)
    shown = min(count, shown(opts))
    drop = count - shown

    lines =
      texts
      |> Enum.drop(drop)
      |> Enum.with_index(first + drop)
      |> Enum.map(fn {text, index} -> {time_of(times, index), String.replace_invalid(text)} end)

    %{
      lines: lines,
      total: first + count,
      shown_from: first + drop,
      source: source,
      held_from: first
    }
  end

  defp shown(opts), do: Keyword.get(opts, :tail, @tail) + Keyword.get(opts, :earlier, 0)

  defp time_of(times, index) when is_tuple(times) and index < tuple_size(times),
    do: elem(times, index)

  defp time_of(_none_or_short, _index), do: nil

  @doc """
  The whole stored log as bytes and its line times (`nil` when none were kept), for the API: `{:ok,
  log, times}`, or `:none` for a command with no log in the store. A log too large to read whole is
  `{:error, :too_large}`: the API has its own route for the bytes.
  """
  @spec raw(Job.t()) ::
          {:ok, binary(), [non_neg_integer() | nil] | nil} | :none | {:error, :too_large}
  def raw(%Job{} = job) do
    with {:ok, %{log: log} = keys} <- keys(job),
         {:ok, %{size: size}} <- Storage.stat(log) do
      read_whole(log, size, fn bytes -> {:ok, bytes, times(keys.times)} end, {:error, :too_large})
    else
      _none -> :none
    end
  end

  # The log's bytes through `found`, when it is small enough to read whole; `too_large` otherwise.
  defp read_whole(log, size, found, too_large) do
    if size > @whole_limit do
      too_large
    else
      case Storage.get(log) do
        {:ok, bytes} -> found.(bytes)
        _unreadable -> :none
      end
    end
  end

  # The stored log's lines and times: whole, or from its tail when it is very large.
  defp stored(job) do
    with {:ok, %{log: log} = keys} <- keys(job),
         {:ok, %{size: size}} <- Storage.stat(log) do
      stored_log(log, size, times(keys[:times]))
    else
      _none -> :none
    end
  end

  defp stored_log(log, size, times) do
    case read_whole(log, size, fn bytes -> {:ok, lines(bytes), times, 0} end, :tail) do
      :tail -> tail_of(log, size, times)
      other -> other
    end
  end

  defp tail_of(log, size, times) do
    case Storage.read_range(log, size - @tail_bytes, @tail_bytes) do
      {:ok, %{bytes: bytes}} ->
        # The first line of a range is cut: it is dropped, and the lines before it are not held.
        texts =
          case :binary.split(bytes, "\n") do
            [_cut, rest] -> lines(rest)
            [_only] -> []
          end

        total = if times, do: length(times), else: length(texts)
        {:ok, texts, times, max(total - length(texts), 0)}

      _error ->
        :none
    end
  end

  @doc """
  The lines of a log: its bytes split at newlines, the empty piece after a final newline not being
  a line. What a line's time is indexed by.
  """
  @spec lines(binary()) :: [binary()]
  def lines(""), do: []

  def lines(bytes) do
    parts = :binary.split(bytes, "\n", [:global])

    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _unterminated -> parts
    end
  end

  defp keys(%Job{id: id}) do
    case Events.latest_for_job(id, "job.finished") do
      %{payload: %{"log" => log} = payload} when is_binary(log) ->
        {:ok, %{log: log, times: payload["times"]}}

      _no_log ->
        :none
    end
  end

  # One decimal millisecond per line; a blob that is missing, unreadable or past `@times_limit` is
  # no times.
  defp times(key) when is_binary(key) do
    with {:ok, %{size: size}} <- Storage.stat(key),
         true <- size <= times_limit(),
         {:ok, bytes} <- Storage.get(key) do
      bytes |> lines() |> Enum.map(&time_line/1)
    else
      _none -> nil
    end
  end

  defp times(_none), do: nil

  defp times_limit, do: Application.get_env(:forge, :command_times_limit, @times_limit)

  defp time_line(text) do
    case Integer.parse(text) do
      {ms, ""} when ms >= 0 -> ms
      _unreadable -> nil
    end
  end
end
