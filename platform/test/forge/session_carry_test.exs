defmodule Forge.SessionCarryTest do
  @moduledoc """
  The harness session a resume needs, carried between machines, from the platform's side
  (`docs/design/claude-code-events.md` § Resume): what a run reports it uploaded, what a resume's
  assignment names, when a new attempt forks its predecessor's session and when it does not, and
  a conversation resuming after it was reopened.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Engine, Events, FakeWorker, Jobs, Storage, Tickets}
  alias Forge.Jobs.Job

  @workflow """
  version: 1
  initial: implementing
  states:
    implementing:
      prompt: agents/implement.md
      inputs: [ticket, review.md]
      produces: [implementation.md, changeset]
      budget: { turns: 200, cost: 10.00 }
    reviewing:
      prompt: agents/review.md
      inputs: [implementation.md, changeset]
      produces: [review.md]
      outcomes: [done, changes_requested]
      budget: { turns: 60, cost: 3.00 }
    review_ready: {}
  transitions:
    - { from: implementing,  to: reviewing }
    - { from: reviewing,     to: review_ready }
    - { from: reviewing,     to: implementing, when: changes_requested, max: 3 }
    - { from: implementing,  to: implementing, when: budget_exhausted,   max: 1 }
    - { from: implementing,  to: implementing, when: did_not_converge,   max: 1 }
  limits:
    ticket_cost: 25.00
  """

  setup do
    repo =
      seeded_repo(%{
        ".forge/workflow.yml" => @workflow,
        ".forge/agents/review.md" => "Review the change.\n"
      })

    {:ok, project} =
      register_owned!(%{name: "carry-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, {:user, user.id})
    %{ticket: ticket, user: user, project: project, worker: FakeWorker.connect()}
  end

  defp pending(ticket) do
    [job] = ticket.id |> Jobs.for_ticket() |> Enum.filter(&(&1.status == :pending))
    job
  end

  # What the worker reports when it uploaded the run's session: the first file under the prefix
  # the assignment named, and the version that wrote it.
  defp uploaded(assignment, id \\ "sess-42"),
    do: %{
      "session_id" => id,
      "session_blob" => assignment["store"]["session_prefix"] <> "1.jsonl",
      "version" => "2.1.284"
    }

  # One run of `ticket`'s pending job, writing `name` with `outcome` and uploading its session.
  defp run(ticket, worker, name, outcome, id \\ "sess-42") do
    assignment = ticket |> pending() |> FakeWorker.assign(worker)
    written = %{name => "---\noutcome: #{outcome}\n---\n# #{name}\n"}

    {:ok, job} =
      FakeWorker.finish(assignment, "success",
        written: written,
        harness: uploaded(assignment, id)
      )

    {Tickets.get!(ticket.id), job, assignment}
  end

  describe "what a run leaves" do
    # A command's assignment has none: `Forge.CommandsTest`.
    test "a run is given a prefix to upload its session under", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      prefix = assignment["store"]["session_prefix"]
      job_id = assignment["job_id"]

      assert "job/" <> ^job_id <> "/session-" <> _nonce = prefix
      assert String.ends_with?(prefix, "/")

      assert :ok =
               Storage.Token.verify(
                 assignment["store"]["session_token"],
                 :put,
                 prefix <> "1.jsonl"
               )

      assert assignment["resume_session"] == nil
      refute Map.has_key?(assignment, "session")
    end

    test "the session a run uploaded is recorded with the version that wrote it", context do
      {_ticket, job, assignment} =
        run(context.ticket, context.worker, "implementation.md", "done")

      assert Jobs.get!(job.id).session_blob == %{
               "key" => assignment["store"]["session_prefix"] <> "1.jsonl",
               "version" => "2.1.284"
             }
    end

    # The worker names the key; one outside the job's own prefix would hand a later resume
    # another job's session.
    test "a key outside the job's own prefix is not recorded", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      written = %{"implementation.md" => "---\noutcome: done\n---\n# I\n"}

      harness = %{"session_blob" => "job/someone-else/session-x/1.jsonl", "version" => "2.1.284"}
      {:ok, job} = FakeWorker.finish(assignment, "success", written: written, harness: harness)

      assert Jobs.get!(job.id).session_blob == nil
    end

    # Under the prefix as a string, and out of it as a path.
    test "a key that climbs out of the job's own prefix is not recorded", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      written = %{"implementation.md" => "---\noutcome: done\n---\n# I\n"}

      climbing =
        assignment["store"]["session_prefix"] <> "../../../someone-else/session-x/1.jsonl"

      harness = %{"session_blob" => climbing, "version" => "2.1.284"}
      {:ok, job} = FakeWorker.finish(assignment, "success", written: written, harness: harness)

      assert Jobs.get!(job.id).session_blob == nil
    end
  end

  describe "a resume of the same job" do
    test "names the session to put back, with a token to fetch it, and does not fork", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      {:ok, parked} = FakeWorker.park(assignment, [], harness: uploaded(assignment))
      assert parked.status == :pending

      again = FakeWorker.assign(Jobs.get!(parked.id), context.worker)
      key = assignment["store"]["session_prefix"] <> "1.jsonl"

      assert again["resume_session"] == "sess-42"
      assert again["fork_session"] == false

      assert %{"key" => ^key, "id" => "sess-42", "version" => "2.1.284", "token" => token} =
               again["session"]

      assert :ok = Storage.Token.verify(token, :get, key)

      # What each run was asked to do, in the job's timeline.
      assert [false, true] =
               parked.id
               |> Events.for_job()
               |> Enum.filter(&(&1.type == "job.started"))
               |> Enum.map(& &1.payload["resume"])
    end

    # A run whose upload failed leaves the job's session as the last one that did, which a later
    # resume still finds.
    test "that uploaded nothing keeps the session the run before it left", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      {:ok, parked} = FakeWorker.park(assignment, [], harness: uploaded(assignment))
      kept = Jobs.get!(parked.id).session_blob

      again = FakeWorker.assign(Jobs.get!(parked.id), context.worker)
      {:ok, _parked} = FakeWorker.park(again, [], harness: %{"session_id" => "sess-42"})

      assert Jobs.get!(parked.id).session_blob == kept
    end
  end

  describe "a new attempt" do
    # The rework lap: the reviewer sent it back, and the implementer's second attempt starts with
    # the first one's conversation rather than re-deriving it.
    test "that came back forks the previous attempt's session", context do
      {ticket, first, first_assignment} =
        run(context.ticket, context.worker, "implementation.md", "done", "sess-impl")

      {ticket, _review, _} =
        run(ticket, context.worker, "review.md", "changes_requested", "sess-rev")

      assert ticket.state == "implementing"

      second = pending(ticket)
      assert second.attempt == 2
      assert second.resume_from_id == first.id

      assignment = FakeWorker.assign(second, context.worker)
      assert assignment["resume_session"] == "sess-impl"
      assert assignment["fork_session"] == true

      assert assignment["session"]["key"] ==
               first_assignment["store"]["session_prefix"] <> "1.jsonl"

      # Once it has run, it resumes its own session, and forks nothing.
      {:ok, _parked} =
        FakeWorker.park(assignment, [], harness: uploaded(assignment, "sess-impl-2"))

      again = FakeWorker.assign(Jobs.get!(second.id), context.worker)
      assert again["resume_session"] == "sess-impl-2"
      assert again["fork_session"] == false
    end

    # The retry lap: a state's own `budget_exhausted` self-loop sends the ticket back into the
    # state it just ran out of budget in, and the second attempt starts with the first's
    # conversation instead of paying again for the reading that produced it. `dev.yml` declares
    # one for `refining`, `planning`, `implementing` and `reviewing` — not for every prompted
    # state: `integrating` has a budget of its own and no self-loop, so a budget stop there
    # sticks the ticket and reaches none of this. The three outcomes that still start fresh are
    # the tests below and after.
    test "after one that ran out of budget forks its session", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)

      {:ok, first} =
        FakeWorker.finish(assignment, "max_budget", harness: uploaded(assignment, "sess-impl"))

      assert first.outcome == :budget_exhausted

      ticket = Tickets.get!(context.ticket.id)
      assert %{state: "implementing", status: :active} = ticket

      second = pending(ticket)
      assert second.attempt == 2
      assert second.resume_from_id == first.id

      resumed = FakeWorker.assign(second, context.worker)
      assert resumed["resume_session"] == "sess-impl"
      assert resumed["fork_session"] == true
      assert resumed["session"]["key"] == assignment["store"]["session_prefix"] <> "1.jsonl"
    end

    # The self-loop's `max: 1` is what bounds a budget stop that repeats, and it is the bound the
    # fork rule leans on rather than replacing: the second attempt running out too is stuck, not
    # a third fork.
    test "that ran out of budget twice is not given a third", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      {:ok, _first} = FakeWorker.finish(assignment, "max_budget", harness: uploaded(assignment))

      second = Tickets.get!(context.ticket.id) |> pending() |> FakeWorker.assign(context.worker)
      {:ok, _second} = FakeWorker.finish(second, "max_budget", harness: uploaded(second))

      assert %{state: "implementing", status: :stuck} = Tickets.get!(context.ticket.id)
    end

    # The sibling self-loop, and the line budget stops are on the other side of: `dev.yml` sends a
    # state back into itself on `did_not_converge` too, and that attempt starts cold. The agent
    # reached no outcome, so whatever stopped it reaching one is in the session a fork would
    # carry.
    test "after one that reported it did not converge starts fresh", context do
      assignment = context.ticket |> pending() |> FakeWorker.assign(context.worker)
      written = %{"implementation.md" => "---\noutcome: did_not_converge\n---\n# I\n"}

      {:ok, first} =
        FakeWorker.finish(assignment, "success",
          written: written,
          harness: uploaded(assignment, "sess-impl")
        )

      assert first.outcome == :did_not_converge
      assert Jobs.get!(first.id).session_blob, "there was a session to fork, and it was not"

      ticket = Tickets.get!(context.ticket.id)
      assert %{state: "implementing", status: :active} = ticket
      assert pending(ticket).resume_from_id == nil
    end

    # Criterion-for-criterion, the rest of what stays out. The predecessor is written to the
    # outcome under test rather than driven to it — `cancelled` has no came_back path of its own
    # (a cancelled ticket is restored `stuck`, and *Run again* does not fork), so the row is the
    # only way to put `forkable/4` in front of one. Add any of these three to its `in` list and
    # the case for it fails.
    for outcome <- [:did_not_converge, :error, :cancelled] do
      test "after one recorded #{outcome} starts fresh", context do
        {ticket, first, _} = run(context.ticket, context.worker, "implementation.md", "done")
        first |> Ecto.Changeset.change(outcome: unquote(outcome)) |> Repo.update!()

        {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")

        assert ticket.state == "implementing"
        assert pending(ticket).resume_from_id == nil
      end
    end

    # A fork remembers the instructions its session began with, and is told they are its own. A
    # re-pin that moved the state's prompt, or a platform upgrade that changed the preamble, makes
    # that untrue, so the new attempt starts fresh.
    for {key, other} <- [{"prompt", "Implement it another way.\n"}, {"preamble_hash", "sha256:0"}] do
      test "after an attempt given another #{key} starts fresh", context do
        {ticket, first, _} = run(context.ticket, context.worker, "implementation.md", "done")

        first
        |> Ecto.Changeset.change(spec: Map.put(first.spec, unquote(key), unquote(other)))
        |> Repo.update!()

        {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")

        assert ticket.state == "implementing"
        assert pending(ticket).resume_from_id == nil
      end
    end

    test "a second review forks the first review's, never the implementer's", context do
      {ticket, _impl, _} =
        run(context.ticket, context.worker, "implementation.md", "done", "sess-impl")

      {ticket, review, _} =
        run(ticket, context.worker, "review.md", "changes_requested", "sess-rev")

      {ticket, _impl2, _} =
        run(ticket, context.worker, "implementation.md", "done", "sess-impl-2")

      second_review = pending(ticket)
      assert second_review.state == "reviewing"
      assert second_review.resume_from_id == review.id
      assert FakeWorker.assign(second_review, context.worker)["resume_session"] == "sess-rev"
    end

    # A person's "Run again" is a request to redo, and it is what they reach for after a failure.
    # Asked here of an attempt that converged and left a session — one a fork would take — resting
    # on an approval, which is where "Run again" is offered after a success.
    test "that a person asked for starts fresh", %{user: user, worker: worker} do
      workflow =
        String.replace(
          @workflow,
          "- { from: implementing,  to: reviewing }",
          "- { from: implementing,  to: reviewing, approve: [implementation.md] }"
        )

      repo =
        seeded_repo(%{".forge/workflow.yml" => workflow, ".forge/agents/review.md" => "R.\n"})

      {:ok, project} =
        register_owned!(%{name: "again-#{System.unique_integer([:positive])}", repo_path: repo})

      join!(project, user)
      funded!(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Again", body: "."}, {:user, user.id})

      {ticket, first, _} = run(ticket, worker, "implementation.md", "done")
      assert ticket.state == "implementing" and is_map(ticket.pending_transition)
      assert Jobs.get!(first.id).session_blob

      {:ok, _ticket} = Engine.retry(ticket, user.id)
      again = pending(ticket)

      assert again.attempt == 2
      assert again.resume_from_id == nil
      assert FakeWorker.assign(again, worker)["resume_session"] == nil
    end

    test "after an attempt that did not converge starts fresh", context do
      {ticket, _impl, _} = run(context.ticket, context.worker, "implementation.md", "done")
      assignment = ticket |> pending() |> FakeWorker.assign(context.worker)

      # A review that wrote nothing it declared: `error`, and the ticket is stuck in reviewing.
      {:ok, _failed} = FakeWorker.finish(assignment, "nothing", harness: uploaded(assignment))
      stuck = Tickets.get!(ticket.id)
      assert stuck.status == :stuck

      {:ok, _ticket} = Engine.choose(stuck, context.user.id, "implementing")

      {ticket, _impl2, _} =
        run(Tickets.get!(ticket.id), context.worker, "implementation.md", "done")

      assert pending(ticket).resume_from_id == nil
    end

    # Only the attempt just before: a third after a second that did not converge does not reach
    # back past it to the first, whose session is two rounds out of date.
    test "after a failed attempt, does not fork the one before it", context do
      {ticket, _impl, _} = run(context.ticket, context.worker, "implementation.md", "done")
      {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")
      second = FakeWorker.assign(pending(ticket), context.worker)
      assert second["fork_session"] == true

      {:ok, _failed} = FakeWorker.finish(second, "nothing", harness: uploaded(second))
      stuck = Tickets.get!(ticket.id)
      assert %{state: "implementing", status: :stuck} = stuck

      {:ok, _ticket} = Engine.choose(stuck, context.user.id, "reviewing")

      {ticket, _review, _} =
        run(Tickets.get!(ticket.id), context.worker, "review.md", "changes_requested")

      third = pending(ticket)
      assert third.attempt == 3
      assert third.resume_from_id == nil
    end

    test "after one that left no session id starts fresh", context do
      {ticket, first, _} = run(context.ticket, context.worker, "implementation.md", "done")
      first |> Ecto.Changeset.change(harness_session_id: nil) |> Repo.update!()
      {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")

      assert pending(ticket).resume_from_id == nil
    end

    test "after one that left no session file starts fresh", context do
      {ticket, first, _} = run(context.ticket, context.worker, "implementation.md", "done")
      first |> Ecto.Changeset.change(session_blob: nil) |> Repo.update!()
      {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")

      assert pending(ticket).resume_from_id == nil
    end

    # A fork the machine could not honour is re-queued as any refused resume is, and tried once.
    test "whose fork is refused is re-queued fresh, and forks no more", context do
      {ticket, _first, _} = run(context.ticket, context.worker, "implementation.md", "done")
      {ticket, _review, _} = run(ticket, context.worker, "review.md", "changes_requested")
      second = pending(ticket)
      assignment = FakeWorker.assign(second, context.worker)

      {:ok, requeued} = FakeWorker.finish(assignment, "no_start")

      assert %Job{status: :pending, resume_from_id: nil, harness_session_id: nil} = requeued
      assert FakeWorker.assign(requeued, context.worker)["resume_session"] == nil
    end
  end

  describe "a conversation" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "first")
      %{chat: chat}
    end

    # Stopped the way an idle timeout leaves one: hibernated, with its session on the row.
    defp dormant(chat),
      do: chat.id |> Jobs.get!() |> Ecto.Changeset.change(status: :hibernated) |> Repo.update!()

    defp turn(chat, turn, harness),
      do: Conversations.record_turn(Jobs.get!(chat.id), %{"turn" => turn, "harness" => harness})

    test "records the session each turn uploaded", %{chat: chat} do
      key = "job/#{chat.id}/session-abc/1.jsonl"

      {:ok, _chat} =
        turn(chat, 1, %{"session_id" => "s1", "session_blob" => key, "version" => "2.1.284"})

      assert Jobs.get!(chat.id).session_blob == %{"key" => key, "version" => "2.1.284"}
    end

    # `docs/design/conversations.md` § Lifetime: reopening keeps the session, and the new process
    # resumes it as a fork — its turns are numbered from one again.
    test "reopened, resumes its carried session as a fork", %{chat: chat} do
      key = "job/#{chat.id}/session-abc/2.jsonl"

      {:ok, _chat} =
        turn(chat, 1, %{"session_id" => "s1", "session_blob" => key, "version" => "2.1.284"})

      {:ok, reopened} = Conversations.reopen(dormant(chat))

      assert reopened.harness_session_id == "s1"
      assert Jobs.resume_source(reopened) == {"s1", %{"key" => key, "version" => "2.1.284"}, true}
    end

    test "with no session carried, reopened, resumes nothing", %{chat: chat} do
      {:ok, _chat} = turn(chat, 1, %{"session_id" => "s1"})
      {:ok, reopened} = Conversations.reopen(dormant(chat))

      assert Jobs.resume_source(reopened) == nil
    end
  end
end
