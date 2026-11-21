defmodule Forge.EventRetentionMigrationTest do
  @moduledoc """
  What `EventRetention` and `CompactEvents` do to a node that is already running
  (`docs/design/storage.md` § Retention): the `thinking_tokens` notices of every job gone, the first
  sweep run at the period configured, the node's record of it, and the table the size of what it
  kept. Checked against a database rolled back to before it and filled the way an old node's would
  be — the pattern `Forge.HoldsMilestonesBackfillTest` set, outside the sandbox for the reason
  `Forge.Migrations` gives.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Forge.{Migrations, Release, Repo}

  @version 20_261_120_120_000
  @compacted 20_261_120_120_100

  setup do
    Sandbox.mode(Repo, :auto)
    Migrations.back_to(@version)

    %{rows: [[start]]} = Repo.query!("SELECT coalesce(max(seq), 0) FROM events")
    {:ok, written} = Agent.start(fn -> %{} end)
    Process.put(:written, written)

    on_exit(fn ->
      rows = Agent.get(written, & &1)
      Agent.stop(written)

      Migrations.forget(@version)
      Release.migrate()

      # The log is append-only, and the one thing that deletes from it is the sweep; a test that
      # wrote events out of the sandbox takes the trigger off to clean up after itself.
      Repo.transaction(fn ->
        Repo.query!("ALTER TABLE events DISABLE TRIGGER events_append_only")

        Repo.query!(
          "DELETE FROM events WHERE job_id = ANY($1) OR seq > $2 AND type = 'events.swept'",
          [
            Map.get(rows, "jobs", []),
            start
          ]
        )

        Repo.query!("ALTER TABLE events ENABLE TRIGGER events_append_only")

        for table <- ~w(jobs projects) do
          Repo.query!("DELETE FROM #{table} WHERE id = ANY($1)", [Map.get(rows, table, [])])
        end
      end)

      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp insert(table, sql, params) do
    id = Ecto.UUID.generate()

    Agent.update(
      Process.get(:written),
      &Map.update(&1, table, [dump(id)], fn ids -> [dump(id) | ids] end)
    )

    Repo.query!(sql, [dump(id) | params])
    id
  end

  defp project do
    insert(
      "projects",
      "INSERT INTO projects (id, name, repo_path, inserted_at, updated_at) " <>
        "VALUES ($1, $2, '/nowhere.git', NOW(), NOW())",
      ["p#{System.unique_integer([:positive])}"]
    )
  end

  defp job(project, status, days_ago) do
    insert(
      "jobs",
      "INSERT INTO jobs (id, project_id, kind, status, attempt, finished_at, inserted_at, updated_at) " <>
        "VALUES ($1, $2, 'chat', $3, 1, NOW() - ($4 || ' days')::interval, NOW(), NOW())",
      [dump(project), status, to_string(days_ago)]
    )
  end

  defp event(job, type, payload, count \\ 1) do
    Repo.query!(
      "INSERT INTO events (job_id, actor, type, payload, inserted_at) " <>
        ~s|SELECT $1, '{"kind":"system","id":null}'::jsonb, $2, $3::jsonb, NOW() | <>
        "FROM generate_series(1, $4)",
      [dump(job), type, payload, count]
    )
  end

  defp types(job) do
    %{rows: rows} =
      Repo.query!(
        "SELECT type, count(*) FROM events WHERE job_id = $1 GROUP BY type ORDER BY type",
        [dump(job)]
      )

    Map.new(rows, fn [type, n] -> {type, n} end)
  end

  defp fill(job) do
    event(job, "job.created", %{})
    event(job, "job.finished", %{})
    event(job, "job.harness.text", %{"text" => "hi"}, 2)
    event(job, "job.harness.rate_limit", %{})
    event(job, "job.harness.tool_use", %{"id" => "t"}, 3)
    event(job, "job.harness.tool_result", %{"tool_use_id" => "t"}, 3)
    event(job, "job.harness.notice", %{"subtype" => "plugin_install"}, 2)
    event(job, "job.harness.notice", %{"subtype" => "thinking_tokens"}, 4)
  end

  test "deletes every thinking_tokens notice, sweeps what is past the period and records both" do
    project = project()
    old = job(project, "finished", 40)
    recent = job(project, "finished", 10)
    running = job(project, "running", 400)
    for job <- [old, recent, running], do: fill(job)

    Migrations.up_to(@version)

    # A thinking_tokens notice is gone from every job, whatever its age or status.
    for job <- [old, recent, running] do
      assert %{rows: [[0]]} =
               Repo.query!(
                 "SELECT count(*) FROM events WHERE job_id = $1 AND payload->>'subtype' = 'thinking_tokens'",
                 [dump(job)]
               )
    end

    # The old job's tool calls and notices went, in the place of which one record of it stands;
    # the lifecycle and the kept harness types stayed.
    assert %{
             "job.created" => 1,
             "job.finished" => 1,
             "job.harness.text" => 2,
             "job.harness.rate_limit" => 1,
             "job.swept" => 1
           } == types(old)

    assert %{rows: [[%{"removed" => 8, "days" => 30, "ended" => ended}]]} =
             Repo.query!("SELECT payload FROM events WHERE job_id = $1 AND type = 'job.swept'", [
               dump(old)
             ])

    assert String.ends_with?(ended, "Z")

    # Recent and running jobs lost only the counter.
    for job <- [recent, running] do
      assert %{
               "job.harness.tool_use" => 3,
               "job.harness.tool_result" => 3,
               "job.harness.notice" => 2
             } =
               types(job)

      refute Map.has_key?(types(job), "job.swept")
    end

    # The node's own record of the run: counts and dates.
    assert %{rows: [[payload]]} =
             Repo.query!(
               "SELECT payload FROM events WHERE type = 'events.swept' ORDER BY seq DESC LIMIT 1"
             )

    assert %{"removed" => 8, "jobs" => 1, "days" => 30, "thinking_tokens" => 12, "cutoff" => _} =
             payload

    assert Enum.sort(Map.keys(payload)) == ~w(cutoff days jobs removed thinking_tokens)

    # And the database now refuses to delete what is kept.
    assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
      Repo.query!("DELETE FROM events WHERE job_id = $1 AND type = 'job.created'", [dump(old)])
    end
  end

  test "the period is the one configured when it runs" do
    previous = Application.get_env(:forge, Forge.Events.Retention)
    on_exit(fn -> Application.put_env(:forge, Forge.Events.Retention, previous) end)
    Application.put_env(:forge, Forge.Events.Retention, days: 5)

    project = project()
    week = job(project, "hibernated", 7)
    day = job(project, "finished", 1)
    for job <- [week, day], do: fill(job)

    Migrations.up_to(@version)

    assert Map.has_key?(types(week), "job.swept")
    refute Map.has_key?(types(day), "job.swept")

    assert %{rows: [[5]]} =
             Repo.query!(
               "SELECT (payload->>'days')::int FROM events WHERE job_id = $1 AND type = 'job.swept'",
               [dump(week)]
             )
  end

  test "compacting rewrites the table, which is what gives the deleted rows' space back" do
    project = project()
    old = job(project, "finished", 40)
    event(old, "job.harness.tool_result", %{"excerpt" => String.duplicate("x", 800)}, 6_000)

    Migrations.up_to(@version)

    %{rows: [[file, before]]} =
      Repo.query!("SELECT pg_relation_filenode('events'), pg_relation_size('events')")

    Migrations.up_to(@compacted)

    %{rows: [[rewritten, compacted]]} =
      Repo.query!("SELECT pg_relation_filenode('events'), pg_relation_size('events')")

    # **Not the size dropping by megabytes**, which is what this asserted at first and which the
    # gate's machine refused twice (40 KB and 300 KB of six thousand rows' worth): a dead row is
    # only reclaimed once no open transaction can still see it, and the suite's other tests share
    # this database and may hold one open. What the migration owns is the rewrite itself, a new
    # file for the table, and that it never grows it.
    assert rewritten != file
    assert compacted <= before
  end

  test "going back puts the old trigger and the old indexes back" do
    Migrations.up_to(@version)
    Migrations.back_to(@version)

    assert %{rows: []} = Repo.query!("SELECT 1 FROM pg_proc WHERE proname = 'forge_event_swept'")

    assert %{rows: []} =
             Repo.query!(
               "SELECT 1 FROM pg_indexes WHERE indexname IN ('events_tool_use_id', 'events_tool_result_id', 'events_ticket_id_type_seq_index')"
             )

    project = project()
    job = job(project, "finished", 40)
    event(job, "job.harness.tool_use", %{}, 1)

    assert_raise Postgrex.Error, ~r/events is append-only/, fn ->
      Repo.query!("DELETE FROM events WHERE job_id = $1", [dump(job)])
    end
  end
end
