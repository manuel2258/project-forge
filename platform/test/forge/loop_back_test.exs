defmodule Forge.LoopBackTest do
  @moduledoc """
  A flow whose later states send work back with their reasons, and a person who writes one of
  them: `docs/design/workflow-grammar-v1.md` § Inputs and § Semantics, and
  `docs/design/job-prompt.md` § How the job arrived.

  The workflow is the operator's own shape — refine, plan, implement, review, then a person
  tries it — and every input that names a reason is one its reader also runs without, the first
  time round. That used to undo the transition into `implementing` and stick the ticket.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, FakeWorker, Jobs, Operator, Tickets}
  alias Forge.Jobs.Job

  @workflow """
  version: 1
  initial: refining
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 20, cost: 0.50 }
    planning:
      prompt: agents/plan.md
      inputs: [ticket, refinement.md, implementation.md]
      produces: [plan.md]
      budget: { turns: 40, cost: 2.00 }
    implementing:
      prompt: agents/implement.md
      inputs: [plan.md, review.md, test-report.md]
      produces: [implementation.md, changeset]
      outcomes: [done, plan_invalid]
      budget: { turns: 200, cost: 10.00 }
    reviewing:
      prompt: agents/review.md
      inputs: [plan.md, implementation.md, changeset]
      produces: [review.md]
      outcomes: [done, changes_requested]
      budget: { turns: 60, cost: 3.00 }
    human_testing:
      produces: [test-report.md]
    merged:
      on_enter: merge
  transitions:
    - { from: refining,      to: planning,     approve: [refinement.md] }
    - { from: planning,      to: implementing }
    - { from: implementing,  to: reviewing }
    - { from: implementing,  to: planning,     when: plan_invalid, max: 2 }
    - { from: reviewing,     to: human_testing }
    - { from: reviewing,     to: implementing, when: changes_requested, max: 3 }
    - { from: human_testing, to: merged,       approve: [changeset] }
    - { from: human_testing, to: implementing }
  limits:
    ticket_cost: 25.00
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/agents/review.md" => "Review the change.\n"
      })

    {:ok, project} =
      register_owned!(%{name: "loop-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})

    %{ticket: ticket, user: user, worker: FakeWorker.connect()}
  end

  defp pending(ticket) do
    assert [%Job{} = job] =
             ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))

    job
  end

  defp run(ticket, worker, name, outcome \\ "done") do
    job = pending(ticket)
    written = %{name => "---\noutcome: #{outcome}\n---\n# #{name}\n\nFrom #{job.state}.\n"}
    {:ok, _job} = FakeWorker.run(job, worker, "success", written: written)
    Tickets.get!(ticket.id)
  end

  defp input_names(job), do: job |> Jobs.spec() |> Map.fetch!(:inputs) |> Enum.map(& &1.name)

  # Up to the first `implementing` job: refined, approved by a person, planned by the engine.
  defp to_implementing(%{ticket: ticket, user: user, worker: worker}) do
    ticket = run(ticket, worker, "refinement.md")
    {:ok, ticket} = Engine.decide(ticket, user.id, :approved, "Keep the table local.")
    run(ticket, worker, "plan.md")
  end

  test "the first implementing job starts without the reasons nobody has written yet", context do
    ticket = to_implementing(context)
    assert ticket.state == "implementing"

    spec = ticket |> pending() |> Jobs.spec()
    assert Enum.map(spec.inputs, & &1.name) == ["plan.md"]
    assert spec.absent_inputs == ["review.md", "test-report.md"]

    assert spec.entered == %{
             "from" => "planning",
             "outcome" => "done",
             "by" => "engine",
             "comment" => nil
           }
  end

  test "a person's approval reaches the next job with what they wrote", context do
    ticket = run(context.ticket, context.worker, "refinement.md")
    {:ok, _ticket} = Engine.decide(ticket, context.user.id, :approved, "Keep the table local.")

    assert %{"from" => "refining", "by" => "person", "comment" => "Keep the table local."} =
             ticket |> pending() |> Jobs.spec() |> Map.fetch!(:entered)
  end

  test "a review that sends the work back is an input the second time round", context do
    ticket = to_implementing(context)
    ticket = run(ticket, context.worker, "implementation.md")
    ticket = run(ticket, context.worker, "review.md", "changes_requested")

    assert ticket.state == "implementing"
    job = pending(ticket)
    spec = Jobs.spec(job)

    assert job.attempt == 2
    assert input_names(job) == ["plan.md", "review.md"]

    assert [%{name: "review.md", version: 1}] =
             Enum.filter(spec.inputs, &(&1.name == "review.md"))

    assert spec.absent_inputs == ["test-report.md"]

    assert spec.entered == %{
             "from" => "reviewing",
             "outcome" => "changes_requested",
             "by" => "engine",
             "comment" => nil
           }
  end

  test "a tester's note and their reason for sending it back reach the next job", context do
    ticket = to_implementing(context)
    ticket = run(ticket, context.worker, "implementation.md")
    ticket = run(ticket, context.worker, "review.md")
    assert ticket.state == "human_testing"

    {:ok, _ticket} =
      Operator.edit(ticket, context.user, "test-report.md", "The save button does nothing.\n")

    {:ok, ticket} =
      Engine.choose(Tickets.get!(ticket.id), context.user.id, "implementing",
        comment: "  Broken on a phone.  "
      )

    job = pending(ticket)
    spec = Jobs.spec(job)

    assert input_names(job) == ["plan.md", "review.md", "test-report.md"]
    assert Enum.find(spec.inputs, &(&1.name == "test-report.md")).content =~ "does nothing"
    assert spec.absent_inputs == []

    # No job ended in `human_testing`, so there is no outcome to name — only who and why.
    assert spec.entered == %{
             "from" => "human_testing",
             "outcome" => nil,
             "by" => "person",
             "comment" => "Broken on a phone."
           }
  end

  # The guarantee a required input carries: its absence is a failure to hear about, never a job
  # that runs without its plan.
  test "a required input that is missing refuses the transition into its reader", context do
    ticket = run(context.ticket, context.worker, "refinement.md")
    {:ok, ticket} = Engine.decide(ticket, context.user.id, :approved, nil)

    # Planning wrote nothing and ended in error, so there is no plan.md for implementing.
    {:ok, _job} = FakeWorker.run(pending(ticket), context.worker, "nothing")
    ticket = Tickets.get!(ticket.id)
    assert ticket.status == :stuck

    assert {:error, {:missing_input, "plan.md"}} =
             Engine.choose(ticket, context.user.id, "implementing")

    assert Tickets.get!(ticket.id).state == "planning"
  end
end
