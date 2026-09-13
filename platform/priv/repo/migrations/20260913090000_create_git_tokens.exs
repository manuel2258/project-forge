defmodule Forge.Repo.Migrations.CreateGitTokens do
  use Ecto.Migration

  def change do
    create table(:git_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :binary, null: false

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :ticket_id, references(:tickets, on_delete: :nilify_all, type: :binary_id)
      add :job_id, references(:jobs, on_delete: :nilify_all, type: :binary_id)
      add :ref, :string
      add :write, :boolean, null: false, default: false
      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:git_tokens, [:token_hash])
    create index(:git_tokens, [:job_id])
    create index(:git_tokens, [:project_id])
  end
end
