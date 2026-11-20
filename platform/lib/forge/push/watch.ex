defmodule Forge.Push.Watch do
  @moduledoc """
  Pushes what has started waiting on a person, as it starts (`docs/design/ui.md` § The phone).

  Every change to a ticket is announced on the tickets topic (`Forge.Events.notify/1`), and after
  each one this reads the ticket the way the queue does — `Forge.Queue.for_ticket/1` — and hands
  each item it had not seen before to `Forge.Push.waiting/1`. Whether that pushes is that
  function's question, and so `Forge.Queue.waiting?/1`'s: the one gate, so nothing here filters
  by kind. A question, an approval, a stuck ticket and a ticket resting where only a person can
  move it push because the queue says they wait; an assumption does not, because it says it does
  not. The one place a kind is named here is what makes two readings the same wait (`key/1`),
  which differs by kind because what a wait is waiting at does.

  **A ticket on hold pushes nothing, and neither does its release.** What waits on a held ticket is
  recorded as seen and marked `:held` in its set, so the read that sees it released finds the mark,
  takes what waits then as seen too and pushes nothing — the person releasing it knows
  (`docs/design/ui.md` § Push follows the queue). A question or approval that starts waiting
  after that pushes as usual.

  **Pushed once per time it starts waiting.** An item stays seen while it waits and is forgotten
  once it stops, so a ticket that is stuck, moved, and stuck again is pushed twice, and a ticket
  whose cost ticks while it is stuck is pushed once. What was waiting when the node started is
  taken as seen, so a restart does not push the queue again.

  A conversation's reply is not seen here: a project conversation is announced under no ticket,
  and a turn ending is its own moment, so `Forge.Conversations` pushes it through the same gate
  when it happens (`Forge.Push.chat_reply/1`). Nor is a schedule's alert, which has no ticket:
  `Forge.Schedules` pushes it as it opens the item.

  Started on the node that runs jobs, when push is configured, as the digest is. Tests start it
  themselves.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Forge.{Events, Push, Queue, Repo}
  alias Forge.Tickets.Ticket

  # How long to wait before reading the queue again when it could not be read.
  @retry :timer.seconds(5)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Waits until every announcement sent before this call has been handled. For tests."
  @spec sync() :: :ok
  def sync, do: GenServer.call(__MODULE__, :sync)

  # The queue is read after `init/1`, so a database that is down delays the watch rather than
  # failing the tree it is started in. A change heard before the read is in what the read finds,
  # and taken as seen with the rest.
  @impl true
  def init(_opts) do
    :ok = Events.subscribe()
    {:ok, %{seen: nil}, {:continue, :seed}}
  end

  @impl true
  def handle_continue(:seed, state), do: {:noreply, seed(state)}

  # The global topic, and every message on it is this process's business: it exists to look at
  # each ticket that changed. What it filters is the one announcement that names no ticket — a
  # project conversation's — before reading anything.
  @impl true
  def handle_info({:ticket_changed, nil}, state), do: {:noreply, state}

  def handle_info({:ticket_changed, _id}, %{seen: nil} = state), do: {:noreply, state}

  def handle_info({:ticket_changed, id}, state),
    do: {:noreply, %{state | seen: changed(state.seen, id)}}

  def handle_info(:seed, state), do: {:noreply, seed(state)}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  # What waits when the watch starts is taken as seen, so a restart does not push the queue
  # again. A project conversation is in the queue and on no ticket, and this is per ticket.
  defp seed(state) do
    seen =
      Queue.items()
      |> Enum.filter(& &1.ticket)
      |> Enum.group_by(& &1.ticket.id, &key/1)
      |> Map.new(fn {id, keys} -> {id, MapSet.new(keys)} end)

    # A held ticket's decisions are not in `Queue.items/0` and are seen all the same, marked, so a
    # restart does not push them when the ticket is released.
    held =
      Repo.all(
        from t in Ticket, where: t.status in ^Ticket.open_statuses() and not is_nil(t.held_at)
      )

    seen =
      Enum.reduce(held, seen, fn ticket, seen ->
        case ticket |> Queue.for_ticket() |> remember(ticket) do
          nil -> seen
          keys -> Map.put(seen, ticket.id, keys)
        end
      end)

    %{state | seen: seen}
  rescue
    error ->
      Logger.warning(
        "push watch could not read the queue, trying again: #{Exception.message(error)}"
      )

      Process.send_after(self(), :seed, @retry)
      state
  end

  @doc """
  Hands `Forge.Push.waiting/1` what the queue holds for ticket `id` now and did not before, and
  returns what is seen. Public so it can be driven without the process.

  A ticket that cannot be read leaves what is seen as it was, so the next change to it looks
  again — rather than the watch crashing, and starting over with whatever waits taken as seen.
  """
  @spec changed(%{String.t() => MapSet.t()}, String.t()) :: %{String.t() => MapSet.t()}
  def changed(seen, id) do
    {ticket, items} =
      case Repo.get(Ticket, id) do
        nil -> {nil, []}
        ticket -> {ticket, Queue.for_ticket(ticket)}
      end

    before = Map.get(seen, id, MapSet.new())

    # Held now, or held at the last read and released since: either way what is waiting is
    # taken as seen and not pushed (`@moduledoc`).
    if not quiet?(ticket, before) do
      for item <- items, not MapSet.member?(before, key(item)), do: Push.waiting(item)
    end

    # A ticket with nothing waiting is dropped rather than kept with an empty set. Equivalent
    # mutant: `Map.get(seen, id, MapSet.new())` reads the two the same, so keeping it changes
    # nothing but the size of the map a long-running node holds — which is why it is dropped.
    case remember(items, ticket) do
      nil -> Map.delete(seen, id)
      keys -> Map.put(seen, id, keys)
    end
  rescue
    error ->
      Logger.warning("push watch could not read ticket #{id}: #{Exception.message(error)}")
      seen
  end

  defp quiet?(nil, _before), do: false
  defp quiet?(ticket, before), do: Ticket.held?(ticket) or MapSet.member?(before, :held)

  # Held and still open: a ticket closed while held has no wait to release, so marking it would keep
  # a set the map never drops (`Queue.for_ticket/1` has nothing for it).
  defp held_open?(%Ticket{status: status} = ticket),
    do: Ticket.held?(ticket) and status in Ticket.open_statuses()

  # The set to keep for a ticket: the keys of what waits, and `:held` while it is on hold — kept
  # even when nothing waits, so the release that follows is still the one read that is quiet. Nil
  # when there is nothing to keep.
  defp remember(items, ticket) do
    keys = MapSet.new(items, &key/1)
    keys = if ticket && held_open?(ticket), do: MapSet.put(keys, :held), else: keys
    if MapSet.size(keys) == 0, do: nil, else: keys
  end

  # What makes two readings the same wait. Not the item's `since`, which for a ticket's own kinds
  # is its `updated_at` and moves whenever the row does. A question is its document and its key:
  # the key survives an edit that makes a new version of the document, and is unique only within
  # one document, so two documents asking with the same key are two questions.
  defp key(%{kind: :question, question: question}),
    do: {:question, question.artifact_version.artifact_id, question.key}

  defp key(%{kind: :approval, detail: pending}), do: {:approval, pending}
  defp key(%{kind: kind, ticket: ticket}), do: {kind, ticket.state}
end
