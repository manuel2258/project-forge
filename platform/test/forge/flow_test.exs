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

    # planned: blocks on a question
    scenario("blocking", "plan.md")
    {:ok, job} = Jobs.run(planned)
    assert job.status == :waiting
    assert job.harness_session_id == "sess-42"
    assert [%{kind: :question, question: %{key: "backend"}}] = Queue.items()
    assert Tickets.get!(ticket.id).state == "planned"

    # answer, resume: the second run resumes the session and sees answers.md
    [question] = Artifacts.open_blocking_questions(job.id)
    {:ok, _answer} = Artifacts.answer(question, user.id, %{choice: "b"})
    assert Artifacts.open_blocking_questions(job.id) == []
    assert %{content: content} = Artifacts.latest(ticket.id, "answers.md")
    assert content =~ "A: b"
    {:ok, job} = Jobs.resume(Jobs.get!(job.id))
    assert job.status == :pending

    scenario("success", "plan.md")
    {:ok, job} = Jobs.run(job)
    assert job.status == :finished
    job_dir = Path.join([Jobs.data_dir(), "jobs", job.id])
    assert File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume sess-42"
    assert File.read!(Path.join(job_dir, "fake-prompt.txt")) =~ "answers.md"
    assert Artifacts.versions(ticket.id, "plan.md") |> length() == 2

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

    {:ok, ticket} = Engine.choose(ticket, user.id, "merged")
    assert ticket.status == :done
    assert Queue.items() == []
    assert "ticket.done" in event_types(ticket)
    assert Jobs.pending() == []
  end

  test "recover/0 re-queues jobs a dead node left running", %{project: project, user: user} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    job = only_pending(ticket)
    {:ok, _} = Repo.update(Job.progress_changeset(job, %{status: :running}))
    assert Jobs.recover() == 1
    assert Jobs.get!(job.id).status == :pending
  end
end
