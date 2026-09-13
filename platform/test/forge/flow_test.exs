defmodule Forge.FlowTest do
  @moduledoc """
  The milestone 1 loop, end to end, against the fake harness: admit a ticket, run jobs,
  approve, answer a blocking question, take a backward edge, get stuck, unstick.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, Jobs, Projects, Queue, Tickets}
  alias Forge.Jobs.Job

  setup do
    repo = seeded_repo()

    {:ok, project} =
      Projects.register(%{name: "game-#{System.unique_integer([:positive])}", repo_path: repo})

    user = user_fixture()

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    %{project: project, user: user, repo: repo}
  end

  defp scenario(name, doc) do
    config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(config, :extra_env, [{"FAKE_SCENARIO", name}, {"FAKE_DOC", doc}])
    )
  end

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
    assert ticket.state == "refined"
    assert ticket.branch == "ticket/1"
    assert Forge.Git.branch_exists?(repo, "ticket/1")
    assert String.length(ticket.workflow_commit) == 40
    assert Tickets.workflow(ticket).initial == "refined"

    assert %{content: "# Persist scores\n\nThey vanish.", version: 1} =
             Artifacts.latest(ticket.id, "ticket")

    job = only_pending(ticket)
    spec = Jobs.spec(job)
    assert spec.state == "refined"
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
      Projects.register(%{name: "broken-#{System.unique_integer([:positive])}", repo_path: repo})

    assert {:error, [%ForgeCore.Error{} | _]} =
             Tickets.admit(project, %{title: "x"}, {:user, user.id})
  end

  test "the whole loop: run, approve, block, answer, resume, backward edge, stuck, unstick", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    # refined: converges, transition needs approval of refinement.md
    scenario("success", "refinement.md")
    {:ok, job} = Jobs.run(only_pending(ticket))
    assert %Job{status: :finished, outcome: :converged, declared_outcome: "done", turns: 3} = job
    assert Decimal.equal?(job.cost_usd, Decimal.from_float(0.0421))

    assert %{version: 1, author: %{"kind" => "job"}} =
             Artifacts.latest(ticket.id, "refinement.md")

    assert %{blob_uri: "file://" <> _} = Artifacts.latest(ticket.id, "transcript-refined-1.jsonl")

    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "refined"
    assert ticket.pending_transition["to"] == "planned"
    assert Decimal.equal?(ticket.cost_usd, Decimal.from_float(0.0421))
    assert [%{kind: :approval}] = Queue.items()
    assert "job.harness.started" in event_types(ticket)

    # approve: transition taken, planned job created
    {:ok, ticket} = Engine.decide(ticket, user.id, :approved, "looks right")
    assert ticket.state == "planned"
    assert ticket.pending_transition == nil

    assert [%{decision: :approved}] =
             Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id)

    planned = only_pending(ticket)
    assert Enum.map(Jobs.spec(planned).inputs, & &1.name) == ["ticket", "refinement.md"]

    # planned: blocks on a question, which is pushed to subscribed browsers
    Forge.Push.TestSender.watch()

    {:ok, _} =
      Forge.Push.subscribe(user, %{
        "endpoint" => "https://push.example/phone",
        "keys" => %{
          "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
          "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        }
      })

    scenario("blocking", "plan.md")
    {:ok, job} = Jobs.run(planned)
    assert job.status == :waiting
    Forge.Push.flush()
    assert_receive {:push, "https://push.example/phone", %{"body" => "Which backend?"}, _opts}
    assert job.harness_session_id == "sess-42"
    assert [%{kind: :question, question: %{key: "backend"}}] = Queue.items()
    assert Tickets.get!(ticket.id).state == "planned"

    # answer, resume: the second run resumes the session and sees answers.md
    [question] = Artifacts.open_blocking_questions(ticket.id)
    {:ok, _answer} = Artifacts.answer(question, user.id, %{choice: "b"})
    assert Artifacts.open_blocking_questions(ticket.id) == []
    assert %{content: content} = Artifacts.latest(ticket.id, "answers.md")
    assert content =~ "A: b"
    assert Artifacts.answered_keys(ticket.id) == ["backend"]

    # a human transition is refused while the job is live
    assert {:error, {:job_live, "planned"}} =
             Engine.choose(Tickets.get!(ticket.id), user.id, "implemented")

    {:ok, job} = Jobs.resume(Jobs.get!(job.id))
    assert job.status == :pending

    # the resumed agent keeps its question block; the answered key no longer blocks it
    scenario("blocking", "plan.md")
    {:ok, job} = Jobs.run(job)
    assert job.status == :finished
    assert job.turns == 6
    job_dir = Path.join([Jobs.data_dir(), "jobs", job.id])
    assert File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume sess-42"
    assert File.read!(Path.join(job_dir, "fake-prompt.txt")) =~ "answers.md"
    assert File.read!(Path.join([job_dir, "inputs", "answers.md"])) =~ "A: b"
    assert Artifacts.versions(ticket.id, "plan.md") |> length() == 2
    assert Queue.items() |> Enum.reject(&(&1.kind == :question)) |> length() == 0

    # planned -> implemented automatically; implemented reports plan_invalid -> back to planned
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "implemented"
    scenario("plan_invalid", "implementation.md")
    {:ok, _} = Jobs.run(only_pending(ticket))
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "planned"
    assert Jobs.spec(only_pending(ticket)).attempt == 2

    # planned again -> implemented -> verified; verified exhausts its budget -> stuck
    scenario("success", "plan.md")
    {:ok, _} = Jobs.run(only_pending(ticket))
    scenario("success", "implementation.md")
    {:ok, _} = Jobs.run(only_pending(Tickets.get!(ticket.id)))
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "verified"
    verified = only_pending(ticket)

    assert Enum.map(Jobs.spec(verified).inputs, & &1.name) == [
             "plan.md",
             "implementation.md",
             "changeset"
           ]

    scenario("max_turns", "report.md")
    {:ok, job} = Jobs.run(verified)
    assert job.outcome == :budget_exhausted
    ticket = Tickets.get!(ticket.id)
    assert ticket.status == :stuck

    # A stuck item lists the transitions out of the state, so the operator can see the
    # choices without reading the workflow: docs/design/api-and-ui.md.
    assert [%{kind: :stuck, detail: detail}] = Queue.items()
    assert detail.state == "verified"
    assert Enum.sort(detail.transitions) == ["implemented", "review_ready"]

    # unstick by choosing the retry edge by hand, then finish
    {:ok, ticket} = Engine.choose(ticket, user.id, "implemented")
    assert {ticket.status, ticket.state} == {:active, "implemented"}
    scenario("success", "implementation.md")
    {:ok, _} = Jobs.run(only_pending(ticket))
    scenario("success", "report.md")
    {:ok, _} = Jobs.run(only_pending(Tickets.get!(ticket.id)))
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

  test "rejecting keeps the ticket pending; a stale job's result is orphaned", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    {:ok, _} = Jobs.run(only_pending(ticket))
    ticket = Tickets.get!(ticket.id)

    {:ok, rejected} = Engine.decide(ticket, user.id, :rejected, "not yet")
    assert rejected.state == "refined"
    assert rejected.pending_transition["to"] == "planned"

    assert [%{decision: :rejected}] =
             Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id)

    # the operator edits and approves the new version
    {:ok, v2} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, {:user, user.id}, %{
        content: "---\noutcome: done\n---\nBetter.\n"
      })

    {:ok, ticket} = Engine.decide(rejected, user.id, :approved, nil)
    assert ticket.state == "planned"
    assert [%{decision: :approved}] = Artifacts.approvals(v2.id)

    # a job whose ticket moved on decides nothing
    planned = only_pending(ticket)

    {:ok, moved} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: "verified",
          status: :active,
          cost_usd: ticket.cost_usd
        })
      )

    scenario("success", "plan.md")
    {:ok, _} = Jobs.run(planned)
    assert Tickets.get!(moved.id).state == "verified"
    assert "job.orphaned" in event_types(ticket)
  end

  test "a resume that never reaches the harness is re-queued as a fresh run", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    {:ok, job} =
      Repo.update(
        Job.progress_changeset(job, %{status: :pending, harness_session_id: "stale-session"})
      )

    scenario("no_start", "refinement.md")
    {:ok, job} = Jobs.run(job)
    assert job.status == :pending
    assert job.harness_session_id == nil
    assert "job.resume_failed" in event_types(ticket)

    scenario("success", "refinement.md")
    {:ok, job} = Jobs.run(job)
    assert job.outcome == :converged
  end

  test "the scheduler starts pending jobs and survives a dead runner", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    start_supervised!(Forge.Jobs.Scheduler)

    assert Forge.Jobs.Scheduler.tick() == 1

    # Recording a job's result and deciding what follows it are deliberately two transactions,
    # so a finished job is visible before the engine has moved the ticket. Waiting on the
    # decision rather than on the status is waiting for the thing this asserts.
    wait_until(fn -> Tickets.get!(ticket.id).pending_transition != nil end)
    assert Tickets.get!(ticket.id).pending_transition["to"] == "planned"

    # a runner that dies leaves no job running: the scheduler fails it and the engine decides
    {:ok, ticket2} = Tickets.admit(project, %{title: "y"}, {:user, user.id})
    job2 = only_pending(ticket2)
    scenario("hang", "refinement.md")
    Forge.Jobs.Scheduler.tick()
    wait_until(fn -> Jobs.get!(job2.id).status == :running end)
    [{_, runner, _, _}] = DynamicSupervisor.which_children(ForgeWorker.Job.Supervisor)
    Process.exit(runner, :kill)
    wait_until(fn -> Jobs.get!(job2.id).status == :finished end)
    assert Jobs.get!(job2.id).outcome == :error
    assert Tickets.get!(ticket2.id).status == :stuck
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(50) && wait_until(fun, attempts - 1)
    end
  end

  test "recover/0 re-queues jobs a dead node left running", %{project: project, user: user} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))
    assert Jobs.recover() == 1
    assert Jobs.get!(job.id).status == :pending
  end

  # `harness_session_id` is only ever persisted by the completion path (`Jobs.complete/2`),
  # so a node killed mid-job always recovers with it nil, no matter how far the dead run got
  # or what it left in the job's out/. Recovery must therefore hand that run a cold start,
  # which clears out/ before the harness runs again; otherwise `collect/2` decides this run's
  # outcome on a document the live run never wrote. See commit b3b7c77.
  test "a job recovered after its node died runs cold and does not collect the dead run's output",
       %{project: project, user: user} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    # The run that was in flight when the node died had reached the harness and written
    # refinement.md, but the node was killed before the job ever completed.
    job_dir = Path.join([Jobs.data_dir(), "jobs", job.id])
    File.mkdir_p!(Path.join(job_dir, "out"))

    File.write!(
      Path.join([job_dir, "out", "refinement.md"]),
      "---\noutcome: done\n---\nwritten by the run that was killed\n"
    )

    {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))
    assert Jobs.recover() == 1
    job = Jobs.get!(job.id)
    assert job.status == :pending
    assert job.harness_session_id == nil

    # The recovered run starts cold (no session to resume) and hits its turn budget without
    # writing anything itself. A correct cold start clears out/ first, so the document left
    # behind by the dead run must not be collected as this run's output.
    scenario("max_turns", "refinement.md")
    {:ok, job} = Jobs.run(job)

    assert job.outcome == :budget_exhausted
    refute Artifacts.latest(ticket.id, "refinement.md")
  end

  # The other half of the same behaviour: a job that *does* carry a session id is a genuine
  # resume, and must keep what the earlier attempt already produced in out/.
  test "a job resumed with a session id keeps the earlier attempt's output", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    job_dir = Path.join([Jobs.data_dir(), "jobs", job.id])
    File.mkdir_p!(Path.join(job_dir, "out"))

    File.write!(
      Path.join([job_dir, "out", "refinement.md"]),
      "---\noutcome: done\n---\nfrom the attempt this one resumes\n"
    )

    {:ok, job} = Repo.update(Job.progress_changeset(job, %{harness_session_id: "sess-42"}))

    # Same lever: max_turns writes nothing itself, so whatever is collected came from out/
    # as prepare/3 left it.
    scenario("max_turns", "refinement.md")
    {:ok, job} = Jobs.run(job)

    assert job.outcome == :budget_exhausted
    assert %{content: content} = Artifacts.latest(ticket.id, "refinement.md")
    assert content =~ "from the attempt this one resumes"
  end

  # A row the progress changeset refuses must be refused before anything is spawned, and as a
  # two-tuple. `mark_started/1` ends in `Repo.transaction/1`, whose Multi failure is a
  # four-tuple that `Forge.Jobs.Scheduler.start_one/2` does not match: it raised, its
  # supervisor restarted it, and the next tick tried the same job again. With the harness
  # started before the row was marked, every one of those cycles billed a real invocation.
  test "a job whose progress cannot be recorded is refused without starting a harness", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)

    # An outcome on a job that is not finished: rejected by `progress_changeset/2`. Written
    # around the changeset, the way a stray query or a bad repair would leave it.
    Repo.update_all(
      from(j in Job, where: j.id == ^job.id),
      set: [outcome: :converged]
    )

    # A four-tuple does not match this, which is the point.
    assert {:error, _reason} = Jobs.start(Jobs.get!(job.id))
    refute File.exists?(Path.join([Jobs.data_dir(), "jobs", job.id]))
  end

  # The checkout is only removed once a job finishes, so a node that died mid-job leaves it
  # behind with whatever the harness had not committed. `blocking` leaves the job waiting, so
  # the checkout is still there to inspect after the run.
  test "a cold start discards uncommitted work the dead run left in the checkout", %{
    project: project,
    user: user
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    checkout = seed_checkout(project, ticket, job, "from the run that was killed")

    scenario("blocking", "refinement.md")
    {:ok, job} = Jobs.run(job)

    assert job.status == :waiting
    assert File.dir?(checkout)
    refute File.exists?(Path.join(checkout, "half-done.txt"))
  end

  test "a resume keeps the work in progress in its checkout", %{project: project, user: user} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    checkout = seed_checkout(project, ticket, job, "from the attempt this one resumes")

    {:ok, job} = Repo.update(Job.progress_changeset(job, %{harness_session_id: "sess-42"}))

    scenario("blocking", "refinement.md")
    {:ok, job} = Jobs.run(job)

    assert job.status == :waiting
    assert File.read!(Path.join(checkout, "half-done.txt")) =~ "resumes"
  end

  # What a killed run leaves behind: a clone of the ticket branch with an uncommitted file in it.
  defp seed_checkout(project, ticket, job, content) do
    dir = Path.join([Jobs.data_dir(), "checkouts", job.id])
    {:ok, token, _row} = Forge.Git.Tokens.issue_for_job(job, ticket, project)

    :ok =
      ForgeWorker.Checkout.ensure(
        dir: dir,
        url: Forge.Git.Url.for(project),
        branch: ticket.branch,
        token: token
      )

    File.write!(Path.join(dir, "half-done.txt"), content)
    dir
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
        initial: built
        states:
          built:
            prompt: agents/plan.md
            inputs: [ticket]
            produces: [plan.md]
            outcomes: [done, retry]
            budget: { turns: 1, cost: 0.01 }
          waiting_room: {}
        transitions:
          - { from: built, to: waiting_room }
          - { from: built, to: waiting_room, when: retry }
        limits:
          ticket_cost: 1.00
        """
      })

    {:ok, project} =
      Projects.register(%{name: "dup-#{System.unique_integer([:positive])}", repo_path: repo})

    {:ok, ticket} = Tickets.admit(project, %{title: "two edges, one target"}, {:user, user.id})

    {:ok, _} = ticket |> Ecto.Changeset.change(status: :stuck) |> Repo.update()

    assert [%{kind: :stuck, detail: %{transitions: transitions}}] =
             Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))

    assert transitions == ["waiting_room"]
  end
end
