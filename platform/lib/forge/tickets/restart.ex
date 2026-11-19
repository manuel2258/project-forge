defmodule Forge.Tickets.Restart do
  @moduledoc """
  A person running a ticket's state again (`docs/design/workflow-grammar-v1.md` § Running a state
  again): who, which state, and the note the new attempt arrives with. Insert-only.

  The jobs it made name it (`jobs.restart_id`), which is how the ledger tells an attempt a person
  restarted from one a transition sent back.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Forge.Actor

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ticket_restarts" do
    field :state, :string
    field :note, :string

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(restart, attrs) do
    restart
    |> cast(attrs, [:ticket_id, :state, :user_id, :token_id, :note])
    |> validate_required([:ticket_id, :state])
    # Equivalent to `Extensions.parse_restart/1`, which refuses a note over the limit before a
    # record is built, counting the same codepoints; kept as the schema's own statement of the
    # limit, the way the database's `char_length` check is.
    |> validate_length(:note, max: Forge.Jobs.Extension.note_limit(), count: :codepoints)
    |> Actor.validate_one_author()
    |> foreign_key_constraint(:ticket_id)
    |> check_constraint(:user_id, name: :ticket_restarts_one_author)
  end
end
