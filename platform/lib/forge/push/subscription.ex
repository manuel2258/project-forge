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
    field :last_sent_at, :utc_datetime

    belongs_to :user, Forge.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:user_id, :endpoint, :p256dh, :auth])
    |> validate_required([:user_id, :endpoint, :p256dh, :auth])
    |> validate_endpoint()
    |> validate_key(:p256dh, 65)
    |> validate_key(:auth, 16)
    |> unique_constraint(:endpoint)
  end

  # An https URL with a host; the push library builds its audience from it.
  defp validate_endpoint(changeset) do
    validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      case URI.new(endpoint) do
        {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> []
        _ -> [endpoint: "must be an https URL with a host"]
      end
    end)
  end

  # Browser keys are base64url of fixed sizes; anything else would crash the encryption.
  defp validate_key(changeset, field, bytes) do
    validate_change(changeset, field, fn ^field, value ->
      case Base.url_decode64(value, padding: false) do
        {:ok, decoded} when byte_size(decoded) == bytes -> []
        _ -> [{field, "must be base64url of #{bytes} bytes"}]
      end
    end)
  end

  @doc "The JSON the push library expects, as the browser produced it."
  def to_json(%__MODULE__{} = s) do
    Jason.encode!(%{endpoint: s.endpoint, keys: %{p256dh: s.p256dh, auth: s.auth}})
  end
end
