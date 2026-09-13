defmodule Forge.Projects.Project do
  @moduledoc "A repository the platform hosts and runs tickets against."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "projects" do
    field :name, :string
    field :repo_path, :string
    field :default_branch, :string, default: "main"
    # The warm starting point a worker snapshots a job's worktree from, or nil when nobody has
    # published one. See docs/design/worker-tier.md § Volumes and the seed.
    field :seed_id, :string

    has_many :tickets, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :default_branch, :seed_id])
    |> validate_required([:name, :repo_path, :default_branch])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "lowercase letters, digits, - or _"
    )
    |> unique_constraint(:name)
  end
end
