defmodule Forge.MergeQueue do
  @moduledoc """
  The per-project line of approved tickets waiting to be merged, one at a time, in the order their
  approvals were recorded (`docs/design/workflow-grammar-v1.md` § The merge queue).

  Storage and reads only. A ticket is queued exactly while it has a row; the decisions about a row
  — when it merges, when it is sent to integration, when it leaves — are `Forge.Engine`'s. A row
  enters, returns and leaves in the transaction that moves the ticket (approval, a job's end, a
  stick, a cancel, a take-out). The runner's own steps are two commits — the ticket's move, then
  the row's end — and `Forge.Engine.recover_queue/1` finishes the one a crash splits.
  """

  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Forge.Events
  alias Forge.MergeQueue.Entry
  alias Forge.Repo
  alias Forge.Tickets.Ticket
  alias ForgeCore.Workflow.Transition

  @doc "The ticket's row, or nil when it is not queued."
  @spec entry(Ticket.t() | String.t()) :: Entry.t() | nil
  def entry(%Ticket{id: id}), do: entry(id)
  def entry(ticket_id) when is_binary(ticket_id), do: Repo.get_by(Entry, ticket_id: ticket_id)

  @doc "Whether the ticket is in the merge queue."
  @spec queued?(Ticket.t()) :: boolean()
  def queued?(%Ticket{id: id}), do: Repo.exists?(from e in Entry, where: e.ticket_id == ^id)

  @doc "The project's queue in the order approvals were recorded, each with its ticket."
  @spec list(String.t()) :: [Entry.t()]
  def list(project_id), do: project_id |> rows() |> Repo.preload(:ticket)

  defp rows(project_id),
    do: Repo.all(from e in Entry, where: e.project_id == ^project_id, order_by: e.position)

  @doc """
  Where each queued ticket of the project stands, by ticket id:
  `%{index: 1.., total:, status:, ahead:}`.
  The board and the project page draw their flag from this one read.
  """
  @spec places(String.t()) :: %{String.t() => map()}
  def places(project_id), do: project_id |> rows() |> place_map()

  @doc """
  The queue in order with each entry's place: `{entry, place}`, ticket preloaded. One read for the
  project page, which draws the order and the places from the same rows.
  """
  @spec with_places(String.t()) :: [{Entry.t(), map()}]
  def with_places(project_id) do
    rows = list(project_id)
    places = place_map(rows)
    Enum.map(rows, &{&1, Map.fetch!(places, &1.ticket_id)})
  end

  defp place_map(rows) do
    total = length(rows)

    # `ahead` is the tickets in front that hold the line: one being integrated is skipped over,
    # so it is not what anyone behind it waits for.
    rows
    |> Enum.with_index(1)
    |> Map.new(fn {entry, index} ->
      ahead = rows |> Enum.take(index - 1) |> Enum.count(&(&1.status != :integrating))
      {entry.ticket_id, %{index: index, total: total, status: entry.status, ahead: ahead}}
    end)
  end

  @doc "Which of these tickets are queued."
  @spec queued_ids([String.t()]) :: [String.t()]
  def queued_ids(ticket_ids),
    do: Repo.all(from e in Entry, where: e.ticket_id in ^ticket_ids, select: e.ticket_id)

  @doc """
  Every project with a ticket waiting to be handled or a merge left unfinished (`merging`: a task
  that is gone, or one that is working, which the task's own registration tells apart).
  """
  @spec working_projects() :: [String.t()]
  def working_projects do
    Repo.all(
      from e in Entry,
        where: e.status in [:waiting, :merging],
        distinct: true,
        select: e.project_id
    )
  end

  @doc "Every `merging` row: a merge being made now, or one a platform or a task left unfinished."
  @spec merging() :: [Entry.t()]
  def merging, do: Repo.all(from e in Entry, where: e.status == :merging, order_by: e.position)

  @doc """
  Adds the ticket's place in the line to `multi`: a row for the edge `transition` (taken for
  `outcome`), against the changeset `source` and the `commit-message` version that are current now,
  and the ids of the approvals the transaction recorded, for withdrawing exactly those.
  `who` is an actor. The event names it.
  """
  @spec put_enter(Multi.t(), Ticket.t(), Transition.t(), String.t() | nil, map(), term(), map()) ::
          Multi.t()
  def put_enter(
        multi,
        %Ticket{} = ticket,
        %Transition{} = transition,
        outcome,
        source,
        who,
        attrs
      ) do
    Multi.run(multi, :merge_queue_entry, fn repo, changes ->
      approvals = Enum.map(transition.approve, &Map.fetch!(changes, {:approval, &1}).id)

      %Entry{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        from_state: transition.from,
        to_state: transition.to,
        outcome: outcome,
        edge_outcome: Transition.outcome(transition),
        changeset_sha: source.sha,
        changeset_version: source.version,
        commit_message_version: attrs[:commit_message_version],
        approval_ids: approvals,
        entered_by: Events.encode_actor(Forge.Actor.of(who)),
        comment: attrs[:comment]
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint(:ticket_id)
      |> repo.insert()
    end)
    |> Events.log(:merge_queue_entered, "merge_queue.entered", Forge.Actor.of(who), %{
      ticket_id: ticket.id,
      payload: %{
        "from" => transition.from,
        "to" => transition.to,
        "changeset" => source.sha,
        "changeset_version" => source.version,
        "comment" => attrs[:comment]
      }
    })
  end

  @doc """
  Puts an integrated ticket back in the line at the place it kept, for the edge it has now taken
  into the merging state and the changeset the integration produced.
  """
  @spec put_return(Multi.t(), Entry.t(), Transition.t(), String.t() | nil, map(), integer() | nil) ::
          Multi.t()
  def put_return(multi, %Entry{} = entry, %Transition{} = transition, outcome, source, message) do
    multi
    |> Multi.update(
      :merge_queue_entry,
      Ecto.Changeset.change(entry, %{
        status: :waiting,
        from_state: transition.from,
        to_state: transition.to,
        outcome: outcome,
        edge_outcome: Transition.outcome(transition),
        changeset_sha: source.sha,
        changeset_version: source.version,
        commit_message_version: message
      })
    )
    |> Events.log(:merge_queue_returned, "merge_queue.returned", :system, %{
      ticket_id: entry.ticket_id,
      payload: %{
        "from" => transition.from,
        "to" => transition.to,
        "changeset" => source.sha,
        "changeset_version" => source.version
      }
    })
  end

  @doc """
  Takes the ticket out of the line, if it is in it, and says why in an event — only when it was.
  A no-op without a row, which is what lets every way a ticket stops calling it unconditionally.
  """
  @spec put_leave(Multi.t(), String.t(), String.t()) :: Multi.t()
  def put_leave(multi, ticket_id, reason) do
    Multi.run(multi, {:merge_queue_left, System.unique_integer([:positive])}, fn repo, _changes ->
      {count, _rows} = repo.delete_all(from e in Entry, where: e.ticket_id == ^ticket_id)

      if count > 0 do
        {:ok, _event} =
          Events.append("merge_queue.left", :system, %{
            ticket_id: ticket_id,
            payload: %{"reason" => reason}
          })
      end

      {:ok, count}
    end)
  end

  @doc "Sets the row's status (`:integrating` when its ticket was sent to integrate)."
  @spec put_status(Multi.t(), String.t(), :waiting | :integrating) :: Multi.t()
  def put_status(multi, ticket_id, status) do
    Multi.update_all(
      multi,
      {:merge_queue_status, System.unique_integer([:positive])},
      from(e in Entry, where: e.ticket_id == ^ticket_id),
      set: [status: status]
    )
  end

  @doc """
  Makes the front `waiting` row of the project the one being merged and returns it, nil when none
  waits, `:busy` when the project already has one being merged and another waits (the second claim
  is what the database refuses). The partial unique index on
  `(project_id) where status = 'merging'` is the guard: two runners claiming at once cannot both win.
  """
  @spec claim(String.t()) :: Entry.t() | nil | :busy
  def claim(project_id) do
    front =
      from e in Entry,
        where: e.project_id == ^project_id and e.status == :waiting,
        order_by: e.position,
        limit: 1,
        select: e.id

    {count, rows} =
      Repo.update_all(
        from(e in Entry, where: e.id in subquery(front), select: e.id),
        set: [status: :merging]
      )

    case {count, rows} do
      {0, _none} -> nil
      {1, [id]} -> Repo.get!(Entry, id)
    end
  rescue
    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: :unique_violation}} -> :busy
        other -> reraise other, __STACKTRACE__
      end
  end

  @doc """
  How the ticket last left the line, for words to a person who pressed *Take out* too late:
  `{:merged | :taken_out | :left, reason}`, or nil when it never was in it.
  """
  @spec last_left(String.t()) :: {atom(), String.t() | nil} | nil
  def last_left(ticket_id) do
    event =
      Repo.one(
        from e in Forge.Events.Event,
          where:
            e.ticket_id == ^ticket_id and e.type in ["merge_queue.left", "merge_queue.taken_out"],
          order_by: [desc: e.seq],
          limit: 1
      )

    case event do
      nil -> nil
      %{type: "merge_queue.taken_out"} -> {:taken_out, nil}
      %{payload: %{"reason" => "merged"}} -> {:merged, "merged"}
      %{payload: %{"reason" => reason}} -> {:left, reason}
    end
  end

  @doc "Asks the runner to look at the project's line; nothing where no runner runs (tests)."
  @spec kick(String.t()) :: :ok
  def kick(project_id), do: Forge.MergeQueue.Runner.kick(project_id)
end
