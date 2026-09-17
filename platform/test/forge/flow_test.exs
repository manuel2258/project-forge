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

    # planning: blocks on a question, which is pushed to subscribed browsers
    Forge.Push.TestSender.watch()

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
    worker = FakeWorker.connect(memory_budget: Forge.Workers.slice_bytes())
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

  # `Forge.Jobs.Scheduler` states the rule in a comment on the line: "Nothing to run is the only
  # moment a machine may be destroyed for being idle." The sweep runs at the top of a pass, before
  # a single job is handed out, so sweeping unconditionally destroys the very machine the pass was
  # about to use — and with `max_workers: 1` that is not a slow queue but a queue that never moves:
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
      Keyword.merge(previous, idle_period_ms: 60_000, max_workers: 1)
    )

    # The machine has been sitting there long enough to qualify; the clock is moved rather than
    # waited on.
    :ok = Forge.Workers.release(worker.id)

    {:ok, _worker} =
      Forge.Workers.update(Forge.Workers.get!(worker.id), %{
        idle_since: DateTime.add(DateTime.utc_now(:second), -120)
      })

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 1

    refute_receive {:provider_destroy, _id}
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
