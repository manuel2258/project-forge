defmodule Forge.Repo.Migrations.EventRetention do
  use Ecto.Migration

  # `docs/design/storage.md` § Retention. The log stays append-only but for the harness's own
  # stream, and the one thing that says which types may go is `forge_event_swept/1`: the trigger
  # asks it, and so does the sweep (`Forge.Events.Retention`), so the two cannot hold two lists.
  #
  # **No application module is called from here**, as in no other migration: the one-off delete and
  # the first sweep are SQL, reading only the retention period from configuration.

  @swept_function """
  CREATE OR REPLACE FUNCTION forge_event_swept(type text) RETURNS boolean AS $$
    SELECT starts_with(type, 'job.harness.')
       AND type NOT IN (
         'job.harness.text',
         'job.harness.delivered',
         'job.harness.started',
         'job.harness.finished',
         'job.harness.rate_limit',
         'job.harness.memory'
       );
  $$ LANGUAGE sql IMMUTABLE;
  """

  @trigger_function """
  CREATE OR REPLACE FUNCTION forge_events_append_only() RETURNS trigger AS $$
  BEGIN
    IF TG_OP = 'DELETE' AND forge_event_swept(OLD.type) THEN
      RETURN OLD;
    END IF;

    RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
  END;
  $$ LANGUAGE plpgsql;
  """

  # A job that has ended and aged past the cut-off, with its swept rows gone and one `job.swept`
  # written in its place, and the totals back. The same selection as `Forge.Events.Retention`.
  @first_sweep """
  WITH due AS (
    SELECT j.id, j.ticket_id, j.project_id, j.finished_at
      FROM jobs j
     WHERE j.status IN ('finished', 'hibernated')
       AND j.finished_at < $1
       AND EXISTS (SELECT 1 FROM events e WHERE e.job_id = j.id AND forge_event_swept(e.type))
  ), gone AS (
    DELETE FROM events e USING due
     WHERE e.job_id = due.id AND forge_event_swept(e.type)
    RETURNING e.job_id
  ), per_job AS (
    SELECT job_id, count(*) AS removed FROM gone GROUP BY job_id
  ), noted AS (
    INSERT INTO events (ticket_id, job_id, project_id, actor, type, payload, inserted_at)
    SELECT due.ticket_id, due.id, due.project_id,
           '{"kind":"system","id":null}'::jsonb, 'job.swept',
           jsonb_build_object(
             'removed', per_job.removed,
             'days', $2::integer,
             'ended', to_char(due.finished_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
           ),
           now() AT TIME ZONE 'utc'
      FROM due JOIN per_job ON per_job.job_id = due.id
    RETURNING 1
  )
  SELECT coalesce(sum(removed), 0)::bigint, count(*)::bigint FROM per_job
  """

  def up do
    execute @swept_function
    execute @trigger_function
    execute "DROP TRIGGER events_append_only ON events"

    execute """
    CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION forge_events_append_only();
    """

    flush()

    days = Application.get_env(:forge, Forge.Events.Retention, [])[:days] || 30
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.to_naive()

    %{rows: [[thinking]]} =
      repo().query!("""
      WITH gone AS (
        DELETE FROM events
         WHERE type = 'job.harness.notice' AND payload->>'subtype' = 'thinking_tokens'
        RETURNING 1
      ) SELECT count(*) FROM gone
      """)

    %{rows: [[removed, jobs]]} = repo().query!(@first_sweep, [cutoff, days])

    repo().query!(
      """
      INSERT INTO events (actor, type, payload, inserted_at)
      VALUES ('{"kind":"system","id":null}'::jsonb, 'events.swept',
              jsonb_build_object(
                'removed', $1::bigint, 'jobs', $2::bigint, 'thinking_tokens', $3::bigint,
                'days', $4::integer,
                'cutoff', to_char($5::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
              ),
              now() AT TIME ZONE 'utc')
      """,
      [removed, jobs, thinking, days, cutoff]
    )

    # What the pages read by: a type of one ticket or one job, newest first, and the two that pair
    # a call with its result. The pairing ones are partial because tool rows are what is swept,
    # so they stay small.
    create index(:events, [:ticket_id, :type, :seq])
    create index(:events, [:job_id, :type, :seq])

    create index(:events, [:job_id, "(payload->>'id')"],
             where: "type = 'job.harness.tool_use'",
             name: :events_tool_use_id
           )

    create index(:events, [:job_id, "(payload->>'tool_use_id')"],
             where: "type = 'job.harness.tool_result'",
             name: :events_tool_result_id
           )
  end

  # Deleted rows stay deleted: there is nothing to put back.
  def down do
    drop index(:events, [:job_id, "(payload->>'tool_use_id')"], name: :events_tool_result_id)
    drop index(:events, [:job_id, "(payload->>'id')"], name: :events_tool_use_id)
    drop index(:events, [:job_id, :type, :seq])
    drop index(:events, [:ticket_id, :type, :seq])

    execute "DROP TRIGGER events_append_only ON events"

    execute """
    CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """

    execute "DROP FUNCTION forge_events_append_only()"
    execute "DROP FUNCTION forge_event_swept(text)"
  end
end
