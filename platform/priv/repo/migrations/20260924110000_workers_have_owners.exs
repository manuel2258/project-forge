defmodule Forge.Repo.Migrations.WorkersHaveOwners do
  @moduledoc """
  A machine has an owner, and reaches a project only because its owner said so.
  `docs/design/identity.md` § Workers and `docs/design/credentials.md` § Sequencing, step 3.

  **`workers.user_id` is nullable**, because rows exist that no rule can give an owner: a machine
  minted before any account, or on a node with more than one node admin and no template to say
  whose it was. Such a row takes no work — nothing can assign it to a project — and every row made
  from now on has one.

  ## The backfill, and what it keeps working

  Before this, every connected machine took any project's jobs. After it, a job runs only on a
  machine assigned to its project. So the backfill does for machines what
  `ProjectMembersAndEventProject` did for people: on a node with one operator, nothing visible
  changes.

  - A machine made from a template belongs to the template's owner, and reaches the projects its
    template is assigned to without a row of its own — that is read at placement.
  - Every other machine belongs to **the node admin, when there is exactly one**. More than one
    and the migration will not guess, which is `Forge.Accounts.owner_for/1`'s rule: guessing
    whose machine it is is guessing whose money it spends.
  - A machine that now has an owner and no template is assigned to every project that owner is a
    member of. Not to every project: an assignment to a project the owner is not in is the one
    thing the rule forbids, and a backfill that wrote one would be the platform breaking its own
    guard during a deploy.
  """

  use Ecto.Migration

  def up do
    alter table(:workers) do
      # Restrict: an account that owns a machine is not one that can be quietly deleted, and the
      # only accounts that can be deleted at all are ones that were never approved.
      add :user_id, references(:users, on_delete: :restrict, type: :binary_id)
    end

    create index(:workers, [:user_id])

    create table(:project_workers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, on_delete: :delete_all, type: :binary_id),
        null: false

      add :worker_id, references(:workers, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_workers, [:project_id, :worker_id])
    create index(:project_workers, [:worker_id])

    execute """
    UPDATE workers SET user_id = worker_templates.user_id
      FROM worker_templates WHERE workers.template_id = worker_templates.id
    """

    execute """
    UPDATE workers SET user_id = (SELECT id FROM users WHERE node_admin)
     WHERE user_id IS NULL AND (SELECT count(*) FROM users WHERE node_admin) = 1
    """

    execute """
    INSERT INTO project_workers (id, project_id, worker_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), m.project_id, w.id, NOW(), NOW()
      FROM workers w JOIN project_members m ON m.user_id = w.user_id
     WHERE w.template_id IS NULL AND w.status <> 'destroyed'
    """
  end

  def down do
    drop table(:project_workers)

    alter table(:workers) do
      remove :user_id
    end
  end
end
