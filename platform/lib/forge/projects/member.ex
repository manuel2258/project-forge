defmodule Forge.Projects.Member do
  @moduledoc """
  One person's place in one project — `docs/design/identity.md` § Projects and members.

  Two roles. `admin` is project settings, deletion and membership; `member` is everything else
  the product does, which is most of it: admit tickets, answer questions, approve transitions
  and merges, edit documents, open conversations, decide proposals.

  Nothing reads this field by name. `Forge.Access` expands it into capabilities and callers ask
  for one of those, so splitting the roles later is a change to one function.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_members" do
    field :role, Ecto.Enum, values: [:admin, :member]

    belongs_to :project, Forge.Projects.Project
    belongs_to :user, Forge.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
  @type role :: :admin | :member

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:project_id, :user_id, :role])
    |> validate_required([:project_id, :user_id, :role])
    |> unique_constraint([:project_id, :user_id])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end
end
