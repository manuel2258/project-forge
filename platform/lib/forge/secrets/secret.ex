defmodule Forge.Secrets.Secret do
  @moduledoc """
  A value a project's jobs may be handed and the platform never uses.
  `docs/design/secrets.md` § What a secret is.

  **The value is never loaded by an ordinary query**, exactly as an inference credential's secret
  is not (`Forge.Credentials.Credential`): `load_in_query: false` keeps even the ciphertext out of
  a struct from `Repo.all/1`, and `redact: true` keeps it out of `inspect/1` should a struct ever
  carry it. The readers select the column by name, as a bare string. A page listing secrets holds
  nothing secret in its assigns because of the query, not because of anybody's care.

  The plaintext never enters a changeset either: `changeset/3` seals it on the way in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Forge.Provisioning.Vault

  # Associated data of this table's own, so a credential's ciphertext pasted into this column does
  # not open here and this table's does not open there (`Forge.Provisioning.Vault.seal/2`).
  @label "forge/secrets/v1"

  # The kernel holds one environment string to 128 KiB (`MAX_ARG_STRLEN`), and a job's process
  # holds all of its secrets in its environment at once; a quarter of that is room for any key
  # that exists.
  @max_bytes 32 * 1024

  # A value shorter than this cannot be masked without mangling everything around it
  # (`secrets.md` § Masking), and a credential that short is not one. Characters, because that is
  # what a person counts; the ceiling above is bytes, because that is what the kernel counts.
  @min_length 8

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_secrets" do
    belongs_to :project, Forge.Projects.Project
    belongs_to :set_by, Forge.Accounts.User
    field :name, :string
    field :value, :string, redact: true, load_in_query: false
    field :version, :integer, default: 1
    field :set_at, :utc_datetime
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  A secret set — a new one, or a new version of a live one — with its value sealed.

  `value` is what a person typed and is never cast: it is checked, sealed here, and the
  ciphertext is the only form the changeset carries. The name is checked on every set, not only
  the first, so a name that has since become reserved cannot be given a new value.
  """
  @spec changeset(t(), map(), term()) :: Ecto.Changeset.t()
  def changeset(secret, attrs, value) do
    secret
    |> cast(attrs, [:project_id, :name, :version, :set_by_id, :set_at])
    |> validate_required([:project_id, :name, :version, :set_at])
    |> validate_name()
    |> put_value(value)
    |> unique_constraint(:name,
      name: :project_secrets_live_name_index,
      message: "was set by somebody else at the same moment; set it again"
    )
  end

  defp validate_name(changeset) do
    case ForgeCore.Secret.validate_name(get_field(changeset, :name)) do
      :ok ->
        changeset

      {:error, :format} ->
        add_error(
          changeset,
          :name,
          "must be upper case: letters, digits and _, starting with a letter"
        )

      {:error, :reserved} ->
        add_error(changeset, :name, "is reserved: a job's environment needs it for itself")
    end
  end

  defp put_value(changeset, value) when is_binary(value) do
    value = normalise(value)

    cond do
      String.contains?(value, <<0>>) ->
        add_error(changeset, :value, "cannot contain a NUL byte; no environment can carry one")

      String.length(value) < @min_length ->
        add_error(changeset, :value, "must be at least #{@min_length} characters")

      byte_size(value) > @max_bytes ->
        add_error(changeset, :value, "must be at most 32 KiB")

      true ->
        put_change(changeset, :value, seal(value))
    end
  end

  defp put_value(changeset, _value), do: add_error(changeset, :value, "is required")

  # A browser submits a textarea's line breaks as CRLF, and a key file with carriage returns in it
  # is one no tool reads. The ends are trimmed because a pasted token picks up a newline more often
  # than not; a key that needs a final newline gets one from the script that writes it to a file.
  defp normalise(value), do: value |> String.replace("\r\n", "\n") |> String.trim()

  @doc "Seals a value for this table."
  @spec seal(String.t()) :: String.t()
  def seal(value) when is_binary(value), do: Vault.seal(%{"value" => value}, @label)

  @doc """
  Opens a sealed value, or `:error` when it cannot be — a rotated `secret_key_base`, a deleted
  row whose value is gone, or ciphertext from another table.
  """
  @spec open(String.t() | nil) :: {:ok, String.t()} | :error
  def open(sealed) do
    case Vault.open(sealed, @label) do
      {:ok, %{"value" => value}} when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end
end
