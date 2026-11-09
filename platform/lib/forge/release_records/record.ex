defmodule Forge.ReleaseRecords.Record do
  @moduledoc """
  One release that ended `done`, as it was when it did (`docs/design/ticket-types.md` § The record,
  the tag, the history). Written once; there is no changeset for an update and no `updated_at`.

  `files` and `links` are lists of maps with string keys, as they come back from the database:
  `%{"name", "version", "size"}` names an exact artifact version of the ticket, and
  `%{"label", "url", "document", "version"}` a link from one.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "release_records" do
    field :version, :string
    field :concluded_at, :utc_datetime_usec
    field :commit_sha, :string
    field :notes, :string
    field :notes_document, :string
    field :notes_version, :integer
    field :files, {:array, :map}, default: []
    field :links, {:array, :map}, default: []
    field :tag_name, :string
    field :tag_status, Ecto.Enum, values: [:tagged, :taken, :failed, :no_version]
    field :tag_detail, :string

    belongs_to :project, Forge.Projects.Project
    belongs_to :ticket, Forge.Tickets.Ticket

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
