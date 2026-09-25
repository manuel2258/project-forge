defmodule Forge.JobRunsBackfillTest do
  @moduledoc """
  What `CreateJobRuns` does to a node that is already running.

  Its claim is that an upgrade changes no figure anybody has already seen: before it, spend was
  `jobs.cost_usd` summed by `jobs.started_at`, and it writes one run per started job carrying
  exactly that. Checked here against a database rolled back to before it, filled the way an old
  node's would be, and migrated forward — the pattern `Forge.WorkersBackfillTest` set, with the
  same reason for running outside the sandbox (`Forge.Migrations`).
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Credentials, Migrations, Release, Repo, Spend}

  @version 20_260_925_100_000
  @monday ~U[2026-03-02 10:00:00Z]

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    # In an agent rather than the test's own process: `on_exit/1` runs after that process is gone.
    {:ok, agent} = Agent.start(fn -> %{} end)
    Process.put(:written, agent)

    on_exit(fn ->
      written = Agent.get(agent, & &1)
      Agent.stop(agent)

      # Forward before anything is deleted, so a test that failed with the schema rolled back
      # still leaves it current for the next file.
      Migrations.forget(@version)
      Release.migrate()

      # Children first: a run goes with its job, a job holds its credential and its project.
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

  defp dump(nil), do: nil
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

  # Revoked, so it needs no secret: the database's own check allows a revoked row without one.
  defp credential(owner) do
    insert(
      "credentials",
      "INSERT INTO credentials (id, user_id, name, harness, kind, revoked_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, $3, 'claude_code', 'oauth', NOW(), NOW(), NOW())",
      [dump(owner), "c#{System.unique_integer([:positive])}"]
    )
  end

  defp job(project, attrs) do
    insert(
      "jobs",
      "INSERT INTO jobs (id, project_id, kind, status, attempt, cost_usd, started_at, finished_at, " <>
        "credential_id, inserted_at, updated_at) VALUES ($1, $2, 'chat', $3, 1, $4, $5, $6, $7, NOW(), NOW())",
      [
        dump(project),
        attrs[:status],
        Decimal.new(attrs[:cost] || "0"),
        attrs[:started_at],
        attrs[:finished_at],
        dump(attrs[:credential])
      ]
    )
  end

  defp runs(job) do
    %{rows: rows} =
      Repo.query!(
        "SELECT credential_id, started_at, cost_usd, finished_at FROM job_runs WHERE job_id = $1",
        [dump(job)]
      )

    Enum.map(rows, fn [credential, started, cost, finished] ->
      {credential && Ecto.UUID.load!(credential), started, Decimal.to_string(cost), finished}
    end)
  end

  test "one run per job that started, saying what the job said, so no figure moves" do
    project = project()
    credential = credential(user())
    finished_at = ~N[2026-03-02 11:00:00]

    finished =
      job(project,
        status: "finished",
        cost: "1.5",
        started_at: @monday,
        finished_at: finished_at,
        credential: credential
      )

    # Waiting on a question, or running: its run is still open, and its next start closes it.
    open = job(project, status: "waiting", cost: "0.7", started_at: @monday)
    never = job(project, status: "pending")

    Migrations.up_to(@version)

    assert runs(finished) == [{credential, ~N[2026-03-02 10:00:00], "1.5", finished_at}]
    assert runs(open) == [{nil, ~N[2026-03-02 10:00:00], "0.7", nil}]
    assert runs(never) == []

    # What the old queries read — `jobs.cost_usd` by `jobs.started_at` — is what the new ones do.
    assert Decimal.equal?(Spend.day_total(~D[2026-03-02]), Decimal.new("2.2"))

    assert Credentials.spent_today([credential], ~D[2026-03-02]) == %{
             credential => Decimal.new("1.5")
           }
  end
end
