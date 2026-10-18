defmodule Forge.MergeConflictTest do
  @moduledoc """
  A merge that conflicts, routed through the workflow by the merging state's `on_conflict`
  rather than refused or stuck (`docs/design/workflow-grammar-v1.md` § Merging): at the check
  before an approval, after a race, on the engine's own edge out of an integrating state, and
  round the loop that edge makes until the bound stops it. And a workflow without the key, which
  must behave exactly as it did before the key existed.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, Merge, Operator, Tickets}

  setup context do
    workflow =
      case context[:route] do
        # A merging state with a transition out, which leaves a ticket in it active.
        :released ->
          :b
          |> conflict_workflow()
          |> String.replace(
            "transitions:\n",
            "  released: {}\ntransitions:\n  - { from: merged, to: released }\n"
          )

        route ->
          conflict_workflow(route || :b)
      end

    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "conflict#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Practice timer", body: "do it"}, {:user, user.id})

    %{project: project, bare: bare, user: user, ticket: ticket}
  end

  describe "a conflict at the approval" do
    test "sends the ticket to on_conflict, says why, and moves nothing on main", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = conflicting!(context)
      {:ok, main} = Git.resolve(bare, "refs/heads/main")

      assert {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, "ship it")

      assert ticket.state == "integrating"
      assert ticket.status == :active
      assert ticket.pending_transition == nil
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
      refute "ticket.merged" in types(ticket)

      assert %{
               "state" => "merged",
               "from" => "review_ready",
               "to" => "integrating",
               "paths" => ["README.md"],
               "head" => ^main,
               "changeset" => ^sha,
               "changeset_version" => 1,
               "by" => "person",
               "stage" => "check"
             } = conflicted(ticket)

      taken = latest_payload(ticket, "transition.taken")

      assert %{"from" => "review_ready", "to" => "integrating", "outcome" => "merge_conflict"} =
               taken

      # Only a transition into the merging state names a commit; this one goes elsewhere.
      refute Map.has_key?(taken, "changeset")

      # The job the route made is told how it got there, like any other — the person's note too.
      assert [%{state: "integrating", status: :pending} = job] = jobs_in(ticket, "integrating")

      assert %{
               "from" => "review_ready",
               "outcome" => "merge_conflict",
               "by" => "person",
               "comment" => "ship it"
             } = Jobs.spec(job).entered

      # What the person approved stays approved: it is what they did. It merged nothing.
      assert [%{decision: :approved}] = Artifacts.approvals(changeset_version(ticket, 1).id)
    end

    @tag route: :plain
    test "without on_conflict is refused, as it always was, and records nothing", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      ticket = pend_merge(ticket)
      before = types(ticket)

      assert {:error, {:merge_conflict, ["README.md"]}} =
               Operator.decide(ticket, user, :approved, nil)

      ticket = Tickets.get!(ticket.id)
      assert ticket.state == "review_ready"
      assert ticket.pending_transition["to"] == "merged"
      assert types(ticket) == before
      assert Artifacts.approvals(changeset_version(ticket, 1).id) == []
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end

    test "a failure that is not a conflict is refused, not routed", context do
      %{ticket: ticket, user: user} = context
      ticket = pend_merge(ticket)

      assert {:error, {:merge_impossible, :no_changeset}} =
               Operator.decide(ticket, user, :approved, nil)

      assert Tickets.get!(ticket.id).state == "review_ready"
    end
  end

  describe "the late race" do
    test "leaves the merging state by on_conflict rather than sticking in it", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_over_http(context.project, ticket.branch, "README.md", "the branch's")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      other = commit_beside(bare, before, "README.md", "the trunk's")
      race(bare, moves: [other])

      assert {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      assert ticket.state == "integrating"
      assert ticket.status == :active
      assert {:ok, ^other} = Git.resolve(bare, "refs/heads/main")

      assert %{
               "from" => "merged",
               "to" => "integrating",
               "paths" => ["README.md"],
               "head" => ^other,
               "changeset" => ^sha,
               "by" => "person",
               "stage" => "merge"
             } = conflicted(ticket)

      assert ["review_ready → merged on done", "merged → integrating on merge_conflict"] =
               ticket |> events_of("transition.taken") |> Enum.map(&Events.summary/1)

      refute "ticket.stuck" in types(ticket)
      assert [_job] = jobs_in(ticket, "integrating")
    end

    test "a failure that is not a conflict still sticks, in the merging state", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_over_http(context.project, ticket.branch, "feature.txt", "the change")
      changeset!(ticket, sha)
      race(bare, refuse: true)

      assert {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      assert ticket.state == "merged"
      assert ticket.status == :stuck
      assert Engine.why_stuck(ticket) =~ "could not merge: {:push_refused"
      refute "ticket.merge_conflicted" in types(ticket)
    end

    # The move out cannot be made — here the target's prompt is not at the pinned commit, so its
    # job cannot be created. The ticket is stuck in the merging state saying so, not left reading
    # `done` with nothing merged.
    test "a move that cannot be made sticks the ticket in the merging state", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_over_http(context.project, ticket.branch, "README.md", "the branch's")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      race(bare, moves: [commit_beside(bare, before, "README.md", "the trunk's")])

      ticket =
        ticket
        |> Ecto.Changeset.change(
          workflow: put_in(ticket.workflow, ["states", "integrating", "prompt"], "agents/gone.md")
        )
        |> Repo.update!()

      assert {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      assert ticket.state == "merged"
      assert ticket.status == :stuck

      assert Engine.why_stuck(ticket) =~
               "merge conflict in README.md, and could not move to integrating: "

      assert jobs_in(ticket, "integrating") == []
    end

    # A merging state may have transitions out, and then a ticket in it is active and can be
    # cancelled. Its merge, reached with the ticket as read before the cancel, must leave it
    # cancelled rather than send it on to integrate.
    @tag route: :released
    test "a ticket cancelled in a merging state it could leave stays cancelled", context do
      %{ticket: ticket, user: user} = context
      conflicting!(context)
      workflow = Tickets.workflow(ticket)
      {:ok, transition} = ForgeCore.Engine.choose(workflow, "review_ready", "merged", nil)

      {:ok, %{ticket: moved}} =
        Ecto.Multi.new()
        |> Engine.put_transition(pend_merge(ticket), workflow, transition, nil, {:user, user.id})
        |> Repo.transaction()

      assert moved.status == :active
      {:ok, _cancelled} = Engine.cancel(moved, user.id)

      Engine.enter(moved, workflow, "merged", user.id)

      assert %{state: "merged", status: :cancelled} = Tickets.get!(ticket.id)
      assert jobs_in(ticket, "integrating") == []
    end

    @tag route: :plain
    test "without on_conflict sticks in the merging state, as it always did", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_over_http(context.project, ticket.branch, "README.md", "the branch's")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      race(bare, moves: [commit_beside(bare, before, "README.md", "the trunk's")])

      assert {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      assert ticket.state == "merged"
      assert ticket.status == :stuck
      assert Engine.why_stuck(ticket) == "merge conflict in README.md"
    end
  end

  describe "the engine's own edge into the merging state" do
    @tag route: :plain
    test "without on_conflict is not checked, and a conflict sticks in the merging state",
         context do
      %{ticket: ticket} = context
      conflicting!(context)
      [job] = jobs_in(ticket, "implementing")

      assert {:ok, ticket} = Engine.after_job(ticket, job, "engine_merges")

      assert ticket.state == "merged"
      assert ticket.status == :stuck
      assert Engine.why_stuck(ticket) == "merge conflict in README.md"
      refute "ticket.merge_conflicted" in types(ticket)
    end

    # Route (b): the integration is clean, so the engine merges it with nobody in between — and
    # what it merges is the version the integrating job recorded.
    test "after a clean integration merges the integrating job's commit", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      integrated = integrate!(context.bare, context.ticket)
      [job] = jobs_in(ticket, "integrating")
      changeset!(ticket, integrated, job)

      assert {:ok, ticket} = Engine.after_job(ticket, job, "done")

      assert ticket.state == "merged"
      assert ticket.status == :done
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      assert Git.ancestor?(bare, integrated, main)
      assert {:ok, ^integrated} = Git.resolve(bare, main <> "^2")

      assert %{"to" => "merged", "changeset" => ^integrated, "changeset_version" => 2} =
               latest_payload(ticket, "transition.taken")

      assert %{"changeset" => ^integrated} = latest_payload(ticket, "ticket.merged")
    end

    # Nobody approved this one, so the engine is the author as well as the committer. Asserting
    # the names rather than only that the merge happened: with the author left unset, git falls
    # back to the host's passwd entry, which is a different commit on every host and no commit
    # at all where there is no global identity — the merge then fails outright, which is what
    # the three tests around this one were catching only on a machine that happens to have none.
    # This one fails wherever the author is not stated, including a machine that has an identity
    # of its own to fall back to.
    test "names the engine as the author of its own merge, not the host", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      integrated = integrate!(context.bare, context.ticket)
      [job] = jobs_in(ticket, "integrating")
      changeset!(ticket, integrated, job)

      assert {:ok, ticket} = Engine.after_job(ticket, job, "done")
      assert ticket.status == :done

      {:ok, main} = Git.resolve(bare, "refs/heads/main")

      assert {:ok, who} =
               Git.run(bare, ["log", "-1", "--format=%an <%ae> / %cn <%ce>", main])

      assert String.trim(who) == "forge <forge@localhost> / forge <forge@localhost>"
    end

    test "still conflicting goes back round, and past the bound sticks saying why", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      # Each integrating job ends without resolving anything: the engine's edge into the merge is
      # checked, conflicts again, and the ticket goes round. Three times in a row, and no more.
      ticket =
        Enum.reduce(1..3, ticket, fn round, ticket ->
          ticket = integration_done!(ticket)
          assert ticket.state == "integrating"
          assert ticket.status == :active
          assert length(jobs_in(ticket, "integrating")) == round + 1
          ticket
        end)

      assert %{"by" => "engine", "from" => "integrating", "to" => "integrating"} =
               conflicted(ticket)

      ticket = integration_done!(ticket)

      assert ticket.state == "integrating"
      assert ticket.status == :stuck

      assert Engine.why_stuck(ticket) ==
               "merge still conflicts after 3 integrations in a row: " <>
                 "the integrate-then-merge loop stops here"

      assert length(jobs_in(ticket, "integrating")) == 4
      assert %{"to" => nil, "by" => "engine"} = conflicted(ticket)
      assert {:ok, ^main} = Git.resolve(bare, "refs/heads/main")
    end

    # The bound is on the engine going round by itself. A person running the state again is a
    # person in the loop, and the count starts again.
    # The engine's own merge, after a clean integration, loses the race: the conflict is the
    # engine's, and counts toward the bound.
    test "a late conflict on the engine's merge is the engine's", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)
      integrated = integrate!(bare, ticket)
      changeset!(ticket, integrated, latest_job(ticket, "integrating"))
      {:ok, head} = Git.resolve(bare, "refs/heads/main")
      race(bare, moves: [commit_beside(bare, head, "README.md", "the trunk's, again")])

      ticket = integration_done!(ticket)

      assert ticket.state == "integrating"

      assert %{
               "by" => "engine",
               "stage" => "merge",
               "from" => "merged",
               "changeset" => ^integrated
             } =
               conflicted(ticket)
    end

    test "a person running the state again starts the count again", context do
      %{ticket: ticket, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      ticket =
        Enum.reduce(1..4, ticket, fn _round, ticket -> integration_done!(ticket) end)

      assert ticket.status == :stuck
      assert {:ok, ticket} = Engine.retry(ticket, user.id)
      ticket = integration_done!(ticket)

      assert ticket.state == "integrating"
      assert ticket.status == :active
    end

    test "a person taking the edge into the merge by hand starts the count again", context do
      %{ticket: ticket, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)
      ticket = Enum.reduce(1..4, ticket, fn _round, ticket -> integration_done!(ticket) end)
      assert ticket.status == :stuck

      # The stuck ticket offers its edges; taking `merged` conflicts and goes round by a person.
      assert {:ok, ticket} = Operator.transition(ticket, user, "merged")
      assert ticket.state == "integrating"
      assert %{"by" => "person"} = conflicted(ticket)

      ticket = integration_done!(ticket)
      assert ticket.state == "integrating"
      assert ticket.status == :active
    end

    # Nothing to merge into, and nowhere to merge it: stuck where it was, with its edges out, not
    # in a terminal state that offers none.
    test "a merge that cannot be made sticks the ticket where it was", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)
      File.rm_rf!(bare)

      ticket = integration_done!(ticket)

      assert ticket.state == "integrating"
      assert ticket.status == :stuck
      assert Engine.why_stuck(ticket) =~ "could not merge: "
    end
  end

  describe "which commit a merge merges" do
    # Two transitions into the merging state: the approval whose merge lost the race, and the
    # engine's after a clean integration. The merge after the second is of what the second named.
    test "is the latest transition's, when the ticket has entered the state before", context do
      %{ticket: ticket, bare: bare, user: user} = context
      sha = commit_over_http(context.project, ticket.branch, "README.md", "the branch's version")
      changeset!(ticket, sha)
      {:ok, before} = Git.resolve(bare, "refs/heads/main")
      race(bare, moves: [commit_beside(bare, before, "README.md", "the trunk's version")])
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)
      assert ticket.state == "integrating"

      integrated = integrate!(bare, ticket)
      changeset!(ticket, integrated, latest_job(ticket, "integrating"))
      ticket = integration_done!(ticket)

      assert ticket.state == "merged"
      assert ticket.status == :done
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^integrated} = Git.resolve(bare, main <> "^2")
    end

    # The option the check hands the transition: what it names is the version that was checked,
    # whatever has been recorded since.
    test "is the version the check was made on, when the transition is told it", context do
      %{ticket: ticket, user: user} = context
      first = commit_over_http(context.project, ticket.branch, "first.txt", "first")
      changeset!(ticket, first)
      later = commit_over_http(context.project, ticket.branch, "later.txt", "later")
      changeset!(ticket, later)

      workflow = Tickets.workflow(ticket)
      {:ok, transition} = ForgeCore.Engine.choose(workflow, "review_ready", "merged", nil)

      {:ok, %{ticket: moved}} =
        Ecto.Multi.new()
        |> Engine.put_transition(pend_merge(ticket), workflow, transition, nil, {:user, user.id},
          source: %{sha: first, version: 1}
        )
        |> Repo.transaction()

      assert %{"changeset" => ^first, "changeset_version" => 1} =
               latest_payload(moved, "transition.taken")
    end

    # Route (a): the integration goes back to a person, and the approval that was given to the
    # version before it cannot merge what the integration wrote — only an approval of the new
    # version can, and it merges that one.
    @tag route: :a
    test "an approval of the version before integration merges nothing after it", context do
      %{ticket: ticket, bare: bare, user: user} = context
      conflicting!(context)
      {:ok, ticket} = Operator.decide(pend_merge(ticket), user, :approved, nil)

      integrated = integrate!(context.bare, context.ticket)
      [job] = jobs_in(ticket, "integrating")
      changeset!(ticket, integrated, job)
      {:ok, ticket} = Engine.after_job(ticket, job, "done")

      assert ticket.state == "review_ready"
      refute Merge.merged?(ticket)
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      refute Git.ancestor?(bare, integrated, main)

      assert {:ok, ticket} = Operator.transition(ticket, user, "merged")

      assert ticket.state == "merged"
      assert ticket.status == :done
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^integrated} = Git.resolve(bare, main <> "^2")
      assert [%{decision: :approved}] = Artifacts.approvals(changeset_version(ticket, 2).id)
    end

    # The rule itself, with the window opened by hand: a version recorded between the transition
    # and the merge after it is not what the merge merges. Read as "the latest version", it was.
    test "is the one its transition named, not one recorded after it", context do
      %{ticket: ticket, bare: bare, user: user} = context
      first = commit_over_http(context.project, ticket.branch, "first.txt", "first")
      changeset!(ticket, first)

      workflow = Tickets.workflow(ticket)
      {:ok, transition} = ForgeCore.Engine.choose(workflow, "review_ready", "merged", nil)

      {:ok, %{ticket: moved}} =
        Ecto.Multi.new()
        |> Engine.put_transition(pend_merge(ticket), workflow, transition, nil, {:user, user.id})
        |> Repo.transaction()

      later = commit_over_http(context.project, ticket.branch, "later.txt", "later")
      changeset!(ticket, later)

      moved = Engine.enter(moved, workflow, "merged", user.id)

      assert moved.status == :done
      {:ok, main} = Git.resolve(bare, "refs/heads/main")
      assert {:ok, ^first} = Git.resolve(bare, main <> "^2")
      refute Git.ancestor?(bare, later, main)
      assert %{"changeset" => ^first} = latest_payload(moved, "ticket.merged")
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # The ticket branch and the default branch both change README.md: the case #9 met in
  # production, in one file. Returns the branch's commit, recorded as changeset version 1.
  defp conflicting!(%{project: project, ticket: ticket, bare: bare}) do
    sha = commit_over_http(project, ticket.branch, "README.md", "the branch's version")
    changeset!(ticket, sha)
    commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
    sha
  end

  defp changeset_version(ticket, n) do
    ticket.id
    |> Artifacts.versions("changeset")
    |> Enum.find(&(&1.version == n))
  end

  defp jobs_in(ticket, state),
    do: ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.state == state))

  defp latest_job(ticket, state), do: ticket |> jobs_in(state) |> List.last()

  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  defp conflicted(ticket), do: latest_payload(ticket, "ticket.merge_conflicted")
end
