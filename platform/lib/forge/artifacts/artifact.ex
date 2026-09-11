defmodule Forge.Artifacts.Artifact do
  @moduledoc """
  A named artifact of a ticket. Holds no content: every write is a new `Version`.
  Unique per ticket and name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "artifacts" do
    field :name, :string
    field :kind, Ecto.Enum, values: [:document, :blob, :presentation]

    belongs_to :ticket, Forge.Tickets.Ticket
    has_many :versions, Forge.Artifacts.Version

    timestamps(type: :utc_datetime)
  end

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:ticket_id, :name, :kind])
    |> validate_required([:ticket_id, :name, :kind])
    |> foreign_key_constraint(:ticket_id)
    |> unique_constraint([:ticket_id, :name])
  end
end
