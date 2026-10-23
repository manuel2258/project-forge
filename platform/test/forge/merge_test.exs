defmodule Forge.MergeTest do
  @moduledoc """
  Merging, from the operator's approval down to the commit on the default branch and its copy on
  the mirror. The whole arc, because the point of the design is that they are one path.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Engine, Events, Git, Merge, Operator, Projects, Tickets}
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

  describe "perform/4" do
    test "puts the approved commit's content on the default branch and on the mirror", context do
      %{ticket: ticket, bare: bare, destination: destination, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      assert {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, sha, message, user)
      assert {:ok, ^merged} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, "the change\n"} = Git.show(bare, merged, "feature.txt")
      assert {:ok, ^merged} = Git.resolve(Projects.repo_path(destination), "refs/heads/main")
    end

    # The one call the old behaviour and the new one disagree about: the approved commit's content
    # lands, the approved commit itself does not join the default branch's ancestry, and the pin
    # is what keeps it reachable (`docs/design/git-hosting.md` § The merge).
    test "lands one commit with one parent, the approved commit no ancestor of it", context do
      %{ticket: ticket, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      assert {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)

      assert {:ok, ^before} = Git.resolve(bare, merged <> "^1")
      assert {:error, _no_second_parent} = Git.resolve(bare, merged <> "^2")
      refute Git.ancestor?(bare, sha, merged)
      assert {:ok, ^sha} = Git.resolve(bare, "refs/forge/approved/#{ticket.number}")
      assert {:ok, ""} = Git.run(bare, ["log", "--merges", "--format=%H", {:data, merged}])
    end

    test "says what the commit message document says, and nothing else", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket, "Persist the scores\n\nThey were lost on restart.\n")

      {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", merged])

      assert String.trim_trailing(body) == "Persist the scores\n\nThey were lost on restart."
      refute body =~ "Changeset:"
      refute body =~ "Ticket:"
      refute body =~ "Approved-by:"
    end

    # The version the transition named, not the latest: a later one exists and is not used.
    test "says the version it was given, not the latest", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      named = commit_message!(ticket, "What the approval saw\n")
      commit_message!(ticket, "What a chat wrote afterwards\n")

      {:ok, %{sha: merged}} = Merge.perform(ticket, sha, named, user)
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", merged])

      assert String.trim(body) == "What the approval saw"
    end

    test "front matter is not part of the message", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket, "---\noutcome: done\n---\n\nJust the body\n")

      {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", merged])

      assert String.trim(body) == "Just the body"
    end

    test "refuses when there is no commit message, and when it is blank", context do
      %{ticket: ticket, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)

      assert {:error, :no_commit_message} = Merge.perform(ticket, sha, nil, user)
      assert {:error, :no_commit_message} = Merge.perform(ticket, sha, 1, user)

      blank = commit_message!(ticket, "---\noutcome: done\n---\n")
      assert {:error, :no_commit_message} = Merge.perform(ticket, sha, blank, user)
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/main")
    end

    test "records who approved in the commit itself", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)
      {:ok, who} = Git.run(bare, ["show", "--no-patch", "--format=%an", merged])

      assert String.trim(who) == user.email
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
      message = commit_message!(ticket)

      {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)
      {:ok, who} = Git.run(bare, ["show", "--no-patch", "--format=%cn <%ce>|%an", merged])

      assert String.trim(who) == "forge <forge@localhost>|#{user.email}"
    end

    # Reachability cannot answer this once a merge leaves one parent: the merged commit is not an
    # ancestor of the default branch, so a second call that read it that way would make a second,
    # content-identical commit every time (`Forge.Merge.merged_tree/3`).
    test "is idempotent, and the branch does not grow a second time", context do
      %{ticket: ticket, bare: bare} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      {:ok, base} = Git.resolve(bare, "refs/heads/main")
      {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, sha, message, context.user)
      assert {:ok, [^merged]} = Git.commits_since(bare, base, "refs/heads/main")

      assert {:ok, %{sha: ^merged, already: true}} =
               Merge.perform(ticket, sha, message, context.user)

      assert Merge.merged?(ticket)
      assert {:ok, ^merged} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, [^merged]} = Git.commits_since(bare, base, "refs/heads/main")
    end

    # The regression the ref exists for. A tree comparison answers "already merged" correctly
    # until the default branch takes an *overlapping* change: the three-way merge then conflicts
    # and a merged ticket reads as unmerged. `refs/forge/merged/ticket/<n>` cannot expire that
    # way (`docs/design/git-hosting.md` § The merge).
    test "stays merged once the default branch moves over what it landed", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the ticket's version")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      assert {:ok, %{sha: merged, already: false}} = Merge.perform(ticket, sha, message, user)
      assert {:ok, ^sha} = Git.resolve(bare, "refs/forge/merged/ticket/#{ticket.number}")

      # Somebody else's change to the same file, on top of the merge.
      diverge_default_branch(context, "README.md", "and then somebody else's")

      assert Merge.merged?(ticket)

      assert {:ok, %{already: true}} = Merge.perform(ticket, sha, message, user)
      assert {:ok, [_theirs]} = Git.commits_since(bare, merged, "refs/heads/main")
    end

    # The ref says the merge *landed*, so it is written after the push and not before. A ref
    # written first would call a refused push a merge, which is the mistake `refs/forge/approved`
    # cannot avoid and this one must.
    test "records nothing as merged when the push is refused", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)
      _pushes = race(bare, refuse: true)

      assert {:error, {:push_refused, _reason}} = Merge.perform(ticket, sha, message, user)

      # The attempt is recorded; the merge is not.
      assert {:ok, ^sha} = Git.resolve(bare, "refs/forge/approved/#{ticket.number}")
      assert {:error, _none} = Git.resolve(bare, "refs/forge/merged/ticket/#{ticket.number}")
      refute Merge.merged?(ticket)
    end

    # Linux caps one `argv` element at `MAX_ARG_STRLEN`, 128 KiB, and `ForgeCore.Document` allows
    # a megabyte: as a `-m` argument a long message failed with "Argument list too long", which
    # reached the operator as the stuck reason `could not merge: {7, ""}`. The message goes in a
    # file, so the only bound is the document's (`Forge.Merge.commit_tree/5`).
    test "commits a message far longer than one argument can hold", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      body = String.duplicate("a long explanation of the change.\n", 6_000)
      text = "Persist the scores\n\n" <> body
      message = commit_message!(ticket, text)

      assert byte_size(body) > 192 * 1024
      assert {:ok, %{sha: merged}} = Merge.perform(ticket, sha, message, user)

      {:ok, committed} = Git.run(bare, ["show", "--no-patch", "--format=%B", merged])
      assert String.trim_trailing(committed) == String.trim_trailing(text)
    end

    test "pins the approved commit so a rewritten branch cannot lose it", context do
      %{ticket: ticket, bare: bare} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      message = commit_message!(ticket)

      {:ok, _merged} = Merge.perform(ticket, sha, message, context.user)
      assert {:ok, ^sha} = Git.resolve(bare, "refs/forge/approved/#{ticket.number}")
    end

    test "refuses when the commit it was named is gone", %{ticket: ticket, user: user} do
      gone = String.duplicate("a", 40)
      changeset!(ticket, gone)
      message = commit_message!(ticket)

      assert {:error, {:approved_commit_gone, ^gone}} = Merge.perform(ticket, gone, message, user)
    end

    test "a ticket with no changeset names nothing to merge", %{ticket: ticket} do
      assert {:error, :no_changeset} = Merge.changeset(ticket)
      refute Merge.merged?(ticket)
    end

    test "names the commit message version a transition would, or nothing", %{ticket: ticket} do
      refute Merge.commit_message_version(ticket)
      assert commit_message!(ticket) == 1
      assert Merge.commit_message_version(ticket) == 1
      assert commit_message!(ticket, "again\n") == 2
      assert Merge.commit_message_version(ticket) == 2
    end

    test "reports the conflicted paths and changes nothing", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      message = commit_message!(ticket)
      main = diverge_default_branch(context, "README.md", "the trunk's version")

      assert {:conflict, ["README.md"], ^main} = Merge.perform(ticket, sha, message, user)
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end

    # A conflicted path goes into an event payload and a ticket's stuck reason, so JSON and
    # Postgres carry it. `merge-tree` quotes anything it cannot print, so what arrives is
    # already safe — what the path pair in `conflicted_paths/1` does is normalise it to the
    # form the rest of the product shows, which is readable where there is a readable form and
    # escaped where there is not.
    test "a conflicted path is named the way the rest of the product names one", context do
      %{ticket: ticket, user: user} = context
      readable = "résumé.md"
      unreadable = "caf" <> <<0xE9>> <> ".md"

      commit_on_branch(context, readable, "the branch's version")
      sha = commit_on_branch(context, unreadable, "the branch's version")
      changeset!(ticket, sha)
      message = commit_message!(ticket)
      diverge_default_branch(context, readable, "the trunk's version")
      diverge_default_branch(context, unreadable, "the trunk's version")

      assert {:conflict, paths, _main} = Merge.perform(ticket, sha, message, user)
      # Readable where there is a readable form, escaped where there is not — and never the
      # `"r\303\251sum\303\251.md"` git itself prints, which is neither.
      assert Enum.sort(paths) == Enum.sort([readable, ~s("caf\\351.md")])
      assert Enum.all?(paths, &String.valid?/1)
      assert {:ok, _json} = Jason.encode(%{"paths" => paths})
    end
  end

  describe "entering a state that merges" do
    test "approving the changeset merges, and says so in the event log", context do
      %{ticket: ticket, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      commit_message!(ticket, "Persist the scores\n")
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, "ship it")
      assert ticket.state == "merged"
      assert ticket.status == :done
      assert "ticket.merged" in event_types(ticket)

      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^before} = Git.resolve(bare, head <> "^1")
      assert {:ok, "the change\n"} = Git.show(bare, head, "feature.txt")
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", head])
      assert String.trim(body) == "Persist the scores"
    end

    # The version the transition named is on its event, and the merge after it says that version.
    test "the transition names the commit message version, and that one is used", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      commit_message!(ticket, "What the approval saw\n")
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)
      assert latest_payload(ticket, "transition.taken")["commit_message_version"] == 1

      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", head])
      assert String.trim(body) == "What the approval saw"
    end

    # A ticket that reached its merge with nothing written for the commit to say does not land
    # under a message nobody wrote (`docs/design/workflow-grammar-v1.md` § Merging).
    test "a merge with no commit message sticks the ticket rather than inventing one", context do
      %{ticket: ticket, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.status == :stuck
      assert stuck_reason(ticket) == "could not merge: :no_commit_message"
      refute "ticket.merged" in event_types(ticket)
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/main")
    end

    # Had the ticket moved into terminal `merged` first, a stuck item there would offer no
    # transitions at all: a terminal state has none. Refusing before the transition is what keeps
    # the way forward open.
    test "a conflict refuses the approval and leaves the ticket where it can still move",
         context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      commit_message!(ticket)
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

    # A transition that named a changeset and no message is refused *before* the merge is
    # attempted, which is what `Engine.named/1`'s own clause is for: reading the version as nil
    # and letting `Merge.perform/4` refuse it would report whatever went wrong first instead —
    # here, an approved commit that has gone.
    test "a transition with no commit message is refused before the merge is tried", context do
      %{ticket: ticket, user: user} = context
      gone = String.duplicate("a", 40)
      changeset!(ticket, gone)

      {:ok, _event} =
        Events.append("transition.taken", {:user, user.id}, %{
          ticket_id: ticket.id,
          payload: %{
            "from" => "review_ready",
            "to" => "merged",
            "changeset" => gone,
            "changeset_version" => 1
          }
        })

      workflow = Tickets.workflow(ticket)

      ticket = Engine.enter(%{ticket | state: "merged"}, workflow, "merged", user.id)

      assert ticket.status == :stuck
      assert stuck_reason(ticket) == "could not merge: :no_commit_message"
    end

    test "a ticket that cannot merge at all is stuck rather than silently done", context do
      %{ticket: ticket, user: user} = context
      sha = commit_on_branch(context, "feature.txt", "the change")
      changeset!(ticket, sha)
      commit_message!(ticket)
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
      commit_message!(ticket)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "other.txt", "another merge")
      pushes = race(bare, moves: [other])
      ticket = pend_merge(ticket)

      assert {:ok, ticket} = Operator.decide(ticket, user, :approved, nil)

      assert ticket.state == "merged"
      assert ticket.status == :done
      assert "ticket.merged" in event_types(ticket)
      assert pushes.() == 2

      # On top of what moved the branch, not over it: what moved it is the only parent.
      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^other} = Git.resolve(bare, head <> "^1")
      assert {:error, _no_second_parent} = Git.resolve(bare, head <> "^2")
      assert {:ok, "the change\n"} = Git.show(bare, head, "feature.txt")
    end

    test "is stuck, naming the paths, when the new head conflicts", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_on_branch(context, "README.md", "the branch's version")
      changeset!(ticket, sha)
      commit_message!(ticket)
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
      commit_message!(ticket)
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
      commit_message!(ticket)
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
      chat_commit_message!(chat)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "other.txt", "another merge")
      pushes = race(bare, moves: [other])

      assert {:ok, %{sha: merged, already: false}} = Merge.perform_chat(chat, user)

      assert pushes.() == 2
      assert {:ok, ^other} = Git.resolve(bare, merged <> "^1")
      assert {:error, _no_second_parent} = Git.resolve(bare, merged <> "^2")
      refute Git.ancestor?(bare, head, merged)
      assert {:ok, "from a conversation\n"} = Git.show(bare, merged, "NOTES.md")
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

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
  defp diverge_default_branch(%{bare: bare}, path, content),
    do: commit_to(bare, "main", %{path => content <> "\n"}, content)

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

    defp chat_head(project, chat) do
      repo = Forge.Projects.repo_path(project)
      {:ok, head} = Git.resolve(repo, "refs/heads/" <> Forge.Jobs.chat_branch(chat))
      head
    end

    test "merges into the default branch by the same route a ticket takes", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      head = commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")
      chat_commit_message!(chat, "Write the notes down\n")

      assert {:ok, %{sha: sha, already: false}} = Merge.perform_chat(chat, user)

      {:ok, default} = Git.resolve(bare, "refs/heads/main")
      assert default == sha
      assert {:ok, ^before} = Git.resolve(bare, sha <> "^1")
      assert {:error, _no_second_parent} = Git.resolve(bare, sha <> "^2")
      refute Git.ancestor?(bare, head, default)
      assert {:ok, "from a conversation\n"} = Git.show(bare, sha, "NOTES.md")

      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", sha])
      assert String.trim(body) == "Write the notes down"
    end

    # The page offers no merge until one exists, and the merge itself refuses rather than
    # committing an empty message (`docs/design/conversations.md` § Commits).
    test "a conversation with no commit message cannot be merged", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")

      assert {:error, :no_commit_message} = Merge.perform_chat(chat, user)
      assert {:ok, ^before} = Git.resolve(bare, "refs/heads/main")
      assert Git.branch_exists?(bare, Forge.Jobs.chat_branch(chat))
    end

    # The pin is what keeps the merged commit reachable. Deleting the branch before it exists
    # would leave the commit collectable in between, and "the branch is deleted when done" would
    # quietly mean the work was too.
    test "the branch is gone afterwards, and the commit is still reachable", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      head = commit_on_chat(project, chat, "NOTES.md", "keep me\n")
      chat_commit_message!(chat)

      assert {:ok, _result} = Merge.perform_chat(chat, user)

      refute Git.branch_exists?(bare, Forge.Jobs.chat_branch(chat))
      assert {:ok, ^head} = Git.resolve(bare, "refs/forge/chat/#{chat.id}")
    end

    test "a conflicting change is refused, naming the paths", context do
      %{project: project, chat: chat, bare: bare, user: user} = context

      # The default branch moves under the conversation, on the same file.
      commit_on_chat(project, chat, "README.md", "the conversation's version\n")
      chat_commit_message!(chat)
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
      chat_commit_message!(chat)

      assert Merge.merged_chat?(chat)
      assert {:ok, %{already: true}} = Merge.perform_chat(chat, user)
    end

    # The latest at the click, not the first: a conversation that rewrote the message as its
    # branch grew commits what it last wrote (`docs/design/conversations.md` § Commits).
    test "says the latest version of the message, not the first", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")
      chat_commit_message!(chat, "What the first turn wrote\n")
      chat_commit_message!(chat, "What the branch holds now\n")

      assert {:ok, %{sha: sha}} = Merge.perform_chat(chat, user)
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", sha])
      assert String.trim(body) == "What the branch holds now"
    end

    # Same regression as the ticket's, on the conversation's own ref. The branch is back because
    # a last turn pushed it after the merge deleted it (§ Lifetime's case for waiting on the
    # worker's report), and the default branch has since been edited over what landed: the
    # three-way merge conflicts, so only the ref can still say this conversation is merged
    # (`docs/design/git-hosting.md` § The merge).
    test "stays merged once the default branch moves over what it landed", context do
      %{project: project, chat: chat, bare: bare, user: user} = context
      branch = Forge.Jobs.chat_branch(chat)
      commit_on_chat(project, chat, "README.md", "the conversation's version\n")
      source = chat_head(project, chat)
      chat_commit_message!(chat)

      assert {:ok, %{already: false}} = Merge.perform_chat(chat, user)
      assert {:ok, ^source} = Git.resolve(bare, "refs/forge/merged/chat/#{chat.id}")

      :ok = Git.pin(bare, "refs/heads/" <> branch, source)
      diverge_default_branch(context, "README.md", "and then somebody else's")

      assert Merge.merged_chat?(chat)
      assert {:ok, %{already: true}} = Merge.perform_chat(chat, user)
      refute Git.branch_exists?(bare, branch)
    end
  end

  # A conversation on a ticket writes `commit-message` against *itself*, not against the ticket:
  # the two branches are different changes and one artifact for both let a chat branch land under
  # the ticket's message and a chat rewrite what the ticket's own merge would commit
  # (`docs/design/conversations.md` § Commits).
  describe "a conversation on a ticket" do
    test "merges under its own message and leaves the ticket's alone", context do
      %{project: project, ticket: ticket, bare: bare, user: user} = context
      {:ok, chat} = Forge.Conversations.open(project, "have a look", ticket: ticket)
      ticket_message = commit_message!(ticket, "The ticket's whole change\n")
      commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")
      chat_commit_message!(chat, "Just the note\n")

      # Writing the conversation's did not become a new version of the ticket's.
      assert Merge.commit_message_version(ticket) == ticket_message

      assert {:ok, %{sha: sha}} = Merge.perform_chat(chat, user)
      {:ok, body} = Git.run(bare, ["show", "--no-patch", "--format=%B", sha])
      assert String.trim(body) == "Just the note"
    end

    test "has no message of its own until it writes one, whatever the ticket says", context do
      %{project: project, ticket: ticket, user: user} = context
      {:ok, chat} = Forge.Conversations.open(project, "have a look", ticket: ticket)
      commit_message!(ticket, "The ticket's whole change\n")
      commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")

      assert {:error, :no_commit_message} = Merge.perform_chat(chat, user)
    end
  end
end
