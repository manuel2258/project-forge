defmodule Forge.Credentials.ProjectCredential do
  @moduledoc """
  A credential in a project's pool: a job in the project may spend it.

  `docs/design/credentials.md` § The pool: **the credential's owner creates this row, and only for
  a project they are a member of.** A project admin cannot reach for somebody else's credential;
  the owner decides which projects their money funds. The guard is `Forge.Credentials.assign/3`'s
  — a changeset can be bypassed, and the rule is about the caller.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_credentials" do
    belongs_to :project, Forge.Projects.Project
    belongs_to :credential, Forge.Credentials.Credential

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:project_id, :credential_id])
    |> validate_required([:project_id, :credential_id])
    |> unique_constraint([:project_id, :credential_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:credential_id)
  end
end
