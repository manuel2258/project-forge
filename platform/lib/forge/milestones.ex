defmodule Forge.Milestones do
  @moduledoc """
  Milestones — named goals of a project, in an order — and the priority order of the tickets in
  them (`docs/design/ui.md` § Milestones).

  Unguarded, as the contexts are: `Forge.Operator` guards what a person or a write token may do
  and passes the actor. Every write here is one transaction that writes its event.

  ## Orders

  A milestone has one order over its tickets, and the tickets in no milestone have an order of
  their own: `tickets.position`, within `(project_id, milestone_id)`. Only **open** tickets
  (active or stuck) are ordered by it; a merged or cancelled ticket keeps whatever place it had.

  **Every write that changes an order locks the list it changes** — the project's row first and,
  for a milestone's list, the milestone's after it (`move_ticket/3` through `lock_list/2`; the
  others take the same two rows themselves, and `put_restored/3` the project's alone) — reads the
  current order under the lock and rewrites dense positions. (Renaming or describing a milestone,
  `update/4`, changes no order and takes the milestone's row only.) A move is *relative* (`move_ticket/3`), worked out against the order read under the
  lock, so two people moving different tickets at once serialise and both moves are kept.

  **Lock order is the project row, then a milestone row**, in every writer here and in
  `Forge.Tickets.put_admit/5`, so no two of them can wait on each other.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.{Events, Repo}
  alias Forge.Milestones.Milestone
  alias Forge.Projects.Project
  alias Forge.Tickets.Ticket
  require Forge.Tickets.Ticket

  @typedoc "Where a move puts a ticket or a milestone in its order."
  @type to :: :top | :up | :down | :bottom | {:before, String.t()}

  @doc "The project's milestones in their order, closed ones last."
  @spec list(String.t()) :: [Milestone.t()]
  def list(project_id) do
    Repo.all(
      from m in Milestone,
        where: m.project_id == ^project_id,
        order_by: [asc: not is_nil(m.closed_at), asc: m.position, asc: m.inserted_at]
    )
  end

  @doc """
  A milestone of the project, or nil. **Resolved inside the project**: another project's id answers
  nil, as one that does not exist.
  """
  @spec get(String.t(), String.t()) :: Milestone.t() | nil
  def get(project_id, id) when is_binary(project_id) and is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Milestone, id: id, project_id: project_id)
      :error -> nil
    end
  end

  def get(_project_id, _id), do: nil

  @doc "The project's current milestone, or nil."
  @spec current(String.t()) :: Milestone.t() | nil
  def current(project_id),
    do: Repo.get_by(Milestone, project_id: project_id, current: true)

  @doc """
  The open milestone `id` of the project, locked `:share` or `:update`, or nil when it is closed, is
  another project's, or does not exist.
  """
  @spec lock_open(module(), String.t(), term(), :share | :update) :: Milestone.t() | nil
  def lock_open(repo, project_id, id, mode) do
    with true <- is_binary(id),
         {:ok, id} <- Ecto.UUID.cast(id) do
      open =
        from m in Milestone,
          where: m.id == ^id and m.project_id == ^project_id and is_nil(m.closed_at)

      case mode do
        :share -> repo.one(from m in open, lock: "FOR SHARE")
        :update -> repo.one(from m in open, lock: "FOR UPDATE")
      end
    else
      _not_an_id -> nil
    end
  end

  @doc "The place after the last ticket of the list `(project, milestone)`; nil is no milestone."
  @spec next_position(module(), String.t(), String.t() | nil) :: pos_integer()
  def next_position(repo, project_id, milestone_id) do
    (repo.one(
       from t in in_list(project_id, milestone_id),
         select: max(t.position)
     ) || 0) + 1
  end

  defp in_list(project_id, nil),
    do: from(t in Ticket, where: t.project_id == ^project_id and is_nil(t.milestone_id))

  defp in_list(project_id, milestone_id),
    do: from(t in Ticket, where: t.project_id == ^project_id and t.milestone_id == ^milestone_id)

  # -- milestones ------------------------------------------------------------------------------

  @doc "Creates a milestone at the bottom of the project's order. `actor` is an `Events` actor."
  @spec create(Project.t(), map(), Events.actor()) ::
          {:ok, Milestone.t()} | {:error, Ecto.Changeset.t()}
  def create(%Project{id: project_id}, attrs, actor) do
    write(project_id, fn -> create_in(project_id, attrs, actor) end)
  end

  defp create_in(project_id, attrs, actor) do
    lock_project(project_id)

    position =
      (Repo.one(from m in Milestone, where: m.project_id == ^project_id, select: max(m.position)) ||
         0) + 1

    %Milestone{}
    |> Milestone.create_changeset(
      attrs
      |> take_text()
      |> Map.merge(%{project_id: project_id, position: position})
    )
    |> Repo.insert()
    |> logged("milestone.created", actor, project_id, fn m -> %{"name" => m.name} end)
  end

  @doc "Changes a milestone's name and description. Open or closed."
  @spec update(String.t(), String.t(), map(), Events.actor()) ::
          {:ok, Milestone.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(project_id, id, attrs, actor) do
    write(project_id, fn -> update_in(project_id, id, attrs, actor) end)
  end

  defp update_in(project_id, id, attrs, actor) do
    with {:ok, milestone} <- fetch_locked(project_id, id) do
      milestone
      |> Milestone.text_changeset(take_text(attrs))
      |> Repo.update()
      |> logged("milestone.updated", actor, project_id, fn m ->
        %{
          "name" => m.name,
          "from" => %{"name" => milestone.name, "description" => milestone.description},
          "to" => %{"name" => m.name, "description" => m.description}
        }
      end)
    end
  end

  # Only the two text fields, whatever a caller sent: a map off the wire is not trusted to leave
  # `project_id`, `current` or `closed_at` alone.
  defp take_text(attrs) do
    for key <- [:name, :description],
        value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))),
        into: %{},
        do: {key, value}
  end

  @doc """
  Marks the milestone `id` as the project's current one, unmarking the old; nil unmarks. A closed
  milestone cannot be marked: `{:error, :closed}`.
  """
  @spec set_current(String.t(), String.t() | nil, Events.actor()) ::
          {:ok, Milestone.t() | nil} | {:error, :not_found | :closed}
  def set_current(project_id, id, actor) do
    write(project_id, fn -> set_current_in(project_id, id, actor) end)
  end

  defp set_current_in(project_id, id, actor) do
    lock_project(project_id)

    with {:ok, target} <- target(project_id, id) do
      Repo.update_all(
        from(m in Milestone, where: m.project_id == ^project_id and m.current),
        set: [current: false]
      )

      marked =
        if target do
          target |> Milestone.current_changeset(true) |> Repo.update!()
        end

      {:ok, _event} =
        Events.append("milestone.current", actor, %{
          project_id: project_id,
          payload: %{
            "milestone_id" => marked && marked.id,
            "name" => marked && marked.name
          }
        })

      {:ok, marked}
    end
  end

  defp target(_project_id, nil), do: {:ok, nil}

  defp target(project_id, id) do
    case get(project_id, id) do
      nil -> {:error, :not_found}
      %Milestone{closed_at: nil} = milestone -> {:ok, milestone}
      %Milestone{} -> {:error, :closed}
    end
  end

  @doc """
  Closes a milestone: its open tickets go to the bottom of the no-milestone order in their
  milestone order, its merged and cancelled tickets stay in it, it is unmarked if it was current.
  Never a deletion.
  """
  @spec close(String.t(), String.t(), Events.actor()) ::
          {:ok, Milestone.t()} | {:error, :not_found | :already_closed}
  def close(project_id, id, actor) do
    write(project_id, fn -> close_in(project_id, id, actor) end)
  end

  defp close_in(project_id, id, actor) do
    lock_project(project_id)

    with {:ok, milestone} <- fetch_locked(project_id, id),
         :ok <- if(Milestone.open?(milestone), do: :ok, else: {:error, :already_closed}) do
      moved = open_ids(project_id, milestone.id)
      base = next_position(Repo, project_id, nil)

      moved
      |> Enum.with_index(base)
      |> Enum.each(fn {ticket_id, position} ->
        Repo.update_all(from(t in Ticket, where: t.id == ^ticket_id),
          set: [milestone_id: nil, position: position]
        )
      end)

      closed =
        milestone
        |> Milestone.closing_changeset(DateTime.utc_now(:second))
        |> Repo.update!()

      {:ok, _event} =
        Events.append("milestone.closed", actor, %{
          project_id: project_id,
          payload: %{"milestone_id" => closed.id, "name" => closed.name, "moved" => moved}
        })

      {:ok, closed}
    end
  end

  @doc "Reopens a closed milestone. The tickets that left it do not come back."
  @spec reopen(String.t(), String.t(), Events.actor()) ::
          {:ok, Milestone.t()} | {:error, :not_found | :not_closed}
  def reopen(project_id, id, actor) do
    write(project_id, fn -> reopen_in(project_id, id, actor) end)
  end

  defp reopen_in(project_id, id, actor) do
    lock_project(project_id)

    with {:ok, milestone} <- fetch_locked(project_id, id),
         :ok <- if(Milestone.open?(milestone), do: {:error, :not_closed}, else: :ok) do
      milestone
      |> Milestone.closing_changeset(nil)
      |> Repo.update!()
      |> then(&{:ok, &1})
      |> logged("milestone.reopened", actor, project_id, fn m ->
        %{"milestone_id" => m.id, "name" => m.name}
      end)
    end
  end

  @doc "Moves an open milestone in the project's order of open milestones (`t:to/0`)."
  @spec move(String.t(), String.t(), to(), Events.actor()) ::
          {:ok, Milestone.t() | :unchanged} | {:error, :not_found | :closed | :not_in_order}
  def move(project_id, id, to, actor) do
    write(project_id, fn -> move_in(project_id, id, to, actor) end)
  end

  defp move_in(project_id, id, to, actor) do
    lock_project(project_id)

    with {:ok, milestone} <- fetch_locked(project_id, id),
         :ok <- if(Milestone.open?(milestone), do: :ok, else: {:error, :closed}) do
      ids =
        Repo.all(
          from m in Milestone,
            where: m.project_id == ^project_id and is_nil(m.closed_at),
            order_by: [asc: m.position, asc: m.inserted_at],
            select: m.id
        )

      with {:ok, ordered} <- reorder(ids, id, to),
           :changed <- changed(ordered, ids) do
        write_positions(Milestone, ordered)

        {:ok, _event} =
          Events.append("milestone.moved", actor, %{
            project_id: project_id,
            payload: %{
              "milestone_id" => id,
              "name" => milestone.name,
              "to" => Enum.find_index(ordered, &(&1 == id)) + 1
            }
          })

        {:ok, Repo.get!(Milestone, id)}
      else
        :same -> {:ok, :unchanged}
        {:error, _reason} = error -> error
      end
    end
  end

  defp changed(ordered, ordered), do: :same
  defp changed(_ordered, _ids), do: :changed

  # Dense positions, 1.. in the order given, written only where one differs.
  defp write_positions(schema, ordered) do
    ordered
    |> Enum.with_index(1)
    |> Enum.each(fn {id, position} ->
      Repo.update_all(from(r in schema, where: r.id == ^id and r.position != ^position),
        set: [position: position]
      )
    end)
  end

  # -- tickets ---------------------------------------------------------------------------------

  @doc """
  Puts an open ticket in an open milestone of its project, or in none (`milestone_id` nil), at the
  bottom of that order. `{:error, :milestone}` for one that is closed, another project's or not
  there — one answer for all three.
  """
  @spec set_ticket_milestone(Ticket.t(), String.t() | nil, Events.actor()) ::
          {:ok, Ticket.t()} | {:error, term()}
  def set_ticket_milestone(%Ticket{id: id, project_id: project_id}, milestone_id, actor) do
    write(project_id, fn -> set_ticket_milestone_in(id, project_id, milestone_id, actor) end)
  end

  defp set_ticket_milestone_in(id, project_id, milestone_id, actor) do
    lock_project(project_id)

    target =
      if milestone_id, do: lock_open(Repo, project_id, milestone_id, :update), else: nil

    ticket = Repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")

    case placement(ticket, milestone_id, target) do
      :place -> {:ok, place(ticket, target, actor)}
      :same -> {:ok, ticket}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The step `Forge.Engine.restore/2` runs first: a cancelled ticket keeps the milestone it had, and
  a milestone closed since would hold an open ticket nothing lists — the closed fold draws no rows
  and the ticket's page says *None*. So a restored ticket whose milestone is closed goes to the
  bottom of the no-milestone order, as closing the milestone would have put it, and the move is
  an event. One whose milestone is open, or who has none, is left as it is.
  """
  @spec put_restored(Ecto.Multi.t(), Ticket.t(), Events.actor()) :: Ecto.Multi.t()
  def put_restored(multi, %Ticket{id: id, project_id: project_id}, actor) do
    Ecto.Multi.run(multi, :unplaced, fn _repo, _changes ->
      lock_project(project_id)
      ticket = Repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")

      closed? =
        ticket.milestone_id != nil and
          Repo.exists?(
            from m in Milestone, where: m.id == ^ticket.milestone_id and not is_nil(m.closed_at)
          )

      if closed?, do: {:ok, place(ticket, nil, actor)}, else: {:ok, ticket}
    end)
  end

  defp placement(%Ticket{status: status}, _id, _target) when not Ticket.open?(status),
    do: {:error, {:not_open, status}}

  defp placement(_ticket, id, nil) when id != nil, do: {:error, :milestone}
  defp placement(%Ticket{milestone_id: nil}, nil, nil), do: :same
  defp placement(%Ticket{milestone_id: id}, _id, %{id: id}), do: :same
  defp placement(_ticket, _id, _target), do: :place

  defp place(%Ticket{} = ticket, target, actor) do
    to = target && target.id
    position = next_position(Repo, ticket.project_id, to)

    {:ok, moved} =
      ticket |> Ticket.place_changeset(%{milestone_id: to, position: position}) |> Repo.update()

    {:ok, _event} =
      Events.append("ticket.milestone_set", actor, %{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        payload: %{
          "from" => ticket.milestone_id,
          "from_name" => name_of(ticket.milestone_id),
          "to" => to,
          "to_name" => target && target.name
        }
      })

    moved
  end

  defp name_of(id), do: name(id)

  @doc "A milestone's name by id, or nil."
  @spec name(String.t() | nil) :: String.t() | nil
  def name(nil), do: nil
  def name(id), do: Repo.one(from m in Milestone, where: m.id == ^id, select: m.name)

  @doc "Names by id for the milestones of `project_id`, for a list that draws many tickets."
  @spec names(String.t()) :: %{String.t() => String.t()}
  def names(project_id),
    do:
      Repo.all(from m in Milestone, where: m.project_id == ^project_id, select: {m.id, m.name})
      |> Map.new()

  @doc """
  Moves an open ticket in the order it is in (`t:to/0`). Worked out against the order read under
  the lock, so a move is relative to what is there now and not to what the mover saw. A move that
  changes nothing writes nothing and answers `{:ok, :unchanged}`.
  """
  @spec move_ticket(Ticket.t(), to(), Events.actor()) ::
          {:ok, Ticket.t() | :unchanged} | {:error, term()}
  def move_ticket(%Ticket{id: id, project_id: project_id}, to, actor) do
    write(project_id, fn -> move_ticket_in(id, project_id, to, actor) end)
  end

  defp move_ticket_in(id, project_id, to, actor) do
    # Which list it is in is read to know which lock to take, and read again under it: a ticket
    # moved to another milestone meanwhile is then ordered in the list it is in now.
    milestone_id = Repo.one(from t in Ticket, where: t.id == ^id, select: t.milestone_id)
    lock_list(project_id, milestone_id)
    ticket = Repo.one!(from t in Ticket, where: t.id == ^id, lock: "FOR UPDATE")

    cond do
      not Ticket.open?(ticket.status) ->
        {:error, {:not_open, ticket.status}}

      ticket.milestone_id != milestone_id ->
        {:error, :moved}

      true ->
        order(ticket, to, actor)
    end
  end

  defp order(%Ticket{} = ticket, to, actor) do
    ids = open_ids(ticket.project_id, ticket.milestone_id)

    with {:ok, ordered} <- reorder(ids, ticket.id, to),
         :changed <- changed(ordered, ids) do
      write_positions(Ticket, ordered)

      {:ok, _event} =
        Events.append("ticket.moved", actor, %{
          project_id: ticket.project_id,
          ticket_id: ticket.id,
          payload: %{
            "in" => name_of(ticket.milestone_id) || "no milestone",
            "milestone_id" => ticket.milestone_id,
            "to" => Enum.find_index(ordered, &(&1 == ticket.id)) + 1
          }
        })

      {:ok, Repo.get!(Ticket, ticket.id)}
    else
      :same -> {:ok, :unchanged}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  `ids` with `id` moved as `to` says, or `{:error, :not_in_order}` when `id` — or the one it is
  to go before — is not among them. Pure, and the one definition of what top, up, down, bottom and
  before mean, for tickets and milestones alike.
  """
  @spec reorder([String.t()], String.t(), to()) :: {:ok, [String.t()]} | {:error, :not_in_order}
  def reorder(ids, id, to) do
    case Enum.find_index(ids, &(&1 == id)) do
      nil -> {:error, :not_in_order}
      index -> place(ids, id, index, to)
    end
  end

  defp place(ids, id, _index, :top), do: {:ok, [id | List.delete(ids, id)]}
  defp place(ids, id, _index, :bottom), do: {:ok, List.delete(ids, id) ++ [id]}
  defp place(ids, _id, 0, :up), do: {:ok, ids}

  defp place(ids, id, index, :up) do
    {before, [other, ^id | rest]} = Enum.split(ids, index - 1)
    {:ok, before ++ [id, other | rest]}
  end

  defp place(ids, id, index, :down) do
    if index == length(ids) - 1 do
      {:ok, ids}
    else
      {before, [^id, other | rest]} = Enum.split(ids, index)
      {:ok, before ++ [other, id] ++ rest}
    end
  end

  defp place(ids, id, _index, {:before, other}) do
    rest = List.delete(ids, id)

    case Enum.find_index(rest, &(&1 == other)) do
      nil -> {:error, :not_in_order}
      at -> {:ok, List.insert_at(rest, at, id)}
    end
  end

  defp place(_ids, _id, _index, _other), do: {:error, :not_in_order}

  defp open_ids(project_id, milestone_id) do
    Repo.all(
      from t in in_list(project_id, milestone_id),
        where: t.status in ^Ticket.open_statuses(),
        order_by: [asc: t.position, asc: t.number],
        select: t.id
    )
  end

  # -- reads -----------------------------------------------------------------------------------

  # What a row of the Milestones view and the API draws of a ticket. Not the whole row: a ticket
  # pins its workflow, and a milestone of hundreds of tickets would read hundreds of them.
  @ticket_fields [
    :id,
    :project_id,
    :number,
    :title,
    :state,
    :status,
    :ticket_type,
    :held_at,
    :held_transition,
    :held_entry,
    :pending_transition,
    :milestone_id,
    :position
  ]

  @doc """
  What the Milestones view draws, from one read of the tickets and one of the merge events: the
  open milestones in their order, each with `open` tickets in its order, `merged` ones and its
  `progress`; the `unplaced` open tickets in no milestone, in their order; and the `closed`
  milestones with the same.

  A ticket is **merged** when it is `done` and has a `ticket.merged` event (`Forge.Tickets.Doing.merged/2`
  reads it the same way); one that is done without a merge counts toward nothing and sits with the
  merged. Cancelled tickets are in no list and in no count.

  `progress` is `%{merged:, total:, on_hold:, in_flight:}`: merged out of open and merged
  together, and the open ones counted apart as on hold and in flight.
  """
  @spec overview(String.t()) :: %{
          milestones: [map()],
          closed: [map()],
          unplaced: [map()],
          current: Milestone.t() | nil
        }
  def overview(project_id) do
    milestones = list(project_id)

    tickets =
      Repo.all(
        from t in Ticket,
          where:
            t.project_id == ^project_id and
              (t.status in ^Ticket.open_statuses() or
                 (t.status == :done and not is_nil(t.milestone_id))),
          order_by: [asc: t.position, asc: t.number],
          select: struct(t, ^@ticket_fields)
      )

    merged = merged_ids(project_id, for(t <- tickets, t.status == :done, do: t.id))
    by_milestone = Enum.group_by(tickets, & &1.milestone_id)

    {open, closed} = Enum.split_with(milestones, &Milestone.open?/1)

    %{
      milestones: Enum.map(open, &entry(&1, by_milestone[&1.id] || [], merged)),
      closed: Enum.map(closed, &entry(&1, by_milestone[&1.id] || [], merged)),
      unplaced: Enum.filter(by_milestone[nil] || [], &Ticket.open?(&1.status)),
      current: Enum.find(open, & &1.current)
    }
  end

  defp entry(milestone, tickets, merged) do
    {open, done} = Enum.split_with(tickets, &Ticket.open?(&1.status))
    on_hold = Enum.count(open, &Ticket.held?/1)
    merged_count = Enum.count(done, &(&1.id in merged))

    %{
      milestone: milestone,
      open: open,
      merged: done,
      progress: %{
        merged: merged_count,
        total: length(open) + merged_count,
        on_hold: on_hold,
        in_flight: length(open) - on_hold
      }
    }
  end

  defp merged_ids(_project_id, []), do: MapSet.new()

  defp merged_ids(project_id, ids) do
    from(e in Events.Event,
      where: e.project_id == ^project_id and e.type == "ticket.merged" and e.ticket_id in ^ids,
      select: e.ticket_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # -- plumbing --------------------------------------------------------------------------------

  # One transaction, and the project's pages told once it committed — never inside it, where a
  # page reading on the message could read what is about to roll back.
  defp write(project_id, fun) do
    case Repo.transaction(fn -> unwrap(fun.()) end) do
      {:ok, value} ->
        Events.notify_project(project_id)
        {:ok, value}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, reason}), do: Repo.rollback(reason)

  defp lock_project(project_id),
    do: Repo.one!(from p in Project, where: p.id == ^project_id, lock: "FOR UPDATE", select: p.id)

  # The list a write orders: the project's row for no milestone, else the project's and then the
  # milestone's (the lock order the moduledoc names).
  defp lock_list(project_id, nil), do: lock_project(project_id)

  defp lock_list(project_id, milestone_id) do
    lock_project(project_id)
    Repo.one(from m in Milestone, where: m.id == ^milestone_id, lock: "FOR UPDATE")
  end

  defp fetch_locked(project_id, id) do
    with true <- is_binary(id),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Milestone{} = milestone <-
           Repo.one(
             from m in Milestone,
               where: m.id == ^id and m.project_id == ^project_id,
               lock: "FOR UPDATE"
           ) do
      {:ok, milestone}
    else
      _none -> {:error, :not_found}
    end
  end

  defp logged({:ok, milestone}, type, actor, project_id, payload) do
    {:ok, _event} =
      Events.append(type, actor, %{
        project_id: project_id,
        payload: Map.put(payload.(milestone), "milestone_id", milestone.id)
      })

    {:ok, milestone}
  end

  defp logged({:error, _changeset} = error, _type, _actor, _project_id, _payload), do: error
end
