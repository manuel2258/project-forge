defmodule Forge.WorkersImageBuildTest do
  @moduledoc """
  What a template naming `latest` does when its account lacks the release's worker image
  (`docs/design/provisioning.md` § Putting the release's image into an account): the marked
  snapshot is still used while a build runs, and only a job with none to use waits — for a reason,
  and not as the template's failure.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ImageBuildsFixtures

  alias Forge.ImageBuilds
  alias Forge.ImageBuilds.Build
  alias Forge.{Projects, Provider, Provisioning, Workers}

  setup do
    Provider.Fake.watch()
    on_exit(&Provider.Fake.allow/0)
    put_release()
    user = user_fixture()
    credential = credential_fixture(user)

    {:ok, project} =
      Projects.register(
        %{
          name: "p-#{System.unique_integer([:positive])}",
          repo_path: Path.join(Forge.GitFixtures.tmp_dir("w"), "p.git")
        },
        user
      )

    %{user: user, project: project, credential: credential}
  end

  defp assigned(c, attrs \\ %{}) do
    {:ok, template} =
      Provisioning.create_template(
        c.user,
        Enum.into(attrs, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          image: "latest",
          memory: 8_000,
          cores: 4,
          max_workers: 2,
          provider_credential_id: c.credential.id
        })
      )

    {:ok, _} = Provisioning.assign(c.user, template.id, c.project.id)
    template
  end

  defp demand(c, protocol \\ nil),
    do: %{kind: :workflow, memory: 1, cores: 1, project_id: c.project.id, protocol: protocol}

  defp failures(template), do: Repo.get!(Provisioning.Template, template.id).failures
  defp running, do: Repo.all(from b in Build, where: b.status == :running)
  defp too_new, do: ForgeCore.WorkerProtocol.current() + 1

  test "the marked snapshot is used while a build runs, and the build is started", c do
    assigned(c)
    listing([snapshot("snap-old", %{current: true, build: "000000000000"})])

    assert {:error, :creating} = Workers.create_machine(demand(c))
    assert_receive {:provider_create, %{image: "snap-old"}}
    assert [%{status: :running}] = running()
  end

  test "a job with no snapshot this platform accepts waits for the build, uncounted", c do
    template = assigned(c)
    listing([snapshot("snap-old", %{current: true, protocol: too_new()})])

    assert {:error, {:image_building, "fake"}} = Workers.create_machine(demand(c))
    assert {:error, {:image_building, "fake"}} = Workers.create_machine(demand(c))
    refute_receive {:provider_create, _}
    assert failures(template) == 0
    assert length(running()) == 1
  end

  test "nothing marked at all waits for the build too", c do
    template = assigned(c)
    listing([snapshot("snap-x")])

    assert {:error, {:image_building, "fake"}} = Workers.create_machine(demand(c))
    assert failures(template) == 0
  end

  test "a marked snapshot too old for the job waits for the build", c do
    template = assigned(c)
    needs = ForgeCore.WorkerProtocol.current()
    listing([snapshot("snap-old", %{current: true, protocol: needs - 1})])

    assert {:error, {:image_building, "fake"}} = Workers.create_machine(demand(c, needs))
    refute_receive {:provider_create, _}
    assert failures(template) == 0
  end

  test "without a build running, a snapshot too old for the job is the wait it always was", c do
    {:ok, _} = ImageBuilds.set_auto(c.user, c.credential.id, false)
    assigned(c)
    needs = ForgeCore.WorkerProtocol.current()
    listing([snapshot("snap-old", %{current: true, protocol: needs - 1})])

    assert {:error, {:image_too_old, ^needs, _}} = Workers.create_machine(demand(c, needs))
    assert running() == []
  end

  # **A template naming a fixed snapshot behaves exactly as it did** (criterion 3), even while a
  # build runs in its account for another template.
  test "a fixed snapshot this platform refuses is refused as it always was, build or not", c do
    fixed = assigned(c, %{image: "snap-fixed"})

    Repo.update_all(from(t in Provisioning.Template, where: t.id == ^fixed.id),
      set: [image_protocol: too_new()]
    )

    listing([])
    {:ok, _} = ImageBuilds.build_now(c.user, c.credential.id)
    assert [_] = running()

    assert {:error, {:create_failed, {:image, _message}}} = Workers.create_machine(demand(c))
    assert failures(fixed) == 1
  end

  test "a build that fails is the template's failure, once", c do
    template = assigned(c)
    listing([snapshot("snap-x")])

    assert {:error, {:image_building, _}} = Workers.create_machine(demand(c))
    ImageBuilds.advance_all()
    Provider.Fake.build_progress({:failed, "no capacity"})
    ImageBuilds.advance_all()

    assert failures(template) == 1
    assert Repo.get!(Provisioning.Template, template.id).last_error =~ "no capacity"
  end

  test "an unpublished image is a wait that is not counted, and nothing is built", c do
    put_release(%{}, false)
    template = assigned(c)
    listing([snapshot("snap-x")])

    assert {:error, :image_unpublished} = Workers.create_machine(demand(c))
    assert failures(template) == 0
    assert running() == []
  end

  # The refused snapshot is not a reason to count the template's failure when the real reason is
  # that nothing can be built yet.
  test "a refused marked snapshot and an unpublished image is the unpublished wait", c do
    put_release(%{}, false)
    template = assigned(c)
    listing([snapshot("snap-old", %{current: true, protocol: too_new()})])

    assert {:error, :image_unpublished} = Workers.create_machine(demand(c))
    assert failures(template) == 0
  end

  test "an unpublished image does not stop a machine from a snapshot that works", c do
    put_release(%{}, false)
    assigned(c)
    listing([snapshot("snap-old", %{current: true})])

    assert {:error, :creating} = Workers.create_machine(demand(c))
    assert_receive {:provider_create, %{image: "snap-old"}}
  end

  test "with the switch off, latest behaves as it did", c do
    {:ok, _} = ImageBuilds.set_auto(c.user, c.credential.id, false)
    template = assigned(c)
    listing([snapshot("snap-x")])

    assert {:error, {:create_failed, {:image, "no snapshot carries the latest mark"}}} =
             Workers.create_machine(demand(c))

    assert failures(template) == 1
    assert running() == []
  end

  test "a template naming a fixed snapshot never causes a build", c do
    assigned(c, %{image: "snap-fixed"})
    assert {:error, :creating} = Workers.create_machine(demand(c))
    assert_receive {:provider_create, %{image: "snap-fixed"}}
    assert running() == []
  end

  test "an account that has the build is not built into again", c do
    assigned(c)
    listing([snapshot("snap-new", %{current: true, build: release_build(), version: "0.20.0"})])

    assert {:error, :creating} = Workers.create_machine(demand(c))
    assert running() == []
  end
end
