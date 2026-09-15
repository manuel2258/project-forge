defmodule Forge.Repo.Migrations.AddWorkerHarness do
  use Ecto.Migration

  # What the machine reported about its harness at `ready`: driver, version, capabilities, login
  # and the models its credential may use. One jsonb column and not a set of them, because it is
  # a blob the worker authors and the platform only reads back — see
  # `docs/design/worker-channel.md` § What a worker offers.
  #
  # Nullable, and null is not "no harness": it is a worker that joined before this existed, or
  # one whose probe could not reach anything. Both are workers that still take jobs.
  def change do
    alter table(:workers) do
      add :harness, :map
    end
  end
end
