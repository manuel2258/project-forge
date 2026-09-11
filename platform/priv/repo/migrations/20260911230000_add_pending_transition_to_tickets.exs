defmodule Forge.Repo.Migrations.AddPendingTransitionToTickets do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      # Set when the engine picked a transition that needs human approval:
      # %{"from" => .., "to" => .., "outcome" => .., "approve" => [..]}. Cleared when decided.
      add :pending_transition, :map
    end
  end
end
