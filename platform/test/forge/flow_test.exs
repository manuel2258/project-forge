defmodule Forge.FlowTest do
  @moduledoc """
  The milestone 1 loop, end to end, against the fake harness: admit a ticket, run jobs,
  approve, answer a blocking question, take a backward edge, get stuck, unstick.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, FakeWorker, Jobs, Projects, Queue, Tickets}
  alias Forge.Jobs.Job

  setup do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "game-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    # Every job is paid for by a credential in its project's pool; these tests are about
    # everything else (`docs/design/credentials.md` § How a job picks).
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    # The worker is a machine on the far end of a channel now. This one is this process:
    # it takes assignments out of its own mailbox and answers them. See Forge.FakeWorker.
    worker = FakeWorker.connect()

    %{project: project, user: user, repo: repo, worker: worker}
  end

  defp run(job, worker, scenario, doc, opts \\ []),
    do: FakeWorker.run(job, worker, scenario, Keyword.put(opts, :doc, doc))

  defp only_pending(ticket) do
    assert [%Job{status: :pending} = job] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    job
  end

  defp event_types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  # A job's wait reasons and its starts, in the order they were written.
  defp waits_and_starts(job) do
    for %{type: type} = event <- Events.for_job(job.id),
        type in ["job.waiting", "job.started"],
        do: if(type == "job.started", do: :started, else: event.payload["reason"])
  end

  test "admission pins the workflow, creates the branch, the ticket document and the first job",
       %{project: project, repo: repo, user: user} do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    assert ticket.number == 1
    assert ticket.state == "refining"
    assert ticket.branch == "ticket/1"
    assert Forge.Git.branch_exists?(repo, "ticket/1")
    assert String.length(ticket.workflow_commit) == 40
    assert Tickets.workflow(ticket).initial == "refining"

    assert %{content: "# Persist scores\n\nThey vanish.", version: 1} =
             Artifacts.latest(ticket.id, "ticket")

    job = only_pending(ticket)
    spec = Jobs.spec(job)
    assert spec.state == "refining"
    assert spec.prompt == "Refine the ticket into a crisp problem statement.\n"
    assert [%{name: "ticket", version: 1}] = spec.inputs
    assert spec.produces == ["refinement.md"]
    assert spec.budget == %{turns: 20, cost: 0.5}

    assert event_types(ticket) == ~w(ticket.admitted artifact.version_written job.created)
  end

  test "admission fails cleanly without a workflow file", %{user: user} do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" =>
          "version: 1\ninitial: nowhere\nstates: {a: {}}\ntransitions: []\nlimits: {ticket_cost: 1}\n"
      })

    {:ok, project} =
      register_owned!(%{name: "broken-#{System.unique_integer([:positive])}", repo_path: repo})

    assert {:error, [%ForgeCore.Error{} | _]} =
             Tickets.admit(project, %{title: "x"}, {:user, user.id})
  end

  test "the whole loop: run, approve, block, answer, resume, backward edge, stuck, unstick", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    # refining: converges, transition needs approval of refinement.md
    {:ok, job} = run(only_pending(ticket), worker, "success", "refinement.md")
    assert %Job{status: :finished, outcome: :converged, declared_outcome: "done", turns: 3} = job
    assert Decimal.equal?(job.cost_usd, Decimal.from_float(0.0421))

    assert %{version: 1, author: %{"kind" => "job"}} =
             Artifacts.latest(ticket.id, "refinement.md")

    assert %{blob_uri: "store:" <> key, content_hash: "sha256:" <> _} =
             Artifacts.latest(ticket.id, "transcript-refining-1.jsonl")

    assert {:ok, transcript} = Forge.Storage.get(key)
    assert transcript =~ "\"type\":"

    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "refining"
    assert ticket.pending_transition["to"] == "planning"
    assert Decimal.equal?(ticket.cost_usd, Decimal.from_float(0.0421))
    assert [%{kind: :approval}] = Queue.items()
    assert "job.harness.started" in event_types(ticket)

    # approve: transition taken, planning job created
    {:ok, ticket} = Engine.decide(ticket, user.id, :approved, "looks right")
    assert ticket.state == "planning"
    assert ticket.pending_transition == nil

    assert [%{decision: :approved}] =
             Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id)

    planning = only_pending(ticket)
    assert Enum.map(Jobs.spec(planning).inputs, & &1.name) == ["ticket", "refinement.md"]

    # planning: blocks on a question, which is pushed to subscribed browsers — by the watch,
    # which hears the ticket change and pushes what started waiting on it.
    Forge.Push.TestSender.watch()
    start_supervised!(Forge.Push.Watch)
    Forge.Push.Watch.sync()

    {:ok, _} =
      Forge.Push.subscribe(user, %{
        "endpoint" => "https://push.example/phone",
        "keys" => %{
          "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      })

    {:ok, job} = run(planning, worker, "blocking", "plan.md")
    assert job.status == :waiting
    # The run is over; the answer resumes the job on a new one with its own git credential.
    assert Forge.Git.Tokens.revoke_for_job(job.id) == 0
    Forge.Push.Watch.sync()
    Forge.Push.flush()
    assert_receive {:push, "https://push.example/phone", %{"body" => "Which backend?"}, _opts}
    assert job.harness_session_id == "sess-42"
    assert [%{kind: :question, question: %{key: "backend"}}] = Queue.items()
    assert Tickets.get!(ticket.id).state == "planning"

    # answer, resume: the second run resumes the session and sees answers.md
    [question] = Artifacts.open_blocking_questions(ticket.id)
    {:ok, _answer} = Artifacts.answer(question, user.id, %{choice: "b"})
    assert Artifacts.open_blocking_questions(ticket.id) == []
    assert %{content: content} = Artifacts.latest(ticket.id, "answers.md")
    assert content =~ "A: b"
    assert Artifacts.answered_keys(ticket.id) == ["backend"]

    # a human transition is refused while the job is live
    assert {:error, {:job_live, "planning"}} =
             Engine.choose(Tickets.get!(ticket.id), user.id, "implementing")

    {:ok, job} = Jobs.resume(Jobs.get!(job.id))
    assert job.status == :pending

    # the resumed agent keeps its question block; the answered key no longer blocks it.
    # What the worker is told is the platform's half of this: the session to resume, the
    # answer as a pinned input, and the key that no longer blocks.
    assignment = FakeWorker.assign(job, worker)
    assert assignment["resume_session"] == "sess-42"
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])
    assert spec.answered_keys == ["backend"]
    assert %{name: "answers.md", content: answers} = List.last(spec.inputs)
    assert answers =~ "A: b"
    assert assignment["git"]["branch"] == "ticket/1"

    {:ok, job} = FakeWorker.finish(assignment, "blocking", doc: "plan.md")
    assert job.status == :finished
    assert job.turns == 6
    assert Artifacts.versions(ticket.id, "plan.md") |> length() == 2
    assert Queue.items() |> Enum.reject(&(&1.kind == :question)) |> length() == 0

    # planning -> implementing automatically; implementing reports plan_invalid -> back to planning
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "implementing"
    {:ok, _} = run(only_pending(ticket), worker, "plan_invalid", "implementation.md")
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "planning"
    assert Jobs.spec(only_pending(ticket)).attempt == 2

    # planning again -> implementing -> verifying; verifying exhausts its budget -> stuck
    {:ok, _} = run(only_pending(ticket), worker, "success", "plan.md")
    {:ok, _} = run(only_pending(Tickets.get!(ticket.id)), worker, "success", "implementation.md")
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "verifying"
    verifying = only_pending(ticket)

    assert Enum.map(Jobs.spec(verifying).inputs, & &1.name) == [
             "plan.md",
             "implementation.md",
             "changeset"
           ]

    {:ok, job} = run(verifying, worker, "max_turns", "report.md")
    assert job.outcome == :budget_exhausted
    ticket = Tickets.get!(ticket.id)
    assert ticket.status == :stuck

    # A stuck item lists the transitions out of the state, so the operator can see the
    # choices without reading the workflow: docs/design/api-and-ui.md.
    assert [%{kind: :stuck, detail: detail}] = Queue.items()
    assert detail.state == "verifying"
    assert Enum.sort(detail.transitions) == ["implementing", "review_ready"]

    # unstick by choosing the retry edge by hand, then finish
    {:ok, ticket} = Engine.choose(ticket, user.id, "implementing")
    assert {ticket.status, ticket.state} == {:active, "implementing"}
    {:ok, _} = run(only_pending(ticket), worker, "success", "implementation.md")
    {:ok, _} = run(only_pending(Tickets.get!(ticket.id)), worker, "success", "report.md")
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "review_ready"
    assert [%{kind: :review, detail: %{transitions: ["merged"]}}] = Queue.items()

    # merging requires approval of the changeset, which the implement job recorded as a version
    changeset = Artifacts.latest(ticket.id, "changeset")
    assert %{blob_uri: "git:" <> head} = changeset
    assert String.length(head) == 40
    {:ok, ticket} = Engine.choose(ticket, user.id, "merged", comment: "ship it")
    assert [%{decision: :approved, comment: "ship it"}] = Artifacts.approvals(changeset.id)
    assert ticket.status == :done
    assert Queue.items() == []
    assert "ticket.done" in event_types(ticket)
    assert Jobs.pending() == []
  end

  test "rejecting hands the ticket back to the operator; a stale job's result is orphaned", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, _} = run(only_pending(ticket), worker, "success", "refinement.md")
    ticket = Tickets.get!(ticket.id)

    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "not yet")
    assert rejected.state == "refining"

    # `docs/design/workflow-grammar-v1.md` § Approval: rejection keeps the ticket in `from` and
    # the operator chooses what happens next. The decision is therefore *finished* — it stopped
    # being pending the moment it was answered. Leaving it pending was a real defect on the dev
    # node: the card never closed, the queue offered the same approve-or-reject again, and the
    # chooser that sentence promises stayed hidden behind `!@ticket.pending_transition`.
    assert rejected.pending_transition == nil
    assert rejected.status == :stuck

    assert [%{decision: :rejected}] =
             Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id)

    # What the sentence lists the operator doing: edit the artifact, which creates a new version,
    # and take the transition by hand — which records the approvals against that new version.
    {:ok, v2} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, {:user, user.id}, %{
        content: "---\noutcome: done\n---\nBetter.\n"
      })

    {:ok, ticket} = Engine.choose(rejected, user.id, "planning")
    assert ticket.state == "planning"
    assert [%{decision: :approved}] = Artifacts.approvals(v2.id)

    # a job whose ticket moved on decides nothing
    planning = only_pending(ticket)

    {:ok, moved} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: "verifying",
          status: :active,
          cost_usd: ticket.cost_usd
        })
      )

    {:ok, _} = run(planning, worker, "success", "plan.md")
    assert Tickets.get!(moved.id).state == "verifying"
    assert "job.orphaned" in event_types(ticket)
  end

  test "a resume that never reaches the harness is re-queued as a fresh run", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    {:ok, job} =
      Repo.update(
        Job.progress_changeset(job, %{status: :pending, harness_session_id: "stale-session"})
      )

    {:ok, job} = run(job, worker, "no_start", "refinement.md")
    assert job.status == :pending
    assert job.harness_session_id == nil
    assert "job.resume_failed" in event_types(ticket)
    # The fresh run mints its own; the failed one's is revoked, not left to its wall clock.
    assert Forge.Git.Tokens.revoke_for_job(job.id) == 0

    {:ok, job} = run(job, worker, "success", "refinement.md")
    assert job.outcome == :converged
  end

  # The other side of that rule, and the expensive one to get wrong. "Never got going" is four
  # conditions at once — it was a resume, it finished, nothing killed it, and no `started` event
  # named a model — and an ordinary failure satisfies some of them. A failure that is re-queued
  # as a fresh run instead of recorded loses the attempt, the transcript and the reason, and the
  # job runs again on the same input until the ticket's allowance is gone, with nothing in the
  # timeline to say why. Only `job.resume_failed` would be there, and only a resume may write it.
  test "a first run that fails is recorded, not re-queued as a fresh one", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    assert job.harness_session_id == nil

    # The same shape a lost resume has — finished, not killed, no model, outcome `:error` — on a
    # job that was never resumed. Three of the four conditions hold; the run is still a failure.
    {:ok, job} = run(job, worker, "no_start", "refinement.md")

    assert job.status == :finished
    assert job.outcome == :error
    refute "job.resume_failed" in event_types(ticket)
  end

  test "a resume whose harness did get going is recorded, however it ended", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})

    {:ok, job} =
      Repo.update(
        Job.progress_changeset(only_pending(ticket), %{
          status: :pending,
          harness_session_id: "live-session"
        })
      )

    # It resumed, it reported a model, and then it failed by writing nothing. That is a run to
    # record — the session was found, so running it again from scratch would throw away a turn
    # the agent really took.
    {:ok, job} = run(job, worker, "nothing", "refinement.md")

    assert job.status == :finished
    assert job.outcome == :error
    assert job.harness_session_id == "sess-42"
    refute "job.resume_failed" in event_types(ticket)
  end

  test "the scheduler hands pending jobs to a worker with room, and holds the rest",
       %{project: project, user: user} = context do
    # A worker with room for exactly one slice, so the second ticket has nowhere to go until
    # the first job is done with it. The setup's roomier worker steps aside.
    Registry.unregister(Forge.Workers.Registry, context.worker.id)
    worker = FakeWorker.connect(memory_budget: Forge.Workers.slice_bytes(), project: project)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, ticket2} = Tickets.admit(project, %{title: "y"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    # One slice, two jobs: one goes out and the other waits. Which one is not the point —
    # both were admitted in the same second, and `pending/1` orders by `inserted_at`.
    assert Forge.Jobs.Scheduler.tick() == 1

    [running, waiting] =
      Enum.split_with([ticket, ticket2], &(job_status(&1) == :running))
      |> then(fn {a, b} -> [hd(a), hd(b)] end)

    assert job_status(waiting) == :pending
    assert Jobs.get!(only_job(running).id).worker_id == worker.id

    # Nothing changes while the slice is taken: the job is offered again, not dropped.
    assert Forge.Jobs.Scheduler.tick() == 0

    assignment = FakeWorker.take_assignment(only_job(running).id)
    {:ok, _job} = FakeWorker.finish(assignment, "success", doc: "refinement.md")
    assert Tickets.get!(running.id).pending_transition["to"] == "planning"

    # With the slice free again, the one that waited goes out.
    assert Forge.Jobs.Scheduler.tick() == 1
    assert job_status(waiting) == :running
  end

  # The scheduler gates on what the *job* was admitted with, not on one number for every job
  # (`docs/design/provisioning.md` § What a job asks for). With `slice_bytes` small and the job's
  # own ceiling large, a memory-only gate reading the constant would happily place it.
  test "a job is gated on its own figures, not on the configured slice", %{
    project: project,
    user: user,
    worker: worker
  } do
    # Out of touch but not destroyed, and serving this project: it is what makes a job that does
    # not fit the small machine *wait* rather than stick, because it could hold it once back.
    Registry.unregister(Forge.Workers.Registry, worker.id)
    Forge.ForgeFixtures.serve!(worker, project)
    previous = Application.get_env(:forge, Forge.Workers, [])
    on_exit(fn -> Application.put_env(:forge, Forge.Workers, previous) end)

    Application.put_env(
      :forge,
      Forge.Workers,
      Keyword.merge(previous, slice_bytes: 1024 ** 3)
    )

    FakeWorker.connect(memory_budget: 4 * 1024 ** 3, cores: 4, project: project)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    job = only_job(ticket)

    # Admitted under the small slice, it fits.
    assert Forge.Jobs.Scheduler.tick() == 1
    assert Jobs.get!(job.id).status == :running

    # The same job asking for more than the machine has does not, however small the constant is.
    {:ok, _} =
      Jobs.get!(job.id)
      |> Ecto.Changeset.change(%{status: :pending, memory_max: 9 * 1024 ** 3, worker_id: nil})
      |> Forge.Repo.update()

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(job.id).status == :pending

    # And the same for cores, which is the dimension the scheduler could most easily pass as a
    # constant without any test noticing: the machine has four and the job wants five.
    {:ok, _} =
      Jobs.get!(job.id)
      |> Ecto.Changeset.change(%{memory_max: 1024 ** 3, cores: 5})
      |> Forge.Repo.update()

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(job.id).status == :pending

    {:ok, _} = Jobs.get!(job.id) |> Ecto.Changeset.change(%{cores: 4}) |> Forge.Repo.update()

    assert Forge.Jobs.Scheduler.tick() == 1
    assert Jobs.get!(job.id).status == :running
  end

  # The distinction `docs/design/provisioning.md` § The gate insists on, end to end. A job no
  # assigned template could *ever* hold is not a queue — it is a ticket that sticks with the
  # reason, through the mechanism an exhausted allowance already uses. Queued instead, it would
  # wait for ever against capacity that will never exist, and look healthy while doing it.
  test "a job no assigned template could ever hold sticks its ticket", %{
    project: project,
    user: user,
    worker: worker
  } do
    # **Destroyed, not merely unregistered.** A machine that exists and could take this once it
    # is free is a queue rather than a wall, however out of touch it is right now — a row that
    # has not been swept yet may still come back. Unregistering left a 64 GiB row standing, so
    # the job had somewhere to wait and the ticket rightly did not stick.
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "small",
        provider: "fake",
        memory: 1_000,
        cores: 1,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)
    job = only_job(ticket)

    {:ok, _} =
      Jobs.get!(job.id) |> Ecto.Changeset.change(%{memory_max: 99_000}) |> Forge.Repo.update()

    assert Forge.Jobs.Scheduler.tick() == 0

    assert Tickets.get!(ticket.id).status == :stuck
    assert "ticket.stuck" in event_types(ticket)

    # The reason lives on the event, which is where an exhausted allowance puts its own, and is
    # what the operator reads on the timeline rather than a bare status.
    assert %{"reason" => reason} =
             Forge.Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "ticket.stuck"))
             |> Map.fetch!(:payload)

    assert reason =~ "template"

    # Stuck is the record, and a wait beside it would be the same fact said twice.
    assert waits_and_starts(job) == []
  end

  # **A placement stick used to be a dead end.** The ticket is stuck holding a pending job, and a
  # transition is refused while a job for the current state is live, so once the missing
  # template arrived there was nothing a person could do from the product. Assigning one is what
  # the ticket was waiting for, and it comes back by itself (`docs/design/credentials.md` § How a
  # job picks).
  test "a ticket stuck for want of a machine comes back when one is assigned", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck

    assert %{"cause" => "placement"} =
             Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "ticket.stuck"))
             |> Map.fetch!(:payload)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "enough",
        provider: "fake",
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)

    assert Tickets.get!(ticket.id).status == :active
    assert "ticket.unstuck" in event_types(ticket)
    assert job_status(ticket) == :pending
  end

  # The same for a permanent machine: its owner assigning it is as much the missing piece as a
  # template is.
  test "a ticket stuck for want of a machine comes back when a permanent one is assigned", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck

    {:ok, mine, _token} =
      Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

    {:ok, _} = Forge.Workers.assign(user, mine.id, project.id)

    assert Tickets.get!(ticket.id).status == :active
  end

  # **The credential before the machine** (`docs/design/credentials.md` § How a job picks). A job
  # nothing can pay for does not ask for capacity, so an empty pool makes no machine — here a
  # template is assigned and would otherwise make one — and the ticket sticks saying who can fix
  # it. The owner assigning a credential brings it back.
  test "a project with nothing in its pool sticks its ticket and makes no machine", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)

    Repo.delete_all(
      from a in Forge.Credentials.ProjectCredential, where: a.project_id == ^project.id
    )

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "would-make-one",
        provider: "fake",
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    refute_receive {:provider_create, _opts}

    assert Tickets.get!(ticket.id).status == :stuck

    assert %{"cause" => "placement", "reason" => reason} =
             Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "ticket.stuck"))
             |> Map.fetch!(:payload)

    assert reason =~ "no credential is assigned to this project"

    credential = credential_fixture(user)
    {:ok, _} = Forge.Credentials.assign(user, credential.id, project.id)

    assert Tickets.get!(ticket.id).status == :active
  end

  # **Enabling a template is an arrival, like assigning one.** The node this was found on: the only
  # template named a snapshot speaking a protocol the platform refuses, three passes refused it and
  # took it out of service, and the ticket stuck on *every worker template assigned to this project
  # is disabled*. Its owner pointed the template at a good snapshot and enabled it, and the ticket
  # stayed stuck with its job pending — no machine was made, and nothing on the page could make one
  # (`docs/design/provisioning.md` § A template that cannot make a working machine is taken out of
  # service).
  test "a ticket stuck on a disabled template comes back when its owner enables it", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)
    {template, ticket} = stuck_on_a_refused_image(project, user)

    # Fixing the recipe does not put it back in service. The edit is a guess that the ticket may
    # now be placed, and the next pass, which decides, sticks it again.
    before_edit = unstuck_count(ticket)

    {:ok, _} =
      Forge.Provisioning.update_template(user, template.id, %{
        image: "snapshot-current",
        image_protocol: ForgeCore.WorkerProtocol.current()
      })

    assert unstuck_count(ticket) == before_edit + 1
    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck
    refute_received {:provider_create, _opts}

    unstuck = unstuck_count(ticket)
    {:ok, _} = Forge.Provisioning.enable(user, template.id)

    assert Tickets.get!(ticket.id).status == :active
    assert unstuck_count(ticket) == unstuck + 1

    # And the pass after that makes the machine the job was waiting for.
    assert Forge.Jobs.Scheduler.tick() == 0
    assert_received {:provider_create, _opts}
  end

  # Only the projects the template is assigned to, and only a ticket stuck for placement: one
  # anywhere else, or stuck on its allowance, was not waiting for this template.
  test "enabling a template brings back no ticket it was not holding up", %{
    project: project,
    user: user
  } do
    template = template_fixture(user, project)
    out_of_service!(template)

    held_up = stuck_for_placement(project, user)
    {:ok, other_cause} = Tickets.admit(project, %{title: "y"}, {:user, user.id})
    {:ok, _} = Engine.stick(Tickets.get!(other_cause.id), "ticket cost cap reached")

    # Another project with a template of its own, out of service as well.
    elsewhere_project = unrelated_project(user)
    user |> template_fixture(elsewhere_project) |> out_of_service!()
    elsewhere = stuck_for_placement(elsewhere_project, user)

    # Somebody else's `Enable` is refused, and refused before it brings anything back.
    stranger = Forge.AccountsFixtures.user_fixture()
    join!(project, stranger)
    assert {:error, :not_found} = Forge.Provisioning.enable(stranger, template.id)
    assert Tickets.get!(held_up.id).status == :stuck

    {:ok, _} = Forge.Provisioning.enable(user, template.id)

    assert Tickets.get!(held_up.id).status == :active
    assert "ticket.unstuck" in event_types(held_up)
    assert Tickets.get!(other_cause.id).status == :stuck
    assert Tickets.get!(elsewhere.id).status == :stuck

    # Enabling it again, in service already, changes nothing the gate reads.
    {:ok, _} = Engine.stick(Tickets.get!(held_up.id), "no template", :placement)
    {:ok, _} = Forge.Provisioning.enable(user, template.id)
    assert Tickets.get!(held_up.id).status == :stuck
  end

  # **An edit is an arrival when it changes what the template could hold**, and only then: the
  # fields `Provisioning.for_demand/2` asks of a template, and the image whose protocol it reads.
  # The rest decide whether a create succeeds, or nothing that places a job at all — a rename is
  # not a fix (`docs/design/provisioning.md` § Editing a template).
  test "an edit brings a stuck ticket back only when it changes what the template could hold", %{
    project: project,
    user: user
  } do
    {:ok, credential} =
      Forge.Provisioning.create_credential(user, %{
        name: "another-account",
        provider: "fake",
        secret: %{"token" => "t"}
      })

    template = template_fixture(user, project)
    ticket = stuck_for_placement(project, user)

    edits = [
      # The templates page sends every field on every save, so a rename re-sends what the template
      # could hold, unchanged (`ForgeWeb.TemplatesLive`): sent is not changed.
      {%{
         name: "renamed",
         memory: template.memory,
         cores: template.cores,
         accepts: nil,
         image: nil,
         image_protocol: nil
       }, :stuck},
      {%{provider: "local"}, :stuck},
      {%{provider: "fake"}, :stuck},
      {%{max_workers: 4}, :stuck},
      {%{idle_ms: 60_000}, :stuck},
      {%{size: "bigger"}, :stuck},
      {%{provider_credential_id: credential.id}, :stuck},
      {%{image_build: "abc123"}, :stuck},
      {%{memory: 128 * 1024 * 1024 * 1024}, :active},
      {%{cores: 128}, :active},
      # Nothing ticked is nil, which the template already says: not a change.
      {%{accepts: []}, :stuck},
      {%{accepts: [:workflow]}, :active},
      {%{image: "snapshot-2"}, :active},
      {%{image_protocol: ForgeCore.WorkerProtocol.current()}, :active}
    ]

    for {edit, expected} <- edits do
      {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
      assert {:ok, _} = Forge.Provisioning.update_template(user, template.id, edit)

      assert Tickets.get!(ticket.id).status == expected,
             "#{inspect(edit)} should have left the ticket #{expected}"
    end

    assert unstuck_count(ticket) == Enum.count(edits, &(elem(&1, 1) == :active))

    # An edit the changeset refuses changes nothing, and brings nothing back.
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
    assert {:error, _} = Forge.Provisioning.update_template(user, template.id, %{memory: 0})
    assert Tickets.get!(ticket.id).status == :stuck
  end

  # **A permanent machine is an arrival when it offers the gate more than it did.** Assigned before
  # it ever booted, it has no memory and no harness, so the pass after its assignment sticks the
  # ticket again, and its first `ready` is when it actually arrives. Updated to a release that takes
  # each job's credential, it arrives at the reconnect that says so. A reconnect saying what it said
  # before is not an arrival, and neither is a harness that changed in nothing the gate reads
  # (`docs/design/credentials.md` § How a job picks).
  test "a permanent machine brings the ticket back when it reports more than it did", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    mine = permanent_machine(user, project)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck

    # A release from before the harness probe: memory it did not have, and no harness, so it
    # cannot take this job and the next pass sticks the ticket again.
    report = %{"memory_budget" => 64 * 1024 * 1024 * 1024, "cores" => 64}
    {:ok, _} = Forge.Workers.ready(mine, report)

    assert Tickets.get!(ticket.id).status == :active
    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck

    # Updated, it takes the job's credential from the assignment: that is the arrival — in the
    # projects this machine serves, and not in another served by another machine.
    elsewhere_project = unrelated_project(user)
    permanent_machine(user, elsewhere_project)
    elsewhere = stuck_for_placement(elsewhere_project, user)

    per_job = %{"driver" => "claude_code", "credential" => "per_job", "version" => "2.0.1"}
    {:ok, _} = Forge.Workers.ready(mine, Map.put(report, "harness", per_job))

    assert Tickets.get!(ticket.id).status == :active
    assert Tickets.get!(elsewhere.id).status == :stuck
    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :active

    # The same again, or a newer `claude` behind the same harness, is not.
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
    {:ok, _} = Forge.Workers.ready(mine, Map.put(report, "harness", per_job))
    newer = Map.put(per_job, "version", "2.0.2")
    {:ok, _} = Forge.Workers.ready(mine, Map.put(report, "harness", newer))

    assert Tickets.get!(ticket.id).status == :stuck
  end

  # **A machine the platform made is not an arrival by booting.** Its figures are its template's,
  # which arrives on its own, and its first report always carries a harness its row did not have:
  # counted, every stuck ticket in the template's projects came back at every boot, to be stuck —
  # and pushed to the project's members — again on the next pass.
  test "a machine the platform made brings nothing back by booting", %{
    project: project,
    user: user
  } do
    template = template_fixture(user, project)
    ticket = stuck_for_placement(project, user)
    {:ok, made, _token} = Forge.Workers.create(Forge.Provisioning.Template.worker_attrs(template))
    {:ok, _} = Forge.Workers.ready(made, template_report(template))

    assert Tickets.get!(ticket.id).status == :stuck
    assert unstuck_count(ticket) == 0
  end

  # **A template back in service by a machine of its own is an arrival**, as its owner's `Enable`
  # is: a machine from it reported, so the recipe works. But only a machine's first report, and
  # only from the image the template still names — a reconnect of a machine made from an older
  # snapshot put a template the new one had taken out of service back in at every restart
  # (`docs/design/provisioning.md` § A template that cannot make a working machine is taken out of
  # service). Below the limit the template was never out, and nothing has arrived.
  test "a template's own machine brings the ticket back when its first report puts it back", %{
    project: project,
    user: user
  } do
    template = template_fixture(user, project)
    report = template_report(template)
    ticket = stuck_for_placement(project, user)

    # Another template, out of service in another project, which this machine says nothing about.
    other = user |> unrelated_project() |> then(&template_fixture(user, &1))
    out_of_service!(other)

    # Past the limit, as a machine swept after the template went out makes it.
    {:ok, made, _token} = Forge.Workers.create(Forge.Provisioning.Template.worker_attrs(template))
    out_of_service!(template)
    :ok = Forge.Provisioning.failed(template.id, "x")
    {:ok, _} = Forge.Workers.ready(made, report)

    assert Tickets.get!(ticket.id).status == :active
    assert unstuck_count(ticket) == 1
    refute Forge.Provisioning.disabled?(reload_template(template))
    assert Forge.Provisioning.disabled?(reload_template(other))

    # A reconnect says nothing about the recipe.
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
    out_of_service!(template)
    {:ok, _} = Forge.Workers.ready(made, report)

    assert Tickets.get!(ticket.id).status == :stuck
    assert Forge.Provisioning.disabled?(reload_template(template))

    # Nor does a machine made from the image the template named before the one it names now.
    {:ok, older, _token} =
      Forge.Workers.create(Forge.Provisioning.Template.worker_attrs(template))

    {:ok, _} = Forge.Provisioning.update_template(user, template.id, %{image: "snapshot-2"})
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
    {:ok, _} = Forge.Workers.ready(older, report)

    assert Tickets.get!(ticket.id).status == :stuck
    assert Forge.Provisioning.disabled?(reload_template(template))

    # Below the limit: the count goes back to zero, and nothing has arrived.
    {:ok, _} = Forge.Provisioning.enable(user, template.id)
    :ok = Forge.Provisioning.failed(template.id, "x")
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)

    {:ok, fresh, _token} =
      Forge.Workers.create(Forge.Provisioning.Template.worker_attrs(reload_template(template)))

    {:ok, _} = Forge.Workers.ready(fresh, report)

    assert reload_template(template).failures == 0
    assert Tickets.get!(ticket.id).status == :stuck
  end

  # **A permanent machine's owner changing what it offers is an arrival**: every figure is one the
  # gate reads. Too small to ever hold the job, the machine sticks the ticket; given more, it brings
  # it back and the next pass does not stick it again. A save that changes nothing brings nothing.
  test "a permanent machine given a bigger offer brings the ticket back", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    mine = permanent_machine(user, project)
    small = %{memory_budget: 1024 * 1024 * 1024, cores: 1}

    {:ok, _} =
      Forge.Workers.ready(mine, %{
        "memory_budget" => small.memory_budget,
        "cores" => small.cores,
        "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
      })

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck

    # Another project of the owner's, served by another machine of theirs: not this one's to fix.
    elsewhere_project = unrelated_project(user)
    permanent_machine(user, elsewhere_project)
    elsewhere = stuck_for_placement(elsewhere_project, user)

    {:ok, _} = Forge.Workers.set_offer(user, mine.id, small)
    assert Tickets.get!(ticket.id).status == :stuck

    assert {:error, _} = Forge.Workers.set_offer(user, mine.id, %{memory_budget: 1, cores: 64})
    assert Tickets.get!(ticket.id).status == :stuck

    {:ok, _} =
      Forge.Workers.set_offer(user, mine.id, %{memory_budget: 64 * 1024 * 1024 * 1024, cores: 64})

    assert Tickets.get!(ticket.id).status == :active
    assert "ticket.unstuck" in event_types(ticket)
    assert Tickets.get!(elsewhere.id).status == :stuck
    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :active
  end

  # **One queued chat, one machine.** A machine being made is not assignable, so the chat is
  # still pending on every pass until it boots — and each of those passes used to make another,
  # until the template's `max_workers` stopped it (`docs/design/provisioning.md` § The gate).
  test "a job waiting for a machine being made does not make another on the next pass", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "four-at-most",
        provider: "fake",
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 4
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    chat = chat_fixture(%{project: project})
    start_supervised!(Forge.Jobs.Scheduler)

    for _pass <- 1..3, do: assert(Forge.Jobs.Scheduler.tick() == 0)

    assert_receive {:provider_create, _opts}
    refute_receive {:provider_create, _opts}
    assert Forge.Provisioning.live_count(template) == 1
    assert waits_and_starts(chat) == ["creating"]
  end

  # Within one pass the jobs ahead count against a booting machine, so what it cannot also hold
  # makes another — and the next pass divides them the same way and makes none.
  test "jobs queued together make as many machines as they need and no more", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)
    %{memory: memory} = Jobs.default_resources()

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "two-chats-each",
        provider: "fake",
        memory: 2 * memory,
        cores: 64,
        max_workers: 4
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    for _chat <- 1..3, do: chat_fixture(%{project: project})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Forge.Provisioning.live_count(template) == 2

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Forge.Provisioning.live_count(template) == 2
  end

  # Everything in the pool rate-limited is the other answer, and must not be mistaken for the
  # first: time resolves it, so the ticket stays active rather than asking a person for something,
  # and — as with an empty pool — no machine is made for a job that could not start on it.
  test "a project whose every credential is rate-limited waits, active, and makes no machine", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)
    [credential] = Forge.Credentials.pool(project.id, "claude_code")

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "would-make-one",
        provider: "fake",
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)

    earlier = chat_fixture(%{project: project})

    Repo.update_all(from(j in Job, where: j.id == ^earlier.id),
      set: [credential_id: credential.id]
    )

    :ok =
      Jobs.record_harness_event(earlier.id, %{
        type: "job.harness.rate_limit",
        payload: %{status: "rejected", resets_at: System.os_time(:second) + 3600}
      })

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    refute_receive {:provider_create, _opts}

    assert Tickets.get!(ticket.id).status == :active
    refute "ticket.stuck" in event_types(ticket)
    assert %Job{status: :pending, worker_id: nil} = job = only_pending(ticket)

    # Not stuck, so the job itself says what it is waiting for.
    assert waits_and_starts(job) == ["limited"]
    assert Jobs.current_wait(job) |> Events.summary() =~ "Waiting for a limit to reset"
  end

  # A conversation has no ticket to stick, so an empty pool is its wait reason instead, in the
  # sentence a ticket would have been stuck with — the same answer a chat gets for a template.
  test "a chat in a project with nothing in its pool waits, saying who can fix it", %{
    project: project,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)

    Repo.delete_all(
      from a in Forge.Credentials.ProjectCredential, where: a.project_id == ^project.id
    )

    {:ok, chat} = Forge.Conversations.open(project, "hello")
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(chat.id).status == :pending
    assert waits_and_starts(chat) == ["no_credential"]

    assert Jobs.current_wait(Jobs.get!(chat.id)) |> Events.summary() =~
             "no credential is assigned to this project"
  end

  # A credential this node cannot open — its `secret_key_base` rotated — is one no job can run on.
  # The job is not sent to the worker without one; it stays pending and the reason names the
  # credential, so the operator knows which to add again.
  test "a credential this node cannot open sends nothing to the worker", %{
    project: project,
    user: user,
    worker: worker
  } do
    [credential] = Forge.Credentials.pool(project.id, "claude_code")

    Repo.update_all(from(c in Forge.Credentials.Credential, where: c.id == ^credential.id),
      set: [secret: Forge.Provisioning.Vault.seal(%{"token" => "under-another-label"})]
    )

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)

    assert {:error, {:credential_unreadable, id}} = Jobs.assign(job, worker)
    assert id == credential.id
    assert Jobs.get!(job.id).status == :pending
    refute_received {:assign, _assignment}
  end

  # The scheduler has to *ask* for the harness: testing `Workers.runs?/2` alone leaves the wiring
  # unchecked. A machine of a release that would ignore the job's credential serves the project,
  # has room, and is connected — and is given nothing.
  test "a machine that predates per-job credentials is given none of its project's jobs", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)

    {:ok, old, _token} = Forge.Workers.create(%{provider: "fake", managed: false})

    {:ok, old} =
      Forge.Workers.ready(old, %{"memory_budget" => 64 * 1024 * 1024 * 1024, "cores" => 64})

    :ok = Forge.Workers.connected(old.id)
    serve!(old, project)

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(only_job(ticket).id).worker_id == nil
  end

  # What paid for a job is on the job, which is what makes a credential's spend a query. It is
  # kept while it is usable and moves only when it must — and the move is on the record, because
  # the job's whole cost moves with it (`credentials.md` § How a job picks).
  test "a job records the credential it runs on, and a change of credential is an event", %{
    project: project,
    user: user,
    worker: worker
  } do
    [first] = Forge.Credentials.pool(project.id, "claude_code")
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)

    FakeWorker.assign(job, worker)
    assert Jobs.get!(job.id).credential_id == first.id
    refute "job.credential_changed" in event_types(ticket)

    # Its credential is revoked while it is back in the queue — a worker lost, say.
    {:ok, _} = Jobs.requeue(job.id, :worker_lost)
    owner = Forge.Repo.get!(Forge.Accounts.User, first.user_id)
    {:ok, _} = Forge.Credentials.revoke(owner, first.id)
    second = pool!(project, credential_fixture(user))

    {:ok, _job} = Jobs.assign(Jobs.get!(job.id), worker)
    assert Jobs.get!(job.id).credential_id == second.id

    assert %{"from" => from, "to" => to} =
             Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "job.credential_changed"))
             |> Map.fetch!(:payload)

    assert {from, to} == {first.id, second.id}
  end

  # **Spend is per run** (`docs/design/credentials.md` § Spend). A job that ran on one credential,
  # stopped for a question, and resumed on another after the first was revoked has spent on both,
  # each what it spent there — summed by the job's current credential, all of it would have landed
  # on the second.
  test "a job that moved between credentials is on each one's figure for what it spent there", %{
    project: project,
    user: user,
    worker: worker
  } do
    [first] = Forge.Credentials.pool(project.id, "claude_code")
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)

    assignment = FakeWorker.assign(job, worker)
    assert [%{credential_id: on_first, worker_id: on_worker, finished_at: nil}] = runs(job)
    assert {on_first, on_worker} == {first.id, worker.id}

    {:ok, _} =
      FakeWorker.finish(assignment, "blocking",
        doc: "refinement.md",
        harness: %{"cost_usd" => 0.25}
      )

    {:ok, _} = Jobs.resume(Jobs.get!(job.id))
    owner = Forge.Repo.get!(Forge.Accounts.User, first.user_id)
    {:ok, _} = Forge.Credentials.revoke(owner, first.id)
    second = pool!(project, credential_fixture(user))

    assignment = FakeWorker.assign(Jobs.get!(job.id), worker)

    {:ok, _} =
      FakeWorker.finish(assignment, "success",
        doc: "refinement.md",
        harness: %{"cost_usd" => 0.5}
      )

    assert [%{finished_at: %DateTime{}}, %{finished_at: %DateTime{}}] = runs(job)

    assert Forge.Credentials.spent_today([first.id, second.id]) == %{
             first.id => Decimal.new("0.25"),
             second.id => Decimal.new("0.5")
           }

    assert Decimal.equal?(Jobs.get!(job.id).cost_usd, Decimal.new("0.75"))
  end

  # A job has one open run at most, and every way a run can end closes it — a result, a failure,
  # a cancel, a lost machine, a platform restart, a resume that never started, an assignment that
  # never reached the worker. An open run under a job that is not running would be a run nothing
  # will ever close, and the next start of the job would be a second open one.
  test "every way a run can end closes it", %{project: project, user: user, worker: worker} do
    started = fn ->
      {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
      job = only_job(ticket)
      {job, FakeWorker.assign(job, worker)}
    end

    {job, assignment} = started.()
    {:ok, _} = FakeWorker.finish(assignment, "success", doc: "refinement.md")
    assert open_runs(job) == 0

    {job, _} = started.()
    {:ok, _} = Jobs.fail(job.id, :runner_died)
    assert open_runs(job) == 0

    {job, _} = started.()
    {:ok, _} = Jobs.hibernate(job.id, nil, "cancelled")
    assert open_runs(job) == 0

    {job, _} = started.()
    {:ok, _} = Jobs.requeue(job.id, :worker_lost)
    assert open_runs(job) == 0

    {job, _} = started.()
    assert Jobs.recover() >= 1
    assert open_runs(job) == 0

    {job, _} = started.()
    {:ok, _} = Repo.update(Job.progress_changeset(Jobs.get!(job.id), %{status: :pending}))
    {:ok, _} = Repo.update(Job.progress_changeset(Jobs.get!(job.id), %{harness_session_id: "s"}))
    assignment = FakeWorker.assign(Jobs.get!(job.id), worker)
    {:ok, %{status: :pending}} = FakeWorker.finish(assignment, "no_start", doc: "refinement.md")
    assert open_runs(job) == 0

    # The worker is gone between the run being opened and the assignment being sent.
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)
    Registry.unregister(Forge.Workers.Registry, worker.id)
    assert {:error, _} = Jobs.assign(job, worker)
    assert [%{finished_at: %DateTime{}}] = runs(job)
  end

  # The migration leaves an open run under every job that had started and not finished, holding
  # all the job had spent. The next start closes it rather than opening a second beside it, and a
  # result arriving on a run the migration left open adds to what it holds, because it holds what
  # the job had already spent.
  test "a run left open is closed by the next start, and a result adds to what a run holds", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)
    left_open = run!(job, cost: "0.7")

    assignment = FakeWorker.assign(job, worker)
    assert %{finished_at: %DateTime{}} = Repo.get!(Forge.Jobs.Run, left_open.id)
    assert open_runs(job) == 1

    # Now the other half: the job is running on a run the migration left open.
    {:ok, _} = Jobs.requeue(job.id, :worker_lost)
    {:ok, _} = Repo.update(Job.progress_changeset(Jobs.get!(job.id), %{status: :running}))
    left_open = run!(job, cost: "0.7")

    {:ok, _} =
      FakeWorker.finish(assignment, "success",
        doc: "refinement.md",
        harness: %{"cost_usd" => 0.1}
      )

    assert Decimal.equal?(Repo.get!(Forge.Jobs.Run, left_open.id).cost_usd, Decimal.new("0.8"))
  end

  # **Stopped by its account's limit, not failed** (`docs/design/credentials.md` § A limit reached
  # mid-run). The run is recorded, the job goes back to pending with its session, its machine is
  # let go, and the workflow does not move — then the pick moves it to the free credential and
  # the next start resumes the session there.
  test "a run stopped by its limit resumes on a free credential, its session kept", %{
    project: project,
    user: user,
    worker: worker
  } do
    pool!(project, credential_fixture(user))
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)

    assignment = FakeWorker.assign(job, worker)
    on = Jobs.get!(job.id).credential_id
    {:ok, stopped} = FakeWorker.finish(assignment, "rate_limited", doc: "refinement.md")

    assert %{status: :pending, outcome: nil, harness_session_id: "sess-42"} = stopped
    assert Decimal.equal?(stopped.cost_usd, Decimal.new("0.2"))
    assert [%{finished_at: %DateTime{}}] = runs(job)
    assert Forge.Workers.get!(worker.id).status == :idle

    ticket = Tickets.get!(ticket.id)
    assert {ticket.status, ticket.state} == {:active, "refining"}
    assert [_only_job] = Jobs.for_ticket(ticket.id)
    refute "job.finished" in event_types(ticket)

    # Recorded like any run: its cost on the ticket, its transcript kept, its git token gone.
    assert Decimal.equal?(ticket.cost_usd, Decimal.new("0.2"))
    assert Artifacts.latest(ticket.id, "transcript-refining-1.jsonl")
    assert Forge.Git.Tokens.revoke_for_job(job.id) == 0

    assert %{"credential_id" => limited, "rate_limit_type" => "five_hour"} =
             Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "job.rate_limited"))
             |> Map.fetch!(:payload)

    assert limited == on

    resumed = FakeWorker.assign(Jobs.get!(job.id), worker)
    assert resumed["resume_session"] == "sess-42"
    refute Jobs.get!(job.id).credential_id in [nil, on]
    assert "job.credential_changed" in event_types(ticket)
  end

  # With every credential limited the job waits, and nobody is asked for anything; once the
  # window frees, the next pass starts it by itself. It frees here by a later report that
  # permits — another job on the same account, say — since the event log is append-only and the
  # reset cannot be moved into the past; that the reset passing frees it too is
  # `Forge.CredentialsTest`'s.
  test "a run stopped with every credential limited waits, and starts again after the reset", %{
    project: project,
    user: user,
    worker: worker
  } do
    serve!(worker, project)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)

    assignment = FakeWorker.assign(job, worker)
    {:ok, _} = FakeWorker.finish(assignment, "rate_limited", doc: "refinement.md")
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(job.id).status == :pending
    assert Tickets.get!(ticket.id).status == :active

    :ok =
      Jobs.record_harness_event(job.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed",
          rate_limit_type: "five_hour",
          resets_at: System.os_time(:second) + 18_000
        }
      })

    assert Forge.Jobs.Scheduler.tick() == 1
    assert %{"resume_session" => "sess-42"} = FakeWorker.take_assignment(job.id)
  end

  # A job waiting for a reset is not work waiting for a machine: it might wait a week, and a pass
  # that counted it would keep every idle machine on the node alive while it did. The rule the
  # test beside `a machine with work waiting is not destroyed` defends is about work that could
  # run.
  test "a job waiting for a reset keeps no idle machine alive", %{
    project: project,
    user: user,
    worker: worker
  } do
    previous = Application.get_env(:forge, Forge.Workers, [])
    on_exit(fn -> Application.put_env(:forge, Forge.Workers, previous) end)
    Application.put_env(:forge, Forge.Workers, Keyword.merge(previous, idle_period_ms: 60_000))

    serve!(worker, project)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    assignment = FakeWorker.assign(only_job(ticket), worker)

    {:ok, %{status: :pending} = job} =
      FakeWorker.finish(assignment, "rate_limited", doc: "refinement.md")

    # Two minutes on, for both clocks the run's end started: the machine's idle one, and the
    # job's return to the queue — which holds the machine it ran on for one idle period
    # (`docs/design/worker-tier.md` § The hour already paid for), and not for the week it waits.
    two_minutes_ago = DateTime.add(DateTime.utc_now(:second), -120)

    {:ok, _worker} =
      Forge.Workers.update(Forge.Workers.get!(worker.id), %{idle_since: two_minutes_ago})

    {:ok, _job} =
      job
      |> Ecto.Changeset.change(updated_at: DateTime.add(two_minutes_ago, 0, :microsecond))
      |> Forge.Repo.update()

    start_supervised!(Forge.Jobs.Scheduler)
    assert Forge.Jobs.Scheduler.tick() == 0
    assert Forge.Workers.get!(worker.id).status == :destroyed
  end

  # Only a run that *failed* can have been stopped by its limit. One that did its work is done,
  # whatever its last report said, and one the wall clock killed was stopped by the wall clock.
  test "a run that finished its work, or that something else stopped, is not a limit", %{
    project: project,
    user: user,
    worker: worker
  } do
    blocking = %{
      "rate_limit" => %{
        "status" => "rejected",
        "resets_at" => System.os_time(:second) + 3600,
        "rate_limit_type" => "five_hour"
      }
    }

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    assignment = FakeWorker.assign(only_job(ticket), worker)

    {:ok, done} =
      FakeWorker.finish(assignment, "success", doc: "refinement.md", harness: blocking)

    assert {done.status, done.outcome} == {:finished, :converged}

    {:ok, ticket} = Tickets.admit(project, %{title: "y"}, {:user, user.id})
    assignment = FakeWorker.assign(only_job(ticket), worker)
    result = FakeWorker.result(assignment, "rate_limited", doc: "refinement.md")

    {:ok, killed} = Jobs.complete(assignment["job_id"], %{result | killed: :wall_clock})
    assert killed.status == :finished
  end

  # A resume the limit refused never got going either — no model, nothing done — and read as a
  # failed resume it would be re-queued *fresh*, throwing away the session it is waiting to
  # continue. The limit is asked first.
  test "a resume refused by the limit keeps its session", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_job(ticket)
    {:ok, job} = Repo.update(Job.progress_changeset(job, %{harness_session_id: "sess-41"}))

    assignment = FakeWorker.assign(job, worker)

    {:ok, stopped} =
      FakeWorker.finish(assignment, "rate_limited",
        doc: "refinement.md",
        harness: %{"model" => nil, "session_id" => nil}
      )

    assert %{status: :pending, harness_session_id: "sess-41"} = stopped
    refute "job.resume_failed" in event_types(ticket)
  end

  # Only a placement stick. A ticket stuck on anything else — its allowance, a rejected approval,
  # a missing transition — was stuck for a reason no assignment answers, and one that holds no
  # pending job has nothing for a machine to run.
  test "an assignment brings back no ticket stuck for any other reason", %{
    project: project,
    user: user
  } do
    {:ok, other_reason} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, _} = Engine.stick(Tickets.get!(other_reason.id), "ticket cost cap reached")

    {:ok, nothing_pending} = Tickets.admit(project, %{title: "y"}, {:user, user.id})
    {:ok, _} = Repo.update(Job.progress_changeset(only_job(nothing_pending), %{status: :running}))
    {:ok, _} = Engine.stick(Tickets.get!(nothing_pending.id), "no template", :placement)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "any",
        provider: "fake",
        memory: 1_000,
        cores: 1,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)

    assert Tickets.get!(other_reason.id).status == :stuck
    assert Tickets.get!(nothing_pending.id).status == :stuck
  end

  # The same path reached by a **project chat**, which has no ticket to stick. Unguarded this
  # is not a wrong answer but a crash — `Tickets.get!(nil)` inside the scheduling pass, on every
  # pass. What it does instead is wait, and say why on its own page.
  #
  # **Destroyed, not merely unregistered**, for the reason the test above gives: a permanent
  # machine that could hold the chat once free makes it a queue, and with it left standing this
  # test answered `:at_capacity` and never reached the template path it is named for.
  test "a chat that no template can hold leaves the scheduler standing", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "tiny",
        provider: "fake",
        memory: 1,
        cores: 1,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, chat} = Forge.Conversations.open(project, "hello")
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Jobs.get!(chat.id).status == :pending

    # Still alive, and still able to answer.
    assert Forge.Jobs.Scheduler.tick() == 0

    # And the answer is recorded once, in the sentence a ticket would have been stuck with.
    assert waits_and_starts(chat) == ["none_fit"]
    sentence = Jobs.current_wait(Jobs.get!(chat.id)) |> Events.summary()
    assert sentence =~ "Waiting for a template"
    # The template here is too small, but the same answer covers one that refuses the kind — a
    # chat on a builds-only template — so the sentence names both rather than size alone.
    assert sentence =~ "both takes this kind of job and is big enough for it"
  end

  # A job that cannot be placed says why, and says it once per reason: the scheduler asks every
  # two seconds and the log is append-only (`docs/design/provisioning.md` § The gate). Three
  # rules, each with its own step — the same reason twice is one event, a changed reason is
  # another, and a job that ran and came back may say the same thing again.
  test "a job that waits says why, once each time the reason changes", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "one",
        provider: "fake",
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    start_supervised!(Forge.Jobs.Scheduler)

    # The template makes a machine, and while it boots the job waits for that one.
    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["creating"]
    assert Jobs.current_wait(Jobs.get!(job.id)) |> Events.summary() =~ "one is being made"

    # Asked again while it boots, the answer is the same, and nothing is written.
    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["creating"]

    # The machine reports ready and drops out of touch: it is no longer being made, and it
    # still fills the template's ceiling — a changed reason, and another event.
    [booted] = Forge.Workers.list() |> Enum.filter(&(&1.template_id == template.id))
    {:ok, _} = Forge.Workers.ready(booted, %{"memory_budget" => 64_000_000_000})
    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["creating", "at_capacity"]

    # Asked again, the answer is the same, and nothing is written.
    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["creating", "at_capacity"]

    # A machine turns up and the job runs on it — then that machine is lost, and the job is
    # back in the queue behind the same full template.
    second = FakeWorker.connect(project: project)
    assert Forge.Jobs.Scheduler.tick() == 1
    {:ok, _} = Jobs.requeue(job.id, :worker_lost)
    Registry.unregister(Forge.Workers.Registry, second.id)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["creating", "at_capacity", :started, "at_capacity"]

    # What the page draws is the latest reason, in words.
    assert Jobs.current_wait(Jobs.get!(job.id)) |> Events.summary() =~ "Waiting for room"
  end

  # A driver that refuses leaves its words on the worker row, and the job says where to look.
  # The refused row keeps its slot until the sweep retires it, so the next pass is a queue.
  test "a machine the provider refused is what the job waits on", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)
    Forge.Provider.Fake.refuse({:fake, "no such size"})
    on_exit(&Forge.Provider.Fake.allow/0)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "refused",
        provider: "fake",
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["create_failed"]
    # The page shows its viewer's own machines, so the sentence says whose to look at.
    assert Jobs.current_wait(Jobs.get!(job.id)) |> Events.summary() =~
             "workers page of whoever owns the template"

    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["create_failed", "at_capacity"]
  end

  # Not every refusal after placement is a wait. A ticket over its allowance is stuck, which is
  # its own record and takes the job out of the queue; recording a wait beside it would say the
  # job is waiting for a machine when it is waiting for a person (`provisioning.md` § The gate).
  test "a ticket over its allowance is stuck, and its job records no wait", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    {:ok, _over} =
      ticket |> Ecto.Changeset.change(cost_usd: Decimal.new("25.00")) |> Forge.Repo.update()

    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Tickets.get!(ticket.id).status == :stuck
    assert waits_and_starts(job) == []
  end

  # The platform refuses a template whose provider credential is not its owner's before any driver
  # is asked, so no worker row is written and the workers page has nothing to say. The sentence
  # sent the operator there all the same; it names the templates page, where the words are.
  test "a template whose credential may not be spent says so, and where", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "theirs",
        provider: "fake",
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1
      })

    {:ok, theirs} =
      Forge.Provisioning.create_credential(Forge.AccountsFixtures.user_fixture(), %{
        name: "theirs",
        provider: "fake",
        secret: %{"token" => "their-money"}
      })

    # A row saved before the changeset checked whose credential it held.
    {1, _} =
      Forge.Repo.update_all(
        Ecto.Query.from(t in Forge.Provisioning.Template, where: t.id == ^template.id),
        set: [provider_credential_id: theirs.id]
      )

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["credential_refused"]

    sentence = Jobs.current_wait(Jobs.get!(job.id)) |> Events.summary()
    assert sentence =~ "templates page of whoever owns the template"
    refute sentence =~ "workers page"
    # And there is nothing on that page to read: no machine was made from the template.
    refute Enum.any?(Forge.Workers.list(), &(&1.template_id == template.id))
  end

  # The same shape for an image the platform knows it cannot talk to: refused before the driver
  # is asked, no worker row, and the words on the template — so the sentence names that page
  # (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol).
  test "a template whose image speaks the wrong protocol says so, and where", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "too-new",
        provider: "fake",
        image: "snapshot-1",
        image_protocol: ForgeCore.WorkerProtocol.current() + 1,
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert waits_and_starts(job) == ["image_refused"]

    sentence = Jobs.current_wait(Jobs.get!(job.id)) |> Events.summary()
    assert sentence =~ "templates page of whoever owns the template"
    refute sentence =~ "workers page"
    refute Enum.any?(Forge.Workers.list(), &(&1.template_id == template.id))
  end

  # A **ticket** chat has a ticket, and it is not the chat's to stick: the ticket's own work may
  # place perfectly well. Here the template takes workflow jobs and refuses chats, so the job is
  # being made a machine while the conversation about it can go nowhere.
  test "a ticket chat no template can hold leaves its ticket active", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    Registry.unregister(Forge.Workers.Registry, worker.id)
    :ok = Forge.Workers.destroy(worker)

    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "builds-only",
        provider: "fake",
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1,
        accepts: [:workflow]
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, chat} = Forge.Conversations.open(project, "what is this about?", ticket: ticket)
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 0
    assert Forge.Jobs.Scheduler.tick() == 0

    assert Jobs.get!(chat.id).status == :pending
    assert Tickets.get!(ticket.id).status == :active
    refute "ticket.stuck" in event_types(ticket)

    # Two jobs on one ticket, each with its own reason, each said once per change. What a wait
    # is compared with is that job's own latest, not the ticket's: read by ticket, each pass
    # found the other job's reason, took it for a change, and wrote its own again.
    job = Enum.find(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    assert waits_and_starts(job) == ["creating"]
    assert waits_and_starts(chat) == ["none_fit"]
  end

  # A job that has run before still points at the machine that ran it, and that machine may
  # still hold its worktree and its harness session
  # (`docs/design/provisioning.md` § Affinity on resume). The scheduler has to *pass* the
  # preference; testing `assignable/2` alone leaves the wiring unchecked, which it was.
  test "a job that has run before goes back to the machine that ran it", %{
    project: project,
    user: user,
    worker: worker
  } do
    Registry.unregister(Forge.Workers.Registry, worker.id)

    # Oldest first is what the gate falls back to, so `first` is what it would pick blind.
    first = FakeWorker.connect(project: project)
    second = FakeWorker.connect(project: project)
    refute first.id == second.id

    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)
    job = only_job(ticket)

    # It ran on the second machine and came back to the queue still naming it — which is what
    # `requeue/2` leaves behind, since it changes the status and not the worker.
    {:ok, _} =
      Jobs.get!(job.id)
      |> Ecto.Changeset.change(%{worker_id: second.id})
      |> Forge.Repo.update()

    assert Forge.Jobs.Scheduler.tick() == 1
    assert Jobs.get!(job.id).worker_id == second.id
  end

  # `Forge.Jobs.Scheduler` states the rule in a comment on the line: "Nothing to run is the only
  # moment a machine may be destroyed for being idle." The sweep runs at the top of a pass, before
  # a single job is handed out, so sweeping unconditionally destroys the very machine the pass was
  # about to use — and with the template's `max_workers` of 1 that is not a slow queue but a queue
  # that never moves:
  # create a machine, wait for it to boot, destroy it before it is given anything, repeat.
  #
  # "Idle" here is the machine having had nothing to do for the period, which a machine that has
  # just finished one job and has another waiting behind it is, for the moment between them.
  test "a machine with work waiting is not destroyed for having been idle", %{
    project: project,
    user: user,
    worker: worker
  } do
    Forge.Provider.Fake.watch()
    previous = Application.get_env(:forge, Forge.Workers, [])
    on_exit(fn -> Application.put_env(:forge, Forge.Workers, previous) end)

    Application.put_env(
      :forge,
      Forge.Workers,
      Keyword.merge(previous, idle_period_ms: 60_000)
    )

    # Only a managed machine is ever destroyed for being idle, so the setup's permanent one is
    # made into what the scheduler would have made: a machine from a template on this project.
    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "idle",
        provider: "fake",
        memory: 64_000_000_000,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)

    {:ok, worker} =
      Forge.Workers.update(Forge.Workers.get!(worker.id), %{
        managed: true,
        template_id: template.id
      })

    # The machine has been sitting there long enough to qualify; the clock is moved rather than
    # waited on.
    Forge.ForgeFixtures.serve!(worker, project)
    :ok = Forge.Workers.release(worker.id)

    {:ok, _worker} =
      Forge.Workers.update(Forge.Workers.get!(worker.id), %{
        idle_since: DateTime.add(DateTime.utc_now(:second), -120)
      })

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 1

    refute_receive {:provider_destroy, _id, _credential}
    assert Forge.Workers.get!(worker.id).status != :destroyed
    assert Jobs.get!(only_job(ticket).id).worker_id == worker.id
  end

  test "a job assigned to a worker that has gone away stays pending", %{
    project: project,
    user: user
  } do
    worker = FakeWorker.connect()
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    # The registry entry goes when the channel process does; here, when this one unregisters.
    Registry.unregister(Forge.Workers.Registry, worker.id)

    assert {:error, :not_connected} = Jobs.assign(job, worker)
    assert Jobs.get!(job.id).status == :pending
  end

  defp only_job(ticket), do: hd(Jobs.for_ticket(ticket.id))

  defp unstuck_count(ticket), do: Enum.count(event_types(ticket), &(&1 == "ticket.unstuck"))

  # A template assigned to `project` that could hold any job the tests here make.
  defp template_fixture(user, project) do
    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "t-#{System.unique_integer([:positive])}",
        provider: "fake",
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    template
  end

  # As many failures as take a template out of service.
  defp out_of_service!(template) do
    for _ <- 1..Forge.Provisioning.failure_limit(),
        do: Forge.Provisioning.failed(template.id, "x")
  end

  defp reload_template(template), do: Repo.get!(Forge.Provisioning.Template, template.id)

  # What a machine made from `template` says at its first join: the template's figures, and a
  # current release's harness.
  defp template_report(template) do
    %{
      "memory_budget" => template.memory,
      "cores" => template.cores,
      "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
    }
  end

  # A permanent machine of `user`'s assigned to `project` before it has ever booted: it has said
  # what protocol it speaks at its join (`Workers.admit/2`), and nothing else yet.
  defp permanent_machine(user, project) do
    {:ok, machine, _token} =
      Forge.Workers.create(%{provider: "fake", managed: false, user_id: user.id})

    {:ok, machine} =
      Forge.Workers.update(machine, %{protocol: ForgeCore.WorkerProtocol.current()})

    {:ok, _} = Forge.Workers.assign(user, machine.id, project.id)
    machine
  end

  # A ticket stuck as the scheduler sticks one it cannot place, holding its pending job.
  defp stuck_for_placement(project, user) do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, _} = Engine.stick(Tickets.get!(ticket.id), "no template", :placement)
    ticket
  end

  # Another project `user` is in, with nothing assigned to it yet.
  defp unrelated_project(user) do
    {:ok, elsewhere} =
      register_owned!(%{
        name: "elsewhere-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    join!(elsewhere, user)
    elsewhere
  end

  # The only template assigned to `project` names a snapshot speaking a protocol this platform
  # refuses: every pass refuses it before asking the driver, the passes up to the failure limit
  # take it out of service, and the next sticks the ticket for placement
  # (`Forge.Workers.create_machine/1`).
  defp stuck_on_a_refused_image(project, user) do
    {:ok, template} =
      Forge.Provisioning.create_template(user, %{
        name: "old-snapshot",
        provider: "fake",
        image: "snapshot-old",
        image_protocol: ForgeCore.WorkerProtocol.minimum() - 1,
        memory: 64 * 1024 * 1024 * 1024,
        cores: 64,
        max_workers: 1
      })

    {:ok, _} = Forge.Provisioning.assign(user, template.id, project.id)
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    for _pass <- 0..Forge.Provisioning.failure_limit(),
        do: assert(Forge.Jobs.Scheduler.tick() == 0)

    assert Tickets.get!(ticket.id).status == :stuck

    assert %{"cause" => "placement", "reason" => reason} =
             Events.for_ticket(ticket.id)
             |> Enum.find(&(&1.type == "ticket.stuck"))
             |> Map.fetch!(:payload)

    assert reason =~ "disabled"
    refute_received {:provider_create, _opts}
    {template, ticket}
  end

  defp runs(job),
    do: Repo.all(from r in Forge.Jobs.Run, where: r.job_id == ^job.id, order_by: r.started_at)

  defp open_runs(job), do: job |> runs() |> Enum.count(&is_nil(&1.finished_at))

  defp job_status(ticket), do: Jobs.get!(only_job(ticket).id).status

  test "recover/0 re-queues jobs a dead node left running", %{project: project, user: user} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))
    assert Jobs.recover() == 1
    assert Jobs.get!(job.id).status == :pending
  end

  # Two behaviours that used to be tested here are the worker's now, and are tested there:
  # that a cold start clears `out/` so a recovered job does not collect the dead run's
  # documents (worker/test/forge_worker/job/dir_test.exs), and that a resume keeps them
  # (worker/test/forge_worker/job/runner_test.exs). The platform no longer has a job
  # directory or a worktree to get this wrong in.

  # A row the progress changeset refuses must be refused before anything is assigned, and as
  # a two-tuple. `mark_started/2` ends in `Repo.transaction/1`, whose Multi failure is a
  # four-tuple that the scheduler does not match: it raised, its supervisor restarted it, and
  # the next tick tried the same job again. With the assignment sent before the row was
  # marked, every one of those cycles billed a real invocation.
  test "a job whose progress cannot be recorded is refused without assigning anything", %{
    project: project,
    user: user,
    worker: worker
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    # An outcome on a job that is not finished: rejected by `progress_changeset/2`. Written
    # around the changeset, the way a stray query or a bad repair would leave it.
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [outcome: :converged])

    # A four-tuple does not match this, which is the point.
    assert {:error, _reason} = Jobs.assign(Jobs.get!(job.id), worker)
    refute_receive {:assign, _assignment}, 100
  end

  # A ticket pins its workflow, and the validator's rules move between milestones, so a
  # pinned definition can stop parsing long after the row was written. The queue is shared:
  # one such ticket must not take it away from every other one.
  test "a stuck ticket whose pinned workflow no longer parses leaves the queue standing", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "unparseable"}, {:user, user.id})

    {:ok, _} =
      ticket
      |> Ecto.Changeset.change(workflow: %{"no longer" => "a workflow"}, status: :stuck)
      |> Repo.update()

    assert [%{kind: :stuck, detail: detail}] =
             Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))

    assert detail.transitions == []
  end

  test "an active ticket whose pinned workflow no longer parses leaves the queue standing", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "unparseable"}, {:user, user.id})

    {:ok, _} =
      ticket
      |> Ecto.Changeset.change(workflow: %{"no longer" => "a workflow"})
      |> Repo.update()

    assert Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id)) == []
  end

  # The grammar requires `when` values to be distinct per `from`, not targets, so two edges
  # may lead to the same state. The queue names states, so it must name each one once.
  test "transitions out of a state are listed once per target", %{user: user} do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => """
        version: 1
        initial: building
        states:
          building:
            prompt: agents/plan.md
            inputs: [ticket]
            produces: [plan.md]
            outcomes: [done, retry]
            budget: { turns: 1, cost: 0.01 }
          waiting_room: {}
        transitions:
          - { from: building, to: waiting_room }
          - { from: building, to: waiting_room, when: retry }
        limits:
          ticket_cost: 1.00
        """
      })

    {:ok, project} =
      register_owned!(%{name: "dup-#{System.unique_integer([:positive])}", repo_path: repo})

    {:ok, ticket} = Tickets.admit(project, %{title: "two edges, one target"}, {:user, user.id})

    {:ok, _} = ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update()

    assert [%{kind: :stuck, detail: %{transitions: transitions}}] =
             Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))

    assert transitions == ["waiting_room"]
  end
end
