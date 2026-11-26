defmodule Forge.JobTimeoutsMigrationTest do
  @moduledoc """
  What `JobTimeouts` does to a node that is already running (`docs/design/workflow-grammar-v1.md`
  § Timeout): every stored `wall_clock` becomes `timeout`, on jobs and on extensions, and every
  extension is given the hour its run was actually allowed. Checked against a database rolled back
  to before it, filled the way an old node's would be, and migrated forward — the pattern
  `Forge.JobRunsBackfillTest` set, with the same reason for running outside the sandbox
  (`Forge.Migrations`).
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Migrations, Release, Repo}

  @version 20_261_125_100_000

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

      # Children first. An extension is insert-only, so the trigger is lifted to take them away.
      Repo.query!("ALTER TABLE job_extensions DISABLE TRIGGER job_extensions_append_only")

      try do
        for table <- ~w(job_extensions jobs tickets projects users) do
          Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [Map.get(written, table, [])])
        end
      after
        Repo.query!("ALTER TABLE job_extensions ENABLE TRIGGER job_extensions_append_only")
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

  defp ticket(project) do
    insert(
      "tickets",
      "INSERT INTO tickets (id, project_id, number, title, base_commit, branch, workflow, " <>
        "workflow_commit, state, status, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, 't', 'abc', 'ticket/1', '{}', 'abc', 'implementing', 'stuck', " <>
        "NOW(), NOW())",
      [dump(project), System.unique_integer([:positive])]
    )
  end

  defp job(project, ticket, attempt, exhausted) do
    insert(
      "jobs",
      "INSERT INTO jobs (id, project_id, ticket_id, kind, state, attempt, spec, status, outcome, " <>
        "exhausted, inserted_at, updated_at) VALUES ($1, $2, $3, 'workflow', 'implementing', $4, " <>
        "'{}', 'finished', 'budget_exhausted', $5, NOW(), NOW())",
      [dump(project), dump(ticket), attempt, exhausted]
    )
  end

  defp extension(job, ticket, user, exhausted) do
    insert(
      "job_extensions",
      "INSERT INTO job_extensions (id, job_id, ticket_id, user_id, tokens, exhausted, inserted_at) " <>
        "VALUES ($1, $2, $3, $4, 1000000, $5, NOW())",
      [dump(job), dump(ticket), dump(user), exhausted]
    )
  end

  defp column(table, column, id) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump(id)])

    value
  end

  test "wall_clock is timeout on jobs and extensions, nothing else moves, and each extension " <>
         "records the hour it was run on" do
    project = project()
    ticket = ticket(project)
    user = user()

    clock = job(project, ticket, 1, "wall_clock")
    turns = job(project, ticket, 2, "turns")
    tokens = job(project, ticket, 3, "tokens")

    clock_extension = extension(clock, ticket, user, "wall_clock")
    tokens_extension = extension(tokens, ticket, user, "tokens")

    Migrations.up_to(@version)

    assert column("jobs", "exhausted", clock) == "timeout"
    assert column("jobs", "exhausted", turns) == "turns"
    assert column("jobs", "exhausted", tokens) == "tokens"

    assert column("job_extensions", "exhausted", clock_extension) == "timeout"
    assert column("job_extensions", "exhausted", tokens_extension) == "tokens"

    # The hour the node's configuration was the only place to set: what those runs were allowed.
    assert column("job_extensions", "timeout_ms", clock_extension) == 3_600_000
    assert column("job_extensions", "timeout_ms", tokens_extension) == 3_600_000
  end

  test "the extensions table is insert-only again, and a new one must say its time" do
    project = project()
    ticket = ticket(project)
    user = user()
    job = job(project, ticket, 1, "tokens")
    existing = extension(job, ticket, user, "tokens")

    Migrations.up_to(@version)

    # The trigger the migration lifted for its one UPDATE is back.
    assert_raise Postgrex.Error, ~r/append-only/, fn ->
      Repo.query!("UPDATE job_extensions SET note = 'x' WHERE id = $1", [dump(existing)])
    end

    # No default stays: an insert that forgets the figure fails, and does not record an hour nobody
    # was given.
    assert_raise Postgrex.Error, ~r/timeout_ms/, fn ->
      extension(job, ticket, user, "tokens")
    end

    assert_raise Postgrex.Error, ~r/job_extensions_timeout_positive/, fn ->
      Repo.query!(
        "INSERT INTO job_extensions (id, job_id, ticket_id, user_id, tokens, timeout_ms, inserted_at) " <>
          "VALUES ($1, $2, $3, $4, 1, 0, NOW())",
        [dump(Ecto.UUID.generate()), dump(job), dump(ticket), dump(user)]
      )
    end
  end
end
