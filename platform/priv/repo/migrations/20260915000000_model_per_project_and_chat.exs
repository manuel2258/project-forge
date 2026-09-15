defmodule Forge.Repo.Migrations.ModelPerProjectAndChat do
  @moduledoc """
  Which model the work runs on, where it can differ.

  A workflow state says its own in `.forge/workflow.yml`, which is in the repository and needs no
  column. What needs one is the two things the repository cannot say: a project's default, and
  the model a particular conversation was opened with.

  Both are nullable, and null is not "no model" — it is "the one below in the chain": a state's,
  then the project's, then whatever the machine was built with.
  """

  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :model, :string
    end

    alter table(:jobs) do
      add :model, :string
    end
  end
end
