defmodule Forge.Repo.Migrations.ResourcesOnJobsAndWorkers do
  @moduledoc """
  The gate stops being one number. `docs/design/provisioning.md` § The gate.

  A job's `memory_max` and `cores` are resolved once at creation from the workflow's chain and
  written here rather than left in `spec`. `spec` is the immutable record of what a job was
  asked to do and the resolved figures belong in it too, but the scheduler has to *sum* them
  across a worker's jobs on every pass, and summing `(spec->>'memory')::bigint` is a query
  nobody should have to read. Written once and never rewritten, like `spec` itself.

  On the worker side, `cores` joins `memory_budget` as something the gate counts against, and
  `accepts` is the list of job kinds the machine will take — which is what keeps inference off
  a machine bought for builds, and is one column rather than the class this design dropped.

  `reported` is what the machine last said about itself at `ready`, verbatim, in the same spirit
  as `harness`. It is recorded and not scheduled on: the row governs, so an operator's edit to a
  permanent worker survives every reconnect. A machine whose report disagrees with its row is
  shown rather than silently believed.

  Every column is nullable and null means *not said*, not zero. A worker row that predates this
  has no `cores` and no `accepts`, and filling those from the first `ready` is how it catches
  up. A `cores` of zero would be a machine that can hold nothing.
  """

  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :memory_max, :bigint
      add :cores, :integer
    end

    alter table(:workers) do
      add :cores, :integer
      add :accepts, {:array, :string}
      add :reported, :map
    end

    # Both sides of the gate's sum. `promised/1` reads every running and waiting job of one
    # worker on every scheduling pass, and did it with a count before there was anything to add
    # up.
    create index(:jobs, [:worker_id, :status])
  end
end
