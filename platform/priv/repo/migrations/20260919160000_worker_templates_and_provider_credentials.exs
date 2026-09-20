defmodule Forge.Repo.Migrations.WorkerTemplatesAndProviderCredentials do
  @moduledoc """
  Where a machine comes from, and whose account it is made in.
  `docs/design/provisioning.md` §§ Two tables and Whose account.

  **A template is a recipe and nothing more.** Its values are *copied* onto a worker at
  creation, never read through, so editing a template does not resize a running fleet and
  deleting one does not orphan the machines it made. `workers.template_id` is provenance, and
  it is nullable because a machine the operator built by hand came from no recipe at all —
  which is the same row shape with `managed: false`, and the reason no second concept appears
  for a permanent worker.

  **A provider credential is its own table, not a third `kind` on `identity.md`'s
  `credential`.** That note defines a credential's spend as a query over the jobs that used it;
  machine spend is hours times a rate and accrues with nothing running. One table would make
  every existing spend query carry a filter to stay correct.

  The secret is one encrypted string holding a map whose shape the driver owns — one token for
  Hetzner, a key pair elsewhere — so a new provider is a module rather than a migration.
  """

  use Ecto.Migration

  def change do
    create table(:provider_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :name, :string, null: false
      add :provider, :string, null: false
      # Encrypted by `Forge.Provisioning.Vault`; never readable from a query.
      add :secret, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:provider_credentials, [:user_id])
    create unique_index(:provider_credentials, [:user_id, :name])

    create table(:worker_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      # Nullable: the local driver needs no account, so a template for it carries no credential
      # and `local` stays a provider like any other rather than a special case.
      add :provider_credential_id,
          references(:provider_credentials, on_delete: :nilify_all, type: :binary_id)

      add :name, :string, null: false
      add :provider, :string, null: false
      # Opaque above the driver: the platform passes it to `Provider.create/1` and never reads
      # it, which is what keeps "cpx32" from meaning anything outside the Hetzner driver.
      add :size, :string
      add :memory, :bigint, null: false
      add :cores, :integer, null: false
      add :accepts, {:array, :string}
      add :max_workers, :integer, null: false, default: 1
      add :idle_ms, :integer

      timestamps(type: :utc_datetime)
    end

    create index(:worker_templates, [:user_id])
    create unique_index(:worker_templates, [:user_id, :name])

    # The mirror of `identity.md`'s `project_worker`: the owner assigns, and only to a project
    # they are a member of, because creating from a template spends their credential.
    create table(:project_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :template_id, references(:worker_templates, on_delete: :delete_all, type: :binary_id),
        null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_templates, [:project_id, :template_id])
    create index(:project_templates, [:template_id])

    alter table(:workers) do
      # Provenance, not authority. `nilify_all` because a machine outlives the recipe that made
      # it and deleting a template must never take a running worker with it.
      add :template_id, references(:worker_templates, on_delete: :nilify_all, type: :binary_id)

      add :provider_credential_id,
          references(:provider_credentials, on_delete: :nilify_all, type: :binary_id)
    end

    create index(:workers, [:template_id])
  end
end
