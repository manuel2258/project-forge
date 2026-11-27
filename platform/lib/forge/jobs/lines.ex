defmodule Forge.Jobs.Lines do
  @moduledoc """
  The live lines of the commands that are running: what a command's page shows while it runs, each
  line with its time since the command started (`docs/design/worker-tier.md` § Looking into a copy).

  **Held in memory and stored as nothing**: a forge `check` prints some 2,100 lines and a ticket ran
  33 commands, against an event log cut down at 280,000 rows (`docs/design/storage.md` § Retention),
  so a line is never an event. They are dropped five minutes after the command finishes, by when the
  log and its times are in the store, and a restart of the platform loses them: the worker sends
  every line it still has again after it joins (from the first, or from the first it kept once it has
  trimmed: `docs/design/worker-channel.md` § Protocol 18), and `put/3` drops the ones it holds.

  A command's lines are bounded at 20,000: past it the oldest go, and `all/1` says where the held
  ones start, so the page can say the earlier lines are in the log once the command ends.

  One process owns the table and serialises writes, so two batches of one command are never applied
  out of order; reads go straight to the table.
  """

  use GenServer

  @table __MODULE__
  @max_lines ForgeCore.Explore.max_live_lines()
  # Text is the worker's, masked and cut at 4 KiB there; a platform that trusted that would hold
  # whatever a machine sent, so it is cut again.
  @max_text 8_192
  @drop_after_ms 5 * 60 * 1000
  # The furthest line number believed for a command that holds nothing: a command prints nothing like
  # a billion lines, and a bound keeps a stray number from being a key.
  @max_from 1_000_000_000

  # -- the table ---------------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "The most lines held for one command."
  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc "The PubSub topic a command's lines are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(job_id), do: "command_lines:" <> job_id

  @doc "Subscribes the caller to `{:command_lines, job_id, from_index, [[ms, text]]}`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(job_id), do: Phoenix.PubSub.subscribe(Forge.PubSub, topic(job_id))

  @doc "Stops the caller hearing a command's lines."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(job_id), do: Phoenix.PubSub.unsubscribe(Forge.PubSub, topic(job_id))

  # -- writing -----------------------------------------------------------------------------------

  @doc """
  Holds `lines` (`[[ms, text], …]`) of a command, the first of them being line number `from`
  (counted from 0). **Lines it already holds are dropped**: after a join the worker sends again
  what it still has. What is new is broadcast on `topic/1` as `{:command_lines, job_id, first_new,
  new}`. An entry that is not `[ms, text]` with a whole `ms` and a text is dropped and ends the
  batch, since every later line's number would be wrong.
  """
  @spec put(String.t(), term(), term()) :: :ok
  def put(job_id, from, lines) when is_binary(job_id) and is_integer(from) and from >= 0 do
    if is_list(lines), do: GenServer.call(__MODULE__, {:put, job_id, from, lines})
    :ok
  end

  def put(_job_id, _from, _lines), do: :ok

  @doc "Drops a command's lines five minutes from now: it has finished, and its log is in the store."
  @spec drop_later(String.t()) :: :ok
  def drop_later(job_id), do: GenServer.cast(__MODULE__, {:drop_later, job_id})

  @doc "Drops a command's lines at once."
  @spec drop(String.t()) :: :ok
  def drop(job_id), do: GenServer.call(__MODULE__, {:drop, job_id})

  # -- reading -----------------------------------------------------------------------------------

  @doc """
  What is held for a command: `%{first: index of the first line held, lines: [[ms, text]],
  total_seen: how many lines have been seen, held or not}`, or nil when nothing has arrived.
  """
  @spec all(String.t()) ::
          %{
            first: non_neg_integer(),
            lines: [[integer() | binary()]],
            total_seen: non_neg_integer()
          }
          | nil
  def all(job_id) do
    case :ets.lookup(@table, {:meta, job_id}) do
      [{_key, next, first}] ->
        lines =
          @table
          |> :ets.select([{{{job_id, :_}, :"$1", :"$2"}, [], [[:"$1", :"$2"]]}])

        %{first: first, lines: lines, total_seen: next}

      [] ->
        nil
    end
  end

  # -- the process -------------------------------------------------------------------------------

  @impl true
  def handle_call({:put, job_id, from, lines}, _from, state) do
    {next, first} =
      case :ets.lookup(@table, {:meta, job_id}) do
        [{_key, next, first}] -> {next, first}
        [] -> {0, 0}
      end

    {next, first} = skip_ahead(job_id, from, lines, next, first)
    {accepted, next} = accept(job_id, from, lines, next)
    first = trim(job_id, first, next)
    :ets.insert(@table, {{:meta, job_id}, next, first})

    case accepted do
      [] ->
        :ok

      [{index, _ms, _text} | _rest] ->
        broadcast(job_id, index, Enum.map(accepted, fn {_index, ms, text} -> [ms, text] end))
    end

    {:reply, :ok, state}
  end

  def handle_call({:drop, job_id}, _from, state) do
    delete(job_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:drop_later, job_id}, state) do
    Process.send_after(self(), {:drop, job_id}, drop_after_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info({:drop, job_id}, state) do
    delete(job_id)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop_after_ms, do: Application.get_env(:forge, :command_lines_drop_ms, @drop_after_ms)

  defp delete(job_id) do
    :ets.match_delete(@table, {{job_id, :_}, :_, :_})
    :ets.delete(@table, {:meta, job_id})
  end

  # A worker that trimmed its own copy sends again, after a join, from the first line it still has:
  # this node holds nothing (it restarted), or less than the worker has dropped (a long disconnect:
  # the worker may have printed far more than the cap since). The lines before `from` are the ones
  # the cap would have dropped, so what is held starts there, whatever is held now. **Only a `from`
  # past `@max_from` is not believed**, and the trim below is bounded by the batch, so a machine
  # that sends line 10^12 costs the one process every other machine's `put/3` waits for nothing,
  # and one that sends a believed number can only move its own command's lines.
  defp skip_ahead(job_id, from, [[ms, text] | _rest], next, _first)
       when from > next and from <= @max_from and is_integer(ms) and ms >= 0 and
              is_binary(text) do
    :ets.match_delete(@table, {{job_id, :_}, :_, :_})
    {from, from}
  end

  defp skip_ahead(_job_id, _from, _lines, next, first), do: {next, first}

  # The lines from `next` on, in order; stops at the first that is not a line, and at a batch that
  # starts past `next` (a gap further than `skip_ahead/5` allows is never filled in).
  defp accept(job_id, from, lines, next) do
    lines
    |> Enum.with_index(from)
    |> Enum.reduce_while({[], next}, fn
      {_line, index}, {accepted, next} when index < next ->
        {:cont, {accepted, next}}

      {[ms, text], index}, {accepted, next}
      when index == next and is_integer(ms) and ms >= 0 and is_binary(text) ->
        text = clean(text)
        :ets.insert(@table, {{job_id, index}, ms, text})
        {:cont, {[{index, ms, text} | accepted], index + 1}}

      {_malformed, _index}, acc ->
        {:halt, acc}
    end)
    |> then(fn {accepted, next} -> {Enum.reverse(accepted), next} end)
  end

  defp clean(text) do
    text = if byte_size(text) > @max_text, do: binary_part(text, 0, @max_text), else: text
    String.replace_invalid(text)
  end

  # Past the cap the oldest go: from `first` up to what leaves `@max_lines` held. Bounded by the
  # batch: `next` moves one line at a time (`accept/4`), so no more than a batch's worth of keys.
  defp trim(job_id, first, next) do
    keep_from = max(next - @max_lines, 0)

    if keep_from > first do
      Enum.each(first..(keep_from - 1)//1, &:ets.delete(@table, {job_id, &1}))
      keep_from
    else
      first
    end
  end

  defp broadcast(job_id, first_new, lines) do
    Phoenix.PubSub.broadcast(
      Forge.PubSub,
      topic(job_id),
      {:command_lines, job_id, first_new, lines}
    )
  end
end
