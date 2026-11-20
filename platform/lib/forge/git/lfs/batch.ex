defmodule Forge.Git.Lfs.Batch do
  @moduledoc """
  The Git LFS batch API's decision, as a pure function: a decoded request in, a response map out.
  It knows nothing of a repository or a token — what is held, the size limit, the address of an
  object and the request's own `Authorization` value are handed in — so every rule of
  `docs/design/git-hosting.md` § Git LFS (*The batch*) is testable without a socket.

  **The `ref` a client names is never read.** It is a field the client fills in, so a check on it
  would be decorative; what limits a job's writes is `pre-receive`.

  **No token is in any address.** An action carries its `href` and, in `header`, the `Authorization`
  the request itself arrived with, which is the one place a token goes (`storage.md` § The token is
  a header).
  """

  @max_objects 1_000
  @max_bytes 1024 * 1024

  @doc "The most bytes of request body the endpoint reads for a batch."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_bytes

  @typedoc """
  What the caller supplies: `:held?` (oid → boolean), `:limit` (bytes), `:download_href` (oid → url),
  `:upload_href` (oid, size → url) and `:authorization` (the request's own header value, or nil).
  """
  @type env :: %{
          held?: (String.t() -> boolean()),
          limit: pos_integer(),
          download_href: (String.t() -> String.t()),
          upload_href: (String.t(), non_neg_integer() -> String.t()),
          authorization: String.t() | nil
        }

  @doc "The operation a request asks for, or `:error`."
  @spec operation(term()) :: {:ok, :download | :upload} | :error
  def operation(%{"operation" => "download"}), do: {:ok, :download}
  def operation(%{"operation" => "upload"}), do: {:ok, :upload}
  def operation(_request), do: :error

  @doc """
  The response to `request`: `{:ok, body, touch}` — `touch` the oids of uploads forge already holds,
  whose clock the caller restarts — or `{:error, status, message}` for a request refused whole.
  """
  @spec respond(term(), env()) ::
          {:ok, map(), [String.t()]} | {:error, 409 | 413 | 422, String.t()}
  def respond(request, env) do
    with {:ok, operation} <- check_operation(request),
         :ok <- check_hash_algo(request),
         :ok <- check_transfers(request),
         {:ok, objects} <- check_objects(request) do
      answered = Enum.map(objects, &object(operation, &1, env))

      touch = for {%{"oid" => oid}, :held_upload} <- answered, do: oid

      {:ok,
       %{
         "transfer" => "basic",
         "hash_algo" => "sha256",
         "objects" => Enum.map(answered, &elem(&1, 0))
       }, touch}
    end
  end

  defp check_operation(request) do
    case operation(request) do
      {:ok, operation} -> {:ok, operation}
      :error -> {:error, 422, "operation must be download or upload"}
    end
  end

  defp check_hash_algo(%{"hash_algo" => algo}) when algo != "sha256",
    do: {:error, 409, "forge's LFS keys objects by sha256 only"}

  defp check_hash_algo(_request), do: :ok

  # A client that lists transfers and does not list `basic` cannot be served: `basic` is all there is.
  defp check_transfers(%{"transfers" => [_ | _] = transfers}) do
    if "basic" in transfers,
      do: :ok,
      else: {:error, 422, "forge's LFS speaks the basic transfer only"}
  end

  defp check_transfers(_request), do: :ok

  defp check_objects(%{"objects" => objects}) when is_list(objects) do
    if length(objects) > @max_objects,
      do: {:error, 413, "a batch names at most #{@max_objects} objects"},
      else: {:ok, objects}
  end

  defp check_objects(_request), do: {:error, 422, "objects must be a list"}

  defp object(operation, %{"oid" => oid, "size" => size} = given, env)
       when is_binary(oid) and is_integer(size) and size >= 0 do
    cond do
      not Forge.Git.Lfs.oid?(oid) ->
        {failure(given, 422, "oid must be 64 lowercase hex characters"), nil}

      operation == :download ->
        download(oid, size, env)

      size > env.limit ->
        {failure(
           given,
           422,
           "object is #{size} bytes; this forge accepts at most #{env.limit} bytes per LFS object"
         ), nil}

      env.held?.(oid) ->
        {%{"oid" => oid, "size" => size, "authenticated" => true}, :held_upload}

      true ->
        {%{
           "oid" => oid,
           "size" => size,
           "authenticated" => true,
           "actions" => %{"upload" => action(env.upload_href.(oid, size), env)}
         }, nil}
    end
  end

  defp object(_operation, given, _env),
    do: {failure(given, 422, "an object needs an oid and a size"), nil}

  defp download(oid, size, env) do
    if env.held?.(oid) do
      {%{
         "oid" => oid,
         "size" => size,
         "authenticated" => true,
         "actions" => %{"download" => action(env.download_href.(oid), env)}
       }, nil}
    else
      {%{
         "oid" => oid,
         "size" => size,
         "error" => %{"code" => 404, "message" => "object not found"}
       }, nil}
    end
  end

  defp action(href, %{authorization: nil}), do: %{"href" => href}

  defp action(href, %{authorization: authorization}),
    do: %{"href" => href, "header" => %{"Authorization" => authorization}}

  # What an error names is what the client sent, bounded, so it can be told which object it was.
  defp failure(given, code, message) when not is_map(given), do: failure(%{}, code, message)

  defp failure(given, code, message) do
    oid = if is_binary(given["oid"]), do: String.slice(given["oid"], 0, 80), else: ""
    size = if is_integer(given["size"]), do: given["size"], else: 0
    %{"oid" => oid, "size" => size, "error" => %{"code" => code, "message" => message}}
  end
end
