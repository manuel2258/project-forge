defmodule Forge.MergeQueueTest do
  @moduledoc """
  The merge queue (`docs/design/workflow-grammar-v1.md` § The merge queue): an approval on an edge
  declared `queue: true` puts the ticket in a per-project line, and the runner merges the front of
  it, sends it down the conflict route, or sticks it — one ticket at a time, in the order the
  approvals were recorded, with one bad ticket never holding the rest. Real repositories, as
  `merge_conflict_test.exs` has them. The runner's loop is driven by calling
  `Forge.Engine.advance_queue/1` directly.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.AccountsFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, MergeQueue, Operator, Repo, Tickets}

  # The grammar's conflict workflow with its approval edge declared to queue.
  defp queueing(route),
    do:
      route
      |> conflict_workflow()
      |> String.replace(
        "{ from: review_ready, to: merged, approve: [changeset] }",
        "{ from: review_ready, to: merged, approve: [changeset], queue: true }"
      )

  defp new_project(workflow) do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      register_owned!(%{
        name: "queue#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    {project, bare}
  end

  setup context do
    workflow =
      case context[:workflow] do
        :plain -> conflict_workflow(:b)
        route -> queueing(route || :b)
      end

    {project, bare} = new_project(workflow)
    user = user_fixture()
    join!(project, user)
    %{project: project, bare: bare, user: user}
  end

  # A ticket whose branch adds `file`, which merges cleanly beside any other ticket's file, with
  # a changeset and a commit message, resting at the approval.
  defp ticket!(project, user, file, opts \\ []) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Add #{file}", body: "do it"}, {:user, user.id})

    sha = commit_over_http(project, ticket.branch, file, "contents of #{file}")
    changeset!(ticket, sha)
    if Keyword.get(opts, :message, true), do: commit_message!(ticket, "Add #{file}\n\nBecause.\n")
    pend_merge(ticket)
  end

  # A ticket whose job has just ended `engine_merges`, so the engine takes its edge.
  defp engine_ticket!(project, user, file) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Add #{file}", body: "do it"}, {:user, user.id})

    changeset!(ticket, commit_over_http(project, ticket.branch, file, "contents of #{file}"))
    commit_message!(ticket, "Add #{file}\n")

    {:ok, _ticket} = finish_job!(ticket, "engine_merges")
    ticket
  end

  # The ticket's latest job ends with `outcome`, and the engine decides what follows.
  defp finish_job!(ticket, outcome) do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> List.last()
      |> Ecto.Changeset.change(status: :finished, outcome: :converged, declared_outcome: outcome)
      |> Repo.update!()

    Engine.after_job(fresh(ticket), job, outcome)
  end

  defp approve!(ticket, user) do
    {:ok, queued} = Operator.decide(ticket, user, :approved, "ship it")
    queued
  end

  defp order(project), do: project.id |> MergeQueue.list() |> Enum.map(& &1.ticket_id)
  defp head!(bare), do: elem(Git.resolve(bare, "refs/heads/main"), 1)
  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
  defp fresh(ticket), do: Tickets.get!(ticket.id)

  describe "entering the line" do
    test "an approval records itself and queues, merging nothing", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "a.txt")
      main = head!(bare)

      queued = approve!(ticket, user)

      assert queued.state == "review_ready"
      assert queued.status == :active
      assert queued.pending_transition == nil
      assert head!(bare) == main

      assert %{status: :waiting, from_state: "review_ready", to_state: "merged"} =
               MergeQueue.entry(ticket)

      assert "merge_queue.entered" in types(ticket)
      refute "transition.taken" in types(ticket)
      assert Artifacts.approved?(Artifacts.latest(ticket.id, "changeset"))
    end

    test "a conflict does not refuse the approval: it is dealt with in the line", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")

      queued = approve!(ticket, user)

      assert queued.state == "review_ready"
      assert %{status: :waiting} = MergeQueue.entry(ticket)
    end

    @tag workflow: :plain
    test "a workflow that declares no queue approves and merges at once, as it always did",
         context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")

      assert {:ok, merged} = Operator.decide(ticket, user, :approved, nil)

      assert merged.state == "merged"
      assert MergeQueue.entry(ticket) == nil
      refute "merge_queue.entered" in types(ticket)
    end
  end

  describe "the front of the line" do
    test "merges in the order approvals were recorded, and an approval again goes to the back",
         context do
      %{project: project, user: user, bare: bare} = context
      [a, b, c] = for file <- ~w(a.txt b.txt c.txt), do: ticket!(project, user, file)

      for ticket <- [b, a, c], do: approve!(ticket, user)
      assert order(project) == [b.id, a.id, c.id]

      # Taken out and approved afresh: a new approval, so a new place.
      assert {:ok, _a} = Operator.take_out(fresh(a), user)
      assert {:ok, _a} = Operator.transition(fresh(a), user, "merged")
      assert order(project) == [b.id, c.id, a.id]

      assert {:merged, b_id} = Engine.advance_queue(project.id)
      assert {:merged, c_id} = Engine.advance_queue(project.id)
      assert {:merged, a_id} = Engine.advance_queue(project.id)
      assert [b_id, c_id, a_id] == [b.id, c.id, a.id]
      assert Engine.advance_queue(project.id) == :idle

      assert order(project) == []
      for ticket <- [a, b, c], do: assert(fresh(ticket).state == "merged")
      {out, 0} = git(bare, ["show", "main:a.txt"])
      assert out =~ "contents of a.txt"
    end

    test "merges the version that was approved, under the message that was current then",
         context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "a.txt")
      approved = Artifacts.latest(ticket.id, "changeset")
      approve!(ticket, user)

      # Written after the approval: neither the changeset nor the message may be what is merged.
      late = commit_over_http(project, ticket.branch, "late.txt", "written later")
      changeset!(ticket, late)
      commit_message!(ticket, "A later message\n")

      assert {:merged, _id} = Engine.advance_queue(project.id)

      {message, 0} = git(bare, ["log", "-1", "--format=%B", "main"])
      assert message =~ "Add a.txt"
      refute message =~ "later"
      assert {_out, 0} = git(bare, ["cat-file", "-e", "main:a.txt"])
      assert {_out, status} = git(bare, ["cat-file", "-e", "main:late.txt"])
      assert status != 0
      assert %{"changeset" => sha} = latest_payload(ticket, "transition.taken")
      assert sha == Forge.Artifacts.commit(approved)
    end

    test "one merge at a time in a project, and projects do not wait for each other", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)
      for ticket <- [a, b], do: approve!(ticket, user)

      {other, _bare} = new_project(queueing(:b))
      join!(other, user)
      elsewhere = ticket!(other, user, "z.txt")
      approve!(elsewhere, user)

      # A merge is already running in the project, so nothing else is started there.
      MergeQueue.entry(a) |> Ecto.Changeset.change(status: :merging) |> Repo.update!()
      assert Engine.advance_queue(project.id) == :busy
      assert %{status: :waiting} = MergeQueue.entry(b)

      assert {:merged, id} = Engine.advance_queue(other.id)
      assert id == elsewhere.id
    end

    test "the database refuses a second merge in a project", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)
      for ticket <- [a, b], do: approve!(ticket, user)

      assert %{status: :merging} = MergeQueue.claim(project.id)
      second = MergeQueue.entry(b) |> Ecto.Changeset.change(status: :merging)
      assert_raise Ecto.ConstraintError, fn -> Repo.update!(second) end
      assert MergeQueue.claim(project.id) == :busy
    end

    test "a merge that fails sticks that ticket and the next one goes", context do
      %{project: project, user: user} = context
      # No message to commit under: the merge is refused, not made under text nobody wrote.
      broken = ticket!(project, user, "a.txt", message: false)
      good = ticket!(project, user, "b.txt")
      for ticket <- [broken, good], do: approve!(ticket, user)

      assert {:stuck, id} = Engine.advance_queue(project.id)
      assert id == broken.id
      assert fresh(broken).status == :stuck
      assert MergeQueue.entry(broken) == nil

      assert {:merged, id} = Engine.advance_queue(project.id)
      assert id == good.id
    end
  end

  describe "a conflict in the line" do
    test "sends the ticket to integration, keeps its place, and the clean one behind goes first",
         context do
      %{project: project, user: user, bare: bare} = context
      conflicting = ticket!(project, user, "README.md")
      clean = ticket!(project, user, "b.txt")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      for ticket <- [conflicting, clean], do: approve!(ticket, user)
      position = MergeQueue.entry(conflicting).position

      assert {:integrating, id} = Engine.advance_queue(project.id)
      assert id == conflicting.id
      assert fresh(conflicting).state == "integrating"
      assert %{status: :integrating, position: ^position} = MergeQueue.entry(conflicting)

      assert {:merged, id} = Engine.advance_queue(project.id)
      assert id == clean.id
      assert Engine.advance_queue(project.id) == :idle
      assert latest_payload(fresh(conflicting), "ticket.merge_conflicted")["by"] == "engine"
    end

    test "an integration on an edge straight to the merging state waits its turn, then merges",
         context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      head = integrate!(bare, fresh(ticket))
      changeset!(fresh(ticket), head)
      integrated = integration_done!(fresh(ticket))

      assert integrated.state == "integrating"

      assert %{status: :waiting, to_state: "merged", from_state: "integrating"} =
               MergeQueue.entry(ticket)

      assert "merge_queue.returned" in types(ticket)
      assert {:merged, _id} = Engine.advance_queue(project.id)
      assert fresh(ticket).state == "merged"
      assert MergeQueue.entry(ticket) == nil
    end

    @tag workflow: :a
    test "an integration on an edge to any other state leaves the line", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      integrated = integration_done!(fresh(ticket))

      assert integrated.state == "review_ready"
      assert MergeQueue.entry(ticket) == nil
      assert "merge_queue.left" in types(ticket)
    end

    test "an integration that ends in an approval to be given leaves the line", context do
      %{user: user} = context

      {project, bare} =
        new_project(
          String.replace(
            queueing(:a),
            "{ from: integrating, to: review_ready }",
            "{ from: integrating, to: review_ready, approve: [changeset] }"
          )
        )

      join!(project, user)
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      integrated = integration_done!(fresh(ticket))

      assert integrated.pending_transition["to"] == "review_ready"
      assert MergeQueue.entry(ticket) == nil
    end

    test "the third integration in a row is the last: the fourth sticks it and not the line",
         context do
      %{project: project, user: user, bare: bare} = context
      stubborn = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      [one, two] = for file <- ~w(b.txt c.txt), do: ticket!(project, user, file)
      for ticket <- [stubborn, one, two], do: approve!(ticket, user)

      # Integration is the first round, and the line goes on past it.
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      assert {:merged, _id} = Engine.advance_queue(project.id)

      for _round <- 2..3 do
        integration_done!(fresh(stubborn))
        assert {:integrating, _id} = Engine.advance_queue(project.id)
      end

      integration_done!(fresh(stubborn))
      assert {:stuck, id} = Engine.advance_queue(project.id)
      assert id == stubborn.id
      assert fresh(stubborn).status == :stuck

      assert Events.latest_for_ticket(stubborn.id, "ticket.stuck").payload["reason"] =~
               "after 3 integrations"

      # Its existing message, and the ticket behind it is not held up by it.
      assert MergeQueue.entry(stubborn) == nil
      assert {:merged, id} = Engine.advance_queue(project.id)
      assert id == two.id
    end

    @tag workflow: :a
    test "a person's approval again resets the count", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)

      # Four integrations, none of them three in a row: a person put it back in between.
      for round <- 1..4 do
        assert {:integrating, _id} = Engine.advance_queue(project.id)
        assert integration_done!(fresh(ticket)).state == "review_ready"
        if round < 4, do: assert({:ok, _} = Operator.transition(fresh(ticket), user, "merged"))
      end

      assert fresh(ticket).status == :active
    end
  end

  describe "leaving the line" do
    test "cancelling a queued ticket takes it out", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)

      assert {:ok, _ticket} = Engine.cancel(fresh(ticket), user.id)

      assert MergeQueue.entry(ticket) == nil
      assert Engine.advance_queue(project.id) == :idle
    end

    test "any stick takes it out", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)

      assert {:ok, stuck} = Engine.stick(fresh(ticket), "no machine")

      assert stuck.status == :stuck
      assert MergeQueue.entry(ticket) == nil
    end
  end

  describe "taking a ticket out" do
    test "withdraws the approval, restores the choice, and needs a new approval", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      version = Artifacts.latest(ticket.id, "changeset")
      assert Artifacts.approved?(version)

      assert {:ok, out} = Operator.take_out(fresh(ticket), user)

      refute Artifacts.approved?(version)
      assert MergeQueue.entry(ticket) == nil
      assert out.state == "review_ready"
      assert Engine.offered_transitions(out, Tickets.workflow(out)) == ["merged"]

      assert %{"kind" => "user", "id" => user_id} =
               Events.latest_for_ticket(ticket.id, "merge_queue.taken_out").actor

      assert user_id == user.id

      # The approval is a new one: the old one stays on the version, withdrawn.
      assert {:ok, _queued} = Operator.transition(out, user, "merged")
      assert Artifacts.approved?(version)
      assert [_withdrawn, _again] = Artifacts.approvals(version.id)
    end

    test "while it is being integrated stops the merge and not the integration", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      main = head!(bare)

      # Being integrated is queued: a hand transition is refused as such, not as a live job.
      assert {:error, :queued} = Operator.transition(fresh(ticket), user, "merged")
      assert Engine.recover_queue() == 0
      assert %{status: :integrating} = MergeQueue.entry(ticket)

      assert {:ok, _ticket} = Operator.take_out(fresh(ticket), user)

      assert MergeQueue.entry(ticket) == nil

      assert [%{status: :pending}] =
               Jobs.for_ticket(ticket.id) |> Enum.filter(&(&1.state == "integrating"))

      head = integrate!(bare, fresh(ticket))
      changeset!(fresh(ticket), head)
      stuck = integration_done!(fresh(ticket))

      # The integrated result is recorded; the edge into the merging state is not taken.
      assert stuck.status == :stuck
      assert stuck.state == "integrating"
      assert head!(bare) == main

      assert Events.latest_for_ticket(ticket.id, "ticket.stuck").payload["reason"] =~
               "taken out of the merge queue"
    end

    test "while the integration's result is being recorded is neither lost nor a raise",
         context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      job =
        ticket.id
        |> Jobs.for_ticket()
        |> List.last()
        |> Ecto.Changeset.change(status: :finished, outcome: :converged, declared_outcome: "done")
        |> Repo.update!()

      # What the engine builds as the job's result arrives; a person takes the ticket out before it
      # commits. Deciding while building left a row to update that was gone.
      recording = Engine.put_after_job(Ecto.Multi.new(), fresh(ticket), job, "done")
      assert {:ok, _ticket} = Operator.take_out(fresh(ticket), user)

      assert {:ok, _changes} = Repo.transaction(recording)

      assert fresh(ticket).status == :stuck
      assert MergeQueue.entry(ticket) == nil

      assert Events.latest_for_ticket(ticket.id, "ticket.stuck").payload["reason"] =~
               "taken out of the merge queue"
    end

    @tag workflow: :a
    test "while it is being integrated, an edge to another state is taken as the workflow says",
         context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      assert {:ok, _ticket} = Operator.take_out(fresh(ticket), user)

      assert integration_done!(fresh(ticket)).state == "review_ready"
    end

    test "is refused with words once the ticket has merged or was taken out", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)
      for ticket <- [a, b], do: approve!(ticket, user)
      assert {:merged, _id} = Engine.advance_queue(project.id)

      assert {:error, {:not_queued, {:merged, "merged"}}} = Operator.take_out(fresh(a), user)
      assert {:ok, _ticket} = Operator.take_out(fresh(b), user)
      assert {:error, {:not_queued, {:taken_out, nil}}} = Operator.take_out(fresh(b), user)
    end

    test "is refused while the merge is running", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      MergeQueue.entry(ticket) |> Ecto.Changeset.change(status: :merging) |> Repo.update!()

      assert {:error, :merging} = Operator.take_out(fresh(ticket), user)
      assert MergeQueue.entry(ticket)
    end

    test "is refused to a stranger and changes nothing", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      version = Artifacts.latest(ticket.id, "changeset")

      # Not a member. An account that is not approved holds no session to reach this with
      # (`identity.md` § Approval), so membership is what this operation can be asked about.
      stranger = user_fixture()
      assert {:error, :forbidden} = Operator.take_out(fresh(ticket), stranger)

      assert MergeQueue.entry(ticket)
      assert Artifacts.approved?(version)
      refute "merge_queue.taken_out" in types(ticket)
    end
  end

  describe "while a ticket is queued" do
    test "no other transition may be taken, by any operation", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      ticket = fresh(ticket)

      assert {:error, :queued} = Operator.transition(ticket, user, "merged")
      assert {:error, :queued} = Operator.integrate(ticket, user)
      assert {:error, :queued} = Operator.repin(ticket, user)
      assert {:error, :queued} = Engine.choose(ticket, user.id, "merged")
      refute Engine.retryable?(ticket)
      assert Engine.integrates_to(ticket, Tickets.workflow(ticket)) == nil
      assert MergeQueue.entry(ticket)
    end

    test "the operator's queue does not list it", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      assert Enum.any?(Forge.Queue.for_ticket(fresh(ticket)))

      approve!(ticket, user)

      assert Forge.Queue.for_ticket(fresh(ticket)) == []
      refute Enum.any?(Forge.Queue.items(), &(&1.ticket && &1.ticket.id == ticket.id))
    end
  end

  describe "an edge the engine takes" do
    @tag workflow: :plain
    test "queues too, and waits in the line without a transition", context do
      %{user: user} = context
      # `:plain` declares an engine edge `implementing -> merged when engine_merges`.
      {project, _bare} =
        new_project(
          String.replace(
            queueing(:plain),
            "when: engine_merges }",
            "when: engine_merges, queue: true }"
          )
        )

      join!(project, user)
      [one, two] = for file <- ~w(a.txt b.txt), do: engine_ticket!(project, user, file)

      assert %{status: :waiting, from_state: "implementing", outcome: "engine_merges"} =
               MergeQueue.entry(one)

      assert fresh(one).state == "implementing"
      assert {:error, :queued} = Operator.retry(fresh(one), user)

      # The edge the line is waiting to take is not one a person may take by hand beside it.
      assert {:error, :queued} = Operator.transition(fresh(one), user, "review_ready")
      assert fresh(one).state == "implementing"

      assert {:ok, _ticket} = Operator.take_out(fresh(two), user)
      assert fresh(two).status == :stuck
      assert Events.latest_for_ticket(two.id, "ticket.stuck").payload["reason"] =~ "taken out"

      assert {:merged, id} = Engine.advance_queue(project.id)
      assert id == one.id
      assert fresh(one).state == "merged"
    end
  end

  describe "taking out what a job's outcome asked approval for" do
    @tag workflow: :plain
    test "brings the pending approval back", context do
      %{user: user} = context

      {project, _bare} =
        new_project(
          String.replace(
            conflict_workflow(:plain),
            "when: engine_merges }",
            "when: engine_merges, approve: [changeset], queue: true }"
          )
        )

      join!(project, user)
      ticket = engine_ticket!(project, user, "a.txt")
      assert %{"to" => "merged", "outcome" => "engine_merges"} = fresh(ticket).pending_transition

      assert {:ok, queued} = Operator.decide(fresh(ticket), user, :approved, nil)
      assert queued.pending_transition == nil
      assert %{status: :waiting} = MergeQueue.entry(ticket)

      assert {:ok, out} = Operator.take_out(queued, user)

      assert %{"to" => "merged", "approve" => ["changeset"]} = out.pending_transition
      assert out.status == :active
      assert MergeQueue.entry(ticket) == nil
    end
  end

  describe "guards that must hold" do
    test "a rejection on a queueing edge rejects and queues nothing", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")

      assert {:ok, rejected} = Operator.decide(ticket, user, :rejected, "no")

      assert rejected.status == :stuck
      assert MergeQueue.entry(ticket) == nil
      refute Artifacts.approved?(Artifacts.latest(ticket.id, "changeset"))
      refute "merge_queue.entered" in types(ticket)
    end

    test "taking one ticket out withdraws its approvals and no one else's", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)
      for ticket <- [a, b], do: approve!(ticket, user)

      assert {:ok, _a} = Operator.take_out(fresh(a), user)

      refute Artifacts.approved?(Artifacts.latest(a.id, "changeset"))
      assert Artifacts.approved?(Artifacts.latest(b.id, "changeset"))
    end

    test "taking a ticket out leaves another approval of the same version alone", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      version = Artifacts.latest(ticket.id, "changeset")
      approve!(ticket, user)

      # An approval of the same version on some other edge, which is not this entry's to withdraw.
      Repo.insert!(%Forge.Artifacts.Approval{
        artifact_version_id: version.id,
        user_id: user.id,
        decision: :approved,
        transition: %{"from" => "elsewhere", "to" => "somewhere"}
      })

      assert {:ok, _ticket} = Operator.take_out(fresh(ticket), user)

      assert Artifacts.approved?(version)

      assert [_other, %{withdrawn_at: %DateTime{}}] =
               Enum.sort_by(Artifacts.approvals(version.id), &(&1.withdrawn_at != nil))
    end

    test "a project's line and places hold its own tickets only", context do
      %{project: project, user: user} = context
      mine = ticket!(project, user, "a.txt")
      approve!(mine, user)

      {other, _bare} = new_project(queueing(:b))
      join!(other, user)
      theirs = ticket!(other, user, "z.txt")
      approve!(theirs, user)

      assert order(project) == [mine.id]
      assert order(other) == [theirs.id]
      assert Map.keys(MergeQueue.places(project.id)) == [mine.id]
      assert [{%{ticket_id: id}, %{total: 1}}] = MergeQueue.with_places(other.id)
      assert id == theirs.id
    end

    test "a ticket that was never queued leaves no trace of leaving", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")

      assert {:ok, _stuck} = Engine.stick(fresh(ticket), "no machine")
      assert {:ok, _cancelled} = Engine.cancel(fresh(ticket), user.id)

      refute "merge_queue.left" in types(ticket)
    end

    test "the approver and the note are what the merge is made under", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)

      assert {:merged, _id} = Engine.advance_queue(project.id)

      assert latest_payload(ticket, "transition.taken")["comment"] == "ship it"
      merged = Events.latest_for_ticket(ticket.id, "ticket.merged")
      assert %{"kind" => "user", "id" => id} = merged.actor
      assert id == user.id
    end

    test "how a ticket last left the line is the latest, not the first", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert {:ok, out} = Operator.take_out(fresh(ticket), user)
      assert {:ok, _queued} = Operator.transition(out, user, "merged")
      assert {:merged, _id} = Engine.advance_queue(project.id)

      assert {:error, {:not_queued, {:merged, _}}} = Operator.take_out(fresh(ticket), user)
    end

    @tag workflow: :human
    test "a conflict route that ends in a person's hands leaves the line", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)

      assert {:left, _id} = Engine.advance_queue(project.id)

      assert fresh(ticket).state == "integrating"
      assert MergeQueue.entry(ticket) == nil
    end

    test "a conflict with nowhere to go sticks that ticket", context do
      %{user: user} = context
      {project, bare} = new_project(queueing(:plain))
      join!(project, user)
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)

      assert {:stuck, _id} = Engine.advance_queue(project.id)

      assert Events.latest_for_ticket(ticket.id, "ticket.stuck").payload["reason"] =~
               "merge conflict in README.md"

      assert MergeQueue.entry(ticket) == nil
    end
  end

  describe "who took a ticket out" do
    test "another ticket's take-out does not stop this one", context do
      %{user: user} = context
      # `:plain`'s engine edge does not queue, so it is checked and merged at once.
      {project, _bare} = new_project(queueing(:plain))
      join!(project, user)
      gone = ticket!(project, user, "a.txt")
      approve!(gone, user)
      assert {:ok, _ticket} = Operator.take_out(fresh(gone), user)

      other = engine_ticket!(project, user, "b.txt")

      assert fresh(other).state == "merged"
    end

    test "running the state again after a take-out is a fresh start", context do
      %{user: user} = context

      {project, _bare} =
        new_project(
          String.replace(
            queueing(:plain),
            "when: engine_merges }",
            "when: engine_merges, queue: true }"
          )
        )

      join!(project, user)
      ticket = engine_ticket!(project, user, "a.txt")
      assert {:ok, _ticket} = Operator.take_out(fresh(ticket), user)
      assert fresh(ticket).status == :stuck

      assert {:ok, _ticket} = Operator.retry(fresh(ticket), user)
      assert {:ok, _ticket} = finish_job!(ticket, "engine_merges")

      assert %{status: :waiting} = MergeQueue.entry(ticket)
      assert fresh(ticket).status == :active
    end
  end

  describe "an integration that ends on an edge of its own" do
    test "returns to the line on that edge, and merges", context do
      %{user: user} = context

      {project, bare} =
        new_project(
          queueing(:b)
          |> String.replace(
            "    inputs: [changeset]\n    produces: [changeset]\n",
            "    inputs: [changeset]\n    outcomes: [done, ship]\n    produces: [integration.md, changeset]\n"
          )
          |> String.replace(
            "  - { from: integrating, to: merged }",
            "  - { from: integrating, to: merged, when: ship }"
          )
        )

      join!(project, user)
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      head = integrate!(bare, fresh(ticket))
      changeset!(fresh(ticket), head)
      assert {:ok, _ticket} = finish_job!(ticket, "ship")

      assert %{status: :waiting, edge_outcome: "ship", from_state: "integrating"} =
               MergeQueue.entry(ticket)

      assert {:merged, _id} = Engine.advance_queue(project.id)
    end
  end

  describe "an edge a person chose among parallel ones" do
    test "is the edge that is taken", context do
      %{user: user} = context

      {project, _bare} =
        new_project(
          queueing(:plain)
          |> String.replace(
            "outcomes: [done, engine_merges]",
            "outcomes: [done, engine_merges, ship]"
          )
          |> String.replace(
            "when: engine_merges }",
            "when: engine_merges, queue: true }\n  - { from: implementing, to: merged, when: ship, queue: true }"
          )
        )

      join!(project, user)
      {:ok, ticket} = Tickets.admit(project, %{title: "Pick", body: "x"}, {:user, user.id})
      changeset!(ticket, commit_over_http(project, ticket.branch, "a.txt", "contents"))
      commit_message!(ticket, "Add a.txt\n")

      ticket.id
      |> Jobs.for_ticket()
      |> List.last()
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Repo.update!()

      assert {:ok, _queued} = Operator.transition(fresh(ticket), user, "merged", outcome: "ship")
      assert %{edge_outcome: "ship"} = MergeQueue.entry(ticket)

      assert {:merged, _id} = Engine.advance_queue(project.id)
      assert latest_payload(ticket, "transition.taken")["outcome"] == "ship"
    end
  end

  describe "the words" do
    test "every queue event says what it means beside its type" do
      said = fn type, payload ->
        Events.summary(%Forge.Events.Event{type: type, payload: payload})
      end

      assert said.("merge_queue.entered", %{"to" => "merged"}) ==
               "queued to merge into merged"

      assert said.("merge_queue.returned", %{}) =~ "back in the merge queue"
      assert said.("merge_queue.taken_out", %{"status" => "waiting"}) =~ "approval is withdrawn"

      assert said.("merge_queue.taken_out", %{"status" => "integrating"}) =~
               "finishes but will not merge"

      assert said.("ticket.merged", %{"sha" => "abc", "already" => false}) == "merged as abc"

      assert said.("ticket.merged", %{"sha" => "abc", "already" => true}) ==
               "merged as abc (it was already there)"

      assert said.("merge_queue.left", %{"reason" => "merged"}) =~ "merged"
      assert said.("merge_queue.left", %{"reason" => "stuck"}) =~ "stuck"
      assert said.("merge_queue.left", %{"reason" => "cancelled"}) =~ "cancelled"
      assert said.("merge_queue.left", %{"reason" => "needs_person"}) =~ "needs a person"
      assert said.("merge_queue.left", %{"reason" => "moved on"}) =~ "(moved on)"
    end

    test "a client of the API is told it is a conflict and not a server fault" do
      conn =
        ForgeWeb.Api.FallbackController.call(Phoenix.ConnTest.build_conn(), {:error, :queued})

      assert conn.status == 409
      assert %{"error" => %{"reason" => "queued"}} = Jason.decode!(conn.resp_body)
    end
  end

  describe "after a restart" do
    test "a ticket that did enter the merging state has its merge finished", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)
      main = head!(bare)

      # The crash after the transition committed and before the merge was made.
      sha = Artifacts.commit(Artifacts.latest(ticket.id, "changeset"))

      {:ok, _event} =
        Events.append("transition.taken", :system, %{
          ticket_id: ticket.id,
          payload: %{
            "from" => "review_ready",
            "to" => "merged",
            "outcome" => "done",
            "changeset" => sha,
            "changeset_version" => 1,
            "commit_message_version" => Forge.Merge.commit_message_version(ticket)
          }
        })

      fresh(ticket) |> Ecto.Changeset.change(state: "merged", status: :done) |> Repo.update!()

      assert Engine.recover_queue() == 1

      assert head!(bare) != main
      assert {_out, 0} = git(bare, ["cat-file", "-e", "main:a.txt"])
      assert MergeQueue.entry(ticket) == nil
      assert "ticket.merged" in types(ticket)
    end

    test "recovering one project leaves another project's merge alone", context do
      %{project: project, user: user} = context
      mine = ticket!(project, user, "a.txt")
      approve!(mine, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)

      {other, _bare} = new_project(queueing(:b))
      join!(other, user)
      theirs = ticket!(other, user, "z.txt")
      approve!(theirs, user)
      assert %{status: :merging} = MergeQueue.claim(other.id)

      assert Engine.recover_queue(project.id) == 1

      assert %{status: :waiting} = MergeQueue.entry(mine)
      assert %{status: :merging} = MergeQueue.entry(theirs)
    end

    test "a ticket that is gone from the line's reach leaves it", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)
      fresh(ticket) |> Ecto.Changeset.change(status: :cancelled) |> Repo.update!()

      assert Engine.recover_queue() == 1

      assert MergeQueue.entry(ticket) == nil
    end

    test "an integrating state that routes back to itself is told by its live job", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      integration_done!(fresh(ticket))

      # Queued from `integrating` now, claimed, and the crash came before the route was taken: no
      # job is live in the state, so it is simply waiting again.
      assert %{status: :merging} = MergeQueue.claim(project.id)
      assert Engine.recover_queue() == 1
      assert %{status: :waiting} = MergeQueue.entry(ticket)

      # The route was taken (the loop makes a new job in the same state) and the row not marked.
      assert {:integrating, _id} = Engine.advance_queue(project.id)
      MergeQueue.entry(ticket) |> Ecto.Changeset.change(status: :merging) |> Repo.update!()
      assert Engine.recover_queue() == 1
      assert %{status: :integrating} = MergeQueue.entry(ticket)
    end

    test "a ticket already sent down the conflict route keeps its place", context do
      %{project: project, user: user, bare: bare} = context
      ticket = ticket!(project, user, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's version\n"}, "another ticket")
      approve!(ticket, user)
      assert {:integrating, _id} = Engine.advance_queue(project.id)

      # The crash between the ticket's move and the row's mark.
      MergeQueue.entry(ticket) |> Ecto.Changeset.change(status: :merging) |> Repo.update!()
      assert Engine.recover_queue() == 1

      assert %{status: :integrating} = MergeQueue.entry(ticket)
    end

    test "a ticket that has moved somewhere else leaves the line", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)
      fresh(ticket) |> Ecto.Changeset.change(state: "implementing") |> Repo.update!()

      assert Engine.recover_queue() == 1

      assert MergeQueue.entry(ticket) == nil
      assert "merge_queue.left" in types(ticket)
    end

    test "a merge that was running is put back in the line", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)

      assert Engine.recover_queue() == 1

      assert %{status: :waiting} = MergeQueue.entry(ticket)
      assert {:merged, _id} = Engine.advance_queue(project.id)
    end

    test "a kick is what starts the runner on an approval", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)

      # No poll to lean on: the approval's own kick has to do it.
      put_env(:merge_queue_poll_ms, 600_000)
      start_supervised!(Forge.MergeQueue.Runner)

      for ticket <- [b, a], do: approve!(ticket, user)
      eventually(fn -> fresh(a).state == "merged" and fresh(b).state == "merged" end)
      eventually(fn -> order(project) == [] end)

      seq = fn ticket -> Events.latest_for_ticket(ticket.id, "ticket.merged").seq end
      assert seq.(b) < seq.(a)
    end

    test "one pass works the whole line", context do
      %{project: project, user: user} = context
      [a, b] = for file <- ~w(a.txt b.txt), do: ticket!(project, user, file)
      for ticket <- [a, b], do: approve!(ticket, user)

      # Both are waiting before the runner exists, and its first pass is the only one there is.
      put_env(:merge_queue_poll_ms, 600_000)
      start_supervised!(Forge.MergeQueue.Runner)

      eventually(fn -> order(project) == [] end)
      assert fresh(a).state == "merged"
      assert fresh(b).state == "merged"
    end

    test "a restarted runner leaves a merge a live task holds", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)

      # A task from before the restart, still alive, holding the project's name. The runner's task
      # does not wait for it here.
      put_env(:merge_queue_name_tries, 0)

      {:ok, owner} =
        Agent.start_link(fn ->
          Registry.register(Forge.MergeQueue.Registry, project.id, nil)
        end)

      put_env(:merge_queue_poll_ms, 600_000)
      start_supervised!(Forge.MergeQueue.Runner)
      Process.sleep(500)

      assert %{status: :merging} = MergeQueue.entry(ticket)
      assert fresh(ticket).state == "review_ready"

      Agent.stop(owner)
    end

    test "a merge whose task is gone is recovered by the next start", context do
      %{project: project, user: user} = context
      ticket = ticket!(project, user, "a.txt")
      approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)

      # Nothing holds the project's name: the task died, with the runner or before it.
      put_env(:merge_queue_poll_ms, 600_000)
      start_supervised!(Forge.MergeQueue.Runner)

      # The state is moved before the merge is made; the row goes after it.
      eventually(fn -> MergeQueue.entry(ticket) == nil end)
      assert fresh(ticket).state == "merged"
    end

    test "a task that dies is replaced, and recovers its project and no other", context do
      %{project: project, user: user} = context
      {other, _bare} = new_project(queueing(:b))
      join!(other, user)
      mine = ticket!(project, user, "a.txt")
      theirs = ticket!(other, user, "z.txt")

      # Stand-ins hold both names, so the approvals' kicks start tasks that stop at once.
      owners =
        for id <- [project.id, other.id] do
          {:ok, owner} =
            Agent.start_link(fn -> Registry.register(Forge.MergeQueue.Registry, id, nil) end)

          owner
        end

      put_env(:merge_queue_poll_ms, 600_000)
      put_env(:merge_queue_retry_ms, 1_000)
      put_env(:merge_queue_name_tries, 0)
      start_supervised!(Forge.MergeQueue.Runner)
      for ticket <- [mine, theirs], do: approve!(ticket, user)
      assert %{status: :merging} = MergeQueue.claim(project.id)
      assert %{status: :merging} = MergeQueue.claim(other.id)
      Enum.each(owners, &Agent.stop/1)

      # The runner is told that a task of this one project died.
      runner = Process.whereis(Forge.MergeQueue.Runner)
      ref = make_ref()

      :sys.replace_state(runner, fn state ->
        %{state | running: Map.put(state.running, ref, project.id)}
      end)

      send(runner, {:DOWN, ref, :process, self(), :killed})

      # Replaced after the delay, not at once: a row that kills its task every time does not spin.
      Process.sleep(300)
      assert %{status: :merging} = MergeQueue.entry(mine)

      eventually(fn -> MergeQueue.entry(mine) == nil end)
      assert fresh(mine).state == "merged"
      assert %{status: :merging} = MergeQueue.entry(theirs)
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:forge, key)
    Application.put_env(:forge, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:forge, key, old)
        :error -> Application.delete_env(:forge, key)
      end
    end)
  end

  defp eventually(check, deadline \\ System.monotonic_time(:millisecond) + 20_000) do
    cond do
      check.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("did not happen in time")
      true -> Process.sleep(50) && eventually(check, deadline)
    end
  end
end
