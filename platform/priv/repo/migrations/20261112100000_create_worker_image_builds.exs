defmodule Forge.Repo.Migrations.CreateWorkerImageBuilds do
  use Ecto.Migration

  # `docs/design/provisioning.md` § Putting the release's image into an account. The switch is
  # on for every credential that exists, which is the column default; the builds are what the
  # platform keeps so a person can read them and a restart can carry on.
  def change do
    alter table(:provider_credentials) do
      add :build_images, :boolean, null: false, default: true
    end

    create table(:worker_image_builds, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :provider_credential_id,
          references(:provider_credentials, on_delete: :delete_all, type: :binary_id),
          null: false

      add :build, :string, null: false
      add :version, :string
      # The protocol the build's own release speaks, kept so a platform upgraded mid-build labels
      # the snapshot with what is in it and not with what the platform now speaks.
      add :protocol, :integer
      # running | built | failed | abandoned
      add :status, :string, null: false, default: "running"
      add :message, :text
      add :image_id, :string
      # Opaque above the driver: what it needs to find its builder again.
      add :handle, :map
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      add :started_by_user_id, references(:users, on_delete: :nilify_all, type: :binary_id)

      add :started_by_template_id,
          references(:worker_templates, on_delete: :nilify_all, type: :binary_id)

      add :template_name, :string

      timestamps(type: :utc_datetime)
    end

    create index(:worker_image_builds, [:provider_credential_id, :started_at])

    # One build per account per platform build at a time: two jobs, or two templates on one
    # credential, share one row.
    create unique_index(:worker_image_builds, [:provider_credential_id, :build],
             where: "status = 'running'",
             name: :worker_image_builds_one_running
           )
  end
end
