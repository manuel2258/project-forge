defmodule Forge.Tickets.Views do
  @moduledoc """
  **Since you last looked** (`docs/design/ui.md` § The end of the pass, and *All*): when each
  person last opened each ticket's page, and what happened on the ticket after that.

  A look is recorded when the ticket's page is opened — by `ForgeWeb.TicketLive`, after the
  membership check, so a page that refused its reader records nothing — and what a page compares
  against is the **previous** look, which `touch/2` returns before it writes the new one. Per
  person: another person's look is another row, and never moves mine.

  Nothing else writes here. The queue reads looks (`since/2`) and does not record one: reading an
  item in the pass is not opening its ticket.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.Events.Event
  alias Forge.Repo
  alias Forge.Tickets.{Ticket, View}

  # What *since you last looked* lists: the ticket's own story — where it went, what stopped it,
  # what was decided, what was said in its conversations, a document written, a job ending. Not a job's harness
  # stream, which is the job page's, nor the bookkeeping around it (a credential changing, a run
  # resumed), which says nothing a person deciding about the ticket needs.
  @listed ~w(ticket.admitted transition.taken ticket.stuck ticket.unstuck ticket.retried
             ticket.done ticket.cancelled ticket.restored ticket.renamed ticket.merged
             ticket.merge_conflicted approval.requested approval.approved approval.rejected
             step.accepted merge_queue.entered merge_queue.left job.finished chat.message
             artifact.version_written)

  @doc "The event types *since you last looked* lists."
  @spec listed() :: [String.t()]
  def listed, do: @listed

  @doc """
  Records that `user` opened `ticket` now, and returns when they had last opened it before —
  nil the first time. The previous look is read **before** the new one is written: returning the
  row after the upsert would always say *just now*, and nothing would ever be new.
  """
  @spec touch(User.t(), Ticket.t()) :: DateTime.t() | nil
  def touch(%User{id: user_id}, %Ticket{id: ticket_id}) do
    now = DateTime.utc_now()

    {:ok, previous} =
      Repo.transaction(fn ->
        previous =
          Repo.one(
            from v in View,
              where: v.user_id == ^user_id and v.ticket_id == ^ticket_id,
              select: v.viewed_at
          )

        Repo.insert!(%View{user_id: user_id, ticket_id: ticket_id, viewed_at: now},
          on_conflict: [set: [viewed_at: now]],
          conflict_target: [:user_id, :ticket_id]
        )

        previous
      end)

    previous
  end

  @doc "When `user` last opened each of `ticket_ids`, as a map; a ticket never opened is absent."
  @spec since(User.t(), [String.t()]) :: %{String.t() => DateTime.t()}
  def since(%User{id: user_id}, ticket_ids) do
    Repo.all(
      from v in View,
        where: v.user_id == ^user_id and v.ticket_id in ^ticket_ids,
        select: {v.ticket_id, v.viewed_at}
    )
    |> Map.new()
  end

  @doc """
  The listed events of `ticket_id` from `at` on, oldest first — the newest `limit` of them, so a
  ticket nobody has opened in a month is not read whole. `at` nil is a ticket never opened: its
  newest `limit` events, all of them new.

  An event's time is whole seconds and a look's is not, so an event in the same second as the
  look counts as after it: one shown as new that was not is the failure a reader can live with.
  """
  @spec events_since(String.t(), DateTime.t() | nil, pos_integer()) :: [Event.t()]
  def events_since(ticket_id, at, limit) do
    query =
      from e in Event,
        where: e.ticket_id == ^ticket_id and e.type in ^@listed,
        order_by: [desc: e.seq],
        limit: ^limit

    query =
      case at do
        nil -> query
        at -> from e in query, where: e.inserted_at >= ^DateTime.truncate(at, :second)
      end

    query |> Repo.all() |> Enum.reverse()
  end
end
