defmodule Forge.Repo.Migrations.CreateTickets do
  use Ecto.Migration

  def change do
    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, on_delete: :restrict, type: :binary_id), null: false
      add :number, :integer, null: false
      add :title, :string, null: false
      add :body, :text, null: false, default: ""
      add :base_commit, :string, null: false
      add :branch, :string, null: false
      add :workflow, :map, null: false
      add :workflow_commit, :string, null: false
      add :state, :string, null: false
      add :status, :string, null: false
      add :cost_usd, :decimal, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tickets, [:project_id, :number])
    create index(:tickets, [:status])
  end
end
