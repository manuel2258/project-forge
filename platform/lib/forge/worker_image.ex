defmodule Forge.WorkerImage do
  @moduledoc """
  What this platform knows of the worker image its release published
  (`docs/design/provisioning.md` § Putting the release's image into an account).

  **The checksum is the platform's own.** It is read from the release's `release.env` when the
  platform is built (`config.exs`) and never fetched from where the image is published, so an
  image that was swapped there is refused by the builder rather than believed. Neither the address
  nor the checksum comes from a form, a template or a credential.

  Every value here ends up in a first-boot script the provider shows in its console, so each is
  validated to the shape it should have before anything is built from it: a malformed release is
  no release.
  """

  @type release :: %{
          build: String.t(),
          version: String.t(),
          protocol: non_neg_integer() | nil,
          repository: String.t(),
          digest: String.t(),
          raw_sha256: String.t(),
          raw_size: pos_integer()
        }

  @doc """
  The release this platform was built with, or nil — a development node, or a release whose
  values are not what they should be. **Nil means this node never builds** and offers no
  *build now*.
  """
  @spec release() :: release() | nil
  def release do
    case config(:release, nil) do
      %{} = raw -> validated(raw)
      _none -> nil
    end
  end

  defp validated(raw) do
    with build when is_binary(build) <- raw["build"],
         true <- build =~ ~r/\A[a-z0-9]{12}\z/,
         version when is_binary(version) <- raw["version"],
         {:ok, _} <- Version.parse(version),
         repository when is_binary(repository) <- raw["repository"],
         true <- repository =~ ~r{\A[a-z0-9][a-z0-9._-]*(:[0-9]+)?(/[a-z0-9._-]+)+\z},
         digest when is_binary(digest) <- raw["digest"],
         true <- digest =~ ~r/\Asha256:[0-9a-f]{64}\z/,
         sha when is_binary(sha) <- raw["raw_sha256"],
         true <- sha =~ ~r/\A[0-9a-f]{64}\z/,
         {size, ""} when size > 0 <- size(raw["raw_size"]) do
      %{
        build: build,
        version: version,
        protocol: protocol(raw["protocol"]),
        repository: repository,
        digest: digest,
        raw_sha256: sha,
        raw_size: size
      }
    else
      _invalid -> nil
    end
  end

  defp size(value) when is_integer(value), do: {value, ""}
  defp size(value) when is_binary(value), do: Integer.parse(value)
  defp size(_value), do: :error

  defp protocol(value) when is_integer(value), do: value

  defp protocol(value) when is_binary(value) do
    case Integer.parse(value) do
      {protocol, ""} -> protocol
      _other -> nil
    end
  end

  defp protocol(_value), do: nil

  @doc """
  Whether an image in `images` carries a release newer than `version`. **Versions are compared
  as versions**, so 0.10.0 is newer than 0.9.0, and an image with no version label — made before
  this, or by hand — is never newer, so it never stops a release's build.
  """
  @spec newer_in?([map()], String.t()) :: boolean()
  def newer_in?(images, version) do
    Enum.any?(images, fn image ->
      case image[:version] do
        nil -> false
        other -> Version.compare(other, version) == :gt
      end
    end)
  end

  @doc """
  Whether `images` already holds this build, in the sense that a build now would add nothing.

  Held means **the platform's snapshot of this build is present and `latest` points at it, or at
  something a person chose** (marked, and not an older release): a snapshot
  marked by hand stays what `latest` uses until the account next lacks the platform's build
  (`docs/design/provisioning.md` § Putting the release's image into an account).

  Why the mark matters at all: the driver sets it when the snapshot is available, so a build that
  ends between the snapshot being begun and the mark being set (the time limit, a mark that kept
  failing) leaves a snapshot of the release that nothing would use. Counting it as present when
  nothing else is marked would stop every later build in that account, and a new account has
  nothing else marked. So a present but unmarked snapshot is held only when **another snapshot
  carries the mark and is not an older release** — a labelled version below this one is a release
  the platform should move on from, and the mark is then ours to set. Unlabelled, or of this
  version or a later one, it is somebody's choice (`bin/hetzner-image` labels a build and a
  protocol and no version) and is left alone. A snapshot unmarked because a newer release holds
  the mark is `newer_in?/2`'s case, also asked, so no build starts for it either.
  """
  @spec holds?([map()], String.t(), String.t()) :: boolean()
  def holds?(images, build, version) do
    # Ours marked is itself "not an older release": its version is this one.
    Enum.any?(images, &(&1[:build] == build)) and
      Enum.any?(images, &(&1[:current] == true and chosen?(&1, version)))
  end

  # A marked snapshot that is not an older release: no version label, or one that is not below.
  defp chosen?(image, version) do
    case image[:version] do
      nil -> true
      other -> Version.compare(other, version) != :lt
    end
  end

  @doc """
  Whether the image can be downloaded from where the release published it, anonymously — which
  is all a builder in someone else's account can do. **Remembered for a minute**, so the platform
  asks the registry at most once a minute however many jobs wait.

  An answer of *no* is a wait, never a failure (`docs/design/provisioning.md` § Putting the release's image into an account): the package may simply not have
  been made public yet.
  """
  @spec published?() :: boolean()
  def published? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get({__MODULE__, :published}, nil) do
      {at, answer} when now - at < 60_000 -> answer
      _stale -> remember(now, ask())
    end
  end

  @doc false
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase({__MODULE__, :published})
    :ok
  end

  defp remember(at, answer) do
    :persistent_term.put({__MODULE__, :published}, {at, answer})
    answer
  end

  defp ask do
    case release() do
      nil -> false
      release -> blob_present?(release)
    end
  end

  # OCI distribution, anonymously: a token for the repository, then a HEAD of the blob by its
  # digest. The registry answers a blob with a redirect to its storage, which is as good as a 200.
  defp blob_present?(%{repository: repository, digest: digest}) do
    [host | path] = String.split(repository, "/")
    path = Enum.join(path, "/")
    token_url = "https://#{host}/token?service=#{host}&scope=repository:#{path}:pull"

    with {:ok, 200, %{"token" => token}} when is_binary(token) <- fetch(:get, token_url, nil),
         {:ok, status, _body} <-
           fetch(:head, "https://#{host}/v2/#{path}/blobs/#{digest}", token) do
      status in [200, 301, 302, 307]
    else
      _unavailable -> false
    end
  end

  # The seam, as `Forge.Provider.Hetzner`'s. Everything inside `http/3` is an equivalent mutant
  # under test: a test that reached it would need a network.
  defp fetch(method, url, token), do: config(:request, &__MODULE__.http/3).(method, url, token)

  @doc false
  @spec http(atom(), String.t(), String.t() | nil) ::
          {:ok, non_neg_integer(), term()} | {:error, term()}
  def http(method, url, token) do
    options =
      [method: method, url: url, redirect: false, receive_timeout: 15_000, retry: false] ++
        if(token, do: [auth: {:bearer, token}], else: [])

    case Req.request(options) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
