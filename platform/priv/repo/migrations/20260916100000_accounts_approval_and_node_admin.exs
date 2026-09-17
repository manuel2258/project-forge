defmodule Forge.Repo.Migrations.AccountsApprovalAndNodeAdmin do
  @moduledoc """
  Who is let into the building — `docs/design/identity.md` § Approval.

  `users.role` goes. It was an Ecto.Enum of `operator | approver | promoter | spender` read in
  exactly one place, `GET /api/v1/me`, which echoed it back: a decorative column in front of a
  real audit trail. What replaces it is not a bigger enum but two different questions. Whether
  an account may act at all (`approved_at`, `suspended_at`) is node-level and belongs here.
  What it may reach is per project and belongs in `project_members`.

  `node_admin` is the one global role that survives, and it governs accounts only: approve,
  suspend, promote. It grants no access to any project.

  Every user that exists when this runs is the operator, so it is approved and a node admin —
  otherwise the migration locks the only person out of their own machine.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      add :node_admin, :boolean, null: false, default: false
      add :approved_at, :utc_datetime
      add :suspended_at, :utc_datetime
    end

    execute "UPDATE users SET node_admin = true, approved_at = NOW()"

    alter table(:users) do
      remove :role
    end

    create index(:users, [:approved_at])
  end

  def down do
    alter table(:users) do
      add :role, :string, null: false, default: "operator"
      remove :node_admin
      remove :approved_at
      remove :suspended_at
    end
  end
end
