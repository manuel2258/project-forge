defmodule Forge.Repo.Migrations.CreateJobs do
  use Ecto.Migration

  def change do
    create table(:jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, on_delete: :restrict, type: :binary_id), null: false
      add :state, :string, null: false
      add :attempt, :integer, null: false
      add :parent_job_id, references(:jobs, on_delete: :restrict, type: :binary_id)
      add :spec, :map, null: false
      add :status, :string, null: false
      add :outcome, :string
      add :declared_outcome, :string
      add :turns, :integer, null: false, default: 0
      add :cost_usd, :decimal, null: false, default: 0
      add :harness_session_id, :string
      add :worker_id, references(:workers, on_delete: :nilify_all, type: :binary_id)
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:jobs, [:ticket_id, :state, :attempt])
    create index(:jobs, [:status])
    create index(:jobs, [:parent_job_id])
    create index(:jobs, [:worker_id])
  end
end
