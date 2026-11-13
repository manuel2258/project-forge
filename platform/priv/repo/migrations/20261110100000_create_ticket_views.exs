defmodule Forge.Repo.Migrations.CreateTicketViews do
  use Ecto.Migration

  # When each person last opened each ticket's page, for *since you last looked*
  # (`docs/design/ui.md` § The end of the pass, and *All*). One row per person and ticket,
  # overwritten on every look: what a page compares against is the previous one, which
  # `Forge.Tickets.Views.touch/2` reads before it writes.
  def change do
    create table(:ticket_views, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false
      add :viewed_at, :utc_datetime_usec, null: false
    end

    # The upsert's conflict target: one look per person per ticket. Another person's look is
    # another row and never moves this one.
    create unique_index(:ticket_views, [:user_id, :ticket_id])
    create index(:ticket_views, [:ticket_id])
  end
end
