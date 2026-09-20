defmodule Forge.Provisioning.Credential do
  @moduledoc """
  A provider account a user owns, and the secret that reaches it.

  `docs/design/identity.md` § A provider credential is a second thing, not a second kind says
  why this is not a `kind` on that note's `credential`: machine spend is not a query over jobs.

  The secret is a map whose shape the driver owns — one token for Hetzner, a key pair
  elsewhere — encrypted by `Forge.Provisioning.Vault` before it is stored and never selected
  back into anything that is rendered.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Forge.Provisioning.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "provider_credentials" do
    belongs_to :user, Forge.Accounts.User
    field :name, :string
    field :provider, :string
    field :secret, :string, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a credential, sealing the secret on the way in.

  `secret` is a map and is never cast: it is encrypted here and the ciphertext is what the
  changeset carries, so a secret cannot reach the database in the clear by any route that goes
  through a changeset — which is every route there is.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credential, attrs) do
    {secret, attrs} = pop_secret(attrs)

    credential
    |> cast(attrs, [:user_id, :name, :provider])
    |> validate_required([:user_id, :name, :provider])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_provider()
    |> put_secret(secret)
    |> validate_required([:secret])
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
  end

  @type t :: %__MODULE__{}

  # A provider this node cannot speak to is a credential that can never be used, and the error
  # belongs where the name was typed rather than at the first create it is asked for.
  #
  # **A provider that takes no credential cannot have one either**, and that is a rule rather
  # than a hidden form: the local driver reaches its machines without an account, so a local
  # credential would be a row holding an empty secret that nothing could ever spend. Without
  # this the failure is `secret is required` on a form with no fields in it, which reads as a
  # bug in the form rather than as a category that does not exist.
  defp validate_provider(changeset) do
    validate_change(changeset, :provider, fn :provider, provider ->
      provider |> Forge.Provider.driver() |> provider_error()
    end)
  end

  defp provider_error({:error, {:unknown_provider, _name}}),
    do: [provider: "is not a provider this node knows"]

  defp provider_error({:ok, driver}) do
    case driver.credential_fields() do
      [] -> [provider: "needs no credential"]
      _fields -> []
    end
  end

  defp pop_secret(attrs) do
    case Map.pop(attrs, :secret) do
      {nil, attrs} -> Map.pop(attrs, "secret")
      {secret, attrs} -> {secret, attrs}
    end
  end

  # An empty map is not a secret. Without this a credential could be saved with nothing in it
  # and would fail at the provider, which is a long way from where the mistake was made.
  defp put_secret(changeset, secret) when is_map(secret) and map_size(secret) > 0 do
    case Enum.reject(Map.values(secret), &(is_binary(&1) and &1 != "")) do
      [] -> put_change(changeset, :secret, Vault.seal(secret))
      _blank -> add_error(changeset, :secret, "must not have blank fields")
    end
  end

  defp put_secret(%Ecto.Changeset{data: %{secret: sealed}} = changeset, nil)
       when is_binary(sealed),
       do: changeset

  defp put_secret(changeset, _secret),
    do: add_error(changeset, :secret, "is required")

  @doc "The secret, decrypted, or `:error` when the key that sealed it is gone."
  @spec secret(t()) :: {:ok, map()} | :error
  def secret(%__MODULE__{secret: sealed}), do: Vault.open(sealed)
end
