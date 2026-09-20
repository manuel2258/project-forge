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
    # What this project's work runs on when a state does not say. Nil means the machine's, which
    # is the platform-wide setting — `docs/design/workflow-grammar-v1.md` § Model.
    field :model, :string

    has_many :tickets, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :default_branch, :seed_id, :model])
    |> validate_required([:name, :repo_path, :default_branch])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "lowercase letters, digits, - or _"
    )
    # A branch name reaches `git config forge.defaultBranch`, `symbolic-ref HEAD` and the
    # pre-receive hook, so it is validated before any of them see it: without this a value like
    # `-rf`, `../evil` or one with a space is accepted and poisons the repository's HEAD and its
    # default-branch guard, or fails deep inside git as a 500. This is git's ref-name shape,
    # conservatively: it allows `release/1.0` and rejects a leading `-`, `..`, `//`, a trailing
    # `/` or `.lock`, and whitespace or shell metacharacters.
    |> validate_format(:default_branch, ~r{^[A-Za-z0-9][A-Za-z0-9._/-]*$},
      message: "must be a valid git branch name"
    )
    |> validate_change(:default_branch, fn :default_branch, branch ->
      if String.contains?(branch, "..") or String.contains?(branch, "//") or
           String.ends_with?(branch, "/") or String.ends_with?(branch, ".lock") do
        [default_branch: "must be a valid git branch name"]
      else
        []
      end
    end)
    # Not checked against a list of models: names change faster than the platform, and a
    # validator that knew them would refuse a model released last week. Emptiness is the only
    # thing that is certainly wrong — it would read as "set" and resolve to nothing.
    |> update_change(:model, &blank_to_nil/1)
    |> unique_constraint(:name)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(model) do
    case String.trim(model) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
