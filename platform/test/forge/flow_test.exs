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
    assert [%{kind: :stuck}] = Queue.items()

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
    wait_until(fn -> Jobs.get!(only_job(ticket).id).status == :finished end)
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

  defp only_job(ticket), do: hd(Jobs.for_ticket(ticket.id))

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
end
