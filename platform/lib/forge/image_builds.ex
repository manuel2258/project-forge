defmodule Forge.ImageBuilds do
  @moduledoc """
  Putting the release's worker image into a provider account
  (`docs/design/provisioning.md` § Putting the release's image into an account).

  The decision of *whether* a build is needed lives here (`ensure/3`, `build_now/2`); the work of
  carrying one out is `advance_all/0`, which `Forge.ImageBuilds.Runner` calls on a tick. Nothing in
  this module knows the provider is Hetzner or that a builder is a server: it asks
  `Forge.Provider` and stores the handle that comes back without reading it.

  **Only a credential's owner controls its builds.** A build spends the owner's money and
  `identity.md` keeps that decision theirs, so `build_now/2` and `set_auto/3` look the credential
  up with `Provisioning.credential/2` — the caller's own, whatever id arrives — and a node admin
  or a project member's id is simply not found.
  """

  import Ecto.Query, only: [from: 2]

  alias Forge.Accounts.User
  alias Forge.ImageBuilds.{Build, Runner}
  alias Forge.{Provider, Provisioning, Repo, WorkerImage}
  alias Forge.Provisioning.{Credential, Template}

  require Logger

  @recent 5

  # What a person reads on a build that ran out of time: the builder can only power off, so it
  # cannot say what went wrong (`docs/design/provisioning.md` § Putting the release's image into an
  # account).
  @abandoned "abandoned at the time limit: the builder powers off only after writing and reading " <>
               "back a verified image, so it never did — the download, the checksum or the write " <>
               "failed, or the account could not run a server"

  @doc "How long a build may run before it is abandoned, in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: config(:build_timeout_ms, :timer.minutes(30))

  # -- deciding -------------------------------------------------------------------------------

  @typedoc "What a template about to make a machine is told about a build."
  @type verdict :: :not_needed | :building | :unpublished

  @doc """
  Whether the template about to make a machine needs the release's image built into its account,
  given the account's snapshot listing, and starts the build if so.

  A build is started only when all of these hold: the template names `latest`; its credential has
  `build_images` on; the platform has a release; the driver can build; the listing does not hold
  the platform's build (`WorkerImage.holds?/3`); and none carries a newer release. A build already running is
  `:building` whatever else is so. If the image is not downloadable the answer is `:unpublished`
  and nothing is paid for.
  """
  @spec ensure(Template.t(), Credential.t() | nil, [Provider.image()]) :: verdict()
  def ensure(_template, nil, _images), do: :not_needed

  def ensure(%Template{} = template, %Credential{} = credential, images) do
    release = WorkerImage.release()

    cond do
      not Template.latest?(template) -> :not_needed
      running?(credential) -> :building
      not credential.build_images -> :not_needed
      not wanted?(credential, release, images) -> :not_needed
      not WorkerImage.published?() -> :unpublished
      true -> start(credential, release, template: template)
    end
  end

  # The release is in no listing yet and no newer one is: this account would be built into.
  defp wanted?(_credential, nil, _images), do: false

  defp wanted?(credential, release, images) do
    Provider.builds?(credential.provider) and
      not WorkerImage.holds?(images, release.build, release.version) and
      not WorkerImage.newer_in?(images, release.version)
  end

  @doc "Whether a build is running in this credential's account."
  @spec running?(Credential.t() | nil) :: boolean()
  def running?(nil), do: false

  def running?(%Credential{id: id}) do
    Repo.exists?(from b in Build, where: b.provider_credential_id == ^id and b.status == :running)
  end

  @doc """
  Whether *build now* would do something for this credential, given its account's listing:
  `:ok`, or the reason it would not — `:no_release`, `:cannot_build`, `:running`, `:present`
  (the current build is there) or `:newer` (a newer release is).
  """
  @spec buildable(Credential.t(), [Provider.image()]) ::
          :ok | {:error, :no_release | :cannot_build | :running | :present | :newer}
  def buildable(%Credential{} = credential, images) do
    release = WorkerImage.release()

    cond do
      release == nil -> {:error, :no_release}
      not Provider.builds?(credential.provider) -> {:error, :cannot_build}
      running?(credential) -> {:error, :running}
      WorkerImage.holds?(images, release.build, release.version) -> {:error, :present}
      WorkerImage.newer_in?(images, release.version) -> {:error, :newer}
      true -> :ok
    end
  end

  @doc """
  Builds the current release into the caller's own credential's account, whatever the switch says.

  `{:error, :not_found}` for any credential that is not the caller's. The listing is read here, so
  the answer is about the account as it is now.
  """
  @spec build_now(User.t(), String.t()) ::
          {:ok, Build.t()}
          | {:error,
             :not_found
             | :unpublished
             | :no_release
             | :cannot_build
             | :running
             | :present
             | :newer
             | {:images, term()}}
  def build_now(%User{} = user, credential_id) do
    with %Credential{} = credential <- Provisioning.credential(user, credential_id),
         {:ok, images} <- listing(credential),
         :ok <- buildable(credential, images),
         true <- WorkerImage.published?() || {:error, :unpublished} do
      start_by(credential, user)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp start_by(credential, user) do
    case start(credential, WorkerImage.release(), user: user) do
      :building -> {:ok, Repo.one(running_build(credential))}
      other -> other
    end
  end

  defp running_build(%Credential{id: id}),
    do: from(b in Build, where: b.provider_credential_id == ^id and b.status == :running)

  @doc "The account's snapshot listing as the platform reads it, or why it cannot."
  @spec listing(Credential.t()) :: {:ok, [Provider.image()]} | {:error, {:images, term()}}
  def listing(%Credential{} = credential) do
    case Provider.images(credential.provider, secret(credential)) do
      {:ok, images} -> {:ok, images}
      {:error, reason} -> {:error, {:images, reason}}
    end
  end

  @doc "Turns automatic building on or off for the caller's own credential."
  @spec set_auto(User.t(), String.t(), boolean()) :: {:ok, Credential.t()} | {:error, :not_found}
  def set_auto(%User{} = user, credential_id, on) when is_boolean(on) do
    case Provisioning.credential(user, credential_id) do
      nil -> {:error, :not_found}
      credential -> credential |> Ecto.Changeset.change(build_images: on) |> Repo.update()
    end
  end

  # One row per credential per build while running (the partial unique index), so two callers at
  # once share it: the loser's insert does nothing.
  defp start(credential, release, who) do
    template = who[:template]
    user = who[:user]

    now = DateTime.utc_now()

    # `on_conflict: :nothing`: the partial unique index is the guard, and the loser's insert is
    # the other caller's row, which is the one build there should be.
    Repo.insert_all(
      Build,
      [
        %{
          id: Ecto.UUID.generate(),
          provider_credential_id: credential.id,
          build: release.build,
          version: release.version,
          protocol: release.protocol,
          status: :running,
          started_at: now,
          started_by_user_id: user && user.id,
          started_by_template_id: template && template.id,
          template_name: template && template.name,
          inserted_at: DateTime.truncate(now, :second),
          updated_at: DateTime.truncate(now, :second)
        }
      ],
      on_conflict: :nothing
    )

    Runner.poke()
    :building
  end

  # -- reading --------------------------------------------------------------------------------

  @doc """
  The last five builds of each of this user's credentials, newest first, as a map from the
  credential's id. **Only the caller's own credentials**, so another user's builds never appear.
  """
  @spec recent(User.t()) :: %{String.t() => [Build.t()]}
  def recent(%User{id: user_id}) do
    from(b in Build,
      join: c in Credential,
      on: c.id == b.provider_credential_id,
      where: c.user_id == ^user_id,
      order_by: [desc: b.started_at]
    )
    |> Repo.all()
    |> Enum.group_by(& &1.provider_credential_id)
    |> Map.new(fn {id, builds} -> {id, Enum.take(builds, @recent)} end)
  end

  # -- carrying out ---------------------------------------------------------------------------

  @doc """
  Moves every running build one step, and sweeps the builders past the limit in the accounts that
  have one. Returns how many builds are still running.
  """
  @spec advance_all() :: non_neg_integer()
  def advance_all do
    builds = Repo.all(from b in Build, where: b.status == :running, preload: :provider_credential)

    for build <- builds, do: guarded(build)

    for credential <- builds |> Enum.map(& &1.provider_credential) |> Enum.uniq_by(& &1.id) do
      Provider.sweep_builders(credential.provider, secret(credential), timeout_ms())
    end

    Repo.aggregate(from(b in Build, where: b.status == :running), :count)
  end

  # One build that raises must not stop the others, nor the runner. Untested: no test makes a
  # driver raise.
  defp guarded(build) do
    advance(build)
  rescue
    exception ->
      Logger.error("image build #{build.id} raised: #{Exception.message(exception)}")
  end

  @doc false
  @spec advance(Build.t()) :: :ok
  def advance(%Build{provider_credential: %Credential{} = credential} = build) do
    secret = secret(credential)

    cond do
      DateTime.diff(DateTime.utc_now(), build.started_at, :millisecond) > timeout_ms() ->
        end_build(build, credential, :abandoned, @abandoned)

      build.handle == nil ->
        begin(build, credential, secret)

      true ->
        progress(build, credential, secret)
    end
  end

  # **Only the release the row was started for.** The row names a build, and the image the
  # platform would fetch is whatever it is built knowing now: after an upgrade under a row that
  # never got a builder, those differ, and writing the new image under the old build's label is
  # the lie this refuses. The next time a machine is needed, the new release is built.
  defp begin(build, credential, secret) do
    case WorkerImage.release() do
      %{build: ours} = release when ours == build.build ->
        case Provider.start_build(credential.provider, secret, source(build, release)) do
          {:ok, handle} -> save(build, handle: handle)
          {:error, reason} -> end_build(build, credential, :failed, words(reason))
        end

      nil ->
        end_build(build, credential, :failed, "this node has no release build to put there")

      %{build: now} ->
        end_build(
          build,
          credential,
          :failed,
          "the platform was upgraded to worker build #{now} before this build of " <>
            "#{build.build} began, so it was not started"
        )
    end
  end

  defp source(build, release) do
    %{
      build_id: build.id,
      repository: release.repository,
      digest: release.digest,
      raw_sha256: release.raw_sha256,
      raw_size: release.raw_size
    }
  end

  defp progress(build, credential, secret) do
    case Provider.build_progress(credential.provider, secret, build.handle) do
      {:running, handle} ->
        save(build, handle: handle)

      {:ready, handle} ->
        snapshot(%{build | handle: handle}, credential, secret)

      {:built, image_id} ->
        save(build, status: :built, image_id: image_id, finished_at: DateTime.utc_now())

      {:failed, words} ->
        end_build(build, credential, :failed, words)
    end
  end

  # **The version rule is asked again at the last moment**: the listing at the start of the build
  # may be a quarter of an hour old, and a newer release may have landed in the account since. The
  # snapshot is then made without the mark, so `latest` is not moved back under it.
  defp snapshot(build, credential, secret) do
    with {:ok, images} <- Provider.images(credential.provider, secret),
         labels = labels(build, images),
         {:ok, handle} <-
           Provider.snapshot_build(credential.provider, secret, build.handle, labels) do
      save(build, handle: handle)
    else
      {:error, reason} -> end_build(build, credential, :failed, words(reason))
    end
  end

  defp labels(build, images) do
    %{
      build: build.build,
      version: build.version,
      protocol: build.protocol,
      current: not WorkerImage.newer_in?(images, build.version)
    }
  end

  # **The builder's deletion comes first, and a build whose builder could not be deleted is not
  # over**: it stays running and the next tick ends it again, so a failed `DELETE` is retried
  # until it takes or the time limit is reached. An abandoned build ends regardless — the limit
  # has been spent — and a builder still there is the sweep's, once past the limit, in the
  # account's next build.
  #
  # A build that never got a handle is discarded by its id (`discard_handle/1`): the platform may
  # have stopped between the request that made the builder and the answer that named it.
  defp end_build(build, credential, status, message) do
    case Provider.discard_build(credential.provider, secret(credential), discard_handle(build)) do
      :ok ->
        finish(build, status, message)

      {:error, reason} when status == :abandoned ->
        Logger.warning("image build #{build.id}: its builder was not deleted: #{inspect(reason)}")
        finish(build, status, message)

      {:error, reason} ->
        Logger.warning(
          "image build #{build.id}: its builder was not deleted, trying again: #{inspect(reason)}"
        )
    end
  end

  # A build with no handle is named by its id alone (`Forge.Provider.discard_build/2`).
  defp discard_handle(%Build{handle: nil, id: id}), do: %{"build_id" => id}
  defp discard_handle(%Build{handle: handle}), do: handle

  defp finish(build, status, message) do
    # The row keeps a bounded piece of it; the whole is here.
    Logger.warning("image build #{build.id} #{status}: #{message}")

    save(build,
      status: status,
      message: String.slice(message, 0, 2000),
      finished_at: DateTime.utc_now()
    )

    # A failed or abandoned build is a failure of the template that asked for it, counted as a
    # failed create is. A build started by hand has none.
    Provisioning.failed(build.started_by_template_id, "worker image build #{status}: " <> message)
  end

  defp save(build, changes) do
    {_count, _} =
      Repo.update_all(from(b in Build, where: b.id == ^build.id and b.status == :running),
        set: Keyword.put(changes, :updated_at, DateTime.utc_now(:second))
      )

    :ok
  end

  @doc """
  Discards the builders of a credential that is about to be deleted, so removing the credential
  leaks no server.
  """
  @spec discard_running(Credential.t()) :: :ok
  def discard_running(%Credential{id: id} = credential) do
    for build <-
          Repo.all(
            from b in Build, where: b.provider_credential_id == ^id and b.status == :running
          ),
        do: Provider.discard_build(credential.provider, secret(credential), discard_handle(build))

    :ok
  end

  defp words(reason) when is_binary(reason), do: reason
  defp words({:hetzner, status, message}), do: "#{status}: #{message}"
  defp words({:hetzner, message}), do: to_string(message)
  defp words(other), do: inspect(other)

  defp secret(%Credential{} = credential) do
    case Credential.secret(credential) do
      {:ok, secret} -> secret
      :error -> nil
    end
  end

  @doc false
  def config(key, default),
    do: :forge |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
