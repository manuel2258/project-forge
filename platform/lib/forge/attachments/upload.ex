defmodule Forge.Attachments.Upload do
  @moduledoc """
  A file a person uploaded that no act has claimed yet: its bytes are in the store under
  `upload/<id>` and this row says whose they are. Nothing counts it, no agent is handed it, and
  `Forge.Attachments.Sweeper` deletes the ones nobody sent (`docs/design/attachments.md` § Staging,
  claiming and the sweep).
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "attachment_uploads" do
    field :key, :string
    field :original_name, :string
    field :size, :integer
    field :content_hash, :string

    belongs_to :project, Forge.Projects.Project
    belongs_to :user, Forge.Accounts.User
    belongs_to :token, Forge.Git.Token

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
