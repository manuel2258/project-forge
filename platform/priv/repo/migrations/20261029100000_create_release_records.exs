defmodule Forge.Repo.Migrations.CreateReleaseRecords do
  use Ecto.Migration

  # `docs/design/ticket-types.md` § The record, the tag, the history. Written once when a release
  # ends `done` and never changed, so there is no `updated_at` and nothing is backfilled: the
  # history starts with the first release that concludes after this.
  def change do
    create table(:release_records, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      # Unique: a release has one record, and a second conclusion finds it.
      add :ticket_id, references(:tickets, on_delete: :delete_all, type: :binary_id), null: false
      add :version, :string
      add :concluded_at, :utc_datetime_usec, null: false
      add :commit_sha, :string, null: false
      add :notes, :text
      add :notes_document, :string
      add :notes_version, :integer

      # `[{name, version, size}]`: exact artifact versions, not copies. Size is nil when unreadable.
      add :files, {:array, :map}, null: false, default: []
      # `[{label, url, document, version}]`.
      add :links, {:array, :map}, null: false, default: []
      add :tag_name, :string
      add :tag_status, :string, null: false
      # The other commit a taken name points at, or the reason a tag was not made.
      add :tag_detail, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:release_records, [:ticket_id])
    create index(:release_records, [:project_id, :concluded_at])
  end
end
