defmodule Forge.DemoTest do
  @moduledoc """
  The milestone 4 demo, which `poc-plan.md` makes the acceptance test: a ticket from idea to
  merged, every human decision taken through `Forge.Operator` — the same operations the queue page
  calls — and the result on the mirror.

  The agents are the fake harness, so this proves the machinery rather than the writing: the
  statechart, the git endpoint a job clones and pushes over, the hooks that guard it, the merge
  the approval triggers, and the mirror the merge reaches.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{
    Artifacts,
    Events,
    FakeWorker,
    Git,
    Jobs,
    Merge,
    Operator,
    Projects,
    Queue,
    Tickets
  }

  setup do
    data_dir = tmp_dir("demo-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    mirror = Path.join(tmp_dir("demo-mirror"), "mirror.git")
    :ok = Git.init_bare(mirror)

    name = "demo#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})
    :ok = Projects.set_mirror(project, mirror)

    # One worker, connected, with room for anything: the tier is milestone 3's and is tested
    # there. What this demo needs from it is that a job runs somewhere and pushes.
    %{
      project: project,
      bare: bare,
      mirror: mirror,
      user: member_fixture(project),
      worker: FakeWorker.connect()
    }
  end

  test "a ticket from idea to merged, and mirrored", context do
    %{project: project, bare: bare, mirror: mirror, user: user, worker: worker} = context
    {:ok, base} = Git.resolve(bare, "refs/heads/main")

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    # refining — the first job writes a document, and the transition out of it asks for approval.
    run(worker, "success", "refinement.md")
    assert [%{kind: :approval}] = queue(ticket)
    {:ok, ticket} = Operator.decide(Tickets.get!(ticket.id), user, :approved, "reads right")
    assert ticket.state == "planning"

    # planning — stops to ask something, which is answered from the queue.
    run(worker, "blocking", "plan.md")
    assert [%{kind: :question, question: %{key: "backend"}}] = queue(ticket)
    {:ok, _} = Operator.answer(Tickets.get!(ticket.id), user, "backend", %{choice: "b"})
    run(worker, "success", "plan.md")
    assert Tickets.get!(ticket.id).state == "implementing"

    # implementing — the agent commits in its checkout, which the platform pushes to the branch.
    run(worker, "success", "implementation.md", commit: {"score.ex", "def persist, do: :ok\n"})
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "verifying"

    {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
    assert head != base
    assert %{blob_uri: "git:" <> ^head} = Artifacts.latest(ticket.id, "changeset")

    # verifying — converges, and the ticket comes to rest in a human state where a person looks at
    # it. The queue marks it reviewable, because the way out of it pins the changeset.
    run(worker, "success", "report.md")
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "review_ready"

    assert [%{kind: :review, detail: %{transitions: ["merged"], reviewable: true}}] =
             queue(ticket)

    # The merge decision: taking the transition records the approval of the changeset and merges,
    # because `merged` declares `on_enter: merge`.
    {:ok, ticket} = Operator.transition(Tickets.get!(ticket.id), user, "merged")
    assert ticket.state == "merged"
    assert ticket.status == :done
    assert Merge.merged?(ticket)

    {:ok, merged} = Git.resolve(bare, "refs/heads/main")
    assert Git.ancestor?(bare, head, merged)
    assert {:ok, "def persist, do: :ok\n"} = Git.show(bare, merged, "score.ex")

    # …and the mirror has it, pushed by the repository's own post-receive hook.
    assert {:ok, ^merged} = Git.resolve(mirror, "refs/heads/main")

    # Nothing is left waiting on the operator, and the record says what happened.
    assert queue(ticket) == []
    types = ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
    assert "ticket.merged" in types
    assert "ticket.done" in types
    assert Decimal.compare(ticket.cost_usd, 0) == :gt
  end

  # Runs the one job the ticket is waiting on, the way the scheduler would: assign it to the
  # worker and let the worker answer.
  defp run(worker, scenario, doc, opts \\ []) do
    [job] = Enum.filter(Jobs.pending(), &(&1.status == :pending))
    {:ok, _job} = FakeWorker.run(job, worker, scenario, Keyword.put(opts, :doc, doc))
    :ok
  end

  defp queue(ticket), do: Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))
end
