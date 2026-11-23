defmodule Forge.MergeRebaseApprovalTest do
  @moduledoc """
  What follows a rebase that ends `done` (`docs/design/workflow-grammar-v1.md` § Merging, *What
  follows the rebase*): the engine's edge out of an integrating state into a merging one merges
  only a ticket whose approval of `changeset` is on record and stands. Otherwise the ticket waits
  at the rebase state for a person, `main` unmoved and no row made in the line.

  Most cases are the reproduction on the ticket (the others say so in their own comments): the
  branch changes `README.md`, `main` changes it too, a person sends the ticket to `integrating` from the notice, and the
  rebase ends `done`. Real repositories and a real database, as `merge_queue_test.exs` has them.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, MergeQueue, Operator, Repo, Tickets}

  # The grammar's route (b), which is also what forge's own workflows draw.
  defp route_b(opts) do
    workflow =
      :b
      |> conflict_workflow()
      |> String.replace(
        "{ from: integrating, to: merged }",
        "{ from: integrating, to: merged#{if opts[:queue], do: ", queue: true"}" <>
          "#{if opts[:notes], do: ", approve: [notes.md]"} }\n" <>
          "  - { from: integrating, to: review_ready, when: needs_review }"
      )
      |> String.replace(
        "    produces: [changeset]\n",
        "    produces: [changeset, notes.md]\n    outcomes: [done, needs_review]\n"
      )

    if opts[:queue] do
      String.replace(
        workflow,
        "{ from: review_ready, to: merged, approve: [changeset] }",
        "{ from: review_ready, to: merged, approve: [changeset], queue: true }"
      )
    else
      workflow
    end
  end

  defp new_project(workflow) do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "rebase#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = user_fixture()
    join!(project, user)
    {project, bare, user}
  end

  # A ticket whose branch changes README.md, with a changeset and a commit message, resting at the
  # approval, and a project whose workflow is `route_b(opts)`.
  defp scenario(opts \\ []) do
    {project, bare, user} = new_project(route_b(opts))

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Practice timer", body: "do it"}, {:user, user.id})

    sha = commit_file_on_branch(project, ticket.branch, "README.md", "the branch's version")
    changeset!(ticket, sha)
    commit_message!(ticket, "Practice timer\n\nBecause.\n")
    %{project: project, bare: bare, user: user, ticket: pend_merge(ticket)}
  end

  defp trunk_moves!(bare, text \\ "the trunk's version\n"),
    do: commit_to(bare, "main", %{"README.md" => text}, "another ticket")

  # A person presses *Send to integrating*, the agent resolves README.md, and the rebase ends.
  defp rebase!(%{bare: bare, user: user}, ticket, outcome \\ "done") do
    {:ok, sent} = Operator.integrate(fresh(ticket), user)
    assert sent.state == "integrating"
    changeset!(sent, integrate!(bare, sent))
    ended!(sent, outcome)
  end

  defp ended!(ticket, outcome) do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> Enum.filter(&(&1.state == "integrating"))
      |> List.last()
      |> Ecto.Changeset.change(status: :finished, outcome: :converged, declared_outcome: outcome)
      |> Repo.update!()

    {:ok, ticket} = Engine.after_job(fresh(ticket), job, outcome)
    ticket
  end

  # The queue's turn conflicts, its rebase writes a new changeset version and ends `needs_review`:
  # the ticket is back at `review_ready` and out of the line, its approval still on record.
  defp sent_back!(%{bare: bare, project: project}, queued) do
    assert {:integrating, _id} = Engine.advance_queue(project.id)
    integrating = fresh(queued)
    changeset!(integrating, integrate!(bare, integrating))
    ended!(integrating, "needs_review")
  end

  defp main(bare), do: elem(Git.resolve(bare, "refs/heads/main"), 1)
  defp fresh(ticket), do: Tickets.get!(ticket.id)
  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  defp approvals(ticket, version \\ nil) do
    versions = Artifacts.versions(ticket.id, "changeset")
    versions = if version, do: Enum.filter(versions, &(&1.version == version)), else: versions
    Enum.flat_map(versions, &Artifacts.approvals(&1.id))
  end

  # Nothing was merged and nobody was asked to approve it before: the ticket waits for a decision.
  defp assert_waits(ticket, bare, main) do
    ticket = fresh(ticket)

    assert ticket.state == "integrating"
    assert ticket.status == :active

    assert %{"from" => "integrating", "to" => "merged", "approve" => ["changeset"]} =
             ticket.pending_transition

    assert Engine.awaiting_approval(ticket) == ["changeset"]
    assert main(bare) == main
    assert MergeQueue.entry(ticket) == nil
    refute "ticket.merged" in types(ticket)
    assert "approval.requested" in types(ticket)
    ticket
  end

  describe "a rebase of a ticket nobody approved" do
    test "waits for an approval and merges nothing, where the workflow queues nothing" do
      %{bare: bare} = context = scenario()
      trunk_moves!(bare)
      main = main(bare)

      ticket = rebase!(context, context.ticket)

      assert_waits(ticket, bare, main)
      assert approvals(ticket) == []

      # The queue lists it as it lists any decision, approving the changeset.
      assert [%{detail: %{"approve" => ["changeset"]}}] =
               ticket |> Forge.Queue.for_ticket() |> Enum.filter(&(&1.kind == :approval))
    end

    test "waits for an approval and makes no row in the line, where the edge queues" do
      %{bare: bare, project: project} = context = scenario(queue: true)
      trunk_moves!(bare)
      main = main(bare)

      ticket = rebase!(context, context.ticket)

      assert_waits(ticket, bare, main)
      assert Engine.advance_queue(project.id) == :idle
      assert main(bare) == main
    end

    test "approving the decision merges, with the approval under the person's name" do
      %{bare: bare, user: user} = context = scenario()
      trunk_moves!(bare)
      ticket = rebase!(context, context.ticket)
      main = main(bare)

      assert {:ok, merged} = Operator.decide(ticket, user, :approved, "ship it")

      assert merged.state == "merged"
      refute main(bare) == main
      assert [%{decision: :approved, user_id: user_id}] = approvals(merged)
      assert user_id == user.id
      assert Artifacts.changeset_decision(merged.id) == :stands
    end

    # The decision row sends the versions it drew (`Engine.decide/5`'s `seen`), and what it drew is
    # `changeset`, though the edge declares no `approve`: the check must read the edge the same way.
    test "approving it as the decision row does, naming the version it drew, merges that version" do
      %{bare: bare, user: user} = context = scenario()
      trunk_moves!(bare)
      ticket = rebase!(context, context.ticket)
      main = main(bare)
      %{version: version} = Artifacts.latest(ticket.id, "changeset")

      assert {:ok, merged} =
               Operator.decide(ticket, user, :approved, nil, %{"changeset" => version})

      assert merged.state == "merged"
      refute main(bare) == main
      assert [%{decision: :approved}] = approvals(merged, version)
    end

    # The edge declares an `approve` of its own, without `changeset`. The decision is recorded as
    # `decide/5` reads it (`Workflow.approving/2`): the row draws `changeset` as well as `notes.md`
    # and sends both, so a press is not refused as stale for a name the pending decision left out.
    test "a rebase edge that approves a document of its own is approved by the row, with the changeset too" do
      %{bare: bare, user: user} = context = scenario(notes: true)
      trunk_moves!(bare)

      {:ok, %{version: notes}} =
        Artifacts.record_version(context.ticket.id, "notes.md", :document, :system, %{
          content: "n\n"
        })

      ticket = rebase!(context, context.ticket)
      main = main(bare)

      assert %{"approve" => approve} = ticket.pending_transition
      assert Enum.sort(approve) == ["changeset", "notes.md"]
      assert Enum.sort(Engine.awaiting_approval(ticket)) == ["changeset", "notes.md"]
      %{version: version} = Artifacts.latest(ticket.id, "changeset")
      seen = %{"changeset" => version, "notes.md" => notes}

      assert {:ok, merged} = Operator.decide(ticket, user, :approved, nil, seen)

      assert merged.state == "merged"
      refute main(bare) == main
      assert [%{decision: :approved}] = approvals(merged, version)
    end

    test "approving the decision queues, where the edge queues, and taking it out withdraws it" do
      %{bare: bare, user: user, project: project} = context = scenario(queue: true)
      trunk_moves!(bare)
      ticket = rebase!(context, context.ticket)

      assert {:ok, queued} = Operator.decide(ticket, user, :approved, nil)

      assert queued.state == "integrating"

      assert %{status: :waiting, from_state: "integrating", approval_ids: [id]} =
               MergeQueue.entry(queued)

      assert [%{id: ^id, decision: :approved}] = approvals(queued)

      assert {:ok, out} = Operator.take_out(queued, user)
      assert Artifacts.changeset_decision(queued.id) == :withdrawn
      assert Engine.advance_queue(project.id) == :idle

      # And the ticket is asked again, as one approved at `review_ready` is: it waits for an
      # approval of the changeset rather than sticking.
      assert out.status == :active
      assert %{"to" => "merged", "approve" => ["changeset"]} = out.pending_transition
    end

    test "rejecting it records the rejection and leaves the ticket stuck with `merged` offered" do
      %{bare: bare, user: user} = context = scenario()
      trunk_moves!(bare)
      ticket = rebase!(context, context.ticket)
      main = main(bare)

      assert {:ok, stuck} = Operator.decide(ticket, user, :rejected, "not this one")

      assert stuck.state == "integrating"
      assert stuck.status == :stuck
      assert "merged" in Engine.offered_transitions(stuck, Tickets.workflow(stuck))
      assert Artifacts.changeset_decision(stuck.id) == :rejected
      assert main(bare) == main
    end

    # Criterion 5a: the chooser offers `merged` after a rejection, and taking it is an approval.
    test "taking the edge by hand records the person's approval of the version it merges" do
      %{bare: bare, user: user} = context = scenario()
      trunk_moves!(bare)
      ticket = rebase!(context, context.ticket)
      {:ok, stuck} = Operator.decide(ticket, user, :rejected, "not this one")
      main = main(bare)

      assert {:ok, merged} = Operator.transition(stuck, user, "merged")

      assert merged.state == "merged"
      refute main(bare) == main
      # The rejection and the approval are of the one version, and the rejection is still there.
      version = Artifacts.latest(merged.id, "changeset").version
      decisions = for ap <- approvals(merged, version), do: {ap.decision, ap.user_id}
      assert decisions -- [{:rejected, user.id}] == [{:approved, user.id}]
    end
  end

  describe "the record is read as one history" do
    # Case 4: approved, taken out of the line (which withdraws the approval), then conflicting.
    test "an approval withdrawn by a take-out does not stand" do
      %{bare: bare, user: user} = context = scenario(queue: true)
      {:ok, queued} = Operator.decide(context.ticket, user, :approved, nil)
      {:ok, _out} = Operator.take_out(queued, user)
      assert Artifacts.changeset_decision(queued.id) == :withdrawn
      trunk_moves!(bare)
      main = main(bare)

      ticket = rebase!(context, queued)

      assert_waits(ticket, bare, main)
    end

    # Case 5: v1 approved, the queue's rebase ends `needs_review`, v2 is rejected, then a rebase.
    test "a later rejection cancels an earlier approval" do
      %{bare: bare, user: user} = context = scenario(queue: true)
      trunk_moves!(bare)
      {:ok, queued} = Operator.decide(context.ticket, user, :approved, nil)
      sent_back = sent_back!(context, queued)
      assert sent_back.state == "review_ready"
      assert MergeQueue.entry(sent_back) == nil

      {:ok, rejected} = Operator.decide(pend_merge(fresh(sent_back)), user, :rejected, "no")
      assert Artifacts.changeset_decision(rejected.id) == :rejected
      trunk_moves!(bare, "the trunk's version, again\n")
      main = main(bare)

      ticket = rebase!(context, rejected)

      assert_waits(ticket, bare, main)
    end

    # Case 3 stays as it was, decided in the refinement: nobody decided v2, so v1's approval
    # stands. This fails when the guard asks for an approval of the latest version.
    test "an approval of an earlier version still stands when a later one was never decided" do
      %{bare: bare, user: user, project: project} = context = scenario(queue: true)
      trunk_moves!(bare)
      {:ok, queued} = Operator.decide(context.ticket, user, :approved, nil)
      sent_back = sent_back!(context, queued)
      trunk_moves!(bare, "the trunk's version, again\n")

      ticket = rebase!(context, sent_back)

      assert ticket.state == "integrating"
      assert ticket.pending_transition == nil
      assert %{status: :waiting, from_state: "integrating"} = MergeQueue.entry(ticket)
      assert {:merged, _id} = Engine.advance_queue(project.id)
      assert fresh(ticket).state == "merged"
    end

    # The row an engine edge makes carries the approval the ticket stood on, so a take-out that
    # follows withdraws it. Without that the record would stand after the take-out.
    test "taking out a ticket the engine queued on a standing approval withdraws that approval" do
      %{bare: bare, user: user} = context = scenario(queue: true)
      trunk_moves!(bare)
      {:ok, queued} = Operator.decide(context.ticket, user, :approved, nil)
      sent_back = sent_back!(context, queued)
      trunk_moves!(bare, "the trunk's version, again\n")
      ticket = rebase!(context, sent_back)
      assert %{approval_ids: [_id]} = MergeQueue.entry(ticket)

      assert {:ok, _out} = Operator.take_out(ticket, user)

      assert Artifacts.changeset_decision(ticket.id) == :withdrawn
    end
  end

  describe "what is left as it was" do
    # A ticket the queue sent has an entry, and goes back into its old place with no approval
    # asked for. This passes with the guard in front of the entry clause too, an equivalent
    # mutant: a ticket in the line was approved on the way in, so the record stands whichever
    # clause is asked first. What it does check is that the row keeps its place and nothing is
    # asked: the entry clause's own behaviour, which the guard must not disturb.
    test "a ticket the queue sent goes back in the line, with nothing asked" do
      %{bare: bare, user: user, project: project} = context = scenario(queue: true)
      trunk_moves!(bare)
      {:ok, queued} = Operator.decide(context.ticket, user, :approved, nil)
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      changeset!(fresh(queued), integrate!(bare, fresh(queued)))

      ticket = ended!(fresh(queued), "done")

      assert ticket.pending_transition == nil
      assert %{status: :waiting} = MergeQueue.entry(ticket)
      refute "approval.requested" in types(ticket)
    end

    # Criterion 7: an engine edge that does not leave an integrating state is not read.
    test "an engine edge into a merging state that names no on_conflict merges with no approval" do
      {project, bare, user} = new_project(conflict_workflow(:plain))

      {:ok, ticket} =
        Tickets.admit(project, %{title: "Add a.txt", body: "do it"}, {:user, user.id})

      changeset!(ticket, commit_file_on_branch(project, ticket.branch, "a.txt", "a"))
      commit_message!(ticket, "Add a.txt\n")
      main = main(bare)
      job = ticket.id |> Jobs.for_ticket() |> List.last()

      job =
        job
        |> Ecto.Changeset.change(
          status: :finished,
          outcome: :converged,
          declared_outcome: "engine_merges"
        )
        |> Repo.update!()

      assert {:ok, merged} = Engine.after_job(fresh(ticket), job, "engine_merges")

      assert merged.state == "merged"
      refute main(bare) == main
      assert approvals(merged) == []
    end
  end

  # An approval on record, as a person's earlier decision left it.
  defp approved_row!(ticket, user) do
    version = Artifacts.latest(ticket.id, "changeset")

    Repo.insert!(%Forge.Artifacts.Approval{
      artifact_version_id: version.id,
      user_id: user.id,
      decision: :approved,
      transition: %{"from" => "review_ready", "to" => "merged"}
    })
  end

  describe "an engine edge that queues, out of a state that is not integrating" do
    # The row carries the approval it stood on only out of an integrating state. Out of any other
    # it stands on nothing, so a take-out withdraws nothing: it does not unapprove what an earlier
    # decision gave.
    test "makes a row that stands on no approval, whatever the record says" do
      {project, _bare, user} =
        new_project(
          String.replace(
            conflict_workflow(:plain),
            "when: engine_merges }",
            "when: engine_merges, queue: true }"
          )
        )

      {:ok, ticket} =
        Tickets.admit(project, %{title: "Add a.txt", body: "do it"}, {:user, user.id})

      changeset!(ticket, commit_file_on_branch(project, ticket.branch, "a.txt", "a"))
      commit_message!(ticket, "Add a.txt\n")
      approval = approved_row!(ticket, user)
      assert Artifacts.changeset_decision(ticket.id) == :stands

      job =
        ticket.id
        |> Jobs.for_ticket()
        |> List.last()
        |> Ecto.Changeset.change(
          status: :finished,
          outcome: :converged,
          declared_outcome: "engine_merges"
        )
        |> Repo.update!()

      assert {:ok, _ticket} = Engine.after_job(fresh(ticket), job, "engine_merges")

      assert %{status: :waiting, approval_ids: []} = MergeQueue.entry(ticket)
      assert {:ok, _out} = Operator.take_out(fresh(ticket), user)
      assert Artifacts.changeset_decision(ticket.id) == :stands
      assert Repo.reload!(approval).withdrawn_at == nil
    end
  end

  describe "what the page says before the rebase" do
    test "reads the record: the ticket would merge on its own, or come back for approval" do
      %{bare: bare, user: user, ticket: ticket} = context = scenario(queue: true)
      trunk_moves!(bare)
      workflow = Tickets.workflow(ticket)

      assert Engine.rebase_outcome(fresh(ticket), workflow) == :ask

      {:ok, queued} = Operator.decide(ticket, user, :approved, nil)
      {:ok, _out} = Operator.take_out(queued, user)
      assert Engine.rebase_outcome(fresh(queued), workflow) == :ask
      assert Engine.rebase_decision_reason(rebase!(context, queued)) == :withdrawn
    end

    test "says nothing where the rebase does not lead into the merge, approved or not" do
      # Route (a): the rebase goes back to a person who approves again, whatever the record says.
      {project, _bare, user} = new_project(conflict_workflow(:a))

      {:ok, ticket} =
        Tickets.admit(project, %{title: "Practice timer", body: "do it"}, {:user, user.id})

      changeset!(
        ticket,
        commit_file_on_branch(project, ticket.branch, "README.md", "the branch's")
      )

      ticket = pend_merge(ticket)
      approved_row!(ticket, user)
      assert Artifacts.changeset_decision(ticket.id) == :stands

      assert Engine.rebase_outcome(fresh(ticket), Tickets.workflow(ticket)) == nil
    end

    test "says it will ask where the edge declares an approval, though the record stands" do
      {project, _bare, user} =
        new_project(
          String.replace(
            conflict_workflow(:b),
            "{ from: integrating, to: merged }",
            "{ from: integrating, to: merged, approve: [changeset] }"
          )
        )

      {:ok, ticket} =
        Tickets.admit(project, %{title: "Practice timer", body: "do it"}, {:user, user.id})

      changeset!(
        ticket,
        commit_file_on_branch(project, ticket.branch, "README.md", "the branch's")
      )

      ticket = pend_merge(ticket)
      approved_row!(ticket, user)
      assert Artifacts.changeset_decision(ticket.id) == :stands

      assert Engine.rebase_outcome(fresh(ticket), Tickets.workflow(ticket)) == :ask
    end
  end
end
