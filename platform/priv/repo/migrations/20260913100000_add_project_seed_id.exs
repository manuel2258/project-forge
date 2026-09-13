defmodule Forge.Repo.Migrations.AddProjectSeedId do
  use Ecto.Migration

  # Which seed a worker should fetch for this project. The store has no listing — that is
  # deliberate, and docs/design/storage.md says why — so the current one is something the
  # database knows, set by `mix forge.seed.publish`. Null means no seed has ever been
  # published, which is not an error: the job clones and builds cold.
  def change do
    alter table(:projects) do
      add :seed_id, :string
    end
  end
end
