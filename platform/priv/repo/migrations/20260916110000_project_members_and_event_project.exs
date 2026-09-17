defmodule Forge.Repo.Migrations.ProjectMembersAndEventProject do
  @moduledoc """
  The user-to-project edge, and the column the event log needs to be readable per project.
  See `docs/design/identity.md` § Projects and members and § Read scoping is the half that leaks.

  Two roles, not the vision's `approver | promoter | spender`: those are capability names for a
  model with more distinctions than there is evidence for, and `Forge.Access` is where they
  expand when there is. `admin` is settings, deletion and membership; `member` is everything
  else the product does.

  Every project that already exists gets every user that already exists as an admin. Before
  this migration everybody could reach everything, so anything narrower would take access away
  from someone who has it, silently, during a deploy.

  ## The event backfill and the trigger that blocks it

  `events` reaches a project only through `ticket_id` or `job_id`, both nullable, so
  `project.registered` and system events have no path at all and "events visible to me" has no
  query. Hence the column.

  Filling it is not an ordinary backfill: `events_append_only` fires `BEFORE UPDATE OR DELETE`,
  so the guarantee the table is built on refuses the statement that populates it. The trigger is
  dropped, the rows are filled, and it is put back — inside this migration's transaction, so
  there is no window in which an append-only table is not one.
  """

  use Ecto.Migration

  def up do
    create table(:project_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      # Restrict, like answers and approvals: a user who decided something is not deletable,
      # and a membership is part of how that decision was allowed to happen.
      add :user_id, references(:users, on_delete: :restrict, type: :binary_id), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_members, [:project_id, :user_id])
    create index(:project_members, [:user_id])

    execute """
    INSERT INTO project_members (id, project_id, user_id, role, inserted_at, updated_at)
    SELECT gen_random_uuid(), p.id, u.id, 'admin', NOW(), NOW()
      FROM projects p CROSS JOIN users u
    """

    alter table(:events) do
      add :project_id, references(:projects, on_delete: :restrict, type: :binary_id)
    end

    execute "DROP TRIGGER events_append_only ON events"

    execute """
    UPDATE events SET project_id = tickets.project_id
      FROM tickets WHERE events.ticket_id = tickets.id
    """

    execute """
    UPDATE events SET project_id = jobs.project_id
      FROM jobs WHERE events.project_id IS NULL AND events.job_id = jobs.id
    """

    # The cast is guarded, not just the existence check. `jobs.record_harness_event/2` stores
    # agent-shaped JSON verbatim as `payload`, so a `project_id` key that is not a UUID is
    # possible — and an unguarded `::uuid` raises 22P02, which rolls the whole migration back.
    # Postgres is also free to evaluate the cast before the EXISTS, so ordering them is no
    # defence.
    execute """
    UPDATE events SET project_id = (payload->>'project_id')::uuid
      WHERE project_id IS NULL
        AND payload->>'project_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        AND EXISTS (
          SELECT 1 FROM projects
           WHERE id::text = payload->>'project_id'
        )
    """

    execute """
    CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """

    create index(:events, [:project_id, :seq])
  end

  def down do
    drop table(:project_members)

    execute "DROP TRIGGER events_append_only ON events"

    alter table(:events) do
      remove :project_id
    end

    execute """
    CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """
  end
end
