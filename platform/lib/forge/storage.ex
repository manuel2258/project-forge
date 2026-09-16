defmodule Forge.Storage do
  @moduledoc """
  Bytes the database does not hold: artifact blobs and worker seeds. One behaviour, one
  implementation (a directory on this host, `Forge.Storage.Local`). A second, S3-compatible one
  would go behind the same callbacks; it is not scheduled, and `docs/design/storage.md`
  § What would move this to S3 says what would change that. The behaviour is what keeps the
  option cheap rather than what promises to use it.

  Both a byte form and a path form exist deliberately: a transcript is small and wants
  `get/1`, a seed is hundreds of megabytes and must never pass through a binary. There is
  no callback that returns a path — that is what would make the S3 implementation
  impossible, and what would quietly reintroduce the assumption that the platform and the
  worker share a disk.
  """

  alias Forge.Storage.Key

  @type key :: String.t()
  @type info :: %{size: non_neg_integer(), hash: String.t()}
  @type source :: {:file, Path.t()} | iodata()

  @doc "Writes `source` at `key`. Fails with `:exists` rather than overwriting a blob."
  @callback put(key(), source(), keyword()) :: {:ok, info()} | {:error, :exists | term()}
  @callback get(key()) :: {:ok, binary()} | {:error, :not_found | term()}
  @doc "Writes the object at `key` to `path`, without holding it in memory."
  @callback fetch(key(), Path.t()) :: {:ok, info()} | {:error, :not_found | term()}
  @callback stat(key()) :: {:ok, info()} | {:error, :not_found}
  @callback delete(key()) :: :ok | {:error, term()}

  @uri_scheme "store:"

  @spec put(key(), source(), keyword()) :: {:ok, info()} | {:error, term()}
  def put(key, source, opts \\ []) do
    with {:ok, key} <- Key.validate(key), do: impl().put(key, source, opts)
  end

  @spec get(key()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    with {:ok, key} <- Key.validate(key), do: impl().get(key)
  end

  @spec fetch(key(), Path.t()) :: {:ok, info()} | {:error, term()}
  def fetch(key, path) do
    with {:ok, key} <- Key.validate(key), do: impl().fetch(key, path)
  end

  @spec stat(key()) :: {:ok, info()} | {:error, term()}
  def stat(key) do
    with {:ok, key} <- Key.validate(key), do: impl().stat(key)
  end

  @spec delete(key()) :: :ok | {:error, term()}
  def delete(key) do
    with {:ok, key} <- Key.validate(key), do: impl().delete(key)
  end

  @doc """
  The `blob_uri` form of a key. Milestone 1 rows carry `file://` instead and are read, never
  written: `artifact_version` is append-only, so rewriting them would mean dropping the
  trigger that says so.
  """
  @spec uri(key()) :: String.t()
  def uri(key), do: @uri_scheme <> key

  @doc "The key in a `store:` URI, or `:error` for any other scheme."
  @spec key_from_uri(String.t()) :: {:ok, key()} | :error
  def key_from_uri(@uri_scheme <> key) do
    case Key.validate(key) do
      {:ok, key} -> {:ok, key}
      {:error, _reason} -> :error
    end
  end

  def key_from_uri(_uri), do: :error

  @doc "The hash form the artifact store records: `sha256:<lowercase hex>`."
  @spec hash(iodata()) :: String.t()
  def hash(content), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp impl, do: config(:impl, Forge.Storage.Local)

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
