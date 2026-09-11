defmodule Forge.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, on_delete: :restrict, type: :binary_id), null: false
      add :name, :string, null: false
      add :kind, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:artifacts, [:ticket_id, :name])
  end
end
