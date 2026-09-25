defmodule Forge.Repo.Migrations.CreateCredentials do
  @moduledoc """
  The secret an agent authenticates with, owned by a person. `docs/design/credentials.md`
  § What a credential is.

  **The secret is nullable only once the row is revoked**, and the database says so rather than
  the changeset alone: revoking overwrites the secret with nothing in the same update, because a
  revoked credential is one its owner wants gone and nothing will ever need it back. The row stays
  — jobs will reference it.

  **A name is unique among the owner's live credentials**, not among every credential they ever
  had: a token that leaked is revoked and its replacement is naturally given the same name.
  """

  use Ecto.Migration

  def change do
    create table(:credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :name, :string, null: false
      # Which harness driver the secret authenticates, and what that driver calls it. Strings
      # rather than enums: a harness is a module in a registry, and a new one must not need a
      # migration (`credentials.md` § What a credential is).
      add :harness, :string, null: false
      add :kind, :string, null: false
      # Sealed by `Forge.Provisioning.Vault` under this table's own label; never loaded by an
      # ordinary query.
      add :secret, :text
      # Recorded and shown, never enforced (`identity.md` § Credentials).
      add :daily_limit_usd, :decimal
      # What the provider said this credential may use, at `checked_at`. Null with a
      # `check_error` when the provider could not be asked.
      add :models, {:array, :map}
      add :checked_at, :utc_datetime
      add :check_error, :string
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:credentials, [:user_id])

    create unique_index(:credentials, [:user_id, :name],
             where: "revoked_at IS NULL",
             name: :credentials_live_name_index
           )

    create constraint(:credentials, :secret_until_revoked,
             check: "revoked_at IS NOT NULL OR secret IS NOT NULL"
           )
  end
end
