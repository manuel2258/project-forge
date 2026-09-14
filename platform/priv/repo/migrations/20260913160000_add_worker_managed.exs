defmodule Forge.Repo.Migrations.AddWorkerManaged do
  use Ecto.Migration

  # Whether the platform created this machine and may therefore destroy it. False for a machine
  # the operator provisioned and registered with `mix forge.worker.new`, which is long-lived and
  # not the platform's to power off. See docs/design/worker-tier.md § Managed and unmanaged for
  # why this is a column rather than `provider_id == nil`: a failed create looks like that too,
  # and treating it as permanent would leave it holding a max_workers slot for ever.
  #
  # Default true, so every row that exists keeps behaving exactly as it did.
  def change do
    alter table(:workers) do
      add :managed, :boolean, null: false, default: true
    end
  end
end
