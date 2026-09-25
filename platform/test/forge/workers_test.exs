defmodule Forge.WorkersTest do
  @moduledoc """
  Worker rows, tokens, the memory gate and the lifecycle: created when a job needs one,
  destroyed when nothing has for long enough.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Provider, Provisioning, Workers}

  setup do
    Provider.Fake.watch()
    previous = Application.get_env(:forge, Workers, [])

    # `refuse/1` is `persistent_term` and would otherwise outlive the test that set it, making
    # every later create in the run fail for a reason nobody could see from the failing test.
    on_exit(fn ->
      Provider.Fake.allow()
      Application.put_env(:forge, Workers, previous)
    end)

    :ok
  end

  # **Every machine comes from a template now**, so a test that wants one assigns a template to
  # a project and asks on that project's behalf. There is no node fallback to lean on
  # (`docs/design/provisioning.md` § Whose account).
  defp assigned(user, project, attrs \\ %{}) do
    {:ok, template} =
      Provisioning.create_template(
        user,
        Enum.into(attrs, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          memory: 8_000,
          cores: 4,
          max_workers: 1
        })
      )

    {:ok, _} = Provisioning.assign(user, template.id, project.id)
    template
  end

  # The repository under a directory of the test's own, removed when it ends. It was
  # `<tmp>/forge-w-N.git` with N from `unique_integer/1`, which restarts with every run: a later
  # run registering the same N found the repository an earlier one left behind.
  defp project_attrs do
    n = System.unique_integer([:positive])
    %{name: "proj-#{n}", repo_path: Path.join(Forge.GitFixtures.tmp_dir("w"), "p.git")}
  end

  # A project with a template on it, for a test whose subject is not templates at all.
  defp with_template(attrs \\ %{}) do
    user = Forge.AccountsFixtures.user_fixture()
    {:ok, project} = Forge.Projects.register(project_attrs(), user)
    template = assigned(user, project, attrs)
    %{user: user, project: project, template: template}
  end

  defp configure(opts) do
    current = Application.get_env(:forge, Workers, [])
    Application.put_env(:forge, Workers, Keyword.merge(current, opts))
  end

  defp configure_provider(opts) do
    current = Application.get_env(:forge, Provider, [])
    on_exit(fn -> Application.put_env(:forge, Provider, current) end)
    Application.put_env(:forge, Provider, Keyword.merge(current, opts))
  end

  describe "tokens" do
    test "are returned once and only their hash is kept" do
      {:ok, worker, token} = Workers.create(%{provider: "fake"})

      refute worker.token_hash == token
      assert {:ok, %{id: id}} = Workers.authenticate(worker.id, token)
      assert id == worker.id
    end

    test "do not open another worker, a destroyed one, or nothing at all" do
      {:ok, worker, token} = Workers.create(%{provider: "fake"})
      {:ok, other, _other_token} = Workers.create(%{provider: "fake"})

      assert :error = Workers.authenticate(other.id, token)
      assert :error = Workers.authenticate(worker.id, "nope")
      assert :error = Workers.authenticate(Ecto.UUID.generate(), token)
      assert :error = Workers.authenticate("not-a-uuid", token)

      {:ok, worker} = Workers.status(worker, :destroyed)
      assert :error = Workers.authenticate(worker.id, token)
    end
  end

  describe "the gate" do
    test "offers a worker only while its slice fits" do
      configure(slice_bytes: 1_000)
      worker = live_worker(%{"memory_budget" => 2_500, "cores" => 8})

      assert %{id: id} = Workers.assignable(demand(memory: 1_000))
      assert id == worker.id
      assert Workers.remaining(Workers.get!(worker.id)) == 2_500
      refute Workers.assignable(demand(memory: 3_000))
    end

    test "ignores a worker nothing can reach" do
      configure(slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 8})
      serve!(worker, gate_project())

      refute Workers.assignable(demand(memory: 1_000))
      :ok = Workers.connected(worker.id)
      assert Workers.assignable(demand(memory: 1_000))
    end

    # The dimension commit 23b6609 exists for. A machine with room in bytes and none in cores
    # would take the job under a memory-only gate, and two four-core commands would both land
    # on four cores.
    test "cores are counted, and a worker out of them is not offered" do
      worker = live_worker(%{"memory_budget" => 8_000_000_000, "cores" => 4})

      assert Workers.assignable(demand(cores: 4))
      refute Workers.assignable(demand(cores: 5))

      running(worker, memory_max: 1_000, cores: 3)

      assert Workers.remaining_cores(Workers.get!(worker.id)) == 1
      assert Workers.assignable(demand(cores: 1))
      refute Workers.assignable(demand(cores: 2))
    end

    # The whole point of `accepts`, and the assertion the design exists for: room is irrelevant
    # when the kind is refused. The real case is a build machine taking only `:command`, which
    # cannot be written until commands are a kind — so it is written here with the kinds that
    # exist, against a machine with sixty-four gigabytes and thirty-two cores going spare.
    test "a worker that does not take this kind is refused however much room it has" do
      live_worker(%{"memory_budget" => 64_000_000_000, "cores" => 32, "accepts" => ["chat"]})

      refute Workers.assignable(demand(kind: :workflow))
      assert Workers.assignable(demand(kind: :chat))
    end

    # A row from before the column, or a release older than the field. Refusing these would idle
    # the fleet on an upgrade — the trap `worker-channel.md` § Open records for the harness.
    test "a worker that has said nothing about kinds takes anything" do
      live_worker(%{"memory_budget" => 8_000_000_000, "cores" => 8})

      assert Workers.assignable(demand(kind: :workflow))
      assert Workers.assignable(demand(kind: :chat))
    end

    # The same trap, and the one that would have bitten hardest: nothing reported cores before
    # this shipped, so reading a nil as zero would have idled every machine in existence. Nil is
    # unknown, not zero.
    test "a worker that has said nothing about cores is not gated on them" do
      live_worker(%{"memory_budget" => 8_000})

      assert Workers.assignable(demand(memory: 1_000, cores: 1))
      assert Workers.assignable(demand(memory: 1_000, cores: 64))
      # Memory still binds: unknown cores is not unknown everything.
      refute Workers.assignable(demand(memory: 9_000, cores: 1))
    end

    # And the asymmetry, stated so nobody "fixes" it into symmetry: a worker with no budget has
    # not reported `ready` at all, and giving it work is the overcommit the tier exists to stop.
    test "a worker that has said nothing about memory gets nothing" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, _worker} = Workers.status(worker, :ready)
      :ok = Workers.connected(worker.id)

      refute Workers.assignable(demand(memory: 1))
    end

    # A kind this platform has never heard of is dropped rather than making the whole list
    # unusable; a list with nothing left in it is "said nothing I understood", not "takes
    # nothing", or a newer worker would strand itself by naming only future kinds.
    test "an unknown kind is dropped from what a worker claims" do
      worker =
        live_worker(%{"memory_budget" => 8_000, "cores" => 2, "accepts" => ["chat", "ray"]})

      assert Workers.get!(worker.id).accepts == [:chat]
      assert Workers.assignable(demand(kind: :chat, memory: 1_000))
      refute Workers.assignable(demand(kind: :workflow, memory: 1_000))

      other =
        live_worker(%{"memory_budget" => 8_000, "cores" => 2, "accepts" => ["ray", "of light"]})

      assert Workers.get!(other.id).accepts == nil
    end

    test "what is promised is summed from the jobs, not counted" do
      configure(slice_bytes: 1_000)
      worker = live_worker(%{"memory_budget" => 10_000, "cores" => 16})

      running(worker, memory_max: 6_000, cores: 1)

      # Counted against the slice this would be 9_000 left, which is the bug the sum replaces.
      assert Workers.remaining(Workers.get!(worker.id)) == 4_000
      assert Workers.assignable(demand(memory: 4_000))
      refute Workers.assignable(demand(memory: 4_001))
    end

    # Affinity, and it must never harden into a requirement: a resumed job whose worker is gone
    # has to land somewhere (`docs/design/provisioning.md` § Affinity on resume).
    test "the worker a job was last on is preferred, and never required" do
      first = live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      second = live_worker(%{"memory_budget" => 8_000, "cores" => 4})

      # `inserted_at` is second-granular, so two rows made in one test tie and "oldest first"
      # picks between them arbitrarily. Aged by hand, because the assertion below is about the
      # preference beating the ordering and needs an ordering to beat.
      age(first)

      # Oldest-first would give the first one; the preference overrides that.
      assert %{id: id} = Workers.assignable(demand(memory: 1_000), second.id)
      assert id == second.id

      # A preference that cannot be met falls through rather than refusing.
      assert %{id: id} = Workers.assignable(demand(memory: 1_000), Ecto.UUID.generate())
      assert id == first.id
    end

    # The row governs (`docs/design/provisioning.md` § What a worker offers). Without this an
    # operator's edit to a permanent worker is undone by the next reconnect, and the field on
    # the page is a lie — which is the whole reason `reported` exists beside the columns.
    test "what the machine says fills a blank row and never overwrites a set one" do
      worker = live_worker(%{"memory_budget" => 8_000, "cores" => 8, "accepts" => ["chat"]})

      # Blank before, filled from the first report.
      assert %{memory_budget: 8_000, cores: 8, accepts: [:chat]} = Workers.get!(worker.id)

      # The operator corrects the row by hand.
      {:ok, _} =
        Workers.update(Workers.get!(worker.id), %{
          memory_budget: 5_000,
          cores: 2,
          accepts: [:workflow]
        })

      # The machine reconnects and says its original piece again.
      {:ok, _} =
        Workers.ready(Workers.get!(worker.id), %{
          "memory_budget" => 8_000,
          "cores" => 8,
          "accepts" => ["chat"]
        })

      reloaded = Workers.get!(worker.id)
      assert reloaded.memory_budget == 5_000
      assert reloaded.cores == 2
      assert reloaded.accepts == [:workflow]

      # And what it actually said is kept, so the disagreement can be shown.
      assert reloaded.reported == %{
               "memory_budget" => 8_000,
               "cores" => 8,
               "accepts" => ["chat"]
             }
    end

    test "a preferred worker that is full is passed over" do
      first = live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      second = live_worker(%{"memory_budget" => 2_000, "cores" => 4})
      age(first)
      running(second, memory_max: 1_500, cores: 1)

      assert %{id: id} = Workers.assignable(demand(memory: 1_000), second.id)
      assert id == first.id
    end
  end

  describe "which projects a machine serves" do
    # The rule `docs/design/identity.md` § Workers exists for: a machine takes a project's jobs
    # only because its owner assigned it there, however much room it has.
    test "a machine not assigned to a project does not take its jobs" do
      live_worker(%{"memory_budget" => 64_000, "cores" => 32})
      {:ok, elsewhere} = register_owned!(project_attrs())

      assert Workers.assignable(demand(memory: 1))
      refute Workers.assignable(demand(memory: 1, project_id: elsewhere.id))
      refute Workers.assignable(demand(memory: 1, project_id: nil))
    end

    # Read at placement, not copied at creation: taking the template out of the project is the
    # owner withdrawing consent, and it has to reach the machines already running.
    test "a machine made from a template serves its template's projects, until unassigned" do
      %{user: user, project: project, template: template} = with_template()

      {:ok, worker, _token} = Workers.create(Provisioning.Template.worker_attrs(template))
      {:ok, _worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
      :ok = Workers.connected(worker.id)

      assert %{id: id, user_id: owner} = Workers.assignable(demand(project_id: project.id))
      assert id == worker.id
      assert owner == user.id

      :ok = Provisioning.unassign(user, template.id, project.id)
      refute Workers.assignable(demand(project_id: project.id))
    end

    # A full machine that serves somebody else's project is not somewhere this job can wait,
    # and answering `:at_capacity` would leave its ticket waiting for ever instead of sticking.
    test "a machine serving another project is not a queue for this one" do
      live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      {:ok, elsewhere} = register_owned!(project_attrs())

      assert {:error, :at_capacity} = Workers.create_machine(demand(memory: 8_000))

      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(memory: 8_000, project_id: elsewhere.id))
    end
  end

  describe "which harness a machine runs" do
    @per_job %{"driver" => "claude_code", "credential" => "per_job"}

    # A job carries its credential now, and a release older than that would run it on whatever
    # its own environment held — recorded against a credential it did not spend. So the gate asks
    # (`docs/design/credentials.md` § What a worker offers now).
    test "a machine that does not take a job's credential is given no agent job" do
      live_worker(%{"memory_budget" => 8_000, "cores" => 4})

      refute Workers.assignable(demand(memory: 1) |> Map.put(:harness, "claude_code"))
    end

    test "one that says it does is, and one running another harness is not" do
      live_worker(%{"memory_budget" => 8_000, "cores" => 4, "harness" => @per_job})

      assert Workers.assignable(demand(memory: 1) |> Map.put(:harness, "claude_code"))
      refute Workers.assignable(demand(memory: 1) |> Map.put(:harness, "another"))
    end

    # The old half of the trap in the other direction: a release that reported a harness but not
    # `per_job` is exactly the one that would ignore the assignment's credential.
    test "a harness reported without per_job credentials is not enough" do
      live_worker(%{
        "memory_budget" => 8_000,
        "cores" => 4,
        "harness" => %{"driver" => "claude_code", "login" => "ok"}
      })

      refute Workers.assignable(demand(memory: 1) |> Map.put(:harness, "claude_code"))
    end

    # A job that runs no harness — the kind `commands.md` will add — needs no credential and so
    # does not care which a machine takes.
    test "a demand naming no harness is placed without asking" do
      live_worker(%{"memory_budget" => 8_000, "cores" => 4})

      assert Workers.assignable(demand(memory: 1))
    end

    # And a machine that cannot run the job is no queue for it either, whatever its size.
    test "a machine that would never be given the job is not somewhere to wait for it" do
      old = live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      running(old, memory_max: 8_000, cores: 4)

      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(memory: 1) |> Map.put(:harness, "claude_code"))
    end
  end

  describe "assigning a machine to a project" do
    setup do
      owner = Forge.AccountsFixtures.user_fixture()
      {:ok, project} = Forge.Projects.register(project_attrs(), owner)

      {:ok, worker, _token} =
        Workers.create(%{provider: "fake", managed: false, user_id: owner.id})

      %{owner: owner, project: project, worker: worker}
    end

    test "the owner may, for a project they are in, and it is recorded", context do
      %{owner: owner, project: project, worker: worker} = context

      assert {:ok, _assignment} = Workers.assign(owner, worker.id, project.id)
      assert [%{id: id}] = Workers.projects(worker)
      assert id == project.id

      assert Forge.Repo.exists?(
               Ecto.Query.from(e in Forge.Events.Event,
                 where: e.type == "worker.assigned" and e.project_id == ^project.id
               )
             )

      assert :ok = Workers.unassign(owner, worker.id, project.id)
      assert Workers.projects(worker) == []
    end

    # The half of the rule a hidden form would otherwise be the only thing enforcing: an admin of
    # the project is not the owner of the machine.
    test "somebody else may not, even as an admin of the project", context do
      %{project: project, worker: worker} = context
      admin = member_fixture(project, :admin)

      assert Workers.assign(admin, worker.id, project.id) == {:error, :not_found}
      assert Workers.unassign(admin, worker.id, project.id) == {:error, :not_found}
      assert Workers.projects(worker) == []
    end

    test "the owner may not, for a project they are not in", context do
      %{owner: owner, worker: worker} = context
      {:ok, elsewhere} = register_owned!(project_attrs())

      assert Workers.assign(owner, worker.id, elsewhere.id) == {:error, :not_a_member}
      assert Workers.assign(owner, worker.id, "not-a-uuid") == {:error, :not_a_member}
      assert Workers.projects(worker) == []
    end

    # A machine the platform made reaches projects through its template; a second way would be a
    # machine still serving a project after its template was taken out of it.
    test "a machine the platform made is assigned through its template, not here", context do
      %{owner: owner, project: project} = context
      {:ok, made, _token} = Workers.create(%{provider: "fake", managed: true, user_id: owner.id})

      assert Workers.assign(owner, made.id, project.id) == {:error, :made_by_the_platform}
    end

    test "only the owner sees it, and only the owner sets what it offers", context do
      %{owner: owner, worker: worker} = context
      outsider = Forge.AccountsFixtures.user_fixture()

      assert [%{id: id}] = Workers.list(owner)
      assert id == worker.id
      assert Workers.list(outsider) == []

      assert Workers.set_offer(outsider, worker.id, %{memory_budget: 1, cores: 1}) ==
               {:error, :not_found}

      assert {:ok, %{memory_budget: 4_000, cores: 2}} =
               Workers.set_offer(owner, worker.id, %{memory_budget: 4_000, cores: 2})

      {:ok, made, _token} = Workers.create(%{provider: "fake", managed: true, user_id: owner.id})

      assert Workers.set_offer(owner, made.id, %{memory_budget: 1, cores: 1}) ==
               {:error, :made_by_the_platform}
    end
  end

  describe "leaving a project" do
    # Assignment is only allowed to a member; without this the rule held on the way in and not
    # afterwards, and a template kept making machines billed to someone who could no longer see
    # the project they were made for.
    test "takes the leaver's templates, machines and credentials out of it, and nobody else's" do
      admin = Forge.AccountsFixtures.user_fixture()
      {:ok, project} = Forge.Projects.register(project_attrs(), admin)
      leaver = member_fixture(project, :member)

      {:ok, theirs, _token} =
        Workers.create(%{provider: "fake", managed: false, user_id: leaver.id})

      {:ok, _} = Workers.assign(leaver, theirs.id, project.id)
      their_template = assigned(leaver, project)

      their_credential = credential_fixture(leaver)
      {:ok, _} = Forge.Credentials.assign(leaver, their_credential.id, project.id)

      {:ok, mine, _token} = Workers.create(%{provider: "fake", managed: false, user_id: admin.id})
      {:ok, _} = Workers.assign(admin, mine.id, project.id)
      my_template = assigned(admin, project)
      my_credential = credential_fixture(admin)
      {:ok, _} = Forge.Credentials.assign(admin, my_credential.id, project.id)

      assert :ok = Forge.Projects.remove_member(project, leaver, admin)

      assert Workers.projects(theirs) == []
      assert Provisioning.for_projects(their_template) == []
      assert Forge.Credentials.projects(their_credential) == []
      assert [_still] = Workers.projects(mine)
      assert [_still] = Provisioning.for_projects(my_template)
      assert [_still] = Forge.Credentials.projects(my_credential)
    end
  end

  describe "creating a machine from a template" do
    setup do
      user = Forge.AccountsFixtures.user_fixture()
      {:ok, project} = Forge.Projects.register(project_attrs(), user)
      %{user: user, project: project}
    end

    # **This asserted the opposite until the fallback was removed**, and the fallback is what
    # made the node it was written for unusable: a Hetzner template sat unassigned while every
    # pass quietly made a `local` machine that failed `:no_image`, swept it, and did it again.
    # A default that substitutes a different machine for the one you configured is a wrong
    # answer given confidently (`docs/design/provisioning.md` § Whose account).
    test "a project with none assigned makes nothing, and says which wall it hit", %{
      project: project
    } do
      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(project_id: project.id))

      refute_receive {:provider_create, _opts}
      assert Workers.list() == []
    end

    # A demand with no project cannot name a template either, and that path must not be the one
    # left that can still make a machine out of node configuration.
    test "a demand naming no project makes nothing" do
      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(memory: 1, project_id: nil))

      refute_receive {:provider_create, _opts}
    end

    # Disabled is invisible to the gate but not to the page, and it is its own answer: *fix
    # your template* rather than *nothing here is big enough*.
    test "a project whose every template is disabled says so", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})

      for _ <- 1..Provisioning.failure_limit(),
          do: Provisioning.failed(template.id, "made a machine that never connected")

      assert {:error, {:no_template, :all_disabled}} =
               Workers.create_machine(demand(project_id: project.id))

      refute_receive {:provider_create, _opts}
      # And it is still listed, or there would be no way to enable it again.
      assert [_listed] = Provisioning.for_project(project.id)
    end

    # Enabling is the way back, and only a person does it.
    test "an enabled template makes machines again", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})

      for _ <- 1..Provisioning.failure_limit(), do: Provisioning.failed(template.id, "nope")

      assert {:error, {:no_template, :all_disabled}} =
               Workers.create_machine(demand(project_id: project.id))

      {:ok, _template} = Provisioning.enable(user, template.id)

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, _opts}
    end

    # **A machine that exists outranks every template answer**, and removing the node fallback
    # is what made this reachable: `create_default/0` used to answer `:at_capacity` here. A node
    # running the pure permanent model — machines provisioned by hand, no templates at all
    # (`worker-tier.md` § Managed and unmanaged) — would otherwise have every ticket stuck the
    # first time a job had to wait for a busy worker.
    test "a job that a busy machine could take once it is free waits rather than sticking" do
      user = Forge.AccountsFixtures.user_fixture()
      {:ok, project} = Forge.Projects.register(project_attrs(), user)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
      serve!(worker, project)
      running(Workers.get!(worker.id), memory_max: 8_000, cores: 4)

      # No template at all, and the machine is full: still a queue, because it will not be.
      assert {:error, :at_capacity} = Workers.create_machine(demand(project_id: project.id))
      refute_receive {:provider_create, _opts}
    end

    # But a machine too small to ever take it is not somewhere to wait.
    test "a job no existing machine could ever take is not made to wait for one" do
      user = Forge.AccountsFixtures.user_fixture()
      {:ok, project} = Forge.Projects.register(project_attrs(), user)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, _worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})

      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(project_id: project.id, memory: 99_000))
    end

    # **Both kinds of failure count, and they are not the same failure.** A create the driver
    # refuses never makes a machine; a machine that is made and never calls home costs money
    # every turn. The second is the one the counter exists for — in the loop it was written
    # for every create succeeded — so a counter watching only refusals would have watched it
    # run for ever.
    test "a refused create counts against the template", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})
      Provider.Fake.refuse({:hetzner, "no Hetzner image configured"})
      on_exit(&Provider.Fake.allow/0)

      assert {:error, {:create_failed, _reason}} =
               Workers.create_machine(demand(project_id: project.id))

      assert reloaded(template).failures == 1
      assert reloaded(template).last_error == "no Hetzner image configured"
    end

    test "a machine that never connects counts against the template", context do
      %{user: user, project: project} = context
      configure(worker_timeout_ms: 60_000)
      template = assigned(user, project, %{})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{worker_id: worker_id}}
      assert reloaded(template).failures == 0

      age_out(worker_id)
      assert Workers.sweep_unreachable() == 1
      assert reloaded(template).failures == 1
      assert reloaded(template).last_error =~ "never connected"
    end

    # A worker that connected and *later* went away is not the template's failure: the machine
    # worked and something else happened to it. `last_seen_at` is the only thing that separates
    # the two, and without it the count would rise on every ordinary idle destroy.
    test "a machine that worked and then went away does not count", context do
      %{user: user, project: project} = context
      configure(worker_timeout_ms: 60_000)
      template = assigned(user, project, %{})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{worker_id: worker_id}}
      {:ok, _worker} = Workers.ready(Workers.get!(worker_id), %{"memory_budget" => 8_000})

      age_out_connected(worker_id)
      assert Workers.sweep_unreachable() == 1
      assert reloaded(template).failures == 0
    end

    test "a machine reaching ready clears what went before", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})
      Provisioning.failed(template.id, "nope")

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{worker_id: worker_id}}
      {:ok, _worker} = Workers.ready(Workers.get!(worker_id), %{"memory_budget" => 8_000})

      assert reloaded(template).failures == 0
    end

    # Past the timeout, the way `sweep_unreachable/0` measures it: from `last_seen_at` when the
    # machine has spoken, and from `inserted_at` when it never has.
    defp age_out(worker_id) do
      long_ago = DateTime.add(DateTime.utc_now(:second), -120)

      Forge.Repo.update_all(
        Ecto.Query.from(w in Forge.Workers.Worker, where: w.id == ^worker_id),
        set: [inserted_at: long_ago, last_seen_at: nil]
      )
    end

    defp age_out_connected(worker_id) do
      long_ago = DateTime.add(DateTime.utc_now(:second), -120)

      Forge.Repo.update_all(
        Ecto.Query.from(w in Forge.Workers.Worker, where: w.id == ^worker_id),
        set: [inserted_at: long_ago, last_seen_at: long_ago]
      )
    end

    defp reloaded(template), do: Forge.Repo.get!(Provisioning.Template, template.id)

    # The copying that makes a template a recipe: the machine is given these values, and does
    # not read through to the row it came from.
    test "a machine is given the template's values, not a reference to them", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{memory: 9_000, cores: 7, accepts: [:workflow]})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{worker_id: worker_id}}

      worker = Workers.get!(worker_id)
      assert worker.template_id == template.id
      assert worker.memory_budget == 9_000
      assert worker.cores == 7
      assert worker.accepts == [:workflow]

      # Editing the template afterwards reaches nothing that exists.
      {:ok, _} = Provisioning.update_template(user, template.id, %{memory: 1, cores: 1})
      assert Workers.get!(worker_id).memory_budget == 9_000
    end

    test "the ceiling is the template's own, not the node's", context do
      %{user: user, project: project} = context
      assigned(user, project, %{max_workers: 1})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, _opts}

      assert {:error, :at_capacity} = Workers.create_machine(demand(project_id: project.id))
      refute_receive {:provider_create, _opts}
    end

    # The distinction that keeps a job from queueing for ever: nothing assigned can *ever* hold
    # it, which is not the same as everything that could being busy.
    test "a job no template could ever hold is refused differently from a full one", context do
      %{user: user, project: project} = context
      assigned(user, project, %{memory: 4_000, cores: 4, max_workers: 1})

      assert {:error, {:no_template, :none_fit}} =
               Workers.create_machine(demand(project_id: project.id, memory: 99_000))

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert {:error, :at_capacity} = Workers.create_machine(demand(project_id: project.id))
    end

    # The image a template names has to reach the driver, or naming one is decorative — which
    # is what it was until `opts.image` existed and a node had one image for the whole fleet.
    test "the image the template names reaches the driver", context do
      %{user: user, project: project} = context
      assigned(user, project, %{image: "snapshot-42", size: "cpx32"})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{image: "snapshot-42", size: "cpx32"}}
    end

    # Null is passed as null and nothing above the driver substitutes for it: what no image means
    # is the driver's to say — the local one boots its host's image, Hetzner refuses (below).
    test "a template naming none leaves it to the driver", context do
      %{user: user, project: project} = context
      assigned(user, project, %{})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{image: nil}}
    end

    # **A Hetzner template saved before it had to name an image.** It is forced in here because
    # `Template.changeset/2` no longer lets one be made. It used to boot whatever
    # `Provider.config(:image)` held — the local driver's qcow2 path — and now it makes nothing,
    # sends nothing, and says why on the template, where the failure counter takes it out of
    # service like any other recipe that cannot work.
    test "a Hetzner template from before the rule makes nothing and says why", context do
      %{user: user, project: project} = context

      configure_provider(
        image: "/nix/store/worker-image/nixos.qcow2",
        request: fn _method, path, _token, _body -> flunk("sent #{path} to Hetzner") end
      )

      {:ok, credential} =
        Provisioning.create_credential(user, %{
          name: "hcloud",
          provider: "hetzner",
          secret: %{"token" => "t"}
        })

      template =
        assigned(user, project, %{
          provider: "hetzner",
          provider_credential_id: credential.id,
          size: "cpx32",
          image: "snapshot-42"
        })

      {1, _} =
        Forge.Repo.update_all(
          Ecto.Query.from(t in Provisioning.Template, where: t.id == ^template.id),
          set: [image: nil]
        )

      assert {:error, {:create_failed, {:hetzner, "the template names no image"}}} =
               Workers.create_machine(demand(project_id: project.id))

      assert reloaded(template).failures == 1
      assert reloaded(template).last_error == "the template names no image"
    end

    test "the credential travels to the driver, decrypted", context do
      %{user: user, project: project} = context

      {:ok, credential} =
        Provisioning.create_credential(user, %{
          name: "acct",
          provider: "fake",
          secret: %{"token" => "hcloud-secret"}
        })

      assigned(user, project, %{provider_credential_id: credential.id, size: "large"})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))

      assert_receive {:provider_create,
                      %{size: "large", credential: %{"token" => "hcloud-secret"}}}
    end

    # **A row saved before `Template.changeset/2` checked whose credential it held.** It cannot
    # be made through the changeset any more, so it is forced in here — and until the check was
    # repeated at creation, every machine made from it was billed to somebody else's account.
    test "a template holding another user's credential makes nothing and says why", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})

      {:ok, theirs} =
        Provisioning.create_credential(Forge.AccountsFixtures.user_fixture(), %{
          name: "theirs",
          provider: "fake",
          secret: %{"token" => "their-money"}
        })

      force_credential(template, theirs)

      assert {:error, {:create_failed, {:credential, message}}} =
               Workers.create_machine(demand(project_id: project.id))

      assert message == "its provider credential belongs to another user"
      refute_receive {:provider_create, _opts}
      # No row: nothing was made, so there is nothing to hold a slot or to sweep.
      assert Workers.list() == []
      assert reloaded(template).failures == 1
      assert reloaded(template).last_error == message
    end

    # With no row to hold a slot it is refused on every pass rather than once per sweep, which
    # is what takes it out of service in three passes — and the answer after that is the one a
    # disabled template gets, so the ticket sticks with a reason rather than waiting.
    test "and three passes of that take the template out of service", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})

      {:ok, theirs} =
        Provisioning.create_credential(Forge.AccountsFixtures.user_fixture(), %{
          name: "theirs",
          provider: "fake",
          secret: %{"token" => "t"}
        })

      force_credential(template, theirs)

      for _ <- 1..Provisioning.failure_limit() do
        assert {:error, {:create_failed, _}} =
                 Workers.create_machine(demand(project_id: project.id))
      end

      assert Provisioning.disabled?(reloaded(template))

      assert {:error, {:no_template, :all_disabled}} =
               Workers.create_machine(demand(project_id: project.id))

      refute_receive {:provider_create, _opts}
    end

    # The changeset's other half, asked again for the same reason: the owner's own credential
    # for another provider would be handed to a driver that cannot use it.
    test "a template holding a credential for another provider makes nothing", context do
      %{user: user, project: project} = context
      template = assigned(user, project, %{})

      {:ok, hetzner} =
        Provisioning.create_credential(user, %{
          name: "hcloud",
          provider: "hetzner",
          secret: %{"token" => "t"}
        })

      force_credential(template, hetzner)

      assert {:error, {:create_failed, {:credential, message}}} =
               Workers.create_machine(demand(project_id: project.id))

      assert message == "its provider credential is for hetzner, not fake"
      refute_receive {:provider_create, _opts}
      assert reloaded(template).last_error == message
    end

    defp force_credential(template, credential) do
      {1, _} =
        Forge.Repo.update_all(
          Ecto.Query.from(t in Provisioning.Template, where: t.id == ^template.id),
          set: [provider_credential_id: credential.id]
        )
    end
  end

  describe "when the driver refuses to make a machine" do
    # The bug as found on a running node: no image configured, so `create` refuses before
    # sending anything, the error goes back to the scheduler, and the scheduler reads every
    # error alike as *not right now*. Nothing logged, nothing on a row, nothing on a page — the
    # node made and swept a row every few minutes for ever and looked idle doing it.
    test "the reason is kept on the row that never became a machine" do
      %{project: project} = with_template(%{max_workers: 1})
      Provider.Fake.refuse({:hetzner, "no Hetzner image configured"})

      assert {:error, {:create_failed, _reason}} =
               Workers.create_machine(demand(memory: 1, project_id: project.id))

      assert [worker] = Workers.list()
      assert worker.last_error == "no Hetzner image configured"
      assert worker.provider_id == nil
    end

    # A driver's own words, because "create failed" sends an operator nowhere.
    test "a status and a message from the provider are both kept" do
      %{project: project} = with_template(%{max_workers: 1})
      Provider.Fake.refuse({:hetzner, 400, "server type not available in this location"})

      assert {:error, {:create_failed, _reason}} =
               Workers.create_machine(demand(memory: 1, project_id: project.id))

      assert [worker] = Workers.list()
      assert worker.last_error == "400: server type not available in this location"
    end

    # The row keeps its place against `max_workers`, which is what rate-limits the retry to one
    # attempt per sweep rather than one per scheduling pass. Destroying it here would let a
    # broken template make a row every two seconds for ever.
    test "the row holds its place rather than being destroyed at once" do
      %{project: project} = with_template(%{max_workers: 1})
      Provider.Fake.refuse({:hetzner, "nope"})

      assert {:error, {:create_failed, _reason}} =
               Workers.create_machine(demand(memory: 1, project_id: project.id))

      assert [%{status: :creating}] = Workers.list()

      # And the ceiling holds: no second row while the first is still there.
      assert {:error, :at_capacity} =
               Workers.create_machine(demand(memory: 1, project_id: project.id))

      assert length(Workers.list()) == 1
    end
  end

  describe "which driver speaks for a machine" do
    # The row, not the configuration. A node reconfigured between a machine being made and
    # being destroyed would otherwise hand the id to a driver where it means nothing — or,
    # worse, means somebody else's machine.
    test "a machine is destroyed through the provider that made it" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1"})

      configure_provider(default: "local")

      assert :ok = Workers.destroy(worker)
      assert_receive {:provider_destroy, "fake-1", _credential}
      assert Workers.get!(worker.id).status == :destroyed
    end

    # A row is marked destroyed even when its driver has gone away, or the row holds a
    # `max_workers` slot for ever and the queue never moves again — the deadlock
    # `worker-tier.md` § What the operator's machine settled records finding the hard way.
    # No driver to ask is not the same as a driver that refused: no number of retries produces
    # one, so retrying for ever is the deadlock rather than an escape from it.
    test "a machine whose provider this node no longer has is still recorded as gone" do
      {:ok, worker, _token} = Workers.create(%{provider: "departed"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "srv-1"})

      assert :ok = Workers.destroy(worker)

      gone = Workers.get!(worker.id)
      assert gone.status == :destroyed
      # And it says why, because the machine may well still be running somewhere.
      assert gone.last_error =~ "departed"
    end

    # **The leak this was found as.** `destroy/1` discarded the driver's answer and marked the
    # row destroyed either way, so a refused destroy read as a success: the machine kept
    # running and billing, `live_count/0` stopped counting it, its `max_workers` slot came
    # free, and the scheduler made a replacement. Three machines leaked on the dev node before
    # anybody looked at the provider's console.
    test "a destroy the driver refuses does not mark the row destroyed" do
      Provider.Fake.refuse_destroy({:fake, "nope"})
      on_exit(&Provider.Fake.allow/0)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1"})

      assert {:error, {:fake, "nope"}} = Workers.destroy(worker)

      kept = Workers.get!(worker.id)
      assert kept.status != :destroyed
      assert kept.last_error =~ "nope"
      # Still counted, which is what stops a replacement being made for a machine that is
      # there: the row is what `max_workers` counts, and a destroyed one is not counted.
      assert Enum.any?(Workers.list(), &(&1.id == worker.id and &1.status != :destroyed))
    end

    # The way out, and deliberately a person's: what it writes down is a claim about the world
    # that the platform could not check.
    test "a refused destroy can be forced, and says that it was" do
      Provider.Fake.refuse_destroy({:fake, "nope"})
      on_exit(&Provider.Fake.allow/0)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1"})

      assert :ok = Workers.destroy(worker, force: true)

      forced = Workers.get!(worker.id)
      assert forced.status == :destroyed
      assert forced.last_error =~ "nope"
    end

    # **What the leak was actually made of.** `create` was given the template's credential and
    # `destroy` was not, so on a node whose Hetzner account is a user's the delete was refused
    # before a request was sent. The machine is destroyed in the account that pays for it.
    test "the machine is destroyed with the credential it was made with" do
      {:ok, credential} =
        Provisioning.create_credential(Forge.AccountsFixtures.user_fixture(), %{
          name: "acct-#{System.unique_integer([:positive])}",
          provider: "fake",
          secret: %{"token" => "sekrit"}
        })

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.update(worker, %{provider_id: "fake-1", provider_credential_id: credential.id})

      assert :ok = Workers.destroy(worker)
      assert_receive {:provider_destroy, "fake-1", %{"token" => "sekrit"}}
    end
  end

  describe "providing a worker" do
    test "creates a machine when there is none, and the job waits for it" do
      %{project: project} = with_template(%{max_workers: 1})

      assert {:error, :creating} = Workers.provide(demand(memory: 1_000, project_id: project.id))
      assert_receive {:provider_create, %{worker_id: worker_id, token: token}}
      assert is_binary(token)

      worker = Workers.get!(worker_id)
      assert worker.status == :creating
      assert worker.provider_id == "fake-" <> worker_id

      # Still creating: nothing is offered, and no second machine is made.
      assert {:error, :at_capacity} =
               Workers.provide(demand(memory: 1_000, project_id: project.id))

      refute_receive {:provider_create, _opts}
    end

    # A machine made from a template runs on its owner's provider credential, so it serves the
    # projects that template is assigned to and nobody else's
    # (`docs/design/provisioning.md` § Whose account).
    test "a managed machine is offered only to projects its template is assigned to" do
      %{user: user, project: mine, template: template} = with_template()
      {:ok, other} = Forge.Projects.register(project_attrs(), user)
      worker = managed_worker(template)

      assert %{id: id} = Workers.assignable(demand(memory: 1_000, project_id: mine.id))
      assert id == worker.id
      refute Workers.assignable(demand(memory: 1_000, project_id: other.id))

      # Read through the assignment as it stands, so unassigning takes effect on a live machine.
      :ok = Provisioning.unassign(user, template.id, mine.id)
      refute Workers.assignable(demand(memory: 1_000, project_id: mine.id))
    end

    # A busy machine this project may use will be free again, so the job waits for it — even
    # once the template it came from is disabled and could make no other.
    test "a busy machine from the project's own template is a queue, even disabled" do
      %{project: project, template: template} = with_template()
      worker = managed_worker(template)
      running(Workers.get!(worker.id), memory_max: 8_000, cores: 4)
      {:ok, _} = template |> Ecto.Changeset.change(failures: 1_000) |> Forge.Repo.update()

      assert {:error, :at_capacity} =
               Workers.provide(demand(memory: 1_000, project_id: project.id))
    end

    # Waiting on a machine this project may never use is a queue that never moves, so another
    # project's busy machine must not turn "nothing assigned" into "at capacity".
    test "another project's machine is not a reason to wait" do
      %{user: user, template: template} = with_template()
      {:ok, other} = Forge.Projects.register(project_attrs(), user)
      managed_worker(template)

      assert {:error, {:no_template, :none_assigned}} =
               Workers.provide(demand(memory: 1_000, project_id: other.id))
    end

    test "offers the one it has rather than making another" do
      configure(slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
      :ok = Workers.connected(worker.id)
      serve!(worker, gate_project())

      assert {:ok, %{id: id}} = Workers.provide(demand(memory: 1_000))
      assert id == worker.id
      refute_receive {:provider_create, _opts}
    end
  end

  describe "idle destroy" do
    # Only a job ending used to make a machine idle, and only an idle machine is swept — so one
    # that came up and was never given anything sat `:ready` and billed for ever. Placing jobs by
    # project made that common: a machine whose template is unassigned before it boots is given
    # nothing, ever.
    test "a machine that comes up with nothing to do is idle from that moment" do
      %{template: template} = with_template()
      {:ok, worker, _token} = Workers.create(%{provider: "fake", template_id: template.id})

      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})

      assert worker.status == :idle
      assert worker.idle_since
    end

    test "a machine with a job running is ready, not idle" do
      worker = live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      running(worker, memory_max: 1_000, cores: 1)

      {:ok, worker} = Workers.ready(Workers.get!(worker.id), %{"memory_budget" => 8_000})

      assert worker.status == :ready
      assert worker.idle_since == nil
    end

    # Otherwise reconnecting would be a way for an idle machine to live for ever.
    test "reconnecting does not restart an idle machine's clock" do
      worker = live_worker(%{"memory_budget" => 8_000, "cores" => 4})
      long_ago = DateTime.add(DateTime.utc_now(:second), -3600)
      {:ok, worker} = Workers.update(worker, %{status: :idle, idle_since: long_ago})

      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000})

      assert worker.status == :idle
      assert worker.idle_since == long_ago
    end

    # The sweep used to run only when nothing at all was pending, so one job nobody could place
    # kept every idle machine on the node alive — and a conversation in a project with no
    # template is exactly such a job, for as long as it exists.
    test "a job nobody can place does not keep another project's idle machine alive" do
      configure(idle_period_ms: 60_000)
      %{user: user, template: template} = with_template()
      worker = managed_worker(template)

      {:ok, _} =
        Workers.update(Workers.get!(worker.id), %{
          provider_id: "fake-idle",
          status: :idle,
          idle_since: DateTime.add(DateTime.utc_now(:second), -3600)
        })

      {:ok, stranded} = Forge.Projects.register(project_attrs(), user)
      chat = chat_fixture(%{project: stranded})
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0

      assert Forge.Jobs.get!(chat.id).status == :pending
      assert Workers.get!(worker.id).status == :destroyed
    end

    # The scheduler marks a machine busy from the row it read at the start of the pass. A job that
    # ended in between made the row idle; a struct that still said busy wrote nothing, and the
    # sweep then destroyed the machine under the job it had just been given.
    test "busy is written from a stale read, and a machine with a job running is never swept" do
      configure(idle_period_ms: 60_000)
      %{template: template} = with_template()
      worker = managed_worker(template)
      {:ok, stale} = Workers.update(Workers.get!(worker.id), %{status: :busy})

      long_ago = DateTime.add(DateTime.utc_now(:second), -3600)
      {:ok, _} = Workers.update(Workers.get!(worker.id), %{status: :idle, idle_since: long_ago})

      assert {:ok, _} = Workers.busy(stale)
      assert %{status: :busy, idle_since: nil} = Workers.get!(worker.id)

      # And the sweep does not take a status's word for it: a row that says idle under a running
      # job, however it came to, keeps its machine.
      {:ok, _} = Workers.update(Workers.get!(worker.id), %{status: :idle, idle_since: long_ago})
      job = running(Workers.get!(worker.id), memory_max: 1_000, cores: 1)

      assert Workers.sweep_idle() == 0
      assert Workers.get!(worker.id).status == :idle

      {:ok, _} = job |> Ecto.Changeset.change(status: :finished) |> Forge.Repo.update()
      assert Workers.sweep_idle() == 1
    end

    # One period cannot serve two kinds of machine: an agent box is cheap by the hour and its
    # warm store is worth keeping, a command machine is expensive by the hour and its warm
    # store is worth more (`docs/design/provisioning.md` § Lifecycle is per template). Tested
    # both ways round, because a template period that were merely *also* consulted would pass a
    # test that only made it shorter.
    test "a machine's period is its template's, not the node's" do
      configure(idle_period_ms: 60_000)
      user = Forge.AccountsFixtures.user_fixture()

      patient = idle_worker(user, 3_600_000)
      hasty = idle_worker(user, 1)

      # The node says a minute; two minutes have passed. The template is what decides.
      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      for w <- [patient, hasty], do: Workers.update(Workers.get!(w.id), %{idle_since: long_ago})

      assert Workers.sweep_idle() == 1
      assert Workers.get!(hasty.id).status == :destroyed
      assert Workers.get!(patient.id).status == :idle
    end

    # The filter moved out of SQL when the period became per template, and `idle_since < cutoff`
    # in Postgres excluded a NULL for free — `NULL < x` is NULL, so the row simply did not
    # match. In Elixir it is a comparison that raises, inside a sweep the scheduler runs on
    # every pass. `update/2` is public and nothing stops this combination.
    test "an idle row with no clock on it is left alone rather than raising" do
      configure(idle_period_ms: 1)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{status: :idle, idle_since: nil})

      assert Workers.sweep_idle() == 0
      assert Workers.get!(worker.id).status == :idle
    end

    test "a machine from no template falls back to the node's period" do
      configure(idle_period_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-n", status: :idle})
      assert worker.template_id == nil

      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      {:ok, _} = Workers.update(Workers.get!(worker.id), %{idle_since: long_ago})

      assert Workers.sweep_idle() == 1
    end

    defp idle_worker(user, idle_ms) do
      {:ok, template} =
        Provisioning.create_template(user, %{
          name: "t-#{System.unique_integer([:positive])}",
          provider: "fake",
          memory: 8_000,
          cores: 4,
          max_workers: 1,
          idle_ms: idle_ms
        })

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.update(worker, %{
          provider_id: "fake-#{System.unique_integer([:positive])}",
          status: :idle,
          template_id: template.id
        })

      worker
    end

    test "destroys a machine that has had nothing to do for the period" do
      configure(idle_period_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-1", status: :ready})
      :ok = Workers.connected(worker.id)

      # Nothing has happened yet, so nothing is destroyed.
      assert Workers.sweep_idle() == 0

      :ok = Workers.release(worker.id)
      assert Workers.get!(worker.id).status == :idle
      assert Workers.sweep_idle() == 0

      # The clock, moved rather than waited on.
      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{idle_since: long_ago})

      assert Workers.sweep_idle() == 1
      assert_receive {:provider_destroy, "fake-1", _credential}
      assert Workers.get!(worker.id).status == :destroyed
    end

    test "a machine nothing can reach is destroyed, and its slot comes back" do
      configure(worker_timeout_ms: 60_000, slice_bytes: 1_000)
      %{project: project, template: template} = with_template(%{max_workers: 1, memory: 8_000})
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.update(worker, %{
          provider_id: "fake-1",
          status: :idle,
          # Its slot is the template's, because that is the only ceiling there is.
          template_id: template.id
        })

      {:ok, _worker} = Workers.ready(Workers.get!(worker.id), %{"memory_budget" => 8_000})

      # Out of touch, but not for long enough: a worker is disconnected for a moment every
      # time the platform restarts.
      assert Workers.sweep_unreachable() == 0

      long_ago = DateTime.add(DateTime.utc_now(:second), -120)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      # Before the sweep, this row is the whole of max_workers and nothing can be created.
      assert {:error, :at_capacity} =
               Workers.provide(demand(memory: 1_000, project_id: project.id))

      assert Workers.sweep_unreachable() == 1
      assert_receive {:provider_destroy, "fake-1", _credential}
      assert Workers.get!(worker.id).status == :destroyed

      # And the capacity it was holding is available again.
      assert {:error, :creating} = Workers.provide(demand(memory: 1_000, project_id: project.id))
    end

    test "a machine that never finished booting expires from when its row was made" do
      configure(worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-2", status: :creating})

      # It has never reported, so there is no last_seen_at to time it from.
      assert worker.last_seen_at == nil
      assert Workers.sweep_unreachable() == 0

      long_ago = DateTime.add(DateTime.utc_now(:second), -120)

      Forge.Repo.update_all(
        Ecto.Query.from(w in Forge.Workers.Worker, where: w.id == ^worker.id),
        set: [inserted_at: long_ago]
      )

      assert Workers.sweep_unreachable() == 1
      assert Workers.get!(worker.id).status == :destroyed
    end

    test "an unmanaged worker is never destroyed by either sweep", %{} do
      configure(idle_period_ms: 60_000, worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake", managed: false})
      {:ok, worker} = Workers.update(worker, %{status: :idle})
      long_ago = DateTime.add(DateTime.utc_now(:second), -600)

      {:ok, _worker} =
        Workers.update(Workers.get!(worker.id), %{idle_since: long_ago, last_seen_at: long_ago})

      # The operator's machine, idle for ten minutes and out of touch for ten minutes. Neither
      # is the platform's business: it did not make this machine and cannot make another.
      assert Workers.sweep_idle() == 0
      assert Workers.sweep_unreachable() == 0
      assert Workers.get!(worker.id).status == :idle
      refute_receive {:provider_destroy, _id, _credential}
    end

    test "an unreachable unmanaged worker loses its jobs but keeps its row", %{} do
      configure(worker_timeout_ms: 60_000)

      {:ok, project} =
        register_owned!(%{
          name: "perm-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        })

      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "x"}, :system)
      [job] = Forge.Jobs.for_ticket(ticket.id)

      {:ok, worker, _token} = Workers.create(%{provider: "fake", managed: false})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Workers.connected(worker.id)
      funded!(project)
      {:ok, _job} = Forge.Jobs.assign(job, worker)
      assert Forge.Jobs.get!(job.id).status == :running

      # The machine goes quiet. Its work has to come back — nothing is watching it — but a
      # destroyed row could never rejoin, and this machine may well return.
      Registry.unregister(Forge.Workers.Registry, worker.id)
      long_ago = DateTime.add(DateTime.utc_now(:second), -600)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      assert Workers.sweep_unreachable() == 1
      assert Forge.Jobs.get!(job.id).status == :pending
      refute Workers.get!(worker.id).status == :destroyed

      # And it does not keep saying so once there is nothing left to re-queue.
      assert Workers.sweep_unreachable() == 0
    end

    test "a connected worker is never swept, however quiet it has been" do
      configure(worker_timeout_ms: 60_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.update(worker, %{provider_id: "fake-3", status: :ready})
      :ok = Workers.connected(worker.id)

      long_ago = DateTime.add(DateTime.utc_now(:second), -600)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: long_ago})

      assert Workers.sweep_unreachable() == 0
      assert Workers.get!(worker.id).status == :ready
    end

    test "a worker with a job on it is not idle" do
      {:ok, project} =
        register_owned!(%{
          name: "idle-#{System.unique_integer([:positive])}",
          repo_path: Forge.GitFixtures.seeded_repo()
        })

      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "x"}, :system)
      [job] = Forge.Jobs.for_ticket(ticket.id)

      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      :ok = Workers.connected(worker.id)
      funded!(project)
      {:ok, _job} = Forge.Jobs.assign(job, worker)

      assert Workers.get!(worker.id).status == :busy
      :ok = Workers.release(worker.id)
      assert Workers.get!(worker.id).status == :busy
    end
  end

  # **A person's one write on a machine, guarded where it is made.** It was guarded only on the
  # workers page, which matched `managed: false` itself and then called `update/2` — no actor,
  # every field cast. These call the context directly, which is what a page that forgot the
  # check would reach (`docs/design/identity.md` § Where the guard lives).
  describe "setting what a permanent machine offers" do
    setup do
      user = Forge.AccountsFixtures.user_fixture()

      {:ok, worker, _token} =
        Workers.create(%{provider: "fake", managed: false, user_id: user.id})

      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
      %{worker: worker, user: user}
    end

    test "the owner sets the three figures, and only those", context do
      %{worker: worker, user: user} = context

      assert {:ok, _worker} =
               Workers.set_offer(user, worker.id, %{
                 memory_budget: 2_000,
                 cores: 2,
                 accepts: [:chat],
                 # None of these is a figure. `update/2` would have written every one.
                 managed: true,
                 status: :destroyed,
                 token_hash: "chosen-by-the-client",
                 provider_id: "somebody-elses-server"
               })

      saved = Workers.get!(worker.id)
      assert {saved.memory_budget, saved.cores, saved.accepts} == {2_000, 2, [:chat]}
      assert saved.managed == false
      assert saved.status == worker.status
      assert saved.token_hash == worker.token_hash
      assert saved.provider_id == worker.provider_id
    end

    # The id is off the wire: well-formed and unknown, malformed, or not a string at all.
    test "an id that names no machine is not found rather than a crash", %{user: user} do
      for id <- [Ecto.UUID.generate(), "not-a-uuid", nil, %{"id" => "x"}] do
        assert {:error, :not_found} = Workers.set_offer(user, id, %{memory_budget: 1, cores: 1}),
               "#{inspect(id)} should not be found"
      end
    end

    # A blank figure would silently un-gate the machine it was meant to correct.
    test "a blank figure is refused rather than stored", %{worker: worker, user: user} do
      for attrs <- [%{memory_budget: nil, cores: 2}, %{memory_budget: 2_000, cores: nil}] do
        assert {:error, %Ecto.Changeset{}} = Workers.set_offer(user, worker.id, attrs)
      end

      for attrs <- [%{memory_budget: -1, cores: 2}, %{memory_budget: 2_000, cores: -1}] do
        assert {:error, %Ecto.Changeset{}} = Workers.set_offer(user, worker.id, attrs)
      end

      saved = Workers.get!(worker.id)
      assert {saved.memory_budget, saved.cores} == {8_000, 4}
    end
  end

  # The models are the worker's answer, not the platform's assumption: the platform holds no
  # credential and a fleet may hold more than one. See docs/design/worker-channel.md § What a
  # worker offers.
  describe "what the workers offer" do
    test "ready keeps what the machine said about its harness" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.ready(worker, %{
          "memory_budget" => 8_000,
          "harness" => %{
            "driver" => "claude_code",
            "version" => "2.1.220",
            "credential" => "per_job",
            "aliases" => ["opus"]
          }
        })

      assert worker.harness["version"] == "2.1.220"
      assert Workers.runs?(worker, "claude_code")
    end

    # A worker running a release older than the probe sends no `harness` at all. Clearing the
    # column on its next `ready` would make an update that touched nothing else look like a
    # machine that suddenly offers nothing.
    test "a ready with no harness keeps the last answer rather than erasing it" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.ready(worker, %{
          "memory_budget" => 8_000,
          "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
        })

      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => nil})

      assert worker.harness["driver"] == "claude_code"
    end

    # The aliases are a property of the harness binary, so they are the machines'. Union and not
    # intersection: an alias only one worker resolves is a half-finished image rollout, not a name
    # to refuse.
    test "the aliases are the union of the live workers', each once" do
      {:ok, one, _t1} = Workers.create(%{provider: "fake"})
      {:ok, two, _t2} = Workers.create(%{provider: "fake"})
      {:ok, gone, _t3} = Workers.create(%{provider: "fake"})

      {:ok, _one} =
        Workers.ready(one, %{"memory_budget" => 8_000, "harness" => %{"aliases" => ~w(a shared)}})

      {:ok, _two} =
        Workers.ready(two, %{"memory_budget" => 8_000, "harness" => %{"aliases" => ~w(shared b)}})

      {:ok, gone} =
        Workers.ready(gone, %{"memory_budget" => 8_000, "harness" => %{"aliases" => ~w(dead)}})

      {:ok, _gone} = Workers.status(gone, :destroyed)

      aliases = Workers.offered(nil).aliases
      assert Enum.sort(aliases) == ~w(a b shared)
    end

    # **The models are the accounts', not the machines'.** A machine holds no credential, so
    # which models may be called is read from the credentials in the project's pool — the set a
    # job there will actually run under (`docs/design/credentials.md` § Checked on save). What a
    # machine of an older release still says about models is ignored.
    test "the models are the project's pool's, and nobody else's" do
      {:ok, here} = register_owned!(project_attrs())
      {:ok, there} = register_owned!(project_attrs())
      owner = Forge.AccountsFixtures.user_fixture()

      pool!(here, credential_fixture(owner, models: [model("a"), model("shared")]))
      pool!(here, credential_fixture(owner, models: [model("shared"), model("b")]))
      pool!(there, credential_fixture(owner, models: [model("elsewhere")]))

      revoked = pool!(here, credential_fixture(owner, models: [model("revoked")]))
      {:ok, _} = Forge.Credentials.revoke(owner, revoked.id)

      {:ok, old, _t} = Workers.create(%{provider: "fake"})

      {:ok, _old} =
        Workers.ready(old, %{
          "memory_budget" => 8_000,
          "harness" => %{"models" => [model("from-a-machine")]}
        })

      ids = Enum.map(Workers.offered(here.id).models, & &1.id)
      assert Enum.sort(ids) == ~w(a b shared)
    end

    test "no project, or a pool with nothing in it, offers no models" do
      {:ok, empty} = register_owned!(project_attrs())

      assert Workers.offered(nil).models == []
      assert Workers.offered(empty.id).models == []
    end

    # A provider is free to list a model with no label, and a row with no id at all. Neither is
    # a reason to drop what is usable: a missing label is not a missing model.
    test "a model with no id is skipped and one with no name keeps its id" do
      {:ok, project} = register_owned!(project_attrs())
      owner = Forge.AccountsFixtures.user_fixture()
      pool!(project, credential_fixture(owner, models: [%{"id" => "bare"}, %{"name" => "no id"}]))

      assert Workers.offered(project.id).models == [%{id: "bare", name: "bare"}]
    end
  end

  defp model(id), do: %{"id" => id, "name" => String.upcase(id)}

  # A job's three questions, with room to spare in whichever dimension a test is not about.
  # A demand is for a project, and the gate's own tests ask on behalf of `gate_project/0` unless
  # they say otherwise. `project_id: nil` is a demand naming none, which is its own case.
  defp demand(opts) do
    base = %{
      kind: Keyword.get(opts, :kind, :workflow),
      memory: Keyword.get(opts, :memory, 1),
      cores: Keyword.get(opts, :cores, 1)
    }

    case Keyword.fetch(opts, :project_id) do
      {:ok, nil} -> base
      {:ok, project_id} -> Map.put(base, :project_id, project_id)
      :error -> Map.put(base, :project_id, gate_project().id)
    end
  end

  # **Every machine a gate test makes serves a project**, because a job runs only on a machine
  # assigned to its own (`docs/design/identity.md` § Workers). One per test, made on first use and
  # kept in the test's process, so a test whose subject is memory or kinds need not name it.
  defp gate_project do
    case Process.get(:gate_project) do
      nil ->
        {:ok, project} = register_owned!(project_attrs())
        Process.put(:gate_project, project)
        project

      project ->
        project
    end
  end

  # Makes a worker unambiguously the oldest, since `inserted_at` is second-granular and two
  # rows written in one test are otherwise tied.
  defp age(worker) do
    worker
    |> Ecto.Changeset.change(%{inserted_at: DateTime.add(DateTime.utc_now(:second), -3600)})
    |> Forge.Repo.update!()
  end

  defp live_worker(report) do
    {:ok, worker, _token} = Workers.create(%{provider: "fake"})
    {:ok, worker} = Workers.ready(worker, report)
    :ok = Workers.connected(worker.id)
    serve!(worker, gate_project())
  end

  # A connected machine as the platform makes one: from `template`, carrying its id.
  defp managed_worker(template) do
    {:ok, worker, _token} =
      Workers.create(%{provider: "fake", managed: true, template_id: template.id})

    {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
    :ok = Workers.connected(worker.id)
    worker
  end

  # A job occupying part of a worker. `:running` rather than pending, because that is what
  # `promised/1` counts.
  defp running(worker, attrs) do
    job_fixture(%{status: :running, worker_id: worker.id})
    |> Ecto.Changeset.change(Map.new(attrs))
    |> Forge.Repo.update!()
  end
end
