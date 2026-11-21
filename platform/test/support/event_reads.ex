defmodule Forge.EventReads do
  @moduledoc """
  What a test says about reads of the event log: **how many rows a query of `events` returned**, so
  that "no read returned more than a page" is something a test asserts and not a thing a reader
  hopes (`docs/design/storage.md` § Retention, `docs/design/ui.md` § Activity).

  A telemetry handler on the repo's query event, which runs in the process that made the query — a
  LiveView's, not the test's — and sends what it saw to the test.
  """

  @doc "Starts counting for the calling test, and stops when it ends."
  def watch do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:forge, :repo, :query], &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  @doc false
  def handle(_event, _measurements, %{query: query, result: {:ok, %{num_rows: rows}}}, test)
      when is_binary(query) do
    if query =~ ~s(FROM "events"), do: send(test, {:events_read, rows, query})
  end

  def handle(_event, _measurements, _metadata, _test), do: :ok

  @doc "The row counts of every `events` read since the last call, oldest first."
  def rows do
    receive do
      {:events_read, rows, _query} -> [rows | rows()]
    after
      0 -> []
    end
  end

  @doc "The most rows any one `events` read since the last call returned."
  def most, do: Enum.max(rows(), fn -> 0 end)
end
