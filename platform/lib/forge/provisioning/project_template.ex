defmodule Forge.Provisioning.ProjectTemplate do
  @moduledoc """
  A template a project may have machines made from.

  The mirror of `docs/design/identity.md` § Workers' `project_worker`, and it inherits that
  note's rule unaltered: **the template's owner creates this row, and only for a project they
  are a member of.** A project admin cannot reach for someone else's template, because creating
  from it spends its owner's credential and the money stays with whoever spends it.

  The guard is in `Forge.Provisioning`, not here — a changeset can be bypassed and the rule is
  about the caller, not the row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_templates" do
    belongs_to :project, Forge.Projects.Project
    belongs_to :template, Forge.Provisioning.Template

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:project_id, :template_id])
    |> validate_required([:project_id, :template_id])
    |> unique_constraint([:project_id, :template_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:template_id)
  end
end
