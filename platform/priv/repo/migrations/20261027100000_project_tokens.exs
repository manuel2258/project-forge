defmodule Forge.Repo.Migrations.ProjectTokens do
  @moduledoc """
  A git token grows into a project token: one secret, two doors (git and the JSON API), each with
  its own permission, a name, who issued it, and which door used it last.

  `write` goes: `git_access` says what it said and more, and two columns describing one
  permission would disagree some day. `reader` is a read token and `branch` a write token for
  the one `ref` it names, so every row keeps meaning what it meant.

  Answers, approvals and proposal decisions can now be written by a token, so each gains a
  `token_id` and `user_id` becomes nullable, with a check that exactly one of the two is set. The
  foreign key is NO ACTION: a token that wrote something is the author of it and is not deletable
  while the row stands. (A project with tickets is not deletable either — `tickets.project_id` is
  restricted — so this adds no new way for a project deletion to fail.)
  """

  use Ecto.Migration

  @authored ~w(answers approvals proposal_decisions)a

  def up do
    alter table(:git_tokens) do
      add :name, :string
      add :git_access, :string
      add :api_access, :string, null: false, default: "none"
      add :issued_by_id, references(:users, on_delete: :nilify_all, type: :binary_id)
      add :last_used_via, :string
    end

    execute "UPDATE git_tokens SET git_access = CASE WHEN write THEN 'branch' ELSE 'reader' END"
    execute "UPDATE git_tokens SET name = 'earlier token' WHERE job_id IS NULL"
    execute "ALTER TABLE git_tokens ALTER COLUMN git_access SET NOT NULL"

    alter table(:git_tokens) do
      remove :write
    end

    create index(:git_tokens, [:issued_by_id])

    for table <- @authored do
      alter table(table) do
        add :token_id, references(:git_tokens, on_delete: :nothing, type: :binary_id)
        modify :user_id, :binary_id, null: true, from: {:binary_id, null: false}
      end

      create index(table, [:token_id])

      create constraint(table, "#{table}_one_author",
               check: "num_nonnulls(user_id, token_id) = 1"
             )
    end
  end

  def down do
    for table <- @authored do
      drop constraint(table, "#{table}_one_author")
      execute "DELETE FROM #{table} WHERE user_id IS NULL"

      alter table(table) do
        remove :token_id
        modify :user_id, :binary_id, null: false, from: {:binary_id, null: true}
      end
    end

    alter table(:git_tokens) do
      add :write, :boolean, null: false, default: false
    end

    execute "UPDATE git_tokens SET write = git_access IN ('branch', 'developer', 'admin')"

    alter table(:git_tokens) do
      remove :name
      remove :git_access
      remove :api_access
      remove :issued_by_id
      remove :last_used_via
    end
  end
end
