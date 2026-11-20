defmodule Forge.Attachments.Attachment do
  @moduledoc """
  One file a person attached in one act, beside the blob version that holds its bytes
  (`docs/design/data-model.md`, `docs/design/attachments.md`).

  A row is never deleted and never edited, but for one thing: **withdrawing** sets the four
  `withdrawn_*` columns from null, once, and the database trigger says so. The version row is not
  touched, so `artifact_versions` stays append-only. A file that was attached and not received
  (its upload failed) has no version, name or size.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "attachments" do
    field :name, :string
    field :original_name, :string
    field :size, :integer
    field :to_kind, Ecto.Enum, values: [:ticket, :document, :message, :answer, :note]
    field :to_event_seq, :integer
    field :author, :map
    field :withdrawn_at, :utc_datetime_usec
    field :withdrawn_by, :map
    field :withdraw_reason, :string

    belongs_to :ticket, Forge.Tickets.Ticket
    belongs_to :job, Forge.Jobs.Job
    belongs_to :artifact_version, Forge.Artifacts.Version
    belongs_to :to_version, Forge.Artifacts.Version
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token
    belongs_to :withdrawn_user, Forge.Accounts.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @doc "Whether anything was received: false for a file that was attached and whose upload failed."
  @spec received?(t()) :: boolean()
  def received?(%__MODULE__{artifact_version_id: id}), do: is_binary(id)

  @doc "Whether it was withdrawn: its bytes are gone and its record is what is left."
  @spec withdrawn?(t()) :: boolean()
  def withdrawn?(%__MODULE__{withdrawn_at: at}), do: not is_nil(at)
end
