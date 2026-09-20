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

  defp project_attrs do
    n = System.unique_integer([:positive])
    %{name: "proj-#{n}", repo_path: Path.join(System.tmp_dir!(), "forge-w-#{n}.git")}
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
      configure(max_workers: 1)

      assert {:error, {:no_template, :none_assigned}} =
               Workers.create_machine(demand(project_id: project.id))

      refute_receive {:provider_create, _opts}
      assert Workers.list() == []
    end

    # A demand with no project cannot name a template either, and that path must not be the one
    # left that can still make a machine out of node configuration.
    test "a demand naming no project makes nothing" do
      configure(max_workers: 1)

      assert {:error, {:no_template, :none_assigned}} = Workers.create_machine(demand(memory: 1))
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
      {:ok, _worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
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
      {:ok, _} = Provisioning.update_template(template, %{memory: 1, cores: 1})
      assert Workers.get!(worker_id).memory_budget == 9_000
    end

    test "the ceiling is the template's own, not the node's", context do
      %{user: user, project: project} = context
      configure(max_workers: 99)
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

    # Null is not "no image": it is *the node's*, which is what every template made before the
    # column has and what keeps them able to create.
    test "a template naming none leaves the driver to its own default", context do
      %{user: user, project: project} = context
      assigned(user, project, %{})

      assert {:error, :creating} = Workers.create_machine(demand(project_id: project.id))
      assert_receive {:provider_create, %{image: nil}}
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

    test "offers the one it has rather than making another" do
      configure(max_workers: 1, slice_bytes: 1_000)
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "cores" => 4})
      :ok = Workers.connected(worker.id)

      assert {:ok, %{id: id}} = Workers.provide(demand(memory: 1_000))
      assert id == worker.id
      refute_receive {:provider_create, _opts}
    end
  end

  describe "idle destroy" do
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
      configure(max_workers: 1, worker_timeout_ms: 60_000)
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
      {:ok, _job} = Forge.Jobs.assign(job, worker)

      assert Workers.get!(worker.id).status == :busy
      :ok = Workers.release(worker.id)
      assert Workers.get!(worker.id).status == :busy
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
            "login" => "ok",
            "models" => [%{"id" => "claude-opus-5", "name" => "Claude Opus 5"}]
          }
        })

      assert worker.harness["version"] == "2.1.220"
      assert Workers.models() == [%{id: "claude-opus-5", name: "Claude Opus 5"}]
    end

    # A worker running a release older than the probe sends no `harness` at all. Clearing the
    # column on its next `ready` would make an update that touched nothing else look like a
    # machine that suddenly offers nothing.
    test "a ready with no harness keeps the last answer rather than erasing it" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, worker} =
        Workers.ready(worker, %{
          "memory_budget" => 8_000,
          "harness" => %{"models" => [%{"id" => "m", "name" => "M"}]}
        })

      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => nil})

      assert worker.harness["models"] == [%{"id" => "m", "name" => "M"}]
    end

    test "the union of the live workers, each model once" do
      {:ok, one, _t1} = Workers.create(%{provider: "fake"})
      {:ok, two, _t2} = Workers.create(%{provider: "fake"})
      {:ok, gone, _t3} = Workers.create(%{provider: "fake"})

      {:ok, _one} =
        Workers.ready(one, %{
          "memory_budget" => 8_000,
          "harness" => %{"models" => [model("a"), model("shared")]}
        })

      {:ok, _two} =
        Workers.ready(two, %{
          "memory_budget" => 8_000,
          "harness" => %{"models" => [model("shared"), model("b")]}
        })

      {:ok, gone} =
        Workers.ready(gone, %{
          "memory_budget" => 8_000,
          "harness" => %{"models" => [model("only-on-the-dead-one")]}
        })

      {:ok, _gone} = Workers.status(gone, :destroyed)

      ids = Enum.map(Workers.models(), & &1.id)

      # Union and not intersection: a model only one worker has is a model the fleet can run,
      # and refusing it would refuse work that would have succeeded.
      assert Enum.sort(ids) == ~w(a b shared)
      assert Enum.count(ids, &(&1 == "shared")) == 1
    end

    test "nothing connected offers nothing, and says so by being empty" do
      {:ok, _worker, _token} = Workers.create(%{provider: "fake"})

      assert Workers.models() == []
    end

    # A worker is free to report a model the platform has never heard of and one with no label
    # at all. Neither is a reason to drop it: the list is an offer, and a missing label is not a
    # missing model.
    test "a malformed row is skipped and an unlabelled one keeps its id" do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})

      {:ok, _worker} =
        Workers.ready(worker, %{
          "memory_budget" => 8_000,
          "harness" => %{
            "models" => [%{"id" => "bare"}, %{"name" => "no id at all"}, "not even a map"]
          }
        })

      assert Workers.models() == [%{id: "bare", name: "bare"}]
    end
  end

  defp model(id), do: %{"id" => id, "name" => String.upcase(id)}

  # A job's three questions, with room to spare in whichever dimension a test is not about.
  defp demand(opts) do
    base = %{
      kind: Keyword.get(opts, :kind, :workflow),
      memory: Keyword.get(opts, :memory, 1),
      cores: Keyword.get(opts, :cores, 1)
    }

    case Keyword.get(opts, :project_id) do
      nil -> base
      project_id -> Map.put(base, :project_id, project_id)
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
