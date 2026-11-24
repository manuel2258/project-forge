defmodule Forge.Repo.Migrations.Pages do
  use Ecto.Migration

  # Pages an agent writes, hosted by forge, with a live store each (`docs/design/pages.md`,
  # `docs/design/data-model.md`).
  #
  # **Five tables and nothing existing changes.** A page's files are blob artifacts named
  # `<page>/<file>`, written as a group's members are, so `artifacts` and `artifact_versions` are
  # untouched. `pages` is the page and its store's counters; `page_versions` says which file
  # versions made one version of it and is append-only; `page_entries` is the store; `page_outside`
  # is a viewer's toggle; `page_bursts` is the audit being gathered into one event.
  def up do
    create table(:pages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false

      # A ticket's page, or a project chat's (a chat is a job). Exactly one, as on artifacts.
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict)
      add :job_id, references(:jobs, type: :binary_id, on_delete: :restrict)
      add :name, :string, null: false

      # The store's counter: every set or delete takes the next, under a lock on this row, so a
      # key deleted and written again never gets a counter back.
      add :seq, :bigint, null: false, default: 0
      add :key_count, :integer, null: false, default: 0
      add :data_bytes, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:pages, [:ticket_id, :name], where: "ticket_id IS NOT NULL")
    create unique_index(:pages, [:job_id, :name], where: "job_id IS NOT NULL")
    create index(:pages, [:project_id])

    create constraint(:pages, :pages_one_scope, check: "num_nonnulls(ticket_id, job_id) = 1")

    create constraint(:pages, :pages_counts,
             check: "seq >= 0 AND key_count >= 0 AND data_bytes >= 0"
           )

    create table(:page_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :page_id, references(:pages, type: :binary_id, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :job_id, references(:jobs, type: :binary_id, on_delete: :restrict)

      # File name => the artifact version id of `<page>/<file>` that is this page version's.
      add :files, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:page_versions, [:page_id, :version])

    execute """
    CREATE TRIGGER page_versions_append_only
    BEFORE UPDATE OR DELETE ON page_versions
    FOR EACH ROW EXECUTE FUNCTION forge_append_only();
    """

    create table(:page_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :page_id, references(:pages, type: :binary_id, on_delete: :restrict), null: false
      add :key, :string, null: false

      # Nullable on purpose: Ecto hands a nil through its type untouched, so JSON `null` is SQL NULL
      # here and every other value is `{"v": value}` (`Forge.Pages.Value`).
      add :value, :jsonb
      add :counter, :bigint, null: false
      add :size, :integer, null: false
      add :written_at, :utc_datetime_usec, null: false

      # Who last wrote it, exactly one. A record of who, as an event's actor is, and not a
      # reference: no foreign key, so that nothing a writer's row needs can be held up by a value
      # it once wrote.
      add :user_id, :binary_id
      add :job_id, :binary_id
      add :token_id, :binary_id
    end

    create unique_index(:page_entries, [:page_id, :key])

    create constraint(:page_entries, :page_entries_one_writer,
             check: "num_nonnulls(user_id, job_id, token_id) = 1"
           )

    create table(:page_outside, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :page_id, references(:pages, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create table(:page_bursts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :page_id, references(:pages, type: :binary_id, on_delete: :restrict), null: false

      # `user:<id>`, `job:<id>` or `token:<id>`: one open burst per writer per page.
      add :writer_key, :string, null: false
      add :writer, :map, null: false
      add :opened_at, :utc_datetime_usec, null: false
      add :last_at, :utc_datetime_usec, null: false
      add :changes, :integer, null: false, default: 0

      # The first fifty names changed, and a count of names that is exact up to fifty and an upper
      # bound past it (`Forge.Pages`' note_burst). Never a value.
      add :keys, {:array, :string}, null: false, default: []
      add :key_count, :integer, null: false, default: 0
    end

    create unique_index(:page_bursts, [:page_id, :writer_key])
    create index(:page_bursts, [:last_at])
  end

  def down do
    drop table(:page_bursts)
    drop table(:page_outside)
    drop table(:page_entries)
    drop table(:page_versions)
    drop table(:pages)
  end
end
