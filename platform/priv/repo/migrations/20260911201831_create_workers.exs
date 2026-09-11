defmodule Forge.Repo.Migrations.CreateWorkers do
  use Ecto.Migration

  def change do
    create table(:workers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :provider, :string, null: false
      add :provider_id, :string
      add :status, :string, null: false
      add :token_hash, :string
      add :memory_budget, :bigint
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:workers, [:status])
  end
end
