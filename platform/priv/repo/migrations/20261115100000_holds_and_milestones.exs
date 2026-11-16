defmodule Forge.Repo.Migrations.HoldsAndMilestones do
  use Ecto.Migration

  # A hold is a flag on the ticket, not a status (`docs/design/workflow-grammar-v1.md` § Holding a
  # ticket), and a milestone is a named goal with an order (`docs/design/ui.md` § Milestones).
  #
  # **Nothing existing changes meaning.** Every ticket is in no milestone, ordered by its number,
  # and not on hold, so a node that never holds a ticket behaves as before.
  def up do
    create table(:milestones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :description, :text
      add :position, :integer, null: false, default: 0
      add :current, :boolean, null: false, default: false
      add :closed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Unique among the project's milestones, open or closed: a closed one keeps its name.
    create unique_index(:milestones, [:project_id, :name])

    # At most one current milestone per project, said by the database and not only by the code that
    # unmarks the old one first.
    create unique_index(:milestones, [:project_id],
             where: "current",
             name: :milestones_one_current_per_project
           )

    create constraint(:milestones, :milestones_current_is_open,
             check: "NOT (current AND closed_at IS NOT NULL)"
           )

    alter table(:tickets) do
      add :held_at, :utc_datetime
      add :held_transition, :map
      add :held_entry, :map
      add :milestone_id, references(:milestones, type: :binary_id, on_delete: :restrict)
      add :position, :integer, null: false, default: 0
    end

    execute "UPDATE tickets SET position = number", ""

    create index(:tickets, [:project_id, :milestone_id, :position])
  end

  def down do
    drop index(:tickets, [:project_id, :milestone_id, :position])

    alter table(:tickets) do
      remove :position
      remove :milestone_id
      remove :held_entry
      remove :held_transition
      remove :held_at
    end

    drop table(:milestones)
  end
end
