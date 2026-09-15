defmodule Forge.Repo.Migrations.ArtifactsHaveAScope do
  @moduledoc """
  An artifact belongs to a ticket or to a conversation — `docs/design/conversations.md`
  § Commits. Exactly one of the two, which is what the CHECK says.

  The index matters as much as the column. `unique_index([:ticket_id, :name])` stops constraining
  anything the moment `ticket_id` can be null, because Postgres treats NULLs as distinct: every
  chat artifact would satisfy it and a conversation would quietly accumulate a second, third and
  fourth `notes.md`. So it becomes partial, and a second partial index covers the chat side.
  """

  use Ecto.Migration

  def up do
    alter table(:artifacts) do
      add :job_id, references(:jobs, on_delete: :restrict, type: :binary_id)
      modify :ticket_id, :binary_id, null: true, from: {:binary_id, null: false}
    end

    create constraint(:artifacts, :artifacts_one_scope,
             check: "(ticket_id IS NULL) <> (job_id IS NULL)"
           )

    drop unique_index(:artifacts, [:ticket_id, :name])

    create unique_index(:artifacts, [:ticket_id, :name],
             where: "ticket_id IS NOT NULL",
             name: :artifacts_ticket_id_name_index
           )

    create unique_index(:artifacts, [:job_id, :name],
             where: "job_id IS NOT NULL",
             name: :artifacts_job_id_name_index
           )
  end

  def down do
    drop constraint(:artifacts, :artifacts_one_scope)
    drop unique_index(:artifacts, [:job_id, :name], name: :artifacts_job_id_name_index)
    drop unique_index(:artifacts, [:ticket_id, :name], name: :artifacts_ticket_id_name_index)

    execute "DELETE FROM artifacts WHERE ticket_id IS NULL"

    alter table(:artifacts) do
      modify :ticket_id, :binary_id, null: false, from: {:binary_id, null: true}
      remove :job_id
    end

    create unique_index(:artifacts, [:ticket_id, :name])
  end
end
