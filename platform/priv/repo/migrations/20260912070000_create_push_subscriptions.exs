defmodule Forge.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false
      add :endpoint, :text, null: false
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :user_agent, :text
      add :last_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
