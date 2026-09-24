defmodule Forge.Repo.Migrations.CreateIdentities do
  use Ecto.Migration

  @moduledoc """
  An external identity a user logs in with. `docs/design/identity.md` § Identity is
  `(issuer, subject)`.

  `users.hashed_password` needs no change: the generator's migration never made it `null: false`,
  so an account with no password has always been representable and this only starts making them.
  """

  def change do
    create table(:identities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # The pair that is the identity. `subject` is stable only within an issuer, which is why
      # neither half is unique on its own.
      add :issuer, :string, null: false
      add :subject, :string, null: false

      # As claimed at the last login, for display. Never looked up by: an address is mutable at
      # the issuer, re-assignable by whoever runs it, and assertable by two issuers at once.
      add :email, :string
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:identities, [:issuer, :subject])
    create index(:identities, [:user_id])
  end
end
