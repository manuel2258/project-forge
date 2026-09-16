defmodule Forge.Proposals.Decision do
  @moduledoc """
  A person accepting or declining one version of a ticket proposal.

  Not a `Forge.Artifacts.Approval`, and the difference is not cosmetic: an approval authorises
  a transition and is read by the engine against a ticket's `pending_transition`. A proposal has
  no transition to be on. See `docs/design/ticket-proposals.md` § Deciding.

  `ticket_id` is the ticket admission created, present exactly when the decision accepted.
  A decline records nothing to point at — and it still has to be recorded, because without it
  the next job proposes the same thing, and the one after that.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "proposal_decisions" do
    field :decision, Ecto.Enum, values: [:accepted, :declined]
    field :comment, :string

    belongs_to :artifact_version, Forge.Artifacts.Version
    belongs_to :user, Forge.Accounts.User
    belongs_to :ticket, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [:artifact_version_id, :user_id, :ticket_id, :decision, :comment])
    |> validate_required([:artifact_version_id, :user_id, :decision])
    |> validate_ticket()
    |> unique_constraint(:artifact_version_id)
    |> check_constraint(:ticket_id, name: :proposal_decisions_accepted_has_ticket)
    |> foreign_key_constraint(:artifact_version_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:ticket_id)
  end

  # An acceptance that recorded no ticket would be a proposal that is no longer open and no
  # longer anywhere: the work it described would have left the product without becoming
  # anything. The database says the same thing, because this changeset is not the only writer.
  defp validate_ticket(changeset) do
    case {get_field(changeset, :decision), get_field(changeset, :ticket_id)} do
      {:accepted, nil} -> add_error(changeset, :ticket_id, "an accepted proposal became a ticket")
      _other -> changeset
    end
  end
end
