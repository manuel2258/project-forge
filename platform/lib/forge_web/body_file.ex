defmodule ForgeWeb.BodyFile do
  @moduledoc """
  A request body streamed to a file, one chunk at a time, and stopped at a limit that counts the
  bytes received — never a `content-length` a client announced. What the store's `PUT` and the
  upload route (`ForgeWeb.UploadController`) share, so that neither reads a body of hundreds of
  megabytes into a binary and neither leaves a temporary file behind: `with_temp/1` removes the
  file whatever the body did.
  """

  @chunk 1024 * 1024

  @doc "The bytes of one read, and so the most that is held in memory at a time."
  @spec chunk() :: pos_integer()
  def chunk, do: @chunk

  @doc """
  Runs `fun` with the path of a temporary file of this request's own and removes it afterwards,
  whether `fun` returned, raised or threw.
  """
  @spec with_temp((Path.t() -> result)) :: result when result: term()
  def with_temp(fun) do
    dir = Path.join(System.tmp_dir!(), "forge-upload")
    File.mkdir_p!(dir)
    path = Path.join(dir, Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  @doc """
  Streams the body to `path`. `{:ok, conn, size}`, `{:error, :too_large}` once more than `max` bytes
  have arrived (what was written stays in `path` for the caller's `with_temp/1` to remove), or the
  read's own error.
  """
  @spec write(Plug.Conn.t(), Path.t(), non_neg_integer()) ::
          {:ok, Plug.Conn.t(), non_neg_integer()} | {:error, term()}
  def write(conn, path, max) do
    file = File.open!(path, [:write, :binary])

    try do
      copy(conn, file, 0, max)
    after
      File.close(file)
    end
  end

  defp copy(conn, file, written, max) do
    case Plug.Conn.read_body(conn, length: @chunk) do
      {:ok, chunk, conn} ->
        written = written + byte_size(chunk)
        if written > max, do: {:error, :too_large}, else: finish(file, chunk, conn, written)

      {:more, chunk, conn} ->
        written = written + byte_size(chunk)

        if written > max do
          {:error, :too_large}
        else
          IO.binwrite(file, chunk)
          copy(conn, file, written, max)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish(file, chunk, conn, written) do
    IO.binwrite(file, chunk)
    {:ok, conn, written}
  end
end
