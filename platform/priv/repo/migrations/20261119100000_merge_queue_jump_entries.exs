defmodule Forge.Repo.Migrations.MergeQueueJumpEntries do
  use Ecto.Migration

  # A jump into a merging state joins the line without an edge behind it
  # (`docs/design/workflow-grammar-v1.md` § Jumping): the row says so, and names no edge outcome.
  def change do
    alter table(:merge_queue_entries) do
      modify :edge_outcome, :string, null: true, from: {:string, null: false}
      add :jump, :boolean, null: false, default: false
    end

    create constraint(:merge_queue_entries, :jump_names_no_edge,
             check: "jump = (edge_outcome IS NULL)"
           )
  end
end
