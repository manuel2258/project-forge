defmodule Forge.UsageMigrationTest do
  @moduledoc """
  What `UsageInWeightedTokens` does to a node that is already running: every past dollar figure
  becomes weighted tokens at 200,000 to the dollar, once, and is marked as converted
  (`docs/design/capacity.md` § Usage in weighted tokens). Checked against a database rolled back to
  before it, filled the way an old node's would be, and migrated forward — the pattern
  `Forge.JobRunsBackfillTest` set, outside the sandbox for the same reason (`Forge.Migrations`).

  Not covered: the `tickets` columns, which the migration converts by the same loop as `jobs`'.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Migrations, Release, Repo}

  @version 20_261_101_100_000
  @monday ~U[2026-03-02 10:00:00Z]

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    {:ok, agent} = Agent.start(fn -> %{} end)
    Process.put(:written, agent)

    on_exit(fn ->
      written = Agent.get(agent, & &1)
      Agent.stop(agent)

      Migrations.forget(@version)
      Release.migrate()

      for table <- ~w(jobs credentials projects users) do
        Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [Map.get(written, table, [])])
      end

      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp insert(table, sql, params) do
    id = Ecto.UUID.generate()

    Agent.update(
      Process.get(:written),
      &Map.update(&1, table, [dump(id)], fn l -> [dump(id) | l] end)
    )

    Repo.query!(sql, [dump(id) | params])
    id
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp user do
    insert(
      "users",
      "INSERT INTO users (id, email, approved_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, NOW(), NOW(), NOW())",
      ["u#{System.unique_integer([:positive])}@example.com"]
    )
  end

  defp project do
    insert(
      "projects",
      "INSERT INTO projects (id, name, repo_path, inserted_at, updated_at) " <>
        "VALUES ($1, $2, '/nowhere.git', NOW(), NOW())",
      ["p#{System.unique_integer([:positive])}"]
    )
  end

  defp credential(owner, limit) do
    insert(
      "credentials",
      "INSERT INTO credentials (id, user_id, name, harness, kind, daily_limit_usd, revoked_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, 'claude_code', 'oauth', $4, NOW(), NOW(), NOW())",
      [dump(owner), "c#{System.unique_integer([:positive])}", limit && Decimal.new(limit)]
    )
  end

  defp job(project, cost, exhausted) do
    insert(
      "jobs",
      "INSERT INTO jobs (id, project_id, kind, status, attempt, cost_usd, exhausted, started_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, 'chat', 'finished', 1, $3, $4, $5, NOW(), NOW())",
      [dump(project), Decimal.new(cost), exhausted, @monday]
    )
  end

  defp run(job, cost) do
    Repo.query!(
      "INSERT INTO job_runs (id, job_id, started_at, cost_usd, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, $4, NOW(), NOW())",
      [Ecto.UUID.bingenerate(), dump(job), @monday, Decimal.new(cost)]
    )
  end

  defp one(sql, id) do
    %{rows: [row]} = Repo.query!(sql, [dump(id)])
    row
  end

  test "every dollar figure is converted at 200,000 to the dollar, and the row says so" do
    project = project()
    owner = user()
    limited = credential(owner, "5")
    unlimited = credential(owner, nil)
    spent = job(project, "1.5", "cost")
    idle = job(project, "0", nil)
    run(spent, "1.5")
    run(spent, "0.25")

    Migrations.up_to(@version)

    assert one("SELECT usage, usage_converted FROM jobs WHERE id = $1", spent) == [300_000, true]
    # Nothing was spent, so nothing was converted.
    assert one("SELECT usage, usage_converted FROM jobs WHERE id = $1", idle) == [0, false]

    # `cost` was the dollar ceiling; it is the token ceiling now.
    assert one("SELECT exhausted FROM jobs WHERE id = $1", spent) == ["tokens"]

    %{rows: runs} =
      Repo.query!(
        "SELECT usage, claude_cost_usd, converted, tokens FROM job_runs WHERE job_id = $1 ORDER BY usage",
        [dump(spent)]
      )

    assert [[50_000, d1, true, nil], [300_000, d2, true, nil]] = runs
    assert Decimal.equal?(d1, Decimal.new("0.25"))
    assert Decimal.equal?(d2, Decimal.new("1.5"))

    assert one("SELECT daily_limit FROM credentials WHERE id = $1", limited) == [1_000_000]
    assert one("SELECT daily_limit FROM credentials WHERE id = $1", unlimited) == [nil]
  end
end
