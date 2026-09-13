defmodule Forge.Repo.Migrations.AddWorkerIdleSince do
  use Ecto.Migration

  # When a worker last ran out of jobs. `updated_at` cannot answer this: a heartbeat is an
  # update, so a machine that is idle and talking would never look idle for long enough to
  # destroy. See docs/design/worker-tier.md § Idle destroy.
  def change do
    alter table(:workers) do
      add :idle_since, :utc_datetime
    end
  end
end
