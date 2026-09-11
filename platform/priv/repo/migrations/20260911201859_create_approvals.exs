defmodule Forge.Repo.Migrations.CreateApprovals do
  use Ecto.Migration

  def change do
    create table(:approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_version_id,
          references(:artifact_versions, on_delete: :restrict, type: :binary_id),
          null: false

      add :user_id, references(:users, on_delete: :restrict, type: :binary_id), null: false
      add :decision, :string, null: false
      add :comment, :text
      add :transition, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:approvals, [:artifact_version_id])
    create index(:approvals, [:user_id])
  end
end
