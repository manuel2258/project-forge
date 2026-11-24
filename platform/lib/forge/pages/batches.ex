defmodule Forge.Pages.Batches do
  @moduledoc """
  What a person's forge page has already applied of the batches it sent (`docs/design/pages.md`
  § What a person's page does): the last sequence number per page and client, in an ETS table this process owns.

  A page batches what is typed and sends it a few times a second, each batch under a client id —
  random per page load — and a number. When the socket drops with a batch out, the page cannot
  know whether the server applied it, and sends it again on the rejoin, to **a new LiveView
  process**: so what was applied cannot be remembered in the process that applied it. A batch at or
  below the last number applied for its client is acknowledged and not applied again, which is what
  keeps a save from being made twice across a reconnect.

  **A platform restart forgets the table.** A batch sent again after one is applied again; that
  sets the same values and changes only their counters, but it can overwrite a write somebody else
  made in the interval. `pages.md` § What it does not defend says so.

  A client's entry goes after `@ttl` without a batch, swept on each call that writes: a table that
  only grew would hold a row for every page load there ever was.
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.hours(6)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether `client`'s batch number `seq` of `page_id` — or a later one — was applied already."
  @spec applied?(String.t(), String.t(), integer()) :: boolean()
  def applied?(page_id, client, seq) do
    case :ets.lookup(@table, {page_id, client}) do
      [{_key, last, _at}] -> seq <= last
      [] -> false
    end
  end

  @doc "Records that `client`'s batch `seq` of `page_id` was applied."
  @spec applied(String.t(), String.t(), integer()) :: :ok
  def applied(page_id, client, seq) do
    now = System.monotonic_time(:millisecond)
    last = max(seq, last(page_id, client))
    :ets.insert(@table, {{page_id, client}, last, now})
    sweep(now)
    :ok
  end

  defp last(page_id, client) do
    case :ets.lookup(@table, {page_id, client}) do
      [{_key, last, _at}] -> last
      [] -> -1
    end
  end

  defp sweep(now) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now - @ttl}], [true]}])
    :ok
  end
end
