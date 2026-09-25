defmodule Forge.Repo.Migrations.CreateJobRuns do
  @moduledoc """
  Each start of a job, with the credential it spent and what it cost — the run ledger
  (`docs/design/credentials.md` § Spend).

  **Why a table and not the column it replaces as the source of spend.** `jobs.credential_id` is
  the credential a job is on *now*. Once a job can move off a limited credential and resume on
  another, summing costs by that column puts all of a job's cost on the one it ended on. A run is
  what spent on one credential, so spend per credential is a sum over runs, and so is the node's
  day, which is how the two keep adding up.

  **Backfilled with one run per job that ever started**: its credential, its worker, its first
  start and its whole cost, closed when the job finished. That is exactly what both figures said
  before this migration — the old queries summed `jobs.cost_usd` by `jobs.started_at` — so an
  upgrade changes no number anybody has already seen. A job still open (running, waiting, or
  pending after a question) gets an open run, which its next start closes.

  `credential_id` is `restrict` for the reason `jobs.credential_id` is: a run's record of what
  paid for it must outlive any attempt to remove the credential. Nullable for the runs from
  before credentials existed, which the node's own key paid for.
  """

  use Ecto.Migration

  def up do
    create table(:job_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:jobs, on_delete: :delete_all, type: :binary_id), null: false
      add :credential_id, references(:credentials, on_delete: :restrict, type: :binary_id)
      add :worker_id, references(:workers, on_delete: :nilify_all, type: :binary_id)
      add :started_at, :utc_datetime, null: false
      add :cost_usd, :decimal, null: false, default: 0
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:job_runs, [:job_id])
    create index(:job_runs, [:credential_id, :started_at])
    create index(:job_runs, [:started_at])

    execute("""
    INSERT INTO job_runs
      (id, job_id, credential_id, worker_id, started_at, cost_usd, finished_at,
       inserted_at, updated_at)
    SELECT gen_random_uuid(), id, credential_id, worker_id, started_at, cost_usd, finished_at,
           NOW(), NOW()
    FROM jobs
    WHERE started_at IS NOT NULL
    """)
  end

  def down do
    drop table(:job_runs)
  end
end
