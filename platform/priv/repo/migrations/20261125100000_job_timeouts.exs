defmodule Forge.Repo.Migrations.JobTimeouts do
  @moduledoc """
  An agent job's time limit becomes a workflow setting called `timeout`
  (`docs/design/workflow-grammar-v1.md` § Timeout), and the stop it names is renamed to match.

  Two things change on rows that already exist:

    * **`exhausted` says `timeout`, not `wall_clock`**, on `jobs` and on `job_extensions`, so the
      API gives one word for every job, recorded before this or after.
    * **An extension records the time its run was given**, `timeout_ms`. Every extension before this
      was given the hour the node's configuration set and nothing else could, so `3600000` is what
      its run was actually allowed, and it is written rather than left empty.

  `job_extensions` is insert-only by trigger, and this is the one UPDATE it will ever have: the
  trigger is disabled around it and enabled again. Adding the column with a default fires no row
  trigger, and the default is dropped straight after, so an insert that forgets the figure fails
  rather than recording an hour nobody was given.

  Events are not rewritten. The log is append-only for good (`docs/design/storage.md`
  § Retention), so a `job.finished` recorded before this still says `wall_clock` in its payload.
  """

  use Ecto.Migration

  def up do
    execute "UPDATE jobs SET exhausted = 'timeout' WHERE exhausted = 'wall_clock'"

    alter table(:job_extensions) do
      add :timeout_ms, :bigint, null: false, default: 3_600_000
    end

    execute "ALTER TABLE job_extensions ALTER COLUMN timeout_ms DROP DEFAULT"

    create constraint(:job_extensions, :job_extensions_timeout_positive, check: "timeout_ms > 0")

    execute "ALTER TABLE job_extensions DISABLE TRIGGER job_extensions_append_only"
    execute "UPDATE job_extensions SET exhausted = 'timeout' WHERE exhausted = 'wall_clock'"
    execute "ALTER TABLE job_extensions ENABLE TRIGGER job_extensions_append_only"
  end

  def down do
    execute "UPDATE jobs SET exhausted = 'wall_clock' WHERE exhausted = 'timeout'"

    execute "ALTER TABLE job_extensions DISABLE TRIGGER job_extensions_append_only"
    execute "UPDATE job_extensions SET exhausted = 'wall_clock' WHERE exhausted = 'timeout'"
    execute "ALTER TABLE job_extensions ENABLE TRIGGER job_extensions_append_only"

    drop constraint(:job_extensions, :job_extensions_timeout_positive)

    alter table(:job_extensions) do
      remove :timeout_ms
    end
  end
end
