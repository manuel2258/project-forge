defmodule Forge.Repo.Migrations.JobExtensions do
  use Ecto.Migration

  # A person extends a job that ran out of budget, runs a state again with a note, or raises a
  # ticket's cap (`docs/design/workflow-grammar-v1.md` § Extending a job). Each is a record of its
  # own, insert-only, naming who (a person or a project token, exactly one, as an answer does).
  #
  # **Nothing existing changes meaning.** A ticket's raise is 0, so its allowance is the workflow's
  # as before; no job has an extension; no job was started by a restart.
  def up do
    alter table(:tickets) do
      add :cap_raise, :bigint, null: false, default: 0
    end

    create constraint(:tickets, :tickets_cap_raise_not_negative, check: "cap_raise >= 0")

    create table(:ticket_restarts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict), null: false
      add :state, :string, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :restrict)
      add :note, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ticket_restarts, [:ticket_id])

    create constraint(:ticket_restarts, :ticket_restarts_one_author,
             check: "num_nonnulls(user_id, token_id) = 1"
           )

    create constraint(:ticket_restarts, :ticket_restarts_note_length,
             check: "note IS NULL OR char_length(note) <= 4000"
           )

    create table(:job_extensions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, type: :binary_id, on_delete: :restrict), null: false
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :restrict)
      add :tokens, :bigint, null: false
      add :turns, :integer
      add :note, :text

      # The stop this extended, so how often a job needed room — and which ceiling it hit — can be
      # counted from the records alone.
      add :exhausted, :string
      add :stopped_at, :utc_datetime
      add :usage_before, :bigint
      add :turns_before, :integer
      add :runs_before, :integer

      # Sub-second, because a job's extensions are read back in the order they were given and two
      # can be given within one second.
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:job_extensions, [:job_id])
    create index(:job_extensions, [:ticket_id])

    create constraint(:job_extensions, :job_extensions_one_author,
             check: "num_nonnulls(user_id, token_id) = 1"
           )

    create constraint(:job_extensions, :job_extensions_tokens_positive, check: "tokens > 0")

    create constraint(:job_extensions, :job_extensions_turns_positive,
             check: "turns IS NULL OR turns > 0"
           )

    create constraint(:job_extensions, :job_extensions_note_length,
             check: "note IS NULL OR char_length(note) <= 4000"
           )

    create table(:ticket_cap_raises, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :restrict)
      add :from_tokens, :bigint, null: false
      add :to_tokens, :bigint, null: false
      add :extension_id, references(:job_extensions, type: :binary_id, on_delete: :restrict)
      add :restart_id, references(:ticket_restarts, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ticket_cap_raises, [:ticket_id])

    create constraint(:ticket_cap_raises, :ticket_cap_raises_one_author,
             check: "num_nonnulls(user_id, token_id) = 1"
           )

    create constraint(:ticket_cap_raises, :ticket_cap_raises_raises,
             check: "to_tokens > from_tokens"
           )

    create constraint(:ticket_cap_raises, :ticket_cap_raises_one_origin,
             check: "num_nonnulls(extension_id, restart_id) = 1"
           )

    # Insert-only, said by the database as `artifact_versions` is: a record of who gave a job more
    # room is no good if it can be edited.
    for table <- [:ticket_restarts, :job_extensions, :ticket_cap_raises] do
      execute """
      CREATE TRIGGER #{table}_append_only
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION forge_append_only();
      """
    end

    alter table(:jobs) do
      add :restart_id, references(:ticket_restarts, type: :binary_id, on_delete: :restrict)
    end

    create index(:jobs, [:restart_id], where: "restart_id IS NOT NULL")

    alter table(:job_runs) do
      add :extension_id, references(:job_extensions, type: :binary_id, on_delete: :restrict)
      add :resumed, :boolean
    end
  end

  def down do
    alter table(:job_runs) do
      remove :resumed
      remove :extension_id
    end

    drop index(:jobs, [:restart_id], where: "restart_id IS NOT NULL")

    alter table(:jobs) do
      remove :restart_id
    end

    drop table(:ticket_cap_raises)
    drop table(:job_extensions)
    drop table(:ticket_restarts)
    drop constraint(:tickets, :tickets_cap_raise_not_negative)

    alter table(:tickets) do
      remove :cap_raise
    end
  end
end
