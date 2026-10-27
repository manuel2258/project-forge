defmodule Forge.Repo.Migrations.EffortPerProjectAndChat do
  @moduledoc """
  How hard the work thinks, where it can differ.

  The second dial beside `model`, and the same two columns for the same reason: a workflow state
  says its own in `.forge/workflows/<type>.yml`, which is in the repository and needs no column.
  What needs one is what the repository cannot say — a project's default, and the effort a
  particular conversation was opened with.

  Both are nullable, and null is not "no effort" — it is "the one below in the chain": a state's,
  then the project's, then whatever the machine was built with. Every row written before this
  migration reads as null, which is why nothing that already exists changes behaviour.
  """

  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :effort, :string
    end

    alter table(:jobs) do
      add :effort, :string
    end
  end
end
