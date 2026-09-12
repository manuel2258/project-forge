defmodule Forge.Push.Subscription do
  @moduledoc "A browser's push subscription for one user. One row per endpoint."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string, redact: true
    field :auth, :string, redact: true
    field :user_agent, :string
    field :last_sent_at, :utc_datetime

    belongs_to :user, Forge.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> validate_format(:endpoint, ~r{^https://}, message: "must be an https URL")
    |> unique_constraint(:endpoint)
  end

  @doc "The JSON the push library expects, as the browser produced it."
  def to_json(%__MODULE__{} = s) do
    Jason.encode!(%{endpoint: s.endpoint, keys: %{p256dh: s.p256dh, auth: s.auth}})
  end
end
