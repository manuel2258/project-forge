defmodule Forge.Repo.Migrations.ChatsMayBeSteps do
  @moduledoc """
  A conversation may carry a `state`: the workflow step it is (`docs/design/conversations.md`
  § A conversation that is a step). `jobs_kind_shape` loses the `state IS NULL` clause of a chat
  and keeps `spec IS NULL`; every other row is shaped as before.

  The partial unique index on `(ticket_id, state, attempt)` is `WHERE kind = 'workflow'` already,
  so a step conversation's visit number sits beside a job's attempt without meeting it.
  """

  use Ecto.Migration

  def up do
    drop constraint(:jobs, :jobs_kind_shape)

    create constraint(:jobs, :jobs_kind_shape,
             check: """
             (kind IN ('workflow', 'command') AND ticket_id IS NOT NULL AND state IS NOT NULL
               AND spec IS NOT NULL)
             OR
             (kind = 'chat' AND spec IS NULL AND (state IS NULL OR ticket_id IS NOT NULL))
             """
           )
  end

  # **Only from a node that has never run a chat step.** A step's conversation is named by events
  # that cannot be deleted (`events_append_only`), so this refuses rather than failing on the
  # constraint halfway through.
  def down do
    execute(fn ->
      %{rows: [[count]]} =
        repo().query!("SELECT count(*) FROM jobs WHERE kind = 'chat' AND state IS NOT NULL")

      if count > 0 do
        raise "cannot roll back past chat steps: #{count} step conversation(s) are on record"
      end
    end)

    drop constraint(:jobs, :jobs_kind_shape)

    create constraint(:jobs, :jobs_kind_shape,
             check: """
             (kind IN ('workflow', 'command') AND ticket_id IS NOT NULL AND state IS NOT NULL
               AND spec IS NOT NULL)
             OR
             (kind = 'chat' AND state IS NULL AND spec IS NULL)
             """
           )
  end
end
