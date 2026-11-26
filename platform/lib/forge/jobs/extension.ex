defmodule Forge.Jobs.Extension do
  @moduledoc """
  What a person gave a job that ran out of budget (`docs/design/workflow-grammar-v1.md`
  § Extending a job): the tokens the reopened run may spend on top of what the job has used, its
  turns where the harness bounds them, the time its runs may take, and the note it reads first.

  Insert-only, in the database as well as here. The job's `spec` is never rewritten; the run that
  follows reads these figures in its place (`Forge.Jobs` builds its budget from them at assignment). The stop it extended is
  kept beside them, so how often jobs needed room — and which ceiling they hit — is a count over
  these rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Forge.Actor

  @type t :: %__MODULE__{}

  # A note, not a document (`docs/design/workflow-grammar-v1.md` § Extending a job).
  @note_limit 4_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "job_extensions" do
    field :tokens, :integer
    field :turns, :integer

    # How long the reopened run, and every later run of the job, may take, in milliseconds: what the
    # person gave, or the job's own limit where they left the box empty. Never null.
    field :timeout_ms, :integer
    field :note, :string
    field :exhausted, Ecto.Enum, values: [:turns, :tokens, :timeout]
    field :stopped_at, :utc_datetime
    field :usage_before, :integer
    field :turns_before, :integer
    field :runs_before, :integer

    belongs_to :job, Forge.Jobs.Job
    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The longest note, in characters."
  @spec note_limit() :: pos_integer()
  def note_limit, do: @note_limit

  @doc false
  def changeset(extension, attrs) do
    extension
    |> cast(attrs, [
      :job_id,
      :ticket_id,
      :user_id,
      :token_id,
      :tokens,
      :turns,
      :timeout_ms,
      :note,
      :exhausted,
      :stopped_at,
      :usage_before,
      :turns_before,
      :runs_before
    ])
    |> validate_required([:job_id, :ticket_id, :tokens, :timeout_ms])
    |> validate_number(:tokens, greater_than: 0)
    |> validate_number(:turns, greater_than: 0)
    |> validate_number(:timeout_ms, greater_than: 0)
    # `count: :codepoints` is an equivalent mutant: `Extensions.parse/2` refuses a note over the
    # limit first, counting codepoints, and graphemes are never more of them than codepoints, so
    # what passes the parser passes this either way. It is the database's own count, stated here.
    # `max:` is not one (the tests refuse a note one over it).
    |> validate_length(:note, max: @note_limit, count: :codepoints)
    |> Actor.validate_one_author()
    |> foreign_key_constraint(:job_id)
    |> foreign_key_constraint(:ticket_id)
    |> check_constraint(:user_id, name: :job_extensions_one_author)
  end
end
