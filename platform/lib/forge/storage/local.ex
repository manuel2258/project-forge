defmodule Forge.Storage.Local do
  @moduledoc """
  A directory on the platform host, one file per key. The PoC's only implementation; see
  `docs/design/storage.md`.

  Writes go to a temporary file beside the destination and are renamed into place, so a crash
  mid-write leaves a stray temp file rather than a short object `stat/1` would report as
  whole. There is no fsync: this is a proof of concept on the operator's machine, and a power
  cut costs the last transcript while the ticket's documents are in Postgres.
  """

  @behaviour Forge.Storage

  alias Forge.Storage

  @impl true
  def put(key, source, _opts) do
    path = path(key)

    if File.exists?(path) do
      {:error, :exists}
    else
      File.mkdir_p!(Path.dirname(path))
      write(path, source)
    end
  end

  @impl true
  def get(key) do
    case File.read(path(key)) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def read_range(key, offset, length) do
    case :file.open(path(key), [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, info} <- :file.read_file_info(io) do
            size = File.Stat.from_record(info).size
            {:ok, %{size: size, bytes: pread(io, offset, length)}}
          end
        after
          :file.close(io)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `pread` answers `:eof` for a range that starts at or past the end, and for a length of zero.
  defp pread(io, offset, length) do
    case :file.pread(io, offset, length) do
      {:ok, bytes} -> bytes
      :eof -> ""
    end
  end

  @impl true
  def fetch(key, destination) do
    source = path(key)

    if File.exists?(source) do
      File.mkdir_p!(Path.dirname(destination))

      with {:ok, _bytes} <- File.copy(source, destination), do: stat(key)
    else
      {:error, :not_found}
    end
  end

  @impl true
  def stat(key) do
    path = path(key)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, %{size: size, hash: hash_file(path)}}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  @impl true
  def delete(key) do
    case File.rm(path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Where this implementation keeps its objects."
  @spec root() :: String.t()
  def root, do: Path.expand(Storage.config(:dir, "tmp/forge/store"))

  defp write(path, {:file, source}) do
    temp = temp_path(path)

    with {:ok, _bytes} <- File.copy(source, temp),
         :ok <- File.rename(temp, path) do
      stat_path(path)
    end
  end

  defp write(path, content) do
    temp = temp_path(path)

    with :ok <- File.write(temp, content),
         :ok <- File.rename(temp, path) do
      stat_path(path)
    end
  end

  defp stat_path(path) do
    %File.Stat{size: size} = File.stat!(path)
    {:ok, %{size: size, hash: hash_file(path)}}
  end

  defp temp_path(path), do: path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9))

  # The key is validated before it reaches here, and the joined path is checked again: a key
  # that smuggled a traversal past the first check does not get to be a path.
  defp path(key) do
    root = root()
    path = Path.expand(Path.join(root, key))

    unless String.starts_with?(path, root <> "/") do
      raise ArgumentError, "storage key escapes the store root: #{inspect(key)}"
    end

    path
  end

  defp hash_file(path) do
    path
    |> File.stream!(2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> then(&("sha256:" <> &1))
  end
end
