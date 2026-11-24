defmodule Forge.Repo.Migrations.WarmBuilds do
  use Ecto.Migration

  # A ticket's warm build (`docs/design/worker-tier.md` § The command copy, `data-model.md`).
  #
  # **Breaking only in that it is a migration.** Nothing changes meaning: `tickets.warm_epoch`
  # starts at 0 and only a clear raises it, and every column on `jobs` is null for the jobs that
  # exist and for any command run by a worker that does not report the facts.
  #
  # `jobs.warm_epoch` is the ticket's epoch when the command was assigned, so a copy kept by a
  # command assigned before a clear is told from one kept after it. `warm_source` is where its
  # tree came from, `warm_from_id` the command that left the copy it started from, `warm_kept`
  # whether its build became the ticket's copy, `warm_unkept` why not, `warm_size` the copy's bytes.
  def change do
    alter table(:tickets) do
      add :warm_epoch, :integer, null: false, default: 0
    end

    alter table(:jobs) do
      add :warm_epoch, :integer
      add :warm_source, :string
      add :warm_from_id, references(:jobs, type: :binary_id, on_delete: :nilify_all)
      add :warm_kept, :boolean
      add :warm_unkept, :string
      add :warm_size, :bigint
    end

    # What `Forge.WarmBuilds.current/1` reads: a ticket's kept commands, newest first.
    create index(:jobs, [:ticket_id, :finished_at],
             where: "warm_kept",
             name: :jobs_warm_kept_index
           )
  end
end
