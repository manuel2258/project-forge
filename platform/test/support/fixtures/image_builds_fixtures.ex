defmodule Forge.ImageBuildsFixtures do
  @moduledoc """
  A platform that knows its release, a credential on the fake driver and a listing, for the tests
  of `Forge.ImageBuilds` and of everything that reads it
  (`docs/design/provisioning.md` § Putting the release's image into an account).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Forge.{Provider, Provisioning, WorkerImage}

  @release %{
    "build" => "abcdef123456",
    "version" => "0.20.0",
    "protocol" => "1",
    "repository" => "ghcr.io/owner/forge-worker-image",
    "digest" => "sha256:" <> String.duplicate("a", 64),
    "raw_sha256" => String.duplicate("b", 64),
    "raw_size" => "4096"
  }

  def release_build, do: @release["build"]
  def release_version, do: @release["version"]

  @doc """
  Makes this platform know a release, with the registry answering `published` (true by default),
  and puts everything back when the test ends. Pass `nil` for a node with no release.
  """
  def put_release(overrides \\ %{}, published \\ true) do
    previous = Application.get_env(:forge, WorkerImage)
    WorkerImage.forget()

    release = if overrides == nil, do: nil, else: Map.merge(@release, overrides)

    Application.put_env(:forge, WorkerImage,
      release: release,
      request: fn
        :get, _url, _token ->
          if published, do: {:ok, 200, %{"token" => "t"}}, else: {:ok, 404, %{}}

        :head, _url, _token ->
          if published, do: {:ok, 307, ""}, else: {:ok, 404, ""}
      end
    )

    on_exit(fn ->
      WorkerImage.forget()

      if previous,
        do: Application.put_env(:forge, WorkerImage, previous),
        else: Application.delete_env(:forge, WorkerImage)
    end)

    :ok
  end

  @doc "A credential of `user`'s on the fake driver."
  def credential_fixture(user, attrs \\ %{}) do
    {:ok, credential} =
      Provisioning.create_credential(
        user,
        Enum.into(attrs, %{
          name: "c-#{System.unique_integer([:positive])}",
          provider: "fake",
          secret: %{"token" => "t0ken"}
        })
      )

    credential
  end

  @doc "Makes the fake driver list `images` and puts it back when the test ends."
  def listing(images) do
    Provider.Fake.listing(images)
    on_exit(&Provider.Fake.allow/0)
  end

  @doc "A snapshot in a listing, labelled."
  def snapshot(id, attrs \\ %{}),
    do: Enum.into(attrs, %{id: id, name: id, build: nil, protocol: nil, version: nil})
end
