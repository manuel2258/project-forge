defmodule Forge.ImageBuildsTest do
  @moduledoc """
  Putting the release's worker image into an account: when a build is needed, who may ask for one,
  and how a running one moves (`docs/design/provisioning.md` § Putting the release's image into an
  account). The driver is the fake; what the Hetzner driver sends is `provider_hetzner_test.exs`.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ImageBuildsFixtures

  alias Forge.ImageBuilds
  alias Forge.ImageBuilds.Build
  alias Forge.{Provider, Provisioning, Repo}

  setup do
    Provider.Fake.watch()
    on_exit(&Provider.Fake.allow/0)
    put_release()
    user = user_fixture()
    %{user: user, credential: credential_fixture(user)}
  end

  defp template(user, credential, attrs \\ %{}) do
    {:ok, template} =
      Provisioning.create_template(
        user,
        Enum.into(attrs, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          image: "latest",
          memory: 8_000,
          cores: 4,
          max_workers: 1,
          provider_credential_id: credential.id
        })
      )

    template
  end

  defp builds(credential),
    do: Repo.all(from b in Build, where: b.provider_credential_id == ^credential.id)

  defp only_build(credential) do
    assert [build] = builds(credential)
    build
  end

  describe "ensure/3 decides whether a build is needed" do
    test "a template naming latest, in an account without the build, starts one", c do
      template = template(c.user, c.credential)

      assert ImageBuilds.ensure(template, c.credential, [
               snapshot("old", %{build: "000000000000"})
             ]) ==
               :building

      build = only_build(c.credential)
      assert build.status == :running
      assert build.build == release_build()
      assert build.version == release_version()
      assert build.template_name == template.name
      assert build.started_by_template_id == template.id
      assert build.started_by_user_id == nil
    end

    test "a template naming a fixed snapshot never causes a build", c do
      template = template(c.user, c.credential, %{image: "snap-1"})
      assert ImageBuilds.ensure(template, c.credential, []) == :not_needed
      assert builds(c.credential) == []
    end

    test "the switch off means no build", c do
      template = template(c.user, c.credential)
      {:ok, credential} = ImageBuilds.set_auto(c.user, c.credential.id, false)
      assert ImageBuilds.ensure(template, credential, []) == :not_needed
      assert builds(c.credential) == []
    end

    test "a node that does not know its release never builds", c do
      put_release(nil)
      template = template(c.user, c.credential)
      assert ImageBuilds.ensure(template, c.credential, []) == :not_needed
      assert builds(c.credential) == []
    end

    test "a driver that cannot build never does", c do
      template = template(c.user, c.credential)
      local = %{c.credential | provider: "local"}
      assert ImageBuilds.ensure(template, local, []) == :not_needed
      assert builds(c.credential) == []
    end

    test "a template with no credential has nothing to build into", c do
      assert ImageBuilds.ensure(template(c.user, c.credential), nil, []) == :not_needed
    end

    test "an account that already holds the build needs none", c do
      template = template(c.user, c.credential)
      images = [snapshot("have", %{build: release_build(), version: "0.20.0", current: true})]
      assert ImageBuilds.ensure(template, c.credential, images) == :not_needed
      assert builds(c.credential) == []
    end

    # A build that ended after its snapshot was begun and before the mark was set leaves one of
    # these, and `latest` cannot resolve to it: it must not stop the next build.
    test "an unmarked snapshot of the build is not the build being there", c do
      template = template(c.user, c.credential)
      images = [snapshot("stray", %{build: release_build(), version: "0.20.0", current: false})]

      assert ImageBuilds.ensure(template, c.credential, images) == :building
      listing(images)
      Repo.delete_all(Build)
      assert {:ok, _build} = ImageBuilds.build_now(c.user, c.credential.id)
    end

    # What a person marked stays what `latest` uses until the account next lacks the
    # platform's build, so the platform's own snapshot being unmarked beside it builds nothing.
    test "a snapshot marked by hand is not moved while ours is present", c do
      template = template(c.user, c.credential)

      images = [
        snapshot("ours", %{build: release_build(), version: "0.20.0", current: false}),
        snapshot("hand", %{build: "ffffffffffff", current: true})
      ]

      assert ImageBuilds.ensure(template, c.credential, images) == :not_needed
      assert builds(c.credential) == []

      listing(images)
      assert {:error, :present} = ImageBuilds.build_now(c.user, c.credential.id)
    end

    test "the stray of a failed build beside an older release's mark builds again", c do
      template = template(c.user, c.credential)

      images = [
        snapshot("stray", %{build: release_build(), version: "0.20.0", current: false}),
        snapshot("old", %{build: "000000000000", version: "0.19.0", current: true})
      ]

      assert ImageBuilds.ensure(template, c.credential, images) == :building
    end

    test "an account holding a newer release is never built into, compared as versions", c do
      put_release(%{"version" => "0.9.0"})
      template = template(c.user, c.credential)

      # 0.10.0 is newer than 0.9.0, which a string comparison gets wrong.
      newer = [snapshot("new", %{build: "111111111111", version: "0.10.0"})]
      assert ImageBuilds.ensure(template, c.credential, newer) == :not_needed
      assert builds(c.credential) == []
    end

    test "an older, an equal or an unlabelled snapshot does not stop a build", c do
      template = template(c.user, c.credential)

      images = [
        snapshot("a", %{build: "111111111111", version: "0.19.0"}),
        snapshot("b", %{build: "222222222222", version: "0.20.0"}),
        snapshot("c")
      ]

      assert ImageBuilds.ensure(template, c.credential, images) == :building
    end

    test "an image that is not published is a wait and nothing is built", c do
      put_release(%{}, false)
      template = template(c.user, c.credential)
      assert ImageBuilds.ensure(template, c.credential, []) == :unpublished
      assert builds(c.credential) == []
    end

    # A build started by hand is waited for whatever the switch says (`ensure/3`'s doc): the
    # snapshot it makes is the one the template will use.
    test "a build already running is waited for even with the switch off", c do
      template = template(c.user, c.credential)
      {:ok, _} = ImageBuilds.build_now(c.user, c.credential.id)
      {:ok, credential} = ImageBuilds.set_auto(c.user, c.credential.id, false)

      assert ImageBuilds.ensure(template, credential, []) == :building
    end

    test "two callers share one build, even when the listing now holds it", c do
      template = template(c.user, c.credential)
      assert ImageBuilds.ensure(template, c.credential, []) == :building
      assert ImageBuilds.ensure(template, c.credential, []) == :building
      assert length(builds(c.credential)) == 1

      # The snapshot may appear in the listing while it is still being made; the account is still
      # waiting for it.
      images = [snapshot("have", %{build: release_build()})]
      assert ImageBuilds.ensure(template, c.credential, images) == :building
    end
  end

  describe "build_now/2" do
    test "builds whatever the switch says, and records who asked", c do
      {:ok, credential} = ImageBuilds.set_auto(c.user, c.credential.id, false)
      assert {:ok, build} = ImageBuilds.build_now(c.user, credential.id)
      assert build.status == :running
      assert build.started_by_user_id == c.user.id
      assert build.template_name == nil
    end

    test "is refused for anyone else's credential, a node admin included, and changes nothing",
         c do
      stranger = user_fixture()
      admin = node_admin_fixture()

      for caller <- [stranger, admin] do
        assert {:error, :not_found} = ImageBuilds.build_now(caller, c.credential.id)
      end

      assert {:error, :not_found} = ImageBuilds.build_now(c.user, "not-a-uuid")
      assert builds(c.credential) == []
    end

    test "is refused when it would do nothing", c do
      listing([snapshot("have", %{build: release_build(), current: true})])
      assert {:error, :present} = ImageBuilds.build_now(c.user, c.credential.id)

      listing([])
      assert {:ok, _build} = ImageBuilds.build_now(c.user, c.credential.id)
      assert {:error, :running} = ImageBuilds.build_now(c.user, c.credential.id)
    end

    # Criterion 21 on the by-hand path: nothing older is built into an account holding a newer one.
    test "is refused when the account holds a newer release", c do
      listing([snapshot("new", %{build: "999999999999", version: "0.21.0"})])
      assert {:error, :newer} = ImageBuilds.build_now(c.user, c.credential.id)
      assert builds(c.credential) == []
    end

    test "buildable/2 refuses a provider that cannot build", c do
      local = %{c.credential | provider: "local"}
      assert {:error, :cannot_build} = ImageBuilds.buildable(local, [])
    end

    test "is refused on a node with no release", c do
      put_release(nil)
      assert {:error, :no_release} = ImageBuilds.build_now(c.user, c.credential.id)
    end

    test "is refused when the image is not published", c do
      put_release(%{}, false)
      assert {:error, :unpublished} = ImageBuilds.build_now(c.user, c.credential.id)
      assert builds(c.credential) == []
    end

    test "is refused when the account's snapshots cannot be read", c do
      Provider.Fake.refuse_images("revoked")
      assert {:error, {:images, "revoked"}} = ImageBuilds.build_now(c.user, c.credential.id)
    end
  end

  describe "set_auto/3" do
    test "flips the switch for the owner only", c do
      assert c.credential.build_images
      assert {:ok, %{build_images: false}} = ImageBuilds.set_auto(c.user, c.credential.id, false)

      stranger = user_fixture()
      assert {:error, :not_found} = ImageBuilds.set_auto(stranger, c.credential.id, true)

      assert {:error, :not_found} =
               ImageBuilds.set_auto(node_admin_fixture(), c.credential.id, true)

      refute Repo.get!(Provisioning.Credential, c.credential.id).build_images
    end

    test "is on for a new credential", c do
      assert credential_fixture(c.user).build_images
    end
  end

  describe "recent/1" do
    test "is the last five of the caller's own credentials, newest first", c do
      now = DateTime.utc_now()

      for n <- 1..7 do
        Repo.insert!(%Build{
          provider_credential_id: c.credential.id,
          build: "build#{n}",
          status: :built,
          started_at: DateTime.add(now, -n * 60)
        })
      end

      other = credential_fixture(user_fixture())

      Repo.insert!(%Build{
        provider_credential_id: other.id,
        build: "theirs",
        status: :built,
        started_at: now
      })

      recent = ImageBuilds.recent(c.user)
      assert Map.keys(recent) == [c.credential.id]

      assert Enum.map(recent[c.credential.id], & &1.build) ==
               ~w(build1 build2 build3 build4 build5)
    end
  end

  describe "advance_all/0 carries a build forward" do
    setup c do
      template = template(c.user, c.credential)
      :building = ImageBuilds.ensure(template, c.credential, [])
      %{template: template}
    end

    test "starts the builder with the release's image and nothing else", c do
      assert ImageBuilds.advance_all() == 1
      assert_receive {:provider_start_build, %{"token" => "t0ken"}, source}

      # The builder is given the download address and the checksum, and no secret: the provider
      # shows its first-boot script in a console.
      assert Enum.sort(Map.keys(source)) == [
               :build_id,
               :digest,
               :raw_sha256,
               :raw_size,
               :repository
             ]

      assert source.repository == "ghcr.io/owner/forge-worker-image"
      assert source.digest == "sha256:" <> String.duplicate("a", 64)
      assert source.raw_size == 4096
      assert %{handle: %{"builder" => _}} = only_build(c.credential)
    end

    test "snapshots a builder that is off, with the mark, and ends built", c do
      ImageBuilds.advance_all()
      Provider.Fake.build_progress(:ready)
      ImageBuilds.advance_all()

      assert_receive {:provider_snapshot_build, _cred, _handle, labels}
      assert labels == %{build: release_build(), version: "0.20.0", protocol: 1, current: true}

      assert ImageBuilds.advance_all() == 0
      build = only_build(c.credential)
      assert build.status == :built
      assert build.image_id == "built-" <> release_build()
      assert build.finished_at
    end

    test "does not move the mark under a newer release that arrived meanwhile", _c do
      ImageBuilds.advance_all()
      listing([snapshot("new", %{build: "999999999999", version: "0.21.0"})])
      Provider.Fake.build_progress(:ready)
      ImageBuilds.advance_all()

      assert_receive {:provider_snapshot_build, _cred, _handle, %{current: false}}
    end

    test "a failed build is discarded and counted against the template that asked", c do
      ImageBuilds.advance_all()
      Provider.Fake.build_progress({:failed, "boom <b>x</b>"})
      ImageBuilds.advance_all()

      assert_receive {:provider_discard_build, _cred, %{"builder" => _}}
      build = only_build(c.credential)
      assert build.status == :failed
      assert build.message == "boom <b>x</b>"
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 1
    end

    test "a build past the time limit is discarded and abandoned, and counted", c do
      ImageBuilds.advance_all()
      old = DateTime.add(DateTime.utc_now(), -31 * 60)
      Repo.update_all(Build, set: [started_at: old])

      assert ImageBuilds.advance_all() == 0
      assert_receive {:provider_discard_build, _cred, %{"builder" => _}}
      build = only_build(c.credential)
      assert build.status == :abandoned
      assert build.message =~ "abandoned at the time limit"
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 1
    end

    test "the row keeps a bounded piece of a long message", c do
      ImageBuilds.advance_all()
      Provider.Fake.build_progress({:failed, String.duplicate("x", 5000)})
      ImageBuilds.advance_all()
      assert String.length(only_build(c.credential).message) == 2000
    end

    # **Not over while its builder may still be there**: the deletion is tried again until it takes,
    # and the failure is counted once, when the build ends.
    test "a builder that cannot be deleted keeps the build running until it can", c do
      ImageBuilds.advance_all()
      Provider.Fake.build_progress({:failed, "boom"})
      Provider.Fake.refuse_discard("locked")
      assert ImageBuilds.advance_all() == 1
      assert %{status: :running} = only_build(c.credential)
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 0

      Provider.Fake.allow()
      Provider.Fake.build_progress({:failed, "boom"})
      assert ImageBuilds.advance_all() == 0
      assert %{status: :failed} = only_build(c.credential)
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 1
    end

    test "a build past the limit ends even when its builder cannot be deleted", c do
      ImageBuilds.advance_all()
      Repo.update_all(Build, set: [started_at: DateTime.add(DateTime.utc_now(), -31 * 60)])
      Provider.Fake.refuse_discard("locked")

      assert ImageBuilds.advance_all() == 0
      assert %{status: :abandoned} = only_build(c.credential)
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 1
    end

    # The platform may have stopped between the request that made the builder and the answer that
    # named it, so a build with no handle is discarded by its id.
    test "a builder that failed to start is discarded by the build's id", c do
      Provider.Fake.refuse_build("reply lost")
      ImageBuilds.advance_all()

      build = only_build(c.credential)
      assert build.status == :failed
      assert_receive {:provider_discard_build, _cred, %{"build_id" => id}}
      assert id == build.id
    end

    test "removing the credential discards a build that never got a handle", c do
      assert :ok = Provisioning.delete_credential(c.user, c.credential.id)
      assert_receive {:provider_discard_build, _cred, %{"build_id" => _id}}
    end

    # Writing the new release's image under the old build's label is the lie this refuses.
    test "a build begun after the platform was upgraded is not started", c do
      put_release(%{"build" => "999999999999"})
      ImageBuilds.advance_all()

      refute_receive {:provider_start_build, _, _}
      assert %{status: :failed, message: message} = only_build(c.credential)
      assert message =~ "was upgraded to worker build 999999999999"
    end

    test "the snapshot is labelled with the protocol the build began with", _c do
      ImageBuilds.advance_all()
      put_release(%{"protocol" => "7", "build" => release_build()})
      Provider.Fake.build_progress(:ready)
      ImageBuilds.advance_all()

      assert_receive {:provider_snapshot_build, _cred, _handle, %{protocol: 1}}
    end

    test "a build inside the limit is left running", _c do
      ImageBuilds.advance_all()
      Repo.update_all(Build, set: [started_at: DateTime.add(DateTime.utc_now(), -29 * 60)])
      assert ImageBuilds.advance_all() == 1
      refute_received {:provider_discard_build, _, _}
    end

    test "a builder that cannot be started is a failed build", c do
      Provider.Fake.refuse_build("no capacity")
      ImageBuilds.advance_all()
      assert %{status: :failed, message: "no capacity"} = only_build(c.credential)
    end

    test "a snapshot that cannot be made is a failed build, and the builder goes", c do
      ImageBuilds.advance_all()
      Provider.Fake.build_progress(:ready)
      Provider.Fake.refuse_snapshot("quota")
      ImageBuilds.advance_all()

      assert %{status: :failed} = only_build(c.credential)
      assert_receive {:provider_discard_build, _cred, _handle}
    end

    test "sweeps builders past the limit in every account with a build, whoever made them", _c do
      ImageBuilds.advance_all()
      limit = ImageBuilds.timeout_ms()
      assert_receive {:provider_sweep_builders, %{"token" => "t0ken"}, ^limit}
    end

    test "a build started by hand has no template to fail", c do
      Repo.delete_all(Build)
      {:ok, _} = ImageBuilds.build_now(c.user, c.credential.id)
      ImageBuilds.advance_all()
      Provider.Fake.build_progress({:failed, "x"})
      ImageBuilds.advance_all()
      assert Repo.get!(Provisioning.Template, c.template.id).failures == 0
    end

    test "removing the credential discards its builder", c do
      ImageBuilds.advance_all()
      assert :ok = Provisioning.delete_credential(c.user, c.credential.id)
      assert_receive {:provider_discard_build, _cred, %{"builder" => _}}
    end
  end
end
