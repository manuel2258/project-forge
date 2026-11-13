defmodule Forge.Repo.Migrations.WorkersOfferHarnesses do
  @moduledoc """
  Every harness a machine offers at `ready`, each with its version (`docs/design/worker-channel.md`
  § Protocol 11). Null for a row that only ever sent the single `harness`, which is read as the one
  it offers.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :harnesses, {:array, :map}
    end
  end
end
