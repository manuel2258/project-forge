defmodule Forge.Repo.Migrations.Schedules do
  use Ecto.Migration

  # A workflow file may declare schedules (`docs/design/schedules.md`). What the file says is read
  # from the repository; this table is only what a person did about it and what came of it: who
  # switched a schedule on, the time it fires after, the ticket it last admitted, and its problem
  # with the open queue item that goes with it. **A schedule with no row is off**, so a project that
  # never switches one on has no row and the runner never reads its repository.
  #
  # A row is kept when a schedule is switched off or leaves the file, for its last ticket and its
  # history; it is "on" when `enabled_by_id` is set.
  def change do
    create table(:schedules, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      # Nil for the single `.forge/workflow.yml`, which has no types.
      add :ticket_type, :string
      add :name, :string, null: false
      # Who it admits in the name of, and since when. Nil for both is off.
      add :enabled_by_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :enabled_at, :utc_datetime
      # The cron line last read for it, which a file that stops parsing leaves it with, so that a
      # time can still come due and fail (`docs/design/schedules.md` § A file that does not read).
      add :cron, :string
      # Only times strictly after this are due; moved to the due time by every firing, success or
      # failure, in the same transaction as the admission.
      add :fires_after, :utc_datetime
      add :last_ticket_id, references(:tickets, type: :binary_id, on_delete: :nilify_all)
      add :problem, :text
      add :problem_kind, :string
      add :problem_at, :utc_datetime
      # Non-null is an open queue item (`docs/design/schedules.md` § Alerts).
      add :alerted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One row per schedule of a file; the single file's NULL type is one place, not many.
    create unique_index(:schedules, ["project_id", "coalesce(ticket_type, '')", "name"],
             name: :schedules_one_per_name
           )

    create index(:schedules, [:enabled_by_id])

    create constraint(:schedules, :schedules_on_is_whole,
             check:
               "(enabled_by_id IS NULL) = (enabled_at IS NULL) AND " <>
                 "(enabled_by_id IS NULL) = (fires_after IS NULL)"
           )

    create constraint(:schedules, :schedules_problem_is_whole,
             check:
               "(problem IS NULL) = (problem_kind IS NULL) AND (problem IS NULL) = (problem_at IS NULL)"
           )

    create constraint(:schedules, :schedules_alert_has_problem,
             check: "alerted_at IS NULL OR problem IS NOT NULL"
           )
  end
end
