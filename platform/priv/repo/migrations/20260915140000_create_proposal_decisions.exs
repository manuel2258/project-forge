defmodule Forge.Repo.Migrations.CreateProposalDecisions do
  @moduledoc """
  A decision on one ticket proposal — `docs/design/ticket-proposals.md` § Deciding.

  Its own table rather than a row in `approvals`, and that is the whole point of it.
  `approvals.transition` is required and validated as `%{from, to}` because an approval
  authorises an edge in a statechart: the engine reads it against a ticket's
  `pending_transition`, and that is all it is for. A proposal has no ticket, no pending
  transition and no edge — what it authorises is admission. Making that column nullable to fit
  one in would hand the engine rows it must never act on, in the one table whose purpose is
  saying which edges are authorised.

  `ticket_id` is set when the decision accepted the proposal, which makes provenance a foreign
  key in both directions rather than a payload field to be dug out of the event log.

  The unique index on `artifact_version_id` is what "open while the latest version has no
  decision" rests on: a version is decided once. A newer version — the operator rewriting a
  verbose title — has no decision until it gets one, exactly as `docs/design/data-model.md`
  says of approvals.
  """

  use Ecto.Migration

  def change do
    create table(:proposal_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :artifact_version_id,
          references(:artifact_versions, on_delete: :restrict, type: :binary_id),
          null: false

      add :user_id, references(:users, on_delete: :restrict, type: :binary_id), null: false
      add :ticket_id, references(:tickets, on_delete: :nilify_all, type: :binary_id)
      add :decision, :string, null: false
      add :comment, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:proposal_decisions, [:artifact_version_id])
    create index(:proposal_decisions, [:ticket_id])

    create constraint(:proposal_decisions, :proposal_decisions_accepted_has_ticket,
             check: "decision <> 'accepted' OR ticket_id IS NOT NULL"
           )
  end
end
