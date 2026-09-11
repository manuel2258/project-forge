defmodule Forge.Repo.Migrations.CreateQuestions do
  use Ecto.Migration

  def change do
    create table(:questions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_version_id,
          references(:artifact_versions, on_delete: :restrict, type: :binary_id),
          null: false

      add :key, :string, null: false
      add :anchor, :text
      add :text, :text, null: false
      add :options, {:array, :string}, null: false, default: []
      add :default, :string
      add :blocking, :boolean, null: false, default: false
      add :assumption, :text
      add :line, :integer, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:questions, [:artifact_version_id, :key])
    create index(:questions, [:blocking])
  end
end
