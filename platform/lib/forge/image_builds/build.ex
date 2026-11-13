defmodule Forge.ImageBuilds.Build do
  @moduledoc """
  One attempt to put the release's worker image into a provider account
  (`docs/design/provisioning.md` § Putting the release's image into an account).

  A row exists so that a restart carries on, so that two jobs share one build (the partial unique
  index on `(provider_credential_id, build) WHERE status = 'running'`), and so that the
  credential's owner can read what happened. `handle` is the driver's and is stored unread.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "worker_image_builds" do
    belongs_to :provider_credential, Forge.Provisioning.Credential
    field :build, :string
    field :version, :string
    field :protocol, :integer
    field :status, Ecto.Enum, values: [:running, :built, :failed, :abandoned], default: :running
    field :message, :string
    field :image_id, :string
    field :handle, :map
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    belongs_to :started_by_user, Forge.Accounts.User
    belongs_to :started_by_template, Forge.Provisioning.Template
    field :template_name, :string

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}
end
