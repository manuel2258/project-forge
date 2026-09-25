defmodule Forge.Repo.Migrations.JobsHoldTheirCredential do
  @moduledoc """
  A project's pool of credentials, and the credential each job picked from it.
  `docs/design/credentials.md` § The pool and § How a job picks.

  **`project_credentials`** is the pool: a credential's owner assigns it to a project they are a
  member of, and a job in that project may spend it. The guard is `Forge.Credentials.assign/3`'s;
  the row is only what it decided.

  **`jobs.credential_id`** is the credential the job picked at its first start and keeps while it
  is usable. It is what makes a credential's spend a query over jobs (`credentials.md` § Spend).
  `restrict`, because a credential is revoked rather than deleted and a job's record of what paid
  for it must outlive any attempt to remove the row. Nullable: every job before this one was paid
  for by the node's own key, which no row describes.

  No backfill, deliberately. The node's `ANTHROPIC_API_KEY` stops being read here, and there is
  nothing a migration could honestly turn it into — `credentials.md` § The node's own key is gone.
  """

  use Ecto.Migration

  def change do
    create table(:project_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :credential_id, references(:credentials, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_credentials, [:project_id, :credential_id])
    create index(:project_credentials, [:credential_id])

    alter table(:jobs) do
      add :credential_id, references(:credentials, on_delete: :restrict, type: :binary_id)
    end

    create index(:jobs, [:credential_id])
  end
end
