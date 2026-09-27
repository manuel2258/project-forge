defmodule Forge.Repo.Migrations.CreateWorkerLog do
  @moduledoc """
  A machine's own history: what the platform saw happen to it, and what the machine reported of
  itself at the level of the machine (`docs/design/worker-log.md`).

  Its own table and not `events`: those rows belong to a project, a ticket or a job and are read by
  who may see that project, while a machine belongs to a user and serves several projects. The
  last 500 lines per machine are kept, trimmed as each is written, so `(worker_id, id)` is the
  index the trim reads and `(worker_id, at)` the one the page does.
  """

  use Ecto.Migration

  def change do
    create table(:worker_log) do
      add :worker_id, references(:workers, on_delete: :delete_all, type: :binary_id), null: false
      add :at, :utc_datetime_usec, null: false
      add :source, :string, null: false
      add :type, :string, null: false
      add :level, :string, null: false
      add :message, :text, null: false
      add :job_id, :binary_id

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:worker_log, [:worker_id, :id])
    create index(:worker_log, [:worker_id, :at])
  end
end
