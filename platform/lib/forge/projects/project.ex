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
    # How hard this project's work thinks when a state does not say. Nil means the machine's, the
    # same bottom of the same chain — `docs/design/workflow-grammar-v1.md` § Effort.
    field :effort, :string

    has_many :tickets, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime)
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_path, :default_branch, :seed_id, :model, :effort])
    |> validate_required([:name, :repo_path, :default_branch])
    |> validate_format(:name, ~r/\A[a-z0-9][a-z0-9_-]*\z/,
      message: "lowercase letters, digits, - or _"
    )
    # A branch name reaches `git config forge.defaultBranch`, `symbolic-ref HEAD` and the
    # pre-receive hook, so it is validated before any of them see it: without this a value like
    # `-rf`, `../evil` or one with a space is accepted and poisons the repository's HEAD and its
    # default-branch guard, or fails deep inside git as a 500.
    #
    # Two checks, and the second is the one that decides. The first is a narrow character set —
    # no whitespace, no shell metacharacters, no leading `-` — which is stricter than git and
    # only ever refuses more. The second asks git itself (`check-ref-format --branch`), because
    # a guard in front of git has to use git's model of a branch name: a hand-written copy of
    # its rules let `main.`, `trunk/.x`, `a.lock/b` and `HEAD` through, and each of them failed
    # inside `register/2` as an unexplained 500 (`docs/security/pentest-2026-09-20.md` F2).
    |> validate_format(:default_branch, ~r{^[A-Za-z0-9][A-Za-z0-9._/-]*$},
      message: "must be a valid git branch name"
    )
    |> validate_git_branch()
    # Not checked against a list of models: names change faster than the platform, and a
    # validator that knew them would refuse a model released last week. Emptiness is the only
    # thing that is certainly wrong — it would read as "set" and resolve to nothing.
    |> update_change(:model, &blank_to_nil/1)
    # Effort is unchecked for a stronger reason: the levels are the harness's and the platform is
    # meant to carry them to harnesses it does not know yet (§ Effort). Emptiness again is the
    # only thing certainly wrong.
    |> update_change(:effort, &blank_to_nil/1)
    |> unique_constraint(:name)
  end

  # Asked only once the format above has passed, and only of a name being changed.
  #
  # **Both conditions are equivalent mutants and must not have a test written for them.** Git
  # reads the operand after `--branch` as a name even when it looks like an option (`--branch -h`
  # is refused as a name, exit 128), so dropping the `has_key?` check only adds a subprocess and a
  # second copy of an error the changeset already carries. `get_change` rather than `get_field`
  # only spares asking git about a stored name it already accepted. Neither is observable.
  defp validate_git_branch(changeset) do
    with branch when is_binary(branch) <- get_change(changeset, :default_branch),
         false <- Keyword.has_key?(changeset.errors, :default_branch),
         {_out, code} when code != 0 <-
           System.cmd("git", ["check-ref-format", "--branch", branch], stderr_to_stdout: true) do
      add_error(changeset, :default_branch, "must be a valid git branch name")
    else
      _valid_or_already_refused -> changeset
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
