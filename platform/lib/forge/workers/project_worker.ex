defmodule Forge.Workers.ProjectWorker do
  @moduledoc """
  A permanent machine a project may run its jobs on.

  `docs/design/identity.md` § Workers: **the machine's owner creates this row, and only for a
  project they are a member of.** A project admin cannot reach for somebody else's machine,
  because the machine is paid for by its owner and the money stays with whoever spends it.

  A machine made from a template has no rows here. It reaches the projects its template is
  assigned to, read when a job is placed, so unassigning the template stops its machines taking
  more of that project's work at once (`Forge.Workers.assignable/2`).

  The guard is in `Forge.Workers`, not here — a changeset can be bypassed and the rule is about
  the caller, not the row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_workers" do
    belongs_to :project, Forge.Projects.Project
    belongs_to :worker, Forge.Workers.Worker

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:project_id, :worker_id])
    |> validate_required([:project_id, :worker_id])
    |> unique_constraint([:project_id, :worker_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:worker_id)
  end
end
