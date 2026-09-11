defmodule Forge.Artifacts.Approval do
  @moduledoc """
  A decision on one artifact version for one transition. `transition` is
  `%{"from" => state, "to" => state}`. A newer version has no approval until it gets one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "approvals" do
    field :decision, Ecto.Enum, values: [:approved, :rejected]
    field :comment, :string
    field :transition, :map

    belongs_to :artifact_version, Forge.Artifacts.Version
    belongs_to :user, Forge.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:artifact_version_id, :user_id, :decision, :comment, :transition])
    |> validate_required([:artifact_version_id, :user_id, :decision, :transition])
    |> validate_transition()
    |> foreign_key_constraint(:artifact_version_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_transition(changeset) do
    case get_field(changeset, :transition) do
      %{"from" => from, "to" => to} when is_binary(from) and is_binary(to) -> changeset
      _ -> add_error(changeset, :transition, "must be %{from: state, to: state}")
    end
  end
end
