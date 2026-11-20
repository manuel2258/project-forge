defmodule Forge.Repo.Migrations.WorkerUpdates do
  use Ecto.Migration

  # A permanent machine updates itself (`docs/design/worker-tier.md` § Updating a permanent
  # machine): its owner's switch, what the machine last said of an update, when the platform
  # stopped placing work on it for one, and the last report of what fills its disk.
  #
  # **`auto_update` is on for every row that exists**, machines running today included: that is
  # the default the column carries, and it is what the owner is told to turn off if they would
  # rather update by hand (`docs/deploy.md` § Upgrading). It means nothing for a machine the
  # platform made, which is replaced.
  def change do
    alter table(:workers) do
      add :auto_update, :boolean, null: false, default: true
      add :update_state, :map
      add :update_reported_at, :utc_datetime
      add :updating_at, :utc_datetime_usec
      add :disk_report, :map
      add :disk_reported_at, :utc_datetime
    end
  end
end
