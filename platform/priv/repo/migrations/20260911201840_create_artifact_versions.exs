defmodule Forge.Repo.Migrations.CreateArtifactVersions do
  use Ecto.Migration

  # Shared by every append-only table. Raising inside a BEFORE trigger aborts the statement,
  # so neither UPDATE nor DELETE can ever touch a row, whatever role the platform uses.
  @append_only_function """
  CREATE OR REPLACE FUNCTION forge_append_only() RETURNS trigger AS $$
  BEGIN
    RAISE EXCEPTION 'table % is append-only', TG_TABLE_NAME;
  END;
  $$ LANGUAGE plpgsql;
  """

  def up do
    execute @append_only_function

    create table(:artifact_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_id, references(:artifacts, on_delete: :restrict, type: :binary_id),
        null: false

      add :version, :integer, null: false
      add :author, :map, null: false
      add :content, :text
      add :blob_uri, :string
      add :content_hash, :string, null: false
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:artifact_versions, [:artifact_id, :version])

    execute """
    CREATE TRIGGER artifact_versions_append_only
    BEFORE UPDATE OR DELETE ON artifact_versions
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """
  end

  def down do
    drop table(:artifact_versions)
    execute "DROP FUNCTION IF EXISTS forge_append_only()"
  end
end
