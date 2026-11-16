defmodule Forge.HoldsMilestonesBackfillTest do
  @moduledoc """
  What `HoldsAndMilestones` does to a node that is already running.

  Its claim is that nothing existing changes meaning: every ticket is in no milestone, ordered by
  its number, and not on hold, so a node that never holds a ticket behaves as before. Checked
  against a database rolled back to before it, filled the way an old node's would be, and migrated
  forward — the pattern `Forge.QuestionOptionsBackfillTest` set, with the same reason for running
  outside the sandbox (`Forge.Migrations`). The indexes are asserted too, because the "at most one
  current milestone" and "a current milestone is open" rules are the database's.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Migrations, Release, Repo}

  @version 20_261_115_100_000

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    {:ok, written} = Agent.start(fn -> %{} end)
    Process.put(:written, written)

    on_exit(fn ->
      rows = Agent.get(written, & &1)
      Agent.stop(written)

      # Forward before anything is deleted, so a test that failed with the schema rolled back
      # still leaves it current for the next file.
      Migrations.forget(@version)
      Release.migrate()

      Repo.transaction(fn ->
        for table <- ~w(tickets projects) do
          Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [Map.get(rows, table, [])])
        end
      end)

      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp insert(table, sql, params) do
    id = Ecto.UUID.generate()

    Agent.update(
      Process.get(:written),
      &Map.update(&1, table, [dump(id)], fn ids -> [dump(id) | ids] end)
    )

    Repo.query!(sql, [dump(id) | params])
    id
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp ticket(project, number) do
    insert(
      "tickets",
      "INSERT INTO tickets (id, project_id, number, title, base_commit, branch, workflow, " <>
        "workflow_commit, state, status, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, 't', 'a', 'b', '{}', 'c', 'planning', 'done', NOW(), NOW())",
      [dump(project), number]
    )
  end

  test "an old ticket is in no milestone, not on hold, and ordered by its number" do
    project =
      insert(
        "projects",
        "INSERT INTO projects (id, name, repo_path, inserted_at, updated_at) " <>
          "VALUES ($1, $2, '/nowhere.git', NOW(), NOW())",
        ["p#{System.unique_integer([:positive])}"]
      )

    three = ticket(project, 3)
    seven = ticket(project, 7)

    Migrations.up_to(@version)

    for {id, number} <- [{three, 3}, {seven, 7}] do
      assert %{rows: [[nil, nil, nil, nil, ^number]]} =
               Repo.query!(
                 "SELECT held_at, held_transition, held_entry, milestone_id, position " <>
                   "FROM tickets WHERE id = $1",
                 [dump(id)]
               )
    end

    # One current milestone per project, and a current one is open: both the database's.
    assert %{rows: [[_]]} =
             Repo.query!(
               "SELECT 1 FROM pg_indexes WHERE indexname = 'milestones_one_current_per_project'"
             )

    assert %{rows: [[_]]} =
             Repo.query!(
               "SELECT 1 FROM pg_constraint WHERE conname = 'milestones_current_is_open'"
             )

    assert %{rows: [[_]]} =
             Repo.query!(
               "SELECT 1 FROM pg_indexes WHERE indexname = 'milestones_project_id_name_index'"
             )

    # And back: the columns and the table are gone, and the tickets are as they were.
    Migrations.back_to(@version)

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM information_schema.columns " <>
                 "WHERE table_name = 'tickets' AND column_name IN ('held_at', 'position')"
             )

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM information_schema.tables WHERE table_name = 'milestones'"
             )

    assert %{rows: [[3]]} = Repo.query!("SELECT number FROM tickets WHERE id = $1", [dump(three)])
  end
end
