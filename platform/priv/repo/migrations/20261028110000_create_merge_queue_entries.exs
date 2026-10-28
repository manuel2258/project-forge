defmodule Forge.Repo.Migrations.CreateMergeQueueEntries do
  use Ecto.Migration

  def change do
    create table(:merge_queue_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :ticket_id, references(:tickets, on_delete: :delete_all, type: :binary_id), null: false
      # The order approvals were recorded in, from the database and not from a process: it is the
      # same after a restart (`docs/design/workflow-grammar-v1.md` § The merge queue).
      add :position, :bigserial, null: false
      add :status, :string, null: false, default: "waiting"
      add :from_state, :string, null: false
      add :to_state, :string, null: false

      # The job's outcome behind the edge, if one asked for the approval; nil for a person's choice.
      add :outcome, :string
      # The edge's own outcome (`Transition.outcome/1`), always set: what picks it out again among
      # parallel edges to one target, which `outcome` cannot when a person chose.
      add :edge_outcome, :string, null: false
      add :changeset_sha, :string
      add :changeset_version, :integer
      add :commit_message_version, :integer
      # The approvals this entry recorded, for withdrawing exactly those and no others.
      add :approval_ids, {:array, :binary_id}, null: false, default: []
      add :entered_by, :map, null: false, default: %{}
      add :comment, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:merge_queue_entries, [:ticket_id])
    create index(:merge_queue_entries, [:project_id, :position])

    # The guard on "one merge at a time in a project": a second claim is refused by the database.
    create unique_index(:merge_queue_entries, [:project_id],
             where: "status = 'merging'",
             name: :merge_queue_entries_one_merging_per_project
           )

    # A withdrawn approval is kept, not deleted, and not ordered against a later one by a clock.
    alter table(:approvals) do
      add :withdrawn_at, :utc_datetime_usec
    end
  end
end
