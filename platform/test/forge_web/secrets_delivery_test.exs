defmodule ForgeWeb.SecretsDeliveryTest do
  @moduledoc """
  A project secret on its way to a job (`docs/design/secrets.md` § Delivery): named by the
  workflow or picked for a conversation, resolved before a machine is asked for, sealed for one
  worker, one job and one purpose, and recorded by id and version — never by value.
  """

  use ForgeWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Events, Jobs, Operator, Projects, Tickets, Workers}
  alias Forge.Jobs.{Commands, Job}
  alias ForgeCore.Job.{Credential, Result}
  alias ForgeWeb.{WorkerChannel, WorkerSocket}

  @workflow """
  version: 1
  initial: refining
  commands:
    publish:
      run: .forge/commands/publish.sh
      timeout: 10m
      secrets: [CARGO_REGISTRY_TOKEN]
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 20, cost: 0.50 }
      secrets: [STRIPE_TEST_KEY]
      may_invoke:
        publish: { max: 2 }
    done: {}
  transitions:
    - { from: refining, to: done }
  limits:
    ticket_cost: 5
  """

  @stripe "sk_test_51Hx-the-project's-own"
  @cargo "cio_the-registry-token"

  setup do
    {:ok, worker, token} = Workers.create(%{provider: "local"})

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/commands/publish.sh" => "#!/bin/sh\necho published\n"
      })

    admin = Forge.AccountsFixtures.user_fixture()

    {:ok, project} =
      Projects.register(
        %{name: "deliver-#{System.unique_integer([:positive])}", repo_path: repo},
        admin
      )

    funded!(project)
    %{worker: worker, token: token, project: project, admin: admin}
  end

  defp join_ready(worker, token) do
    {:ok, _reply, _socket} =
      worker
      |> then(&connect(WorkerSocket, %{"worker_id" => &1.id}, bearer(token)))
      |> then(fn {:ok, socket} -> socket end)
      |> subscribe_and_join(WorkerChannel, "worker:#{worker.id}", %{
        "protocol" => ForgeCore.WorkerProtocol.current()
      })

    {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
    worker
  end

  defp bearer(token), do: [connect_info: %{x_headers: [{"x-forge-worker-token", token}]}]

  defp admit(project) do
    {:ok, ticket} = Tickets.admit(project, %{title: "Take payments"}, :system)
    [job] = Jobs.for_ticket(ticket.id)
    {ticket, job}
  end

  defp opened(sealed, token, job_id) do
    {:ok, hash} = Credential.token_hash(token)
    {:ok, json} = Credential.open(sealed, hash, job_id, :secrets)
    Jason.decode!(json)
  end

  defp secrets_events(job_id),
    do: for(%{type: "job.secrets"} = e <- Events.for_job(job_id), do: e)

  describe "a workflow job" do
    test "carries the secrets its state names, sealed for this worker, this job and this purpose",
         %{worker: worker, token: token, project: project, admin: admin} do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      {:ok, _other} = Operator.set_secret(project, admin, "UNNAMED_KEY", "sk_not_named_anywhere")

      # Another project's secret of the same name is another project's.
      elsewhere = project_fixture()
      their_admin = member_fixture(elsewhere, :admin)
      {:ok, _} = Operator.set_secret(elsewhere, their_admin, "STRIPE_TEST_KEY", "sk_test_theirs")

      {_ticket, job} = admit(project)
      assert job.secret_names == ["STRIPE_TEST_KEY"]

      worker = join_ready(worker, token)
      {:ok, _job} = Jobs.assign(job, worker)

      job_id = job.id
      assert_push "assign", %{"job_id" => ^job_id} = assignment

      # Only what the state names, and in the clear nowhere on the way. The spec names what the
      # run holds, which is what its manifest tells the agent.
      assert opened(assignment["secrets"], token, job_id) == %{"STRIPE_TEST_KEY" => @stripe}
      assert assignment["spec"]["secrets"] == ["STRIPE_TEST_KEY"]
      refute inspect(assignment, limit: :infinity) =~ @stripe
      refute inspect(assignment, limit: :infinity) =~ "sk_not_named_anywhere"

      # Not the credential's purpose, and not another job's.
      {:ok, hash} = Credential.token_hash(token)
      assert Credential.open(assignment["secrets"], hash, job_id) == :error

      assert Credential.open(assignment["secrets"], hash, Ecto.UUID.generate(), :secrets) ==
               :error

      assert [event] = secrets_events(job_id)

      assert event.payload == %{
               "held" => [
                 %{"secret_id" => secret.id, "name" => "STRIPE_TEST_KEY", "version" => 1}
               ],
               "gone" => []
             }
    end

    test "that names none sends what it always sent", %{worker: worker, token: token} do
      {:ok, project} =
        register_owned!(%{
          name: "plain-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        })

      funded!(project)
      {_ticket, job} = admit(project)
      assert job.secret_names == []

      worker = join_ready(worker, token)
      {:ok, _job} = Jobs.assign(job, worker)

      assert_push "assign", assignment
      refute Map.has_key?(assignment, "secrets")
      assert secrets_events(job.id) == []
    end

    # Resolved again at assignment, the answer that counts: deleted between the scheduler's look
    # and the assignment, the job goes back to pending and the next pass sticks its ticket.
    test "naming a secret deleted since goes back to pending, holding nothing", %{
      worker: worker,
      token: token,
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      {_ticket, job} = admit(project)
      {:ok, _} = Operator.delete_secret(project, admin, secret.id)

      worker = join_ready(worker, token)
      assert Jobs.assign(job, worker) == {:error, {:no_secret, ["STRIPE_TEST_KEY"]}}

      refute_push "assign", _assignment
      assert Jobs.get!(job.id).status == :pending
    end

    # A value this node cannot open — a rotated `secret_key_base` — is named, and the job is not
    # run with some of what it names: it goes back to pending, as for a deletion.
    test "naming a secret this node cannot open goes back to pending, holding nothing", %{
      worker: worker,
      token: token,
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)

      sealed_elsewhere =
        Plug.Crypto.MessageEncryptor.encrypt(
          Jason.encode!(%{"value" => @stripe}),
          "forge/secrets/v1",
          :crypto.strong_rand_bytes(32),
          "unused"
        )

      Forge.Repo.update_all(from(s in Forge.Secrets.Secret, where: s.id == ^secret.id),
        set: [value: sealed_elsewhere]
      )

      {_ticket, job} = admit(project)
      worker = join_ready(worker, token)

      ExUnit.CaptureLog.capture_log(fn ->
        assert Jobs.assign(job, worker) == {:error, {:secrets_unreadable, ["STRIPE_TEST_KEY"]}}
      end)

      refute_push "assign", _assignment
      assert Jobs.get!(job.id).status == :pending
      assert secrets_events(job.id) == []
    end

    # A release from before secrets ignores them and would run the job without them — and this
    # release has to speak the protocol it asks for, or no job holding one is ever placed.
    test "that holds a secret needs a worker that speaks protocol 6", %{project: project} do
      {_ticket, job} = admit(project)
      assert Jobs.protocol(job) == 6
      assert Jobs.protocol(job) <= ForgeCore.WorkerProtocol.current()
      assert Jobs.protocol(%{job | secret_names: []}) == 3
      assert Jobs.protocol(%Job{kind: :command, secret_names: ["X_KEY"]}) == 6
      assert Jobs.protocol(%Job{kind: :command, secret_names: []}) == 2
    end
  end

  describe "the scheduler" do
    # Before a machine is asked for, like the credential: the ticket sticks saying who can fix it,
    # and setting the secret is an arrival that brings it back.
    test "sticks a ticket whose job names a secret the project has not set, until it is set", %{
      project: project,
      admin: admin
    } do
      # The same name set in another project sets nothing here.
      elsewhere = project_fixture()
      their_admin = member_fixture(elsewhere, :admin)
      {:ok, _} = Operator.set_secret(elsewhere, their_admin, "STRIPE_TEST_KEY", @stripe)

      {ticket, _job} = admit(project)
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0
      assert Tickets.get!(ticket.id).status == :stuck

      assert %{"cause" => "placement", "reason" => reason} =
               Events.for_ticket(ticket.id)
               |> Enum.find(&(&1.type == "ticket.stuck"))
               |> Map.fetch!(:payload)

      assert reason ==
               "the state `refining` names `STRIPE_TEST_KEY`, which this project has not set; " <>
                 "a project admin sets it in the project's settings"

      # Any new secret is an arrival, as any assignment is (`Engine.resume_placement/2`): one by
      # another name brings the ticket back, and the next pass sticks it again for the same reason.
      {:ok, _} = Operator.set_secret(project, admin, "UNNAMED_KEY", @stripe)
      assert Tickets.get!(ticket.id).status == :active
      assert Forge.Jobs.Scheduler.tick() == 0
      assert Tickets.get!(ticket.id).status == :stuck

      # A new version of a secret that already existed answers no stick.
      {:ok, _} = Operator.set_secret(project, admin, "UNNAMED_KEY", "sk_test_the-second-one")
      assert Tickets.get!(ticket.id).status == :stuck

      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      assert Tickets.get!(ticket.id).status == :active
    end

    # A deleted secret is not set: the same stick, naming it, and not a machine looked for.
    test "sticks a ticket whose job names a secret deleted since", %{
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      {ticket, _job} = admit(project)
      {:ok, _} = Operator.delete_secret(project, admin, secret.id)

      start_supervised!(Forge.Jobs.Scheduler)
      assert Forge.Jobs.Scheduler.tick() == 0
      assert Tickets.get!(ticket.id).status == :stuck

      assert %{"reason" => reason} =
               Events.for_ticket(ticket.id)
               |> Enum.find(&(&1.type == "ticket.stuck"))
               |> Map.fetch!(:payload)

      assert reason =~
               "the state `refining` names `STRIPE_TEST_KEY`, which this project has not set"
    end
  end

  describe "a command" do
    test "sticks its ticket naming itself, not the state that invoked it", %{project: project} do
      {ticket, job, workflow, _spec} = invoking(project)
      # Only the command is pending, so the stick the pass writes is the command's.
      Forge.Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [status: :finished])

      {:ok, _command} =
        Commands.insert(Forge.Repo, ticket, workflow, %{
          command: "publish",
          args: [],
          at: ticket.base_commit,
          state: "refining",
          parent: nil,
          batch: "batch-1",
          concurrent: nil
        })

      start_supervised!(Forge.Jobs.Scheduler)
      assert Forge.Jobs.Scheduler.tick() == 0

      assert %{"reason" => reason} =
               Events.for_ticket(ticket.id)
               |> Enum.find(&(&1.type == "ticket.stuck"))
               |> Map.fetch!(:payload)

      assert reason =~ "the command `publish` names `CARGO_REGISTRY_TOKEN`"
    end

    defp invoking(project) do
      {ticket, job} = admit(project)
      workflow = Tickets.workflow(ticket)
      spec = Jobs.spec(job)
      {ticket, job, workflow, spec}
    end

    # Its own secrets, whoever invokes it; an agent asking for one that names an unset secret is
    # told why, and the refusal does not count against its grant.
    test "an agent's invocation naming an unset secret is refused, and allowed once it is set", %{
      project: project,
      admin: admin
    } do
      {_ticket, job, workflow, spec} = invoking(project)

      result = %Result{
        status: :parked,
        invocations: [%{"command" => "publish", "args" => ["--dry"]}]
      }

      # A refusal is not an invocation: three refused in one batch, against a grant of two, are
      # all refused for the secret and none for the grant.
      thrice = %{result | invocations: List.duplicate(hd(result.invocations), 3)}
      refusals = Commands.decide(job, spec, workflow, thrice)
      assert length(refusals) == 3

      for {:refused, %{"refused" => why}} <- refusals,
          do: assert(why =~ "names `CARGO_REGISTRY_TOKEN`")

      assert [{:refused, refusal}] = Commands.decide(job, spec, workflow, result)

      assert refusal == %{
               "command" => "publish",
               "args" => ["--dry"],
               "refused" =>
                 "the command `publish` names `CARGO_REGISTRY_TOKEN`, which this project has " <>
                   "not set; " <>
                   "a project admin sets it in the project's settings"
             }

      {:ok, _} = Operator.set_secret(project, admin, "CARGO_REGISTRY_TOKEN", @cargo)
      assert [{:run, %{command: "publish"}}] = Commands.decide(job, spec, workflow, result)
    end

    test "carries the secrets its declaration names, not its invoker's", %{
      worker: worker,
      token: token,
      project: project,
      admin: admin
    } do
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      {:ok, _} = Operator.set_secret(project, admin, "CARGO_REGISTRY_TOKEN", @cargo)
      {ticket, job, workflow, _spec} = invoking(project)

      {:ok, command} =
        Commands.insert(Forge.Repo, ticket, workflow, %{
          command: "publish",
          args: [],
          at: ticket.base_commit,
          state: "refining",
          parent: job.id,
          batch: "batch-1",
          concurrent: nil
        })

      assert command.secret_names == ["CARGO_REGISTRY_TOKEN"]

      worker = join_ready(worker, token)
      {:ok, _} = Jobs.assign(command, worker)

      command_id = command.id
      assert_push "assign", %{"job_id" => ^command_id, "kind" => "command"} = assignment

      assert opened(assignment["secrets"], token, command_id) == %{
               "CARGO_REGISTRY_TOKEN" => @cargo
             }

      # And its run is recorded as an agent's is: what the settings row's *last held* reads.
      assert [%{payload: %{"held" => [%{"name" => "CARGO_REGISTRY_TOKEN", "version" => 1}]}}] =
               secrets_events(command_id)
    end
  end

  describe "a conversation" do
    # A conversation sticks nothing and waits on no secret: the pass goes on to find it a machine,
    # and here says there is no template — not that a secret is missing.
    test "is not held back by the scheduler for a secret deleted since it was opened", %{
      project: project,
      admin: admin
    } do
      {:ok, gone} = Operator.set_secret(project, admin, "GONE_KEY", "sk_test_deleted-soon")
      {:ok, chat} = Conversations.open(project, "hi", secrets: ["GONE_KEY"])
      {:ok, _} = Operator.delete_secret(project, admin, gone.id)

      start_supervised!(Forge.Jobs.Scheduler)
      Forge.Jobs.Scheduler.tick()

      assert %{payload: %{"reason" => "none_assigned"}} = Jobs.current_wait(Jobs.get!(chat.id))
    end

    test "holds what the person opening it picked, and only from its own project", %{
      project: project,
      admin: admin
    } do
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)

      elsewhere = project_fixture()
      their_admin = member_fixture(elsewhere, :admin)
      {:ok, _} = Operator.set_secret(elsewhere, their_admin, "THEIR_KEY", @stripe)

      assert Conversations.open(project, "hi", secrets: ["THEIR_KEY"]) ==
               {:error, {:unknown_secrets, ["THEIR_KEY"]}}

      assert Conversations.open(project, "hi", secrets: ["NOT_SET"]) ==
               {:error, {:unknown_secrets, ["NOT_SET"]}}

      assert Conversations.open(project, "hi", secrets: "STRIPE_TEST_KEY") ==
               {:error, {:unknown_secrets, []}}

      # A name that is not a string is no secret's, and is refused before any query.
      assert Conversations.open(project, "hi", secrets: [1]) == {:error, {:unknown_secrets, []}}

      # Ticked twice off the wire is held once, and counted once on the settings row.
      assert {:ok, chat} =
               Conversations.open(project, "hi", secrets: ["STRIPE_TEST_KEY", "STRIPE_TEST_KEY"])

      assert chat.secret_names == ["STRIPE_TEST_KEY"]

      assert {:ok, plain} = Conversations.open(project, "hi")
      assert plain.secret_names == []
    end

    # A conversation does not stick on a secret deleted since it was opened: it holds what is
    # still set, and its run's record says what is not.
    test "holds what is still set and records what is gone", %{
      worker: worker,
      token: token,
      project: project,
      admin: admin
    } do
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @stripe)
      {:ok, gone} = Operator.set_secret(project, admin, "GONE_KEY", "sk_test_deleted-soon")

      {:ok, chat} = Conversations.open(project, "hi", secrets: ["STRIPE_TEST_KEY", "GONE_KEY"])
      {:ok, _} = Operator.delete_secret(project, admin, gone.id)

      worker = join_ready(worker, token)
      {:ok, _} = Jobs.assign(chat, worker)

      chat_id = chat.id
      assert_push "assign", %{"job_id" => ^chat_id} = assignment
      assert opened(assignment["secrets"], token, chat_id) == %{"STRIPE_TEST_KEY" => @stripe}
      assert assignment["spec"]["secrets"] == ["STRIPE_TEST_KEY"]
      # And the agent is told, so a resumed session does not go looking for it.
      assert assignment["spec"]["secrets_gone"] == ["GONE_KEY"]

      assert [%{payload: %{"gone" => ["GONE_KEY"], "held" => [%{"name" => "STRIPE_TEST_KEY"}]}}] =
               secrets_events(chat_id)
    end
  end
end
