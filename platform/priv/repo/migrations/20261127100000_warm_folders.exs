defmodule Forge.Repo.Migrations.WarmFolders do
  use Ecto.Migration

  # The sizes of the folders git ignores in a kept command copy (`docs/design/worker-tier.md`
  # § Looking into a copy, ticket 84; `data-model.md`), saved with the command that kept it so they
  # outlive the copy and its machine. `ForgeCore.WarmBuild.folders/1` is the shape, bounded at
  # fifty folders and three totals. Null for every command that exists and for any kept by a worker
  # that does not report them.
  #
  # **Breaking only in that it is a migration**: no column changes meaning.
  def change do
    alter table(:jobs) do
      add :warm_folders, :map
    end
  end
end
