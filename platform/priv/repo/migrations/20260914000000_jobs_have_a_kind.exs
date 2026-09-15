defmodule Forge.Repo.Migrations.JobsHaveAKind do
  @moduledoc """
  A conversation is a job with a kind — `docs/design/conversations.md` § Shape.

  Everything a `:workflow` row has stays required *for a workflow row*; what changes is that the
  column can no longer say so on its own, because a `:chat` row has a project and no ticket, no
  state and no spec. The CHECK constraint is what keeps the two shapes honest in the one place
  neither application code nor a changeset can be bypassed.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :kind, :string, null: false, default: "workflow"
      add :project_id, references(:projects, on_delete: :restrict, type: :binary_id)
    end

    # Every existing row is a workflow job, and reaches its project through its ticket — which
    # is exactly why a chat needed a column of its own.
    execute """
    UPDATE jobs SET project_id = tickets.project_id
      FROM tickets WHERE jobs.ticket_id = tickets.id
    """

    alter table(:jobs) do
      modify :ticket_id, :binary_id, null: true, from: {:binary_id, null: false}
      modify :state, :string, null: true, from: {:string, null: false}
      modify :spec, :map, null: true, from: {:map, null: false}
      modify :project_id, :binary_id, null: false, from: {:binary_id, null: true}
    end

    create constraint(:jobs, :jobs_kind_shape,
             check: """
             (kind = 'workflow' AND ticket_id IS NOT NULL AND state IS NOT NULL AND spec IS NOT NULL)
             OR
             (kind = 'chat' AND state IS NULL AND spec IS NULL)
             """
           )

    # The unique index was `(ticket_id, state, attempt)`, which constrains nothing once any of
    # them can be null: Postgres treats NULLs as distinct, so every chat row would satisfy it.
    # It becomes partial, over the rows it was always about.
    drop unique_index(:jobs, [:ticket_id, :state, :attempt])

    create unique_index(:jobs, [:ticket_id, :state, :attempt],
             where: "kind = 'workflow'",
             name: :jobs_ticket_id_state_attempt_index
           )

    create index(:jobs, [:project_id])
    create index(:jobs, [:kind, :status])
  end

  def down do
    drop constraint(:jobs, :jobs_kind_shape)
    drop index(:jobs, [:kind, :status])
    drop index(:jobs, [:project_id])
    drop unique_index(:jobs, [:ticket_id, :state, :attempt])

    execute "DELETE FROM jobs WHERE kind = 'chat'"

    alter table(:jobs) do
      modify :ticket_id, :binary_id, null: false, from: {:binary_id, null: true}
      modify :state, :string, null: false, from: {:string, null: true}
      modify :spec, :map, null: false, from: {:map, null: true}
      remove :project_id
      remove :kind
    end

    create unique_index(:jobs, [:ticket_id, :state, :attempt])
  end
end
