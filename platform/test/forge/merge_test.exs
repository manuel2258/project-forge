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
  alias Forge.Git.Tokens

  setup do
    data_dir = tmp_dir("merge-data")
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
    name = "merge#{System.unique_integer([:positive])}"

    {:ok, project} =
      register_owned!(%{name: name, repo_path: bare, default_branch: "main"})

    # Moved to `<repos_dir>/<name>.git`, the address a normal registration would have: see the
    # comment on the config override above for why the credential path needs it.
    real_bare = Path.join(Projects.repos_dir(), project.name <> ".git")
    File.mkdir_p!(Path.dirname(real_bare))
    File.rename!(bare, real_bare)

    {:ok, project} =
      project |> Forge.Projects.Project.changeset(%{repo_path: real_bare}) |> Repo.update()

    bare = real_bare

    # Mirrored over the platform's own git endpoint rather than to a local path, which the
    # post-receive hook now refuses outright: a second registered project, reached the same way a
    # job or the settings page would reach any mirror, with a default-branch write token minted
    # for it. A clone of `bare`'s own current state, not an independently seeded repository: the
    # mirror push is fast-forward only on both ends, and two unrelated histories are never a
    # fast-forward of one another.
    destination_bare = mirror_target(bare)

    {:ok, destination} =
      register_owned!(%{
        name: "merge-mirror#{System.unique_integer([:positive])}",
        repo_path: destination_bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)

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

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "do it"}, {:user, user.id})

    %{project: project, bare: bare, destination: destination, user: user, ticket: ticket}
  end

  describe "perform/2" do
    test "puts the approved commit on the default branch and on the mirror", context do
      %{ticket: ticket, bare: bare, destination: destination, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      assert {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, user)
      assert {:ok, ^merged} = Git.resolve(bare, "refs/heads/main")
      assert Git.ancestor?(bare, sha, merged)
      assert {:ok, ^merged} = Git.resolve(Projects.repo_path(destination), "refs/heads/main")
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

  # `docs/design/git-hosting.md` § Where it runs, and what a conflict does: a merge whose push
  # loses to another write of the default branch is retried once against the new head. The race
  # is real, not simulated in Elixir: the repository's `pre-receive` is wrapped so that the
  # default branch moves after the push was advertised and before `receive-pack` takes the ref's
  # lock, which is exactly the window another merge would land in.
  describe "a default branch that moves under the merge" do
    test "is merged against the new head, and only once more", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "other.txt", "another merge")
      pushes = race(bare, moves: [other])
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.state == "merged"
      assert ticket.status == :done
      assert "ticket.merged" in event_types(ticket)
      assert pushes.() == 2

      # On top of what moved the branch, not over it: the other merge is the first parent, and
      # the approved commit the second.
      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^other} = Git.resolve(bare, head <> "^1")
      assert {:ok, ^sha} = Git.resolve(bare, head <> "^2")
    end

    test "is stuck, naming the paths, when the new head conflicts", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "README.md", "the trunk's version")
      pushes = race(bare, moves: [other])
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.status == :stuck
      assert stuck_reason(ticket) == "merge conflict in README.md"
      refute "ticket.merged" in event_types(ticket)
      # The retry found the conflict before writing anything, so it never pushed.
      assert pushes.() == 1
      assert {:ok, ^other} = Git.resolve(bare, "refs/heads/main")
    end

    # Once, not until it works. Two writers that keep crossing are a sign of something other than
    # bad luck, and a stuck ticket says so where a loop would not.
    test "is stuck when it loses the retry too, and is not retried again", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      first = commit_beside(bare, before, "one.txt", "a merge")
      second = commit_beside(bare, first, "two.txt", "and another")
      pushes = race(bare, moves: [first, second, before])
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.status == :stuck
      assert stuck_reason(ticket) =~ "could not merge: {:push_refused"
      assert pushes.() == 2
      assert {:ok, ^second} = Git.resolve(bare, "refs/heads/main")
    end

    # What the push asserts is that the branch is still where the attempt found it, so a refusal
    # with the branch unmoved was for some other reason — and a second attempt would meet it again.
    test "a refusal with the branch unmoved is not retried", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      pushes = race(bare, refuse: true)
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.status == :stuck
      assert stuck_reason(ticket) =~ "could not merge: {:push_refused"
      assert pushes.() == 1
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/main")
    end

    # The same code is beneath the second route into the default branch.
    test "a conversation's merge is retried the same way", context do
      %{project: project, bare: bare, user: user} = context
      {:ok, chat} = Forge.Conversations.open(project, "have a look at this")
      head = commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "other.txt", "another merge")
      pushes = race(bare, moves: [other])

      assert {:ok, %{sha: merged, already: false}} = Merge.perform_chat(chat, user)

      assert pushes.() == 2
      assert {:ok, ^other} = Git.resolve(bare, merged <> "^1")
      assert {:ok, ^head} = Git.resolve(bare, merged <> "^2")
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # A commit on top of `parent`, made in a scratch clone and fetched into the bare repository
  # without moving any ref: something for the race below to move the default branch to.
  defp commit_beside(bare, parent, path, content) do
    dir = Path.join(tmp_dir("merge-beside"), "work")
    {:ok, _out} = Git.run(tmp_dir("merge-beside-parent"), ["clone", "--quiet", bare, dir])

    for args <- [
          ["checkout", "--quiet", "--detach", parent],
          ["config", "user.name", "elsewhere"],
          ["config", "user.email", "elsewhere@forge"]
        ],
        do: {:ok, _out} = Git.run(dir, args)

    File.write!(Path.join(dir, path), content <> "\n")
    {:ok, _out} = Git.run(dir, ["add", path])
    {:ok, _out} = Git.run(dir, ["commit", "--quiet", "-m", content])
    {:ok, sha} = Git.resolve(dir, "HEAD")
    {:ok, _out} = Git.run(bare, ["fetch", "--quiet", dir, "HEAD"])
    sha
  end

  # Wraps the repository's `pre-receive`. On the n-th push it moves the default branch to the n-th
  # of `moves`, if there is one, and then hands over to the real hook — or, with `refuse: true`,
  # refuses without moving anything. Returns a function counting the pushes it saw.
  #
  # The move has to leave git's quarantine to be allowed at all: a hook may not update a ref
  # while the pushed objects are still quarantined, which is the rule that makes this window
  # otherwise impossible to reach from inside the push.
  defp race(bare, opts) do
    dir = tmp_dir("merge-race")
    count = Path.join(dir, "pushes")
    moves = Path.join(dir, "moves")
    File.write!(moves, Enum.map_join(Keyword.get(opts, :moves, []), &(&1 <> "\n")))

    hook = Path.join([bare, "hooks", "pre-receive"])
    File.rename!(hook, hook <> ".real")

    finish =
      if Keyword.get(opts, :refuse, false),
        do: ~s(echo "forge: refused by the test" >&2; exit 1),
        else: ~s(exec "$0.real")

    File.write!(hook, """
    #!/usr/bin/env bash
    set -eu
    n=$(( $(cat "#{count}" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "#{count}"
    target=$(sed -n "${n}p" "#{moves}")
    if [ -n "$target" ]; then
      env -u GIT_QUARANTINE_PATH git update-ref refs/heads/main "$target"
    fi
    #{finish}
    """)

    File.chmod!(hook, 0o755)

    fn ->
      case File.read(count) do
        {:ok, n} -> n |> String.trim() |> String.to_integer()
        {:error, :enoent} -> 0
      end
    end
  end

  defp stuck_reason(ticket) do
    ticket.id
    |> Events.for_ticket()
    |> Enum.filter(&(&1.type == "ticket.stuck"))
    |> List.last()
    |> Map.fetch!(:payload)
    |> Map.fetch!("reason")
  end

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
