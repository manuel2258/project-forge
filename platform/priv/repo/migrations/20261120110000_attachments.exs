defmodule Forge.Repo.Migrations.Attachments do
  use Ecto.Migration

  # Files people attach (`docs/design/attachments.md`, `docs/design/data-model.md`).
  #
  # **Two tables and nothing else changes.** Nothing existing changes meaning: a ticket with no
  # files has no row in either, and `artifact_versions` is not touched — it stays append-only by
  # trigger. A file is a blob version of an artifact named `attachments/<file>`; the row here sits
  # beside the version and says what it was attached to and who withdrew it.
  #
  # `attachment_uploads` is the staging: bytes the store holds under `upload/<id>` that no act has
  # claimed. Nothing counts one, and the sweep deletes the old ones.
  def up do
    create table(:attachment_uploads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :restrict)
      add :key, :string, null: false
      add :original_name, :text, null: false
      add :size, :bigint, null: false
      add :content_hash, :string, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:attachment_uploads, [:inserted_at])
    create index(:attachment_uploads, [:user_id])

    create constraint(:attachment_uploads, :attachment_uploads_one_author,
             check: "num_nonnulls(user_id, token_id) = 1"
           )

    create constraint(:attachment_uploads, :attachment_uploads_size, check: "size >= 0")

    create table(:attachments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The pool: a ticket's, or a project chat's (a chat is a job). Exactly one, as on artifacts.
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :restrict)
      add :job_id, references(:jobs, type: :binary_id, on_delete: :restrict)

      # Null for a file that was not received: attached, and its upload failed.
      add :artifact_version_id,
          references(:artifact_versions, type: :binary_id, on_delete: :restrict)

      add :name, :string
      add :original_name, :text, null: false
      add :size, :bigint

      # What it was attached to: `ticket`, `document`, `message`, `answer` or `note`, and the row
      # that says so — a version for the first two, an event's `seq` for the rest.
      add :to_kind, :string, null: false
      add :to_version_id, references(:artifact_versions, type: :binary_id, on_delete: :restrict)
      add :to_event_seq, :bigint

      add :author, :map, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :restrict)

      add :withdrawn_at, :utc_datetime_usec
      add :withdrawn_by, :map
      add :withdrawn_user_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :withdraw_reason, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:attachments, [:artifact_version_id],
             where: "artifact_version_id IS NOT NULL"
           )

    create index(:attachments, [:ticket_id], where: "ticket_id IS NOT NULL")
    create index(:attachments, [:job_id], where: "job_id IS NOT NULL")
    create index(:attachments, [:to_event_seq], where: "to_event_seq IS NOT NULL")
    create index(:attachments, [:to_version_id], where: "to_version_id IS NOT NULL")

    create constraint(:attachments, :attachments_one_pool,
             check: "num_nonnulls(ticket_id, job_id) = 1"
           )

    create constraint(:attachments, :attachments_one_author,
             check: "num_nonnulls(user_id, token_id) = 1"
           )

    create constraint(:attachments, :attachments_one_anchor,
             check: "num_nonnulls(to_version_id, to_event_seq) = 1"
           )

    create constraint(:attachments, :attachments_kind,
             check: "to_kind IN ('ticket', 'document', 'message', 'answer', 'note')"
           )

    # A file received has a version, a name and a size; one that was not has none of the three.
    create constraint(:attachments, :attachments_received_or_not,
             check:
               "(artifact_version_id IS NULL AND name IS NULL AND size IS NULL) " <>
                 "OR (artifact_version_id IS NOT NULL AND name IS NOT NULL AND size IS NOT NULL)"
           )

    # **Not append-only, and not editable either.** Withdrawing a file is the one change a row
    # takes, once: it sets the four withdrawal columns from null, and nothing else about it moves.
    # A row is never deleted. The version row beside it is never touched at all.
    execute """
    CREATE OR REPLACE FUNCTION forge_attachments_guard() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'table % is never deleted from', TG_TABLE_NAME;
      END IF;

      IF OLD.withdrawn_at IS NOT NULL THEN
        RAISE EXCEPTION 'a withdrawn attachment is not changed';
      END IF;

      IF NEW.withdrawn_at IS NULL OR NEW.withdrawn_by IS NULL OR
         (to_jsonb(NEW) - 'withdrawn_at' - 'withdrawn_by' - 'withdrawn_user_id' - 'withdraw_reason')
         <> (to_jsonb(OLD) - 'withdrawn_at' - 'withdrawn_by' - 'withdrawn_user_id' - 'withdraw_reason') THEN
        RAISE EXCEPTION 'an attachment is changed only by withdrawing it';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER attachments_guard
    BEFORE UPDATE OR DELETE ON attachments
    FOR EACH ROW EXECUTE FUNCTION forge_attachments_guard();
    """
  end

  def down do
    drop table(:attachments)
    execute "DROP FUNCTION IF EXISTS forge_attachments_guard()"
    drop table(:attachment_uploads)
  end
end
