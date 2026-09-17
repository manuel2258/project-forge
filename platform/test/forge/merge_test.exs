defmodule Forge.MergeTest do
  @moduledoc """
  Merging, from the operator's approval down to the commit on the default branch and its copy on
  the mirror. The whole arc, because the point of the design is that they are one path.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
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
      register_owned!(%{name: name, repo_path: bare, default_branch: "main"})

    :ok = Projects.set_mirror(project, mirror)
    user = user_fixture()
    join!(project, user)

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

    # The author is who approved; the committer is the platform, and is *stated* rather than
    # left to git. `commit-tree` with no committer falls back to the host's passwd entry and
    # hostname — a different commit on every host, and no commit at all where there is neither,
    # which is precisely the container image (`docs/deploy.md` § In a container), where git
    # fails with "unable to auto-detect email address".
    test "the committer is the platform, stated rather than taken from the host", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      {:ok, %{sha: merged}} = Merge.perform(ticket, user)
      {:ok, who} = Git.run(bare, ["show", "--no-patch", "--format=%cn <%ce>|%an", merged])

      assert String.trim(who) == "forge <forge@localhost>|#{user.email}"
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

  describe "a conversation's branch" do
    setup %{project: project} do
      {:ok, chat} = Forge.Conversations.open(project, "have a look at this")
      %{chat: chat}
    end

    defp commit_on_chat(project, chat, path, content) do
      repo = Forge.Projects.repo_path(project)
      branch = Forge.Jobs.chat_branch(chat)
      work = tmp_dir("chat-work")
      {_out, 0} = System.cmd("git", ["clone", "--quiet", "--branch", branch, repo, work])
      File.write!(Path.join(work, path), content)

      # FORGE_INTERNAL because this stands in for the worker, which pushes with a token scoped
      # to exactly this ref. The hook refuses an uncredentialed push, which is the point of it.
      for args <- [
            ["config", "user.name", "chat"],
            ["config", "user.email", "chat@forge"],
            ["add", "."],
            ["commit", "--quiet", "-m", "from the conversation"],
            ["push", "--quiet", "origin", "HEAD:refs/heads/" <> branch]
          ] do
        {_out, 0} =
          System.cmd("git", ["-C", work] ++ args,
            stderr_to_stdout: true,
            env: [{"FORGE_INTERNAL", "1"}]
          )
      end

      {:ok, head} = Git.resolve(repo, "refs/heads/" <> branch)
      head
    end

    test "merges into the default branch by the same route a ticket takes", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      head = commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")

      assert {:ok, %{sha: sha, already: false}} = Merge.perform_chat(chat, user)

      {:ok, default} = Git.resolve(bare, "refs/heads/main")
      assert default == sha
      assert Git.ancestor?(bare, head, default)
      assert {:ok, "from a conversation\n"} = Git.show(bare, sha, "NOTES.md")
    end

    # The pin is what keeps the merged commit reachable. Deleting the branch before it exists
    # would leave the commit collectable in between, and "the branch is deleted when done" would
    # quietly mean the work was too.
    test "the branch is gone afterwards, and the commit is still reachable", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      head = commit_on_chat(project, chat, "NOTES.md", "keep me\n")

      assert {:ok, _result} = Merge.perform_chat(chat, user)

      refute Git.branch_exists?(bare, Forge.Jobs.chat_branch(chat))
      assert {:ok, ^head} = Git.resolve(bare, "refs/forge/chat/#{chat.id}")
    end

    test "a conflicting change is refused, naming the paths", context do
      %{project: project, chat: chat, bare: bare, user: user} = context

      # The default branch moves under the conversation, on the same file.
      commit_on_chat(project, chat, "README.md", "the conversation's version\n")
      work = tmp_dir("main-work")
      {_out, 0} = System.cmd("git", ["clone", "--quiet", bare, work])
      File.write!(Path.join(work, "README.md"), "someone else's version\n")

      for args <- [
            ["config", "user.name", "other"],
            ["config", "user.email", "other@forge"],
            ["add", "."],
            ["commit", "--quiet", "-m", "meanwhile"],
            ["push", "--quiet", "origin", "HEAD:refs/heads/main"]
          ] do
        {_out, 0} =
          System.cmd("git", ["-C", work] ++ args,
            stderr_to_stdout: true,
            env: [{"FORGE_INTERNAL", "1"}]
          )
      end

      assert {:conflict, paths} = Merge.perform_chat(chat, user)
      assert "README.md" in paths

      # And the branch stays: there is nothing merged for the pin to protect.
      assert Git.branch_exists?(bare, Forge.Jobs.chat_branch(chat))
    end

    test "a conversation that changed nothing is already merged", context do
      %{chat: chat, user: user} = context

      assert Merge.merged_chat?(chat)
      assert {:ok, %{already: true}} = Merge.perform_chat(chat, user)
    end
  end
end
