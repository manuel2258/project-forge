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

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Events, Git, Jobs, Merge, Operator, Projects, Queue, Tickets}

  setup do
    data_dir = tmp_dir("demo-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    mirror = Path.join(tmp_dir("demo-mirror"), "mirror.git")
    :ok = Git.init_bare(mirror)

    name = "demo#{System.unique_integer([:positive])}"
    {:ok, project} = Projects.register(%{name: name, repo_path: bare, default_branch: "main"})
    :ok = Projects.set_mirror(project, mirror)

    %{project: project, bare: bare, mirror: mirror, user: user_fixture()}
  end

  test "a ticket from idea to merged, and mirrored", context do
    %{project: project, bare: bare, mirror: mirror, user: user} = context
    {:ok, base} = Git.resolve(bare, "refs/heads/main")

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    # refined — the first job writes a document, and the transition out of it asks for approval.
    run("success", "refinement.md")
    assert [%{kind: :approval}] = queue(ticket)
    {:ok, ticket} = Operator.decide(Tickets.get!(ticket.id), user, :approved, "reads right")
    assert ticket.state == "planned"

    # planned — stops to ask something, which is answered from the queue.
    run("blocking", "plan.md")
    assert [%{kind: :question, question: %{key: "backend"}}] = queue(ticket)
    {:ok, _} = Operator.answer(Tickets.get!(ticket.id), user, "backend", %{choice: "b"})
    run("success", "plan.md")
    assert Tickets.get!(ticket.id).state == "implemented"

    # implemented — the agent commits in its checkout, which the platform pushes to the branch.
    run("success", "implementation.md", commit: "score.ex")
    ticket = Tickets.get!(ticket.id)
    assert ticket.state == "verified"

    {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
    assert head != base
    assert %{blob_uri: "git:" <> ^head} = Artifacts.latest(ticket.id, "changeset")

    # verified — converges, and the ticket comes to rest in a human state where a person looks at
    # it. The queue marks it reviewable, because the way out of it pins the changeset.
    run("success", "report.md")
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
    assert {:ok, "score.ex\n"} = Git.show(bare, merged, "score.ex")

    # …and the mirror has it, pushed by the repository's own post-receive hook.
    assert {:ok, ^merged} = Git.resolve(mirror, "refs/heads/main")

    # Nothing is left waiting on the operator, and the record says what happened.
    assert queue(ticket) == []
    types = ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
    assert "ticket.merged" in types
    assert "ticket.done" in types
    assert Decimal.compare(ticket.cost_usd, 0) == :gt
  end

  # Runs the one job the ticket is waiting on, the way the scheduler would.
  defp run(scenario, doc, opts \\ []) do
    config = Application.get_env(:forge, Forge.Jobs)

    env =
      [{"FAKE_SCENARIO", scenario}, {"FAKE_DOC", doc}] ++
        case Keyword.get(opts, :commit) do
          nil -> []
          path -> [{"FAKE_COMMIT", path}]
        end

    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :extra_env, env))

    [job] = Enum.filter(Jobs.pending(), &(&1.status == :pending))
    {:ok, _job} = Jobs.run(job)
    :ok
  end

  defp queue(ticket), do: Enum.filter(Queue.items(), &(&1.ticket.id == ticket.id))
end
