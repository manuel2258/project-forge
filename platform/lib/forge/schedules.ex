defmodule Forge.Schedules do
  @moduledoc """
  Schedules: tickets a workflow file says to admit on a clock, once a project admin has switched
  each on (`docs/design/schedules.md`, grammar in `docs/design/workflow-grammar-v1.md` §
  Schedules).

  What a schedule *is* — its cron line, title and body — is in the repository, read at the default
  branch's head. This module keeps what a person did about it and what came of it
  (`Forge.Schedules.Schedule`), and does the firing.

  **No guards here.** Who may switch a schedule on or off, and who may dismiss its alert, is
  `Forge.Operator`'s to say (`docs/design/identity.md` § Where the guard lives); the runner and
  the membership functions that switch a schedule off are the platform's own and past every gate.
  What *is* checked here, at the moment it matters, is that the admin a schedule acts for may still
  admit (`fire/4`): the switch having been turned off when a role changed is not relied on.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Multi
  alias Forge.Access
  alias Forge.Accounts.{Scope, User}
  alias Forge.{Events, Projects, Push, Repo, Tickets}
  alias Forge.Projects.Project
  alias Forge.Schedules.Schedule
  alias ForgeCore.Cron
  alias ForgeCore.Workflow

  @types_cache :forge_schedules_types

  # -- reading ------------------------------------------------------------------------------

  @doc "Every row of a project: the schedules a person has ever switched on."
  @spec rows(Project.t()) :: [Schedule.t()]
  def rows(%Project{id: project_id}) do
    Repo.all(
      from s in Schedule,
        where: s.project_id == ^project_id,
        preload: [:enabled_by, :last_ticket],
        order_by: [asc: s.ticket_type, asc: s.name]
    )
  end

  @doc "The row of one schedule, or nil: `type` is nil for the single file."
  @spec get(Project.t(), String.t() | nil, String.t()) :: Schedule.t() | nil
  def get(%Project{id: project_id}, type, name) do
    Repo.one(
      from s in Schedule,
        where: s.project_id == ^project_id and s.name == ^name,
        where: ^type_is(type),
        preload: [:enabled_by, :last_ticket]
    )
  end

  @doc "A schedule's row by id, or nil: for a page that was given an id and nothing else."
  @spec find(term()) :: Schedule.t() | nil
  def find(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Schedule, id)
      :error -> nil
    end
  end

  def find(_id), do: nil

  defp type_is(nil), do: Ecto.Query.dynamic([s], is_nil(s.ticket_type))
  defp type_is(type), do: Ecto.Query.dynamic([s], s.ticket_type == ^type)

  @doc """
  What a project's Workflow view and the JSON API draw: for each entry of the types listing
  (`Forge.Tickets.types/2`), the schedules its file declares, each with its row if there is one and
  the next time it comes due; or, for a file that does not parse, the reason and the schedules
  that are on, by name.

  A schedule is *declared* by the file and *on* by its row. The rows come from `rows/1`.
  """
  @spec declared(map(), [Schedule.t()], DateTime.t()) :: [map()]
  def declared(%{types: types}, rows, now \\ DateTime.utc_now()) do
    Enum.map(types, fn %{name: type, workflow: workflow} = entry ->
      mine = Enum.filter(rows, &(&1.ticket_type == type))

      case workflow do
        {:ok, %Workflow{schedules: schedules}} ->
          %{
            type: type,
            release: entry[:release] == true,
            schedules:
              Enum.map(schedules, &view(&1, Enum.find(mine, fn r -> r.name == &1.name end), now)),
            error: nil
          }

        {:error, reason} ->
          %{
            type: type,
            release: entry[:release] == true,
            schedules: for(r <- mine, Schedule.on?(r), do: view(nil, r, now)),
            error: reason
          }
      end
    end)
  end

  @doc """
  What `declared/3` draws when the workflow cannot be read **at all** — no workflow, or both forms —
  so there are no files to list: the schedules that are on, by name, grouped by the type they were
  declared in, each with `reason` (`docs/design/schedules.md` § A file that does not read).
  """
  @spec unreadable([Schedule.t()], term(), DateTime.t()) :: [map()]
  def unreadable(rows, reason, now \\ DateTime.utc_now()) do
    rows
    |> Enum.filter(&Schedule.on?/1)
    |> Enum.group_by(& &1.ticket_type)
    |> Enum.sort_by(fn {type, _rows} -> type || "" end)
    |> Enum.map(fn {type, mine} ->
      %{type: type, release: false, schedules: Enum.map(mine, &view(nil, &1, now)), error: reason}
    end)
  end

  @doc "The UTC date, `2026-11-23`, of a due time given as a `DateTime` or the ISO 8601 text the log keeps."
  @spec due_date(DateTime.t() | String.t() | term()) :: String.t()
  def due_date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()
  def due_date(<<date::binary-size(10), _rest::binary>>), do: date
  def due_date(_other), do: "?"

  # One schedule as it is drawn. `schedule` is nil for one whose file does not parse: its name and
  # the line last read are all there is.
  defp view(schedule, row, now) do
    line = (schedule && schedule.cron) || (row && row.cron)

    %{
      name: (schedule && schedule.name) || row.name,
      cron: line,
      title: schedule && schedule.title,
      body: schedule && schedule.body,
      row: row,
      on: row != nil and Schedule.on?(row),
      next_at: next_at(line, row, now)
    }
  end

  defp next_at(nil, _row, _now), do: nil

  defp next_at(line, row, now) do
    case Cron.parse(line) do
      {:ok, cron} -> Cron.next_after(cron, latest(row, now))
      {:error, _} -> nil
    end
  end

  # An off schedule's next time is the next time it *would* come due, from now; one that is on has
  # its cursor, so a firing it is late for is shown as due now rather than a week away.
  defp latest(%Schedule{fires_after: %DateTime{} = after_}, _now), do: after_
  defp latest(_row, now), do: now

  # -- switching ----------------------------------------------------------------------------

  @doc """
  Switches a schedule on in `admin`'s name: every ticket it admits is admitted as them. Refuses,
  and writes nothing, with `{:error, :schedule_gone}` (the file no longer declares it),
  `{:error, :schedule_unreadable}` (it cannot be read: its file does not parse, or there is no
  workflow) or `{:error, :already_on}`. It fires only for times **after** now.
  """
  @spec switch_on(Project.t(), User.t(), String.t() | nil, String.t()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def switch_on(%Project{} = project, %User{} = admin, type, name) do
    with {:ok, schedule} <- declared_schedule(project, type, name) do
      now = DateTime.utc_now(:second)

      Multi.new()
      |> Multi.run(:row, fn _repo, _ -> lock_or_create(project, type, name) end)
      |> Multi.run(:on, fn repo, %{row: row} -> turn_on(repo, row, admin, schedule, now) end)
      |> Events.log(:event, "schedule.switched_on", {:user, admin.id}, fn %{on: row} ->
        %{project_id: project.id, payload: payload(row, %{"cron" => schedule.cron})}
      end)
      |> Repo.transaction()
      |> finish(project)
    end
  end

  defp turn_on(_repo, %Schedule{enabled_by_id: id}, _admin, _schedule, _now) when not is_nil(id),
    do: {:error, :already_on}

  defp turn_on(repo, row, admin, schedule, now) do
    row
    |> Ecto.Changeset.change(%{
      enabled_by_id: admin.id,
      enabled_at: now,
      fires_after: now,
      cron: schedule.cron,
      problem: nil,
      problem_kind: nil,
      problem_at: nil,
      alerted_at: nil
    })
    |> repo.update()
  end

  @doc """
  Switches a schedule off, by `user`. `{:error, :already_off}` when it is not on. Clears its
  problem and its open queue item with it.
  """
  @spec switch_off(Project.t(), User.t(), String.t() | nil, String.t()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def switch_off(%Project{} = project, %User{} = user, type, name) do
    Multi.new()
    |> Multi.run(:row, fn _repo, _ -> lock_existing(project, type, name, :already_off) end)
    |> Multi.run(:off, fn repo, %{row: row} ->
      if Schedule.on?(row), do: repo.update(off_changeset(row)), else: {:error, :already_off}
    end)
    |> Events.log(:event, "schedule.switched_off", {:user, user.id}, fn %{off: row} ->
      %{project_id: project.id, payload: payload(row, %{})}
    end)
    |> Repo.transaction()
    |> finish(project)
  end

  @doc """
  Dismisses a schedule's queue item: any member may, and the dismissal is recorded with who. The
  problem stays on the schedule, on the Workflow view; only the item goes.
  `{:error, :no_alert}` when there is none open.
  """
  @spec dismiss(Project.t(), Events.actor(), String.t() | nil, String.t()) ::
          {:ok, Schedule.t()} | {:error, term()}
  def dismiss(%Project{} = project, actor, type, name) do
    Multi.new()
    |> Multi.run(:row, fn _repo, _ -> lock_existing(project, type, name, :no_alert) end)
    |> Multi.run(:dismissed, fn repo, %{row: row} ->
      if row.alerted_at,
        do: row |> Ecto.Changeset.change(%{alerted_at: nil}) |> repo.update(),
        else: {:error, :no_alert}
    end)
    |> Events.log(:event, "schedule.dismissed", actor, fn %{dismissed: row} ->
      %{project_id: project.id, payload: payload(row, %{})}
    end)
    |> Repo.transaction()
    |> finish(project)
  end

  defp finish({:ok, %{on: row}}, project), do: announce(row, project)
  defp finish({:ok, %{off: row}}, project), do: announce(row, project)
  defp finish({:ok, %{dismissed: row}}, project), do: announce(row, project)
  defp finish({:error, _step, reason, _changes}, _project), do: {:error, reason}

  defp announce(row, project) do
    Events.notify_schedules(project.id)
    {:ok, Repo.preload(row, [:enabled_by, :last_ticket], force: true)}
  end

  defp off_changeset(row) do
    Ecto.Changeset.change(row, %{
      enabled_by_id: nil,
      enabled_at: nil,
      fires_after: nil,
      problem: nil,
      problem_kind: nil,
      problem_at: nil,
      alerted_at: nil
    })
  end

  defp payload(%Schedule{} = row, extra) do
    Map.merge(
      %{"schedule_id" => row.id, "name" => row.name, "ticket_type" => row.ticket_type},
      extra
    )
  end

  # The schedule as the file declares it at the default branch's head, or why it cannot be read.
  defp declared_schedule(project, type, name) do
    case read_types(project) do
      {:ok, _head, %{types: types}} ->
        case Enum.find(types, &(&1.name == type)) do
          nil -> {:error, :schedule_gone}
          %{workflow: {:error, _}} -> {:error, :schedule_unreadable}
          %{workflow: {:ok, wf}} -> find_declared(wf, name)
        end

      {:error, _reason} ->
        {:error, :schedule_unreadable}
    end
  end

  defp find_declared(%Workflow{schedules: schedules}, name) do
    case Enum.find(schedules, &(&1.name == name)) do
      nil -> {:error, :schedule_gone}
      schedule -> {:ok, schedule}
    end
  end

  # The row locked for the rest of the transaction, made if it is not there. The insert does
  # nothing when it is, so two admins switching on at once serialise on the row and the second
  # finds it on.
  defp lock_or_create(project, type, name) do
    Repo.insert_all(
      Schedule,
      [
        %{
          id: Ecto.UUID.generate(),
          project_id: project.id,
          ticket_type: type,
          name: name,
          inserted_at: DateTime.utc_now(:second),
          updated_at: DateTime.utc_now(:second)
        }
      ],
      on_conflict: :nothing
    )

    lock_existing(project, type, name, :already_on)
  end

  # `FOR UPDATE` here too: serialises two admins switching one schedule, which the suite's single
  # connection per test cannot interleave, so dropping it is an equivalent mutant.
  defp lock_existing(project, type, name, missing) do
    row =
      Repo.one(
        from s in Schedule,
          where: s.project_id == ^project.id and s.name == ^name,
          where: ^type_is(type),
          lock: "FOR UPDATE"
      )

    if row, do: {:ok, row}, else: {:error, missing}
  end

  # -- reading the repository ---------------------------------------------------------------

  @doc """
  The project's workflow files at its default branch's head, as `Forge.Tickets.types/2` reads
  them, with the head — or why there are none to read.

  Read again only when the head moves, when the runner has made its cache (`Forge.Schedules.Runner`):
  a project's files are parsed once per commit and not once per tick.
  """
  @spec read_types(Project.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def read_types(%Project{} = project) do
    repo = Projects.repo_path(project)

    with {:ok, head} <- Forge.Git.resolve(repo, project.default_branch) do
      case cached(project.id, head) do
        {:ok, types} -> {:ok, head, types}
        :miss -> read_fresh(project, head)
      end
    end
  end

  defp read_fresh(project, head) do
    with {:ok, types} <- Tickets.types(project, at: head) do
      cache(project.id, head, types)
      {:ok, head, types}
    end
  end

  @doc "Makes the cache `read_types/1` keeps. The runner owns it; without one, every read is fresh."
  @spec create_cache() :: :ok
  def create_cache do
    if :ets.whereis(@types_cache) == :undefined,
      do: :ets.new(@types_cache, [:named_table, :public, :set])

    :ok
  end

  defp cached(project_id, head) do
    with tid when tid != :undefined <- :ets.whereis(@types_cache),
         [{^project_id, ^head, types}] <- :ets.lookup(tid, project_id) do
      {:ok, types}
    else
      _ -> :miss
    end
  end

  defp cache(project_id, head, types) do
    if :ets.whereis(@types_cache) != :undefined,
      do: :ets.insert(@types_cache, {project_id, head, types})

    :ok
  end

  # -- firing -------------------------------------------------------------------------------

  @doc """
  One pass of the runner: every schedule of every project that has one switched on, or an alert
  open, is looked at, and each that has come due is fired.

  **A project with no such row is never read.** That is the whole of "a project with no schedules
  behaves as it does now" (`docs/design/schedules.md` § The model): nobody has switched one on, and
  the repository is not touched. Returns one `{schedule_name, what}` per schedule it acted on —
  including a firing that found, on a second look, that there was nothing to do (`:not_due`,
  `:stale`).

  `now` is a parameter so that a test drives time itself; the runner passes the clock.
  """
  @spec tick(DateTime.t(), keyword()) :: [{String.t(), term()}]
  def tick(now \\ DateTime.utc_now(), opts \\ []) do
    read = Keyword.get(opts, :read, &read_types/1)
    now = DateTime.truncate(now, :second)

    project_ids =
      Repo.all(
        from s in Schedule,
          where: not is_nil(s.enabled_by_id) or not is_nil(s.alerted_at),
          distinct: true,
          select: s.project_id
      )

    Enum.flat_map(project_ids, fn project_id ->
      try do
        project_id |> Projects.get!() |> project_tick(now, read)
      rescue
        # One project's repository, or one schedule's data, must not stop the others — nor a
        # project deleted since the ids were read.
        error ->
          Logger.error(
            "schedules of project #{project_id}: #{Exception.message(error)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          []
      end
    end)
  end

  defp project_tick(project, now, read) do
    rows =
      Repo.all(
        from s in Schedule,
          where: s.project_id == ^project.id,
          where: not is_nil(s.enabled_by_id) or not is_nil(s.alerted_at),
          order_by: [asc: s.ticket_type, asc: s.name]
      )

    # After the rows, so that what a pass decides about a row is decided on files read no earlier
    # than the row was: a row changed since is found changed under its lock (`leave/2`,
    # `lock_current/2`), not judged by an older view of it.
    layout = read.(project)

    Enum.flat_map(rows, fn row ->
      case {presence(layout, row), Schedule.on?(row)} do
        {:left, _on} ->
          leave(project, row)

        {_present, false} ->
          []

        {{:declared, schedule}, true} ->
          visit(project, row, schedule.cron, now)

        {:unreadable, true} ->
          visit(project, row, nil, now)
      end
    end)
  end

  # Where a row's schedule is in what the repository says. A layout that does not read, and a file
  # that does not parse, are *unreadable*: a failure to read is not a schedule leaving
  # (`docs/design/schedules.md` § Leaving the file). It has *left* only when the layout reads and
  # the type is not in it, or the type's file parses and does not name it. A single-file schedule
  # has left when the project has moved to types, and vice versa.
  defp presence({:ok, _head, %{types: types}}, row) do
    # The single file is the entry named nil and a type is named, so a single-file schedule meeting
    # a directory of types, and a type's schedule meeting the single file, both find no entry: that
    # is the whole of "moved from one layout to the other".
    case Enum.find(types, &(&1.name == row.ticket_type)) do
      nil -> :left
      entry -> in_file(entry.workflow, row.name)
    end
  end

  defp presence({:error, _reason}, _row), do: :unreadable

  defp in_file({:error, _}, _name), do: :unreadable

  defp in_file({:ok, %Workflow{schedules: schedules}}, name) do
    case Enum.find(schedules, &(&1.name == name)) do
      nil -> :left
      schedule -> {:declared, schedule}
    end
  end

  # Whether a schedule that is on has come due, by the cron line the file says now — or, when the
  # file cannot be read, the one it was last read with, so that it can fail when due.
  defp visit(project, row, cron_line, now) do
    with line when is_binary(line) <- cron_line || row.cron,
         {:ok, cron} <- Cron.parse(line),
         :ok <- remember_cron(row, cron_line, line),
         %DateTime{} = due <- Cron.latest_at_or_before(cron, now),
         :gt <- DateTime.compare(due, row.fires_after) do
      [{row.name, fire(project, row, due, now)}]
    else
      _not_due -> []
    end
  end

  # The line the file says is kept on the row, so that a file that stops parsing after an edit is
  # failed against the line it last said and not an older one. Only a line read from the file is
  # kept: with none, the row's own is what is being used.
  defp remember_cron(%Schedule{cron: line}, _read, line), do: :ok
  defp remember_cron(_row, nil, _line), do: :ok

  defp remember_cron(%Schedule{id: id, enabled_by_id: admin}, read, _line) do
    Repo.update_all(
      from(s in Schedule, where: s.id == ^id and s.enabled_by_id == ^admin),
      set: [cron: read]
    )

    :ok
  end

  @doc """
  Fires one schedule that `due` says is due: reads the workflow as admission does, takes the
  schedule's title and body from the definition **that admission pins**, and admits one ticket in
  the name of the admin who switched it on, moving the cursor to the due time in the same
  transaction and first in it. A second firing of the same stale row finds the cursor moved and
  writes nothing.

  Returns `{:admitted, ticket}`, `{:failed, reason}` (a failure is recorded on the schedule, the
  cursor moved, and nothing tries again before the next time), `{:switched_off, reason}` (its admin
  can no longer admit), or `:stale` / `:not_due` when there was nothing to do after all.
  """
  @spec fire(Project.t(), Schedule.t(), DateTime.t(), DateTime.t()) :: term()
  def fire(%Project{} = project, %Schedule{} = row, %DateTime{} = due, %DateTime{} = now) do
    case Tickets.prepare_admission(project, row.ticket_type) do
      {:ok, %{ticket_type: type} = prepared} when type == row.ticket_type ->
        admit(project, row, prepared, now)

      {:ok, _implied_type} ->
        # A directory of one type implies it for a ticket with none, and a single-file schedule
        # is not that type's: it has left, and the next pass will say so.
        :not_due

      {:error, reason} ->
        record_failure(project, row, due, reason)
    end
  end

  defp admit(project, row, prepared, now) do
    with {:ok, schedule} <- pinned_schedule(prepared, row),
         {:ok, cron} <- Cron.parse(schedule.cron),
         %DateTime{} = due <- Cron.latest_at_or_before(cron, now),
         :gt <- DateTime.compare(due, row.fires_after) do
      case acting_admin(project, row) do
        {:ok, admin} -> admit_as(project, row, prepared, schedule, due, admin)
        {:error, reason} -> withdraw(project, row, reason)
      end
    else
      _not_due -> :not_due
    end
  end

  # The schedule in the very definition admission read, so the title and body come from the commit
  # the ticket pins and not from a read an instant earlier. Gone from it: the file changed since
  # the pass looked, and the next pass finds it left.
  defp pinned_schedule(%{workflow: %Workflow{schedules: schedules}}, row) do
    case Enum.find(schedules, &(&1.name == row.name)) do
      nil -> :left
      schedule -> {:ok, schedule}
    end
  end

  # The same capability check the admission itself uses, and the one the switch needed, asked now
  # (`docs/design/schedules.md` § Firing, step 3): not the role as it was when the schedule was
  # switched on.
  defp acting_admin(project, %Schedule{enabled_by_id: admin_id}) do
    admin = Repo.get(User, admin_id)

    scope = admin && Scope.for_project(Scope.for_user(admin), project)

    # `:use` is what admission asks and `:manage` what the switch asked. Dropping the `:use` is an
    # equivalent mutant today — an admin holds both, and a role that holds `:manage` and not `:use`
    # does not exist — and is asked anyway, so that the check is admission's own and stays right the
    # day the two split (`Forge.Access`).
    if scope != nil and Access.can?(scope, :use) and Access.can?(scope, :manage),
      do: {:ok, admin},
      else: {:error, admin}
  end

  defp admit_as(project, row, prepared, schedule, due, admin) do
    attrs = %{
      title: "#{schedule.title} · #{due_date(due)}",
      body: schedule.body,
      schedule: %{
        "id" => row.id,
        "name" => row.name,
        "due_at" => DateTime.to_iso8601(due),
        # Who it was admitted in the name of, as the log keeps it beside the actor's id.
        "admin" => admin.email
      }
    }

    Multi.new()
    |> Multi.run(:locked, fn _repo, _ -> lock_current(row, due) end)
    |> Tickets.put_admit(prepared, project, attrs, {:user, admin.id})
    |> Multi.update(:schedule, fn %{locked: locked, ticket: ticket} ->
      Ecto.Changeset.change(locked, %{
        cron: schedule.cron,
        last_ticket_id: ticket.id,
        problem: nil,
        problem_kind: nil,
        problem_at: nil,
        alerted_at: nil
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{ticket: ticket, locked: locked}} ->
        Events.notify(ticket.id)
        if locked.alerted_at, do: Events.notify_schedules(project.id)
        {:admitted, ticket}

      {:error, :locked, :stale, _changes} ->
        :stale

      {:error, step, reason, _changes} ->
        record_failure(project, row, due, {:transaction, step, reason})
    end
  end

  # The compare-and-set that makes a firing happen at most once for a due time, including across a
  # restart: the row is locked, and it must still be on for the admin and the time the pass read.
  # The cursor moves in the same step, so whatever follows in the transaction is for a time no
  # other firing can have. The `FOR UPDATE` is what makes it hold under two firings at once; the
  # compares are tested serially, and the lock cannot be, since the suite's sandbox runs a test on
  # one connection — so dropping it is a mutation nothing here can see, kept because without it two
  # connections could both read the row before either wrote.
  defp lock_current(row, due) do
    current =
      Repo.one(
        from s in Schedule,
          where: s.id == ^row.id and s.fires_after == ^row.fires_after,
          where: s.enabled_by_id == ^row.enabled_by_id,
          lock: "FOR UPDATE"
      )

    case current do
      nil -> {:error, :stale}
      locked -> locked |> Ecto.Changeset.change(%{fires_after: due}) |> Repo.update()
    end
  end

  @doc false
  # Records a failure to admit: no ticket, the cursor moved to the due time so nothing tries again
  # before the next, the reason on the schedule, and an item in the queue unless one is open
  # already, in which case its text is updated and nobody is pushed again.
  def record_failure(project, row, due, reason) do
    text = failure_text(reason)
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.run(:locked, fn _repo, _ -> lock_current(row, due) end)
    |> Multi.run(:schedule, fn repo, %{locked: locked} ->
      locked
      |> Ecto.Changeset.change(%{
        problem: text,
        problem_kind: :failed,
        problem_at: now,
        alerted_at: locked.alerted_at || now
      })
      |> repo.update()
    end)
    |> Events.log(:event, "schedule.failed", :system, fn %{schedule: s} ->
      %{
        project_id: project.id,
        payload: payload(s, %{"due_at" => DateTime.to_iso8601(due), "reason" => text})
      }
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{schedule: schedule, locked: locked}} ->
        # Pushed once: the first failure while no item is open. A repeat updates the open item.
        if is_nil(locked.alerted_at), do: push(project, schedule)
        Events.notify_schedules(project.id)
        {:failed, text}

      {:error, :locked, :stale, _changes} ->
        :stale
    end
  end

  # `Admission.explain/1`'s words for what admission refuses, which is what a person is told by the
  # ticket form; a failure inside the admission's transaction is `{:transaction, step, reason}` and says where.
  defp failure_text({:transaction, step, reason}),
    do: "admitting it failed at #{inspect(step)}: #{inspect(reason)}"

  defp failure_text(reason), do: ForgeWeb.Operator.Admission.explain(reason)

  # Its admin can no longer admit: nothing is admitted, and the schedule switches itself off with
  # why (criterion 28).
  defp withdraw(_project, row, admin_or_nil) do
    text = reason_text(:cannot_admit, admin_or_nil)

    Multi.new()
    |> put_switched_off(row, text, :cannot_admit)
    |> Repo.transaction()
    |> case do
      {:ok, %{withdrawn_schedules: []}} ->
        :stale

      {:ok, changes} ->
        announce_withdrawn(changes)
        {:switched_off, text}
    end
  end

  # Switches off the row the pass read, in `multi`, as the platform's own act: it keeps `problem`,
  # and opens an item unless one is open. **Only if it is still switched on by the admin the pass
  # asked about**: the row is locked and compared, as `lock_current/2` does, so an admin who
  # switched it on in the instant between is not told they can no longer admit.
  defp put_switched_off(multi, %Schedule{id: id, enabled_by_id: admin_id}, text, cause) do
    # `FOR UPDATE` below: an equivalent mutant in the suite, whose sandbox runs a test on one connection so
    # no two writers can interleave; the compare beside it is what the tests defend (see `lock_current/2`).
    Multi.run(multi, :withdrawn_schedules, fn repo, _changes ->
      rows =
        repo.all(
          from s in Schedule,
            where: s.id == ^id and s.enabled_by_id == ^admin_id,
            lock: "FOR UPDATE"
        )

      {:ok, withdraw_rows(repo, rows, text, cause)}
    end)
  end

  defp withdraw_rows(repo, rows, text_or_fun, cause) do
    now = DateTime.utc_now(:second)

    # `Schedule.on?/1` here is an equivalent mutant: both callers select rows by `enabled_by_id`, so
    # every row is on. It stays as the line that says what is being switched off.
    for %Schedule{} = row <- rows, Schedule.on?(row) do
      text = if is_function(text_or_fun, 1), do: text_or_fun.(row), else: text_or_fun
      who = row.enabled_by_id

      updated =
        row
        |> Ecto.Changeset.change(%{
          enabled_by_id: nil,
          enabled_at: nil,
          fires_after: nil,
          problem: text,
          problem_kind: :switched_off,
          problem_at: now,
          alerted_at: row.alerted_at || now
        })
        |> repo.update!()

      {:ok, _event} =
        Events.append("schedule.switched_off", :system, %{
          project_id: row.project_id,
          payload:
            payload(row, %{"reason" => text, "cause" => to_string(cause), "was_enabled_by" => who})
        })

      %{schedule: updated, push: is_nil(row.alerted_at)}
    end
  end

  # -- switching itself off when its admin can no longer act --------------------------------

  @doc """
  Adds to `multi` the switching off of every schedule `user` switched on — in `project`, or in all
  of them with `:all` — because they are no longer an admin of it, were removed from it, or were
  suspended (`cause`: `:demoted`, `:removed`, `:suspended`). Each is recorded with why and goes to
  the queue of the project's members as a `switched_off` alert. Another admin's schedules are not
  touched.

  Done in the same transaction as the change of role, so no ticket is admitted in the name of
  someone who could not admit it; and `fire/4` asks again at the moment, for a role changed some
  other way. The step's result is `announce_withdrawn/1`'s input, to be called after the commit.
  """
  @spec put_withdrawn(Multi.t(), Project.t() | :all, User.t(), atom()) :: Multi.t()
  def put_withdrawn(multi, scope, %User{} = user, cause) do
    # `FOR UPDATE` below: an equivalent mutant in the suite, whose sandbox runs a test on one connection so
    # no two writers can interleave; the compare beside it is what the tests defend (see `lock_current/2`).
    Multi.run(multi, :withdrawn_schedules, fn repo, _changes ->
      rows =
        repo.all(
          from s in Schedule,
            where: s.enabled_by_id == ^user.id,
            where: ^in_scope(scope),
            lock: "FOR UPDATE"
        )

      {:ok, withdraw_rows(repo, rows, reason_text(cause, user), cause)}
    end)
  end

  defp same_admin(nil), do: Ecto.Query.dynamic([s], is_nil(s.enabled_by_id))
  defp same_admin(id), do: Ecto.Query.dynamic([s], s.enabled_by_id == ^id)

  defp in_scope(:all), do: Ecto.Query.dynamic(true)
  defp in_scope(%Project{id: id}), do: Ecto.Query.dynamic([s], s.project_id == ^id)

  defp reason_text(:demoted, user),
    do: "#{who(user)} is no longer an admin of this project, so nothing is admitted in their name"

  defp reason_text(:removed, user),
    do: "#{who(user)} was removed from this project, so nothing is admitted in their name"

  defp reason_text(:suspended, user),
    do: "#{who(user)} was suspended, so nothing is admitted in their name"

  defp reason_text(:cannot_admit, user),
    do:
      "#{who(user)} can no longer admit tickets on this project, so nothing is admitted in their name"

  defp who(%User{email: email}), do: email
  defp who(nil), do: "the admin who switched it on"

  @doc """
  After the commit of a transaction that held `put_withdrawn/4`: pushes each newly opened alert to
  the phones of the project's members and tells the pages and queues drawing them.
  """
  @spec announce_withdrawn(map()) :: :ok
  def announce_withdrawn(changes) do
    for %{schedule: schedule, push: pushed} <- Map.get(changes, :withdrawn_schedules, []) do
      if pushed, do: push(Projects.get!(schedule.project_id), schedule)
      Events.notify_schedules(schedule.project_id)
    end

    :ok
  end

  # -- leaving the file ---------------------------------------------------------------------

  # The schedule has left its file (or the file its type): switched off for good, its problem and
  # its item cleared, no item made — a schedule that is gone has nothing to be fixed
  # (`docs/design/schedules.md` § Leaving the file).
  defp leave(project, row) do
    Multi.new()
    |> Multi.run(:row, fn repo, _ ->
      # Locked and compared with who had it on when the pass read it: one an admin switched on in the
      # meantime is theirs, and the next pass will say whether it has left. The `FOR UPDATE` is an
      # equivalent mutant in the suite (one connection per test, see `lock_current/2`); the compare,
      # for a row read on and for one read off, is what the tests defend.
      {:ok,
       repo.one(
         from s in Schedule,
           where: s.id == ^row.id,
           where: ^same_admin(row.enabled_by_id),
           lock: "FOR UPDATE"
       )}
    end)
    |> Multi.run(:left, fn repo, %{row: locked} ->
      if locked && (Schedule.on?(locked) or locked.alerted_at) do
        repo.update(off_changeset(locked))
      else
        {:ok, nil}
      end
    end)
    |> Multi.run(:event, fn _repo, %{row: locked, left: left} ->
      if left && Schedule.on?(locked) do
        Events.append("schedule.switched_off", :system, %{
          project_id: project.id,
          payload:
            payload(locked, %{
              "reason" => "it is no longer in its file",
              "cause" => "left",
              "was_enabled_by" => locked.enabled_by_id
            })
        })
      else
        {:ok, nil}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{left: nil}} ->
        []

      {:ok, %{left: _left}} ->
        Events.notify_schedules(project.id)
        [{row.name, :left}]
    end
  end

  # -- the queue ----------------------------------------------------------------------------

  @doc """
  The queue items for schedules with an open alert, in `project_ids` — or every project's when
  nil (`Forge.Queue.items/0`). One per schedule: a repeat failure updated the item it found.
  """
  @spec items([String.t()] | nil) :: [map()]
  def items(project_ids) do
    Repo.all(
      from s in Schedule,
        where: not is_nil(s.alerted_at),
        where: ^project_scope(project_ids),
        order_by: [asc: s.alerted_at, asc: s.id]
    )
    |> Enum.map(&item/1)
  end

  defp project_scope(nil), do: Ecto.Query.dynamic(true)
  defp project_scope(ids), do: Ecto.Query.dynamic([s], s.project_id in ^ids)

  @doc "A schedule's alert as a `Forge.Queue` item: no ticket, and what happened and why in `detail`."
  @spec item(Schedule.t()) :: map()
  def item(%Schedule{} = s) do
    %{
      kind: :schedule,
      ticket: nil,
      project: Projects.get!(s.project_id),
      since: s.alerted_at,
      question: nil,
      detail: %{
        id: s.id,
        ticket_type: s.ticket_type,
        name: s.name,
        problem_kind: s.problem_kind,
        reason: s.problem
      }
    }
  end

  defp push(_project, schedule), do: Push.waiting(item(schedule))
end
