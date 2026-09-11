defmodule Forge.Repo.Migrations.CreateAnswers do
  use Ecto.Migration

  def change do
    create table(:answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :question_id, references(:questions, on_delete: :restrict, type: :binary_id),
        null: false

      add :user_id, references(:users, on_delete: :restrict, type: :binary_id), null: false
      add :choice, :string
      add :text, :text

      add :artifact_version_id,
          references(:artifact_versions, on_delete: :restrict, type: :binary_id),
          null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:answers, [:question_id])
    create index(:answers, [:user_id])
  end
end
