defmodule Forge.Repo.Migrations.CreateProjectSecrets do
  @moduledoc """
  A project's secrets: values the platform never uses and only carries to the jobs that list
  them. `docs/design/secrets.md` § What a secret is.

  **A live row has a value and a deleted row has none**, and the database says so rather than the
  changeset alone: deleting overwrites the value with nothing in the same update, because a
  deleted secret is one the project wants gone. The row stays — events name a secret by name and
  version.

  **A name is unique among the project's live secrets**, so a deleted name may be set again, as a
  new row starting at version 1.
  """

  use Ecto.Migration

  def change do
    create table(:project_secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :name, :string, null: false
      # Sealed by `Forge.Provisioning.Vault` under this table's own label; never loaded by an
      # ordinary query.
      add :value, :text
      add :version, :integer, null: false, default: 1
      # Who set the current version. Nullified rather than cascaded: an account deleted does not
      # take the project's secrets with it.
      add :set_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :set_at, :utc_datetime, null: false
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Every row, live or deleted: deleting a project cascades to all of its secrets, and deleting
    # an account nullifies what it set, and the partial index below serves neither.
    create index(:project_secrets, [:project_id])
    create index(:project_secrets, [:set_by_id])

    create unique_index(:project_secrets, [:project_id, :name],
             where: "deleted_at IS NULL",
             name: :project_secrets_live_name_index
           )

    create constraint(:project_secrets, :value_while_live,
             check: "(deleted_at IS NULL) = (value IS NOT NULL)"
           )
  end
end
