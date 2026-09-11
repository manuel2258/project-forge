defmodule Forge.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def up do
    create table(:events, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :ticket_id, references(:tickets, on_delete: :restrict, type: :binary_id)
      add :job_id, references(:jobs, on_delete: :restrict, type: :binary_id)
      add :actor, :map, null: false
      add :type, :string, null: false
      add :payload, :map, null: false, default: %{}

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:events, [:ticket_id, :seq])
    create index(:events, [:job_id, :seq])
    create index(:events, [:type])

    execute """
    CREATE TRIGGER events_append_only
    BEFORE UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """
  end

  def down do
    drop table(:events)
  end
end
