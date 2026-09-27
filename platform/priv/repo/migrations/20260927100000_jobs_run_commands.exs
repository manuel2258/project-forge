defmodule Forge.Repo.Migrations.JobsRunCommands do
  @moduledoc """
  A command invocation is a job of a third kind (`docs/design/commands.md` § An invocation is a
  job).

  - `jobs_kind_shape` gains a `command` row, shaped like a workflow row: a ticket, the invoking
    state and a spec. The partial unique index on `(ticket_id, state, attempt)` stays over
    workflow rows only, because a batch of two commands entered together has one state.
  - `jobs.exit_status` is a command's status, null for every other kind and for a command that
    ended without one — its timeout, a slice that could not be made.
  - An index over command rows by ticket: a ticket's commands, a batch's state and a command's
    next attempt are each asked per ticket, and without it each scans every command on the node.

  `parked` needs nothing here: `jobs.status` is a string the schema's enum reads.
  """

  use Ecto.Migration

  def up do
    alter table(:jobs) do
      add :exit_status, :integer
    end

    drop constraint(:jobs, :jobs_kind_shape)

    create constraint(:jobs, :jobs_kind_shape,
             check: """
             (kind IN ('workflow', 'command') AND ticket_id IS NOT NULL AND state IS NOT NULL
               AND spec IS NOT NULL)
             OR
             (kind = 'chat' AND state IS NULL AND spec IS NULL)
             """
           )

    create index(:jobs, [:ticket_id, :state],
             where: "kind = 'command'",
             name: :jobs_commands_on_ticket_index
           )
  end

  # **Only from a node that has never run a command.** A command's events name it, and the event
  # log is append-only (`events_append_only`): going back would mean deleting history the
  # platform promises to keep, so this refuses and says why rather than failing on the foreign
  # key halfway through.
  def down do
    execute(fn ->
      %{rows: [[count]]} =
        repo().query!("SELECT count(*) FROM jobs WHERE kind = 'command' OR status = 'parked'")

      if count > 0 do
        raise "cannot roll back past commands: #{count} command or parked job(s) are on record, " <>
                "and the events that name them cannot be deleted"
      end
    end)

    drop_if_exists index(:jobs, [:ticket_id, :state], name: :jobs_commands_on_ticket_index)
    drop constraint(:jobs, :jobs_kind_shape)

    create constraint(:jobs, :jobs_kind_shape,
             check: """
             (kind = 'workflow' AND ticket_id IS NOT NULL AND state IS NOT NULL AND spec IS NOT NULL)
             OR
             (kind = 'chat' AND state IS NULL AND spec IS NULL)
             """
           )

    alter table(:jobs) do
      remove :exit_status
    end
  end
end
