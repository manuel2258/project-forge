defmodule Forge.Credentials.Credential do
  @moduledoc """
  A secret an agent authenticates with, and the person who owns it.
  `docs/design/credentials.md` § What a credential is.

  **The secret is never loaded by an ordinary query.** `load_in_query: false` means a struct from
  `Repo.all/1` or `Repo.get/2` does not carry even the ciphertext, and `redact: true` means
  `inspect/1` leaves the field out on the one path that does select it. A page listing
  credentials therefore holds nothing secret in its assigns as a consequence of the query rather
  than of anybody's care — which is the only kind of guarantee that survives the next edit.

  The plaintext never enters a changeset either: `create_changeset/2` seals it on the way in, so
  a changeset that is logged, returned or inspected carries ciphertext at worst, and `inspect/1`
  leaves even that out.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Forge.Provisioning.Vault

  # Associated data of this table's own, so a provider credential's ciphertext does not open here
  # and this table's does not open there (`Forge.Provisioning.Vault.seal/2`).
  @label "forge/credentials/v1"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credentials" do
    belongs_to :user, Forge.Accounts.User
    field :name, :string
    field :harness, :string
    field :kind, :string
    field :secret, :string, redact: true, load_in_query: false
    field :daily_limit_usd, :decimal
    field :models, {:array, :map}
    field :checked_at, :utc_datetime
    field :check_error, :string
    field :revoked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  A new credential, with its secret sealed.

  `secret` is the plaintext string a person typed and is never cast: it is sealed here and the
  ciphertext is the only form the changeset carries. A harness this node does not know, or a kind
  that harness does not take, is refused where it was chosen rather than at the first job that
  tries to use it.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(credential, attrs) do
    {secret, attrs} = pop_secret(attrs)

    credential
    |> cast(attrs, [:user_id, :name, :harness, :kind, :daily_limit_usd])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:user_id, :name, :harness, :kind])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_number(:daily_limit_usd, greater_than: 0)
    |> validate_kind()
    |> put_secret(secret)
    |> unique_constraint(:name,
      name: :credentials_live_name_index,
      message: "is already one of your credentials"
    )
    |> check_constraint(:secret, name: :secret_until_revoked)
    |> foreign_key_constraint(:user_id)
  end

  # The kind is checked against the harness it is for, which is also how an unknown harness is
  # found: a harness this node has no driver for takes no kinds at all.
  defp validate_kind(changeset) do
    harness = get_field(changeset, :harness)

    case Forge.Harness.driver(harness) do
      {:error, :unknown_harness} ->
        add_error(changeset, :harness, "is not a harness this node knows")

      {:ok, driver} ->
        validate_inclusion(changeset, :kind, Enum.map(driver.kinds(), &elem(&1, 0)),
          message: "is not a kind of secret #{driver.label()} takes"
        )
    end
  end

  defp pop_secret(attrs) do
    case Map.pop(attrs, :secret) do
      {nil, attrs} -> Map.pop(attrs, "secret")
      {secret, attrs} -> {secret, attrs}
    end
  end

  # Whitespace is trimmed because a pasted token picks up a newline more often than not, and a
  # token with one in it is refused by the provider with a message that does not say why.
  defp put_secret(changeset, secret) when is_binary(secret) do
    case String.trim(secret) do
      "" -> add_error(changeset, :secret, "is required")
      token -> put_change(changeset, :secret, seal(token))
    end
  end

  defp put_secret(changeset, _secret), do: add_error(changeset, :secret, "is required")

  @doc "Seals a secret for this table."
  @spec seal(String.t()) :: String.t()
  def seal(token) when is_binary(token), do: Vault.seal(%{"token" => token}, @label)

  @doc """
  Opens a sealed secret, or `:error` when it cannot be — a rotated `secret_key_base`, a revoked
  row whose secret is gone, or ciphertext from another table.
  """
  @spec open(String.t() | nil) :: {:ok, map()} | :error
  def open(sealed), do: Vault.open(sealed, @label)
end
