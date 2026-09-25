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

  alias Forge.Git.Tokens

  setup do
    data_dir = tmp_dir("demo-data")
    config = Application.get_env(:forge, Forge.Jobs)

    # `repos_dir` too, not only `data_dir`: the mirror below is authenticated, and the hook
    # derives its mirror-credential directory from its own working directory while
    # `Forge.Git.Credentials.path/2` derives it from `Projects.repos_dir/0` — the two agree only
    # when the project's repository actually lives under `repos_dir`, which `seeded_repo/1`'s
    # fixture does not on its own (see the rename below). `node_repos_dir/0` rather than a fixed
    # `System.tmp_dir/0` sibling: unique per test, so an interrupted run never leaves a stale
    # `<name>.git` behind for the next run's `File.rename!` to collide with, and it is already
    # under `System.tmp_dir/0` so the rename stays same-filesystem.
    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.merge(config, data_dir: data_dir, repos_dir: node_repos_dir())
    )

    # Captured now, while the override above is live: `Credentials.dir/0` reads
    # `Projects.repos_dir/0` when called, and an `on_exit` that restored the config first and
    # read it after would compute the *original* `repos_dir` — deleting an empty directory
    # nobody used while leaving the real credential files, mode 0600 and holding live git
    # tokens, behind in the shared `mirror-credentials` directory forever.
    credentials_dir = Forge.Git.Credentials.dir()

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, config)
      File.rm_rf(credentials_dir)
    end)

    bare = seeded_repo()
    name = "demo#{System.unique_integer([:positive])}"
    {:ok, project} = register_owned!(%{name: name, repo_path: bare, default_branch: "main"})

    # Moved to `<repos_dir>/<name>.git`, the address a normal registration would have: see the
    # comment on the config override above for why the credential path needs it.
    real_bare = Path.join(Projects.repos_dir(), project.name <> ".git")
    File.mkdir_p!(Path.dirname(real_bare))
    File.rename!(bare, real_bare)

    {:ok, project} =
      project |> Forge.Projects.Project.changeset(%{repo_path: real_bare}) |> Repo.update()

    bare = real_bare

    # `member_fixture/2` is an admin by default, which is what `put_mirror/5` needs.
    user = member_fixture(project)

    # Mirrored over the platform's own git endpoint rather than to a local path, which the
    # post-receive hook now refuses outright: a second registered project, reached the same way a
    # job or the settings page would reach any mirror, with a default-branch write token minted
    # for it. A clone of `bare`'s own current state, not an independently seeded repository: the
    # mirror push is fast-forward only on both ends, and two unrelated histories are never a
    # fast-forward of one another.
    destination_bare = mirror_target(bare)

    {:ok, destination} =
      register_owned!(%{
        name: "demo-mirror#{System.unique_integer([:positive])}",
        repo_path: destination_bare,
        default_branch: "main"
      })

    {:ok, token, _row} = Tokens.issue(destination, ref: "refs/heads/main", write: true)

    :ok =
      Projects.put_mirror(
        project,
        user,
        "backup",
        platform_git_url(destination.name),
        user: "forge",
        token: token
      )

    # One worker, connected, with room for anything: the tier is milestone 3's and is tested
    # there. What this demo needs from it is that a job runs somewhere and pushes.
    %{
      project: project,
      bare: bare,
      destination: destination,
      user: user,
      worker: FakeWorker.connect()
    }
  end

  test "a ticket from idea to merged, and mirrored", context do
    %{project: project, bare: bare, destination: destination, user: user, worker: worker} =
      context

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
    assert {:ok, ^merged} = Git.resolve(Projects.repo_path(destination), "refs/heads/main")

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
