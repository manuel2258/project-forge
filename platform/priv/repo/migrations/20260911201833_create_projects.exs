defmodule Forge.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :repo_path, :text, null: false
      add :default_branch, :string, null: false, default: "main"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:name])
  end
end
