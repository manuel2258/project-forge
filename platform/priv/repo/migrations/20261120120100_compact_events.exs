defmodule Forge.Repo.Migrations.CompactEvents do
  use Ecto.Migration

  # The rows `EventRetention` deleted are dead space until the table is rewritten; this gives it
  # back to the disk (`docs/design/storage.md` § Retention). `VACUUM` cannot run inside a
  # transaction, so this migration has none and takes no migration lock. It holds `events` for its
  # duration, which is why the release that carries it is deployed while the platform is not
  # serving. Later sweeps do not compact.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: execute("VACUUM (FULL, ANALYZE) events")

  # A rewrite has nothing to undo.
  def down, do: :ok
end
