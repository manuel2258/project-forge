defmodule Forge.MergeTest do
  @moduledoc """
  Merging, from the operator's approval down to the commit on the default branch and its copy on
  the mirror. The whole arc, because the point of the design is that they are one path.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Engine, Events, Git, Merge, Operator, Projects, Tickets}

  setup do
    data_dir = tmp_dir("merge-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    mirror = Path.join(tmp_dir("merge-mirror"), "mirror.git")
    :ok = Git.init_bare(mirror)

    name = "merge#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.register(%{name: name, repo_path: bare, default_branch: "main"})

    :ok = Projects.set_mirror(project, mirror)
    user = user_fixture()

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "do it"}, {:user, user.id})

    %{project: project, bare: bare, mirror: mirror, user: user, ticket: ticket}
  end

  describe "perform/2" do
    test "puts the approved commit on the default branch and on the mirror", context do
      %{ticket: ticket, bare: bare, mirror: mirror, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      assert {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, user)
      assert {:ok, ^merged} = Git.resolve(bare, "refs/heads/main")
      assert Git.ancestor?(bare, sha, merged)
      assert {:ok, ^merged} = Git.resolve(mirror, "refs/heads/main")
    end

    test "records who approved in the commit itself", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      {:ok, %{sha: merged}} = Merge.perform(ticket, user)
      {:ok, message} = Git.run(bare, ["show", "--no-patch", "--format=%an%n%B", merged])

      assert message =~ user.email
      assert message =~ "Changeset: #{sha}"
      assert message =~ "Ticket: #{Tickets.project_of(ticket).name}##{ticket.number}"
    end

    test "is idempotent", context do
      %{ticket: ticket, bare: bare} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, context.user)
      assert {:ok, %{sha: ^merged, already: true}} = Merge.perform(ticket, context.user)
      assert {:ok, [^merged]} = Git.commits_since(bare, sha, "refs/heads/main")
    end

    test "pins the approved commit so a rewritten branch cannot lose it", context do
      %{ticket: ticket, bare: bare} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      {:ok, _merged} = Merge.perform(ticket, context.user)
      assert {:ok, ^sha} = Git.resolve(bare, "refs/forge/approved/#{ticket.number}")
    end

    test "refuses when the approved commit is gone", %{ticket: ticket, user: user} do
      changeset!(ticket, String.duplicate("a", 40))

      assert {:error, {:approved_commit_gone, _sha}} = Merge.perform(ticket, user)
    end

    test "refuses when nothing was ever approved", %{ticket: ticket, user: user} do
      assert {:error, :no_changeset} = Merge.perform(ticket, user)
    end

    test "reports the conflicted paths and changes nothing", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      main = diverge_default_branch(context, "README.md", "the trunk's version")

      assert {:conflict, ["README.md"]} = Merge.perform(ticket, user)
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end
  end

  describe "entering a state that merges" do
    test "approving the changeset merges, and says so in the event log", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, "ship it")
      assert ticket.state == "merged"
      assert ticket.status == :done
      assert "ticket.merged" in event_types(ticket)

      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      assert Git.ancestor?(bare, sha, head)
    end

    # Had the ticket moved into terminal `merged` first, a stuck item there would offer no
    # transitions at all: a terminal state has none. Refusing before the transition is what keeps
    # the way forward open.
    test "a conflict refuses the approval and leaves the ticket where it can still move",
         context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      main = diverge_default_branch(context, "README.md", "the trunk's version")
      ticket = pend_merge(ticket)

      assert {:error, {:merge_conflict, ["README.md"]}} =
               Operator.decide(ticket, user, :approved, nil)

      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "review_ready"
      assert ticket.pending_transition["to"] == "merged"
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
      refute "ticket.merged" in event_types(ticket)
    end

    test "a ticket that cannot merge at all is stuck rather than silently done", context do
      %{ticket: ticket, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      ticket = pend_merge(ticket)

      # The engine's own path skips the pre-flight, which is what makes a late failure visible.
      workflow = Tickets.workflow(ticket)
      {:ok, transition} = ForgeCore.Engine.choose(workflow, "review_ready", "merged", nil)

      File.rm_rf!(Projects.repo_path(Tickets.project_of(ticket)))

      ticket =
        Engine.enter(
          %{ticket | state: transition.to},
          workflow,
          transition.to,
          user.id
        )

      assert ticket.status == :stuck
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # A commit on the ticket branch, pushed the way a job pushes: over the platform's endpoint.
  defp commit_on_branch(%{project: project, ticket: ticket}, path, content) do
    commit_over_http(project, ticket.branch, path, content)
  end

  # Moves the default branch somewhere the ticket branch cannot merge into cleanly. Written
  # directly, because the endpoint exists precisely to refuse this.
  defp diverge_default_branch(%{project: project, bare: bare}, path, content) do
    dir = Path.join(tmp_dir("merge-trunk"), "trunk")
    {:ok, _out} = Git.run(tmp_dir("merge-trunk-parent"), ["clone", "--quiet", bare, dir])
    {:ok, _out} = Git.run(dir, ["config", "user.name", "trunk"])
    {:ok, _out} = Git.run(dir, ["config", "user.email", "trunk@forge"])
    File.write!(Path.join(dir, path), content <> "\n")
    {:ok, _out} = Git.run(dir, ["commit", "--quiet", "-am", content])

    {:ok, _out} =
      Git.run(dir, ["push", "--quiet", bare, "HEAD:refs/heads/main"],
        env: [{"FORGE_INTERNAL", "1"}]
      )

    {:ok, sha} = Git.resolve(Projects.repo_path(project), "refs/heads/main")
    sha
  end

  defp changeset!(ticket, sha) do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
        blob_uri: "git:" <> sha
      })

    :ok
  end

  # The state the workflow leaves a ticket in just before the merge: resting in `review_ready`
  # with the approval of `changeset` pending.
  defp pend_merge(ticket) do
    {:ok, ticket} =
      ticket
      |> Ecto.Changeset.change(
        state: "review_ready",
        pending_transition: %{
          "from" => "review_ready",
          "to" => "merged",
          "outcome" => nil,
          "approve" => ["changeset"]
        }
      )
      |> Repo.update()

    ticket
  end

  defp event_types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
end
