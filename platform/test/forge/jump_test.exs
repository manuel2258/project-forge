defmodule Forge.JumpTest do
  @moduledoc """
  A jump (`docs/design/workflow-grammar-v1.md` § Jumping): the move of a ticket to any state of its
  pinned workflow when no transition it is offered leads there. Every test names the rule it
  holds; the numbers are the acceptance criteria of ticket 56's refinement.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures
  require Forge.Engine

  alias Forge.{Artifacts, Engine, Events, Git, Jobs, MergeQueue, Operator, Repo, Tickets}
  alias ForgeCore.Job.Spec

  setup context do
    bare = seeded_repo(jump_files(queue: context[:queue] == true))

    {:ok, project} =
      register_owned!(%{
        name: "jump#{System.unique_integer([:positive])}",
        repo_path: bare,
        default_branch: "main"
      })

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Jump", body: "."}, {:user, user.id})
    %{project: project, bare: bare, user: user, ticket: ticket}
  end

  # The ticket at rest in `state` with no job live: what a stuck or human state looks like.
  defp rest_in(ticket, state, status \\ :stuck) do
    for job <- Jobs.for_ticket(ticket.id), job.status in [:pending, :running] do
      job
      |> Forge.Jobs.Job.progress_changeset(%{status: :finished, outcome: :converged})
      |> Repo.update!()
    end

    ticket |> Ecto.Changeset.change(state: state, status: status) |> Repo.update!()
  end

  defp document!(ticket, name, text \\ "# Text\n") do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, name, :document, :system, %{
        content: "---\noutcome: done\n---\n" <> text
      })

    :ok
  end

  defp fresh(ticket), do: Tickets.get!(ticket.id)
  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)
  defp head!(bare), do: elem(Git.resolve(bare, "refs/heads/main"), 1)

  defp pending(ticket) do
    ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending)) |> List.last()
  end

  # A ticket with work on its branch, a changeset and a commit message, resting in `review_ready`.
  defp ready!(%{project: project, ticket: ticket}, file \\ "a.txt") do
    sha = commit_over_http(project, ticket.branch, file, "contents of #{file}")
    changeset!(ticket, sha)
    commit_message!(ticket, "Add #{file}\n\nBecause.\n")
    rest_in(ticket, "review_ready", :active)
  end

  describe "a request for a state no transition leads to (criteria 1, 5, 6)" do
    test "moves the ticket, logs a jump and records no approval", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "refinement.md")
      document!(ticket, "plan.md")
      ticket = rest_in(ticket, "refining")

      assert {:ok, moved} = Operator.transition(ticket, user, "implementing", comment: "skip it")
      assert moved.state == "implementing"
      assert moved.status == :active

      event = ticket |> events_of("transition.taken") |> List.last()

      assert event.payload == %{
               "from" => "refining",
               "to" => "implementing",
               "jump" => true,
               "comment" => "skip it"
             }

      assert event.actor == %{"kind" => "user", "id" => user.id}
      refute "approval.approved" in types(ticket)

      spec = moved |> pending() |> Jobs.spec()

      assert spec.entered == %{
               "from" => "refining",
               "outcome" => nil,
               "by" => "person",
               "comment" => "skip it",
               "jump" => true
             }
    end

    test "a target an offered edge reaches still takes that edge, with its approval", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "refinement.md")
      ticket = rest_in(ticket, "refining")

      assert {:ok, moved} = Operator.transition(ticket, user, "planning")
      assert moved.state == "planning"

      event = ticket |> events_of("transition.taken") |> List.last()
      assert event.payload["outcome"] == "done"
      refute Map.has_key?(event.payload, "jump")
      assert "approval.approved" in types(ticket)
    end

    test "an edge not offered (its approval has no version) is a jump, and a jump approves nothing",
         context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")

      # `refining → planning` approves `refinement.md`, which has no version: not offered.
      assert Engine.offered_transitions(ticket, Tickets.workflow(ticket)) == []

      assert {:error, {:missing_input, "refinement.md"}} =
               Operator.transition(ticket, user, "planning")

      assert events_of(ticket, "approval.approved") == []

      document!(ticket, "refinement.md")
      assert Engine.offered_transitions(fresh(ticket), Tickets.workflow(ticket)) == ["planning"]
    end

    test "a state the workflow does not have is refused and drawn as text", context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")

      assert {:error, {:unknown_state, "<b>x</b>"}} =
               Operator.transition(ticket, user, "<b>x</b>")

      assert fresh(ticket).state == "refining"

      assert Engine.refusal({:unknown_state, "<b>x</b>"}) =~ ~s("<b>x</b>")
    end
  end

  describe "what the target's job needs (criteria 2, 3, 27)" do
    test "a missing required input refuses the move and leaves the ticket where it was",
         context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")
      events = length(Events.for_ticket(ticket.id))

      assert {:error, {:missing_input, "plan.md"}} =
               Operator.transition(ticket, user, "implementing")

      assert fresh(ticket).state == "refining"
      assert length(Events.for_ticket(ticket.id)) == events
    end

    test "an optional input that does not exist is no reason, and is named as absent", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      ticket = rest_in(ticket, "refining")

      assert {:ok, moved} = Operator.transition(ticket, user, "implementing")
      assert %{absent_inputs: ["notes.md"]} = moved |> pending() |> Jobs.spec()
    end

    test "a human state and a chat step require nothing", context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")

      assert {:ok, %{state: "review_ready"}} = Operator.transition(ticket, user, "review_ready")

      assert {:ok, %{state: "chatting"}} =
               Operator.transition(rest_in(ticket, "refining"), user, "chatting")
    end

    test "the missing inputs the manifest lists are the ones a jump is refused for", context do
      %{ticket: ticket} = context
      ticket = rest_in(ticket, "refining")
      workflow = Tickets.workflow(ticket)

      assert Jobs.missing_inputs(ticket, workflow, "implementing") == ["plan.md"]
      assert Jobs.missing_inputs(ticket, workflow, "chatting") == []
      assert Jobs.missing_inputs(ticket, workflow, "review_ready") == []
      assert Jobs.missing_inputs(ticket, workflow, "merged") == ["changeset", "commit-message"]

      document!(ticket, "plan.md")
      assert Jobs.missing_inputs(ticket, workflow, "implementing") == []
    end
  end

  describe "a jump into a state that merges (criteria 4, 7)" do
    test "approves the changeset in the actor's name, at the version it merges, and merges",
         context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      ticket = rest_in(ticket, "implementing", :stuck)
      main = head!(bare)

      assert {:ok, moved} = Operator.transition(ticket, user, "merged", comment: "ship")
      assert moved.state == "merged"
      assert moved.status == :done
      refute head!(bare) == main

      event = ticket |> events_of("transition.taken") |> List.last()

      assert %{"jump" => true, "changeset_version" => version, "commit_message_version" => _} =
               event.payload

      assert [approval] = events_of(ticket, "approval.approved")

      assert approval.payload == %{
               "from" => "implementing",
               "to" => "merged",
               "comment" => "ship"
             }

      assert approval.actor == %{"kind" => "user", "id" => user.id}

      changeset = Artifacts.latest(ticket.id, "changeset")
      assert changeset.version == version
      assert Artifacts.approved?(changeset)
    end

    test "is refused with no changeset or no commit message, and nothing is written", context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "implementing")

      assert {:error, {:merge_impossible, :no_changeset}} =
               Operator.transition(ticket, user, "merged")

      sha = commit_over_http(context.project, ticket.branch, "a.txt", "a")
      changeset!(ticket, sha)

      assert {:error, {:merge_impossible, :no_commit_message}} =
               Operator.transition(ticket, user, "merged")

      assert fresh(ticket).state == "implementing"
      assert events_of(ticket, "approval.approved") == []
    end

    test "a jump elsewhere approves nothing, whatever the edges into its target approve",
         context do
      %{user: user} = context
      ticket = ready!(context)

      # `review_ready → merged` approves the changeset; a jump to `integrating` is not that edge.
      assert {:ok, %{state: "integrating"}} = Operator.transition(ticket, user, "integrating")
      assert events_of(ticket, "approval.approved") == []
    end

    @tag queue: true
    test "joins the line when the workflow's edges into it queue: the ticket stays where it is",
         context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      ticket = rest_in(ticket, "implementing", :stuck)
      main = head!(bare)

      assert {:ok, queued} = Operator.transition(ticket, user, "merged")
      assert queued.state == "implementing"
      assert queued.status == :active
      assert head!(bare) == main

      assert %{jump: true, edge_outcome: nil, from_state: "implementing", to_state: "merged"} =
               MergeQueue.entry(ticket)

      assert %{"jump" => true} = latest_payload(ticket, "merge_queue.entered")

      assert {:merged, _id} = Engine.advance_queue(context.project.id)
      merged = fresh(ticket)
      assert merged.state == "merged"
      refute head!(bare) == main
      assert %{"jump" => true} = latest_payload(ticket, "transition.taken")
    end

    @tag queue: true
    test "taking a queued jump out withdraws its approval and leaves the ticket stuck", context do
      %{user: user} = context
      ticket = ready!(context)
      ticket = rest_in(ticket, "implementing", :stuck)
      assert {:ok, _queued} = Operator.transition(ticket, user, "merged")
      approval = Artifacts.latest(ticket.id, "changeset")
      assert Artifacts.approved?(approval)

      assert {:ok, out} = Operator.take_out(fresh(ticket), user)
      assert out.state == "implementing"
      assert out.status == :stuck
      assert out.pending_transition == nil
      assert MergeQueue.entry(ticket) == nil
      refute Artifacts.approved?(Artifacts.latest(ticket.id, "changeset"))
    end

    test "a conflict goes down the conflict route with the approval recorded", context do
      %{user: user, bare: bare} = context
      ticket = ready!(context, "README.md")
      commit_to(bare, "main", %{"README.md" => "the trunk's\n"}, "another ticket")
      ticket = rest_in(ticket, "implementing", :stuck)

      assert {:ok, moved} = Operator.transition(ticket, user, "merged")
      assert moved.state == "integrating"
      assert [_approval] = events_of(ticket, "approval.approved")
      assert %{"stage" => "check"} = latest_payload(ticket, "ticket.merge_conflicted")
    end
  end

  describe "a jump into an integrating state (criteria 8, 19)" do
    test "is told it arrived by a jump and that no conflict sent it", context do
      %{user: user, project: project} = context
      ticket = ready!(context)

      # A conflict from long ago is still on the ticket's record.
      {:ok, _event} =
        Events.append("ticket.merge_conflicted", :system, %{
          ticket_id: ticket.id,
          payload: %{
            "state" => "merged",
            "paths" => ["old.txt"],
            "changeset" => "abc",
            "by" => "engine"
          }
        })

      assert {:ok, moved} = Operator.transition(ticket, user, "integrating")
      job = pending(moved)
      assert protocol_before_attachments(job) == 12

      spec = Jobs.assignment(job, moved, project, "token")["spec"]
      assert %{"jump" => true, "paths" => []} = spec["integration"]
      assert spec["entered"]["jump"] == true

      manifest = ForgeCore.Prompt.manifest(Spec.from_map(spec), "/job")
      assert manifest =~ "No conflict sent this ticket here"
      assert manifest =~ "by a jump"
      refute manifest =~ "old.txt"
    end

    test "a chat step entered by a jump needs protocol 12, one entered by an edge does not",
         context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")

      # `chatting` has an edge from `review_ready` only: from `refining` it is a jump.
      assert {:ok, moved} = Operator.transition(ticket, user, "chatting")
      assert moved.state == "chatting"
      chat = moved.id |> Jobs.step_chats_for_ticket() |> List.last()
      assert Forge.Jobs.Job.step?(chat)
      assert Jobs.protocol_needs(chat)[:jump] == 12
      assert protocol_before_attachments(chat) == 12

      by_edge = rest_in(moved, "review_ready", :stuck)
      assert {:ok, again} = Operator.transition(by_edge, user, "chatting")
      chat = again.id |> Jobs.step_chats_for_ticket() |> List.last()
      assert Jobs.protocol_needs(chat)[:jump] == 0
      assert protocol_before_attachments(chat) == 11
    end

    test "a job of any other arrival needs no newer worker", context do
      %{user: user} = context
      document!(context.ticket, "refinement.md")
      ticket = rest_in(context.ticket, "refining")
      {:ok, moved} = Operator.transition(ticket, user, "planning")
      assert protocol_before_attachments(pending(moved)) < 12
    end
  end

  describe "a done ticket (criteria 9, 10, 11)" do
    test "is reopened by a jump, and a cancelled one is refused", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      done = rest_in(ticket, "merged", :done)

      assert {:ok, moved} = Operator.transition(done, user, "implementing")
      assert moved.status == :active
      assert moved.state == "implementing"
      assert %{"reopened" => true} = latest_payload(ticket, "transition.taken")

      cancelled = rest_in(ticket, "refining", :cancelled)

      assert {:error, {:not_active, :cancelled}} =
               Operator.transition(cancelled, user, "implementing")
    end

    test "merges again only what the branch changed since its earlier merge", context do
      %{user: user, bare: bare, project: project} = context
      ticket = ready!(context)

      assert {:ok, %{state: "merged", status: :done}} =
               Operator.transition(ticket, user, "merged")

      first_merge = head!(bare)
      assert %{"sha" => ^first_merge} = latest_payload(ticket, "ticket.merged")

      # Reopened with work that touches the file already landed.
      document!(ticket, "plan.md")
      assert {:ok, reopened} = Operator.transition(fresh(ticket), user, "implementing")
      assert reopened.base_commit == first_merge
      assert %{"reopened" => true} = latest_payload(ticket, "ticket.base_moved")

      # The branch has the merge in its history now, so the changeset is only what comes next.
      assert {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      assert Git.ancestor?(bare, first_merge, head)

      new = commit_over_http(project, ticket.branch, "a.txt", "contents of a.txt, changed")
      changeset!(ticket, new)
      commit_message!(ticket, "Change a.txt\n")
      rest_in(reopened, "review_ready", :active)

      assert {:ok, %{state: "merged"}} = Operator.transition(fresh(ticket), user, "merged")
      assert {:ok, "contents of a.txt, changed\n"} = Git.show(bare, head!(bare), "a.txt")
      assert {:ok, diff} = Git.diff(bare, reopened.base_commit, new)
      assert diff =~ "changed"
      refute diff =~ "+contents of a.txt\n"
    end

    test "the target's job reads the base the reopening moved", context do
      %{user: user, project: project} = context
      ticket = ready!(context, "old.txt")
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")
      commit_over_http(project, ticket.branch, "new.txt", "after the merge")

      assert {:ok, moved} = Operator.transition(fresh(ticket), user, "integrating")
      assert moved.base_commit == latest_payload(ticket, "ticket.merged")["sha"]

      changeset =
        pending(moved)
        |> Jobs.spec()
        |> Map.fetch!(:inputs)
        |> Enum.find(&(&1.name == "changeset"))

      assert changeset.content =~ "new.txt"
      refute changeset.content =~ "old.txt"
    end

    test "to the state it is already in creates a new attempt", context do
      %{user: user, ticket: ticket} = context
      # `refining` has no edge to itself, so asking for it is a jump; its job is a new attempt.
      ticket = rest_in(ticket, "refining")
      assert [%{attempt: 1}] = Jobs.for_ticket(ticket.id)

      assert {:ok, moved} = Operator.transition(ticket, user, "refining")
      assert moved.state == "refining"
      assert %{attempt: 2} = pending(moved)
      assert %{"jump" => true} = latest_payload(ticket, "transition.taken")
    end

    test "a branch that no longer combines with its own earlier merge is refused in words",
         context do
      %{user: user, project: project} = context
      ticket = ready!(context)
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")

      # The branch was changed after it merged, against what landed: add/add on `a.txt`.
      commit_over_http(project, ticket.branch, "a.txt", "something else entirely")
      document!(ticket, "plan.md")
      done = fresh(ticket)

      assert {:error, {:reopen_conflict, ["a.txt"]}} =
               Operator.transition(done, user, "implementing")

      assert fresh(ticket) == done
      assert Engine.refusal({:reopen_conflict, ["a.txt"]}) =~ "a.txt"
    end

    test "a refused reopening leaves the branch and the base where they were", context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")
      done = fresh(ticket)
      {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)

      # `plan.md` was never written: the jump is refused when the job is created, which is before
      # the branch is moved (it moves last), so neither has moved.
      assert {:error, {:missing_input, "plan.md"}} =
               Operator.transition(done, user, "implementing")

      assert Git.resolve(bare, "refs/heads/" <> ticket.branch) == {:ok, head}
      assert fresh(ticket).base_commit == done.base_commit
      assert fresh(ticket).status == :done
    end
  end

  describe "what a jump counts and is refused (criteria 12, 13, 17)" do
    test "counts against no transition's max and is no loop in Past", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      ticket = rest_in(ticket, "refining")

      for _ <- 1..2 do
        assert {:ok, moved} = Operator.transition(fresh(ticket), user, "implementing")
        rest_in(moved, "refining")
      end

      # Two `transition.taken` events with no outcome: counted, they would be an undeclared loop.
      assert length(for e <- events_of(ticket, "transition.taken"), e.payload["jump"], do: e) == 2
      assert Engine.rounds(ticket.id) == %{}
      assert Forge.Tickets.Past.loops(fresh(ticket), Tickets.workflow(ticket)) == []
    end

    test "a state's own edge to itself that is the only one is that edge, and counts", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      ticket = rest_in(ticket, "implementing")

      assert {:ok, moved} = Operator.transition(ticket, user, "implementing")
      assert %{"outcome" => "again"} = latest_payload(ticket, "transition.taken")
      assert Engine.rounds(ticket.id) == %{{"implementing", "implementing", "again"} => 1}
      assert moved.state == "implementing"
    end

    test "is refused while a job is live or a decision is pending", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      # The admission's own job is live.
      assert {:error, {:job_live, "refining"}} = Operator.transition(ticket, user, "implementing")

      pending_ticket =
        ticket
        |> rest_in("refining")
        |> Ecto.Changeset.change(pending_transition: %{"from" => "refining", "to" => "planning"})
        |> Repo.update!()

      assert {:error, :pending_approval} =
               Operator.transition(pending_ticket, user, "implementing")
    end

    @tag queue: true
    test "is refused while the ticket is in the merge line", context do
      %{user: user} = context
      ticket = ready!(context)
      ticket = rest_in(ticket, "implementing", :stuck)
      assert {:ok, _queued} = Operator.transition(ticket, user, "merged")
      document!(ticket, "plan.md")

      assert {:error, :queued} = Operator.transition(fresh(ticket), user, "refining")
    end

    test "is refused for a non-member", context do
      %{ticket: ticket} = context
      ticket = rest_in(ticket, "refining")
      document!(ticket, "plan.md")
      stranger = Forge.AccountsFixtures.user_fixture()

      assert {:error, _forbidden} = Operator.transition(ticket, stranger, "implementing")
      assert fresh(ticket).state == "refining"
    end

    test "the queue's way is refused a jump, and a page's arrow drawn as a jump is refused an edge",
         context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      document!(ticket, "refinement.md")
      ticket = rest_in(ticket, "refining")

      assert {:error, {:is_jump, "implementing"}} =
               Operator.transition(ticket, user, "implementing", jump: false, approving: false)

      # An edge since the page was drawn: a row of the fold is refused, nothing is approved.
      assert {:error, {:is_edge, "planning"}} =
               Operator.transition(ticket, user, "planning", jump: true)

      assert fresh(ticket).state == "refining"
      refute "approval.approved" in types(ticket)
    end
  end

  describe "its history (criterion 18)" do
    test "Activity reads a jump as one, with its comment, and a reopening as such", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")
      done = rest_in(ticket, "merged", :done)

      {:ok, _moved} = Operator.transition(done, user, "implementing", comment: "one more thing")

      event = ticket |> events_of("transition.taken") |> List.last()

      assert Events.summary(event) ==
               "jumped from merged to implementing, with no transition (reopened): one more thing"
    end

    @tag queue: true
    test "the line's entry says it was a jump", context do
      %{user: user} = context
      ticket = ready!(context)
      {:ok, _} = Operator.transition(rest_in(ticket, "implementing"), user, "merged")

      assert Events.summary(ticket |> events_of("merge_queue.entered") |> List.last()) ==
               "queued to merge into merged, by a jump"
    end
  end

  describe "its words (criterion 21)" do
    test "every new refusal has a sentence, and an unrelated reason has none" do
      for reason <- [
            {:unknown_state, "x"},
            {:missing_input, "plan.md"},
            {:is_jump, "x"},
            {:is_edge, "x"},
            {:merge_impossible, :no_changeset},
            {:merge_impossible, :no_commit_message},
            {:reopen_conflict, ["a.txt"]}
          ] do
        assert is_binary(Engine.refusal(reason)), inspect(reason)
        assert Engine.refused?(reason), inspect(reason)
      end

      assert Engine.refusal({:merge_impossible, :no_commit_message}) ==
               "the ticket has no commit-message yet, so a merge has nothing to say; " <>
                 "run the state that writes it"

      assert Engine.refusal({:merge_impossible, :no_changeset}) ==
               "the ticket has no changeset yet, so there is nothing to merge"

      assert Engine.refusal(:queued) == nil
    end

    test "a long hostile name is clipped" do
      assert String.length(Engine.refusal({:unknown_state, String.duplicate("<", 1000)})) < 200
    end
  end

  describe "reopening a done ticket meets what restoring one does (criterion 9)" do
    test "a milestone closed since leaves the ticket in none", context do
      %{user: user, project: project, ticket: ticket} = context
      document!(ticket, "plan.md")
      {:ok, milestone} = Operator.create_milestone(project, user, %{name: "Goal"})
      {:ok, placed} = Operator.set_milestone(ticket, user, milestone.id)
      assert placed.milestone_id == milestone.id

      done = rest_in(placed, "merged", :done)
      {:ok, _closed} = Operator.close_milestone(project, user, milestone.id)
      # Closing keeps a ticket that merged in the milestone it was merged in.
      assert fresh(ticket).milestone_id == milestone.id

      assert {:ok, moved} = Operator.transition(done, user, "implementing")
      assert moved.status == :active
      assert fresh(ticket).milestone_id == nil
      assert "ticket.milestone_set" in types(ticket)
    end

    test "a release is not reopened beside another that is open", context do
      %{user: user, project: project, ticket: ticket} = context
      document!(ticket, "plan.md")

      release = fn t ->
        t
        |> Ecto.Changeset.change(workflow: Map.put(t.workflow, "release", true))
        |> Repo.update!()
      end

      {:ok, other} = Tickets.admit(project, %{title: "Other", body: "."}, {:user, user.id})
      other = release.(other)
      done = ticket |> release.() |> rest_in("merged", :done)

      assert {:error, {:release_open, %{id: id}}} =
               Operator.transition(done, user, "implementing")

      assert id == other.id
      assert fresh(ticket).status == :done
      assert fresh(ticket).state == "merged"

      # Once the other is over, it reopens.
      {:ok, _} = Engine.cancel(other, {:user, user.id})
      assert {:ok, %{status: :active}} = Operator.transition(fresh(ticket), user, "implementing")
    end
  end

  describe "a pin with no state that writes a commit-message (criterion 4)" do
    test "merges under the old message, and the manifest does not list one as missing",
         context do
      %{user: user, project: project, ticket: ticket, bare: bare} = context
      sha = commit_over_http(project, ticket.branch, "a.txt", "a")
      changeset!(ticket, sha)

      old =
        ticket
        |> old_pin!("implementing")
        |> Ecto.Changeset.change(status: :stuck)
        |> Repo.update!()

      workflow = Tickets.workflow(old)

      assert Forge.Merge.legacy_message?(old)
      refute Forge.Merge.commit_message_missing?(old)
      assert Jobs.missing_inputs(old, workflow, "merged") == []
      main = head!(bare)

      assert {:ok, %{state: "merged", status: :done}} = Operator.transition(old, user, "merged")
      refute head!(bare) == main
    end

    test "a pin that has one and a ticket with none is missing it", context do
      %{ticket: ticket} = context
      assert Forge.Merge.commit_message_missing?(ticket)
      commit_message!(ticket)
      refute Forge.Merge.commit_message_missing?(fresh(ticket))
    end
  end

  describe "reopening into the merging state meets the same checks, on every path (criterion 9)" do
    # A done ticket in a milestone that has since closed, and a release with another open beside
    # it: the jump is refused for the release, and once that is over leaves the milestone.
    defp guarded_reopening!(context, ticket) do
      %{user: user, project: project} = context

      release = fn t ->
        t
        |> Ecto.Changeset.change(workflow: Map.put(t.workflow, "release", true))
        |> Repo.update!()
      end

      {:ok, milestone} = Operator.create_milestone(project, user, %{name: "Goal"})
      {:ok, placed} = Operator.set_milestone(ticket, user, milestone.id)
      {:ok, other} = Tickets.admit(project, %{title: "Other", body: "."}, {:user, user.id})
      other = release.(other)
      placed |> release.() |> rest_in("merged", :done)
      {:ok, _closed} = Operator.close_milestone(project, user, milestone.id)

      assert {:error, {:release_open, %{id: id}}} =
               Operator.transition(fresh(ticket), user, "merged")

      assert id == other.id
      assert fresh(ticket).status == :done
      assert fresh(ticket).milestone_id == milestone.id

      {:ok, _} = Engine.cancel(other, {:user, user.id})
      assert {:ok, _moved} = Operator.transition(fresh(ticket), user, "merged")
      assert fresh(ticket).milestone_id == nil
    end

    test "merging at once", context do
      guarded_reopening!(context, ready!(context))
    end

    test "into a conflict", context do
      ticket = ready!(context, "README.md")
      commit_to(context.bare, "main", %{"README.md" => "the trunk's\n"}, "another ticket")
      guarded_reopening!(context, ticket)
      assert fresh(ticket).state == "integrating"
    end

    @tag queue: true
    test "into the merge line", context do
      guarded_reopening!(context, ready!(context))
      assert %{jump: true} = MergeQueue.entry(context.ticket)
    end

    test "an open release's own jump is not a reopening, and meets no check", context do
      %{user: user, ticket: ticket} = context
      document!(ticket, "plan.md")

      release =
        ticket
        |> Ecto.Changeset.change(workflow: Map.put(ticket.workflow, "release", true))
        |> Repo.update!()
        |> rest_in("refining")

      assert {:ok, %{state: "implementing"}} = Operator.transition(release, user, "implementing")
    end
  end

  describe "a done ticket jumped back into its merging state" do
    test "is not in conflict with its own landed work", context do
      %{user: user, bare: bare} = context
      ticket = ready!(context, "README.md")

      assert {:ok, %{state: "merged", status: :done}} =
               Operator.transition(ticket, user, "merged")

      landed = head!(bare)

      # The default branch has touched the file the ticket landed since.
      later = commit_to(bare, "main", %{"README.md" => "something later\n"}, "later")
      assert later != landed

      assert {:ok, again} = Operator.transition(fresh(ticket), user, "merged")
      assert again.state == "merged"
      assert again.status == :done
      assert events_of(ticket, "ticket.merge_conflicted") == []
      assert head!(bare) == later
    end

    test "Merge.check calls a source that has landed clean, and one that conflicts a conflict",
         context do
      %{user: user, bare: bare, project: project} = context
      {:ok, other} = Tickets.admit(project, %{title: "Other", body: "."}, {:user, user.id})
      ticket = ready!(context, "README.md")
      {:ok, _} = Operator.transition(ticket, user, "merged")
      commit_to(bare, "main", %{"README.md" => "something later\n"}, "later")
      {:ok, %{sha: landed}} = Forge.Merge.changeset(fresh(ticket))
      assert Forge.Merge.check(fresh(ticket), landed) == :ok

      sha = commit_over_http(project, other.branch, "README.md", "the other's version")
      assert {:conflict, ["README.md"], _head} = Forge.Merge.check(other, sha)
    end
  end

  describe "taking a queued jump out of a terminal state" do
    @tag queue: true
    test "leaves a done ticket stuck, not active in a state with no way out", context do
      %{user: user} = context
      ticket = ready!(context)
      done = rest_in(ticket, "merged", :done)

      assert {:ok, queued} = Operator.transition(done, user, "merged")
      assert queued.status == :active
      assert %{jump: true} = MergeQueue.entry(ticket)

      assert {:ok, out} = Operator.take_out(fresh(ticket), user)
      assert out.state == "merged"
      assert out.status == :stuck
      assert MergeQueue.entry(ticket) == nil
    end
  end

  describe "a jump on a held ticket (criterion 2)" do
    test "is refused for a missing required input, and kept for the release otherwise",
         context do
      %{user: user, ticket: ticket} = context
      ticket = rest_in(ticket, "refining")
      {:ok, held} = Operator.hold(ticket, user)

      assert {:error, {:missing_input, "plan.md"}} =
               Operator.transition(held, user, "implementing")

      assert fresh(ticket).state == "refining"
      assert fresh(ticket).held_entry == nil

      document!(ticket, "plan.md")
      assert {:ok, moved} = Operator.transition(fresh(ticket), user, "implementing")
      assert moved.state == "implementing"
      assert %{"state" => "implementing"} = fresh(ticket).held_entry

      assert {:ok, released} = Operator.release(fresh(ticket), user)
      assert released.state == "implementing"
      assert %{state: "implementing"} = pending(released)
    end
  end

  describe "a reopening left half-written (criterion 10)" do
    test "is finished by the next one, which moves the base and not the branch again",
         context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")
      done = fresh(ticket)
      merged = latest_payload(ticket, "ticket.merged")["sha"]
      document!(ticket, "plan.md")

      assert {:ok, reopened} = Operator.transition(done, user, "implementing")
      {:ok, carried} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      assert reopened.base_commit == merged
      assert Git.resolve(bare, carried <> "^2") == {:ok, merged}

      # The commit failed after the branch moved: the branch is at the carry, the base is not.
      broken =
        rest_in(reopened, "merged", :done)
        |> Ecto.Changeset.change(base_commit: done.base_commit)
        |> Repo.update!()

      assert {:ok, again} = Operator.transition(broken, user, "implementing")
      assert again.base_commit == merged
      assert Git.resolve(bare, "refs/heads/" <> ticket.branch) == {:ok, carried}
    end

    # An integrating job merges the default branch into the ticket's, which then holds the earlier
    # merge as an ancestor without a carry commit: nothing is unfinished, and the base stays.
    test "a branch that merely contains the merge has nothing to carry", context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")
      merged = latest_payload(ticket, "ticket.merged")["sha"]
      later = commit_to(bare, "main", %{"later.txt" => "later\n"}, "later")

      work = Path.join(tmp_dir("merge-main"), "work")
      {_out, 0} = git(Path.dirname(work), ["clone", "-q", "--branch", ticket.branch, bare, work])

      {_out, 0} =
        git(work, [
          "-c",
          "user.name=j",
          "-c",
          "user.email=j@f",
          "merge",
          "-q",
          "--no-edit",
          "origin/main"
        ])

      {_out, 0} = git(work, ["push", "-q", "origin", "HEAD:refs/heads/" <> ticket.branch])
      {:ok, head} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      assert Git.ancestor?(bare, merged, head)
      assert Git.resolve(bare, head <> "^2") == {:ok, later}
      refute later == merged

      document!(ticket, "plan.md")
      base = fresh(ticket).base_commit
      assert {:ok, reopened} = Operator.transition(fresh(ticket), user, "implementing")
      assert reopened.base_commit == base
      assert events_of(ticket, "ticket.base_moved") == []
      assert Git.resolve(bare, "refs/heads/" <> ticket.branch) == {:ok, head}
    end

    test "a ticket that already carries its merge is carried no further", context do
      %{user: user, bare: bare} = context
      ticket = ready!(context)
      assert {:ok, %{status: :done}} = Operator.transition(ticket, user, "merged")
      document!(ticket, "plan.md")

      assert {:ok, reopened} = Operator.transition(fresh(ticket), user, "implementing")
      {:ok, carried} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      base_moved = length(events_of(ticket, "ticket.base_moved"))

      assert {:ok, _again} =
               Operator.transition(rest_in(reopened, "merged", :done), user, "implementing")

      assert Git.resolve(bare, "refs/heads/" <> ticket.branch) == {:ok, carried}
      assert length(events_of(ticket, "ticket.base_moved")) == base_moved
    end
  end
end
