defmodule Forge.HoldTest do
  @moduledoc """
  A ticket on hold (`docs/design/workflow-grammar-v1.md` § Holding a ticket): while it is, the
  platform takes no step on it by itself, and releasing it does what waited.

  Each test aims at the guard it names: the dispatch gate (`Forge.Jobs.pending/2` and the
  placement), the deferral of what the engine would make, the transition that waits and is taken
  at release, stop now, the merge queue's skip and the refresh of a ticket that never started.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Engine, Events, FakeWorker, Git, Jobs, MergeQueue, Operator, Tickets}
  alias Forge.Jobs.Job
  alias Forge.MergeQueue.Entry

  setup do
    repo = seeded_repo()

    {:ok, project} =
      register_owned!(%{name: "hold-#{System.unique_integer([:positive])}", repo_path: repo})

    user = member_fixture(project)
    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    %{project: project, user: user, repo: repo, worker: FakeWorker.connect()}
  end

  defp admit!(project, user, opts \\ []) do
    attrs = Map.merge(%{title: "An idea", on_hold: false}, Map.new(opts))
    {:ok, ticket} = Operator.admit(project, user, attrs)
    ticket
  end

  defp pending(ticket), do: Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
  defp types(ticket), do: ticket.id |> Events.for_ticket() |> Enum.map(& &1.type)

  # Refined and approved, so the ticket is in `planning` with its job pending.
  defp in_planning!(ticket, user, worker) do
    [job] = pending(ticket)
    {:ok, _} = FakeWorker.run(job, worker, "success", doc: "refinement.md")
    {:ok, ticket} = Engine.decide(Tickets.get!(ticket.id), user.id, :approved, "ok")
    assert ticket.state == "planning"
    ticket
  end

  describe "hold and release" do
    test "each is an event naming who, and doing either twice is refused", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user)

      {:ok, held} = Operator.hold(ticket, user)
      assert held.held_at
      assert {:error, :already_on_hold} = Operator.hold(held, user)

      assert %{actor: %{"kind" => "user", "id" => id}} =
               ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.held"))

      assert id == user.id

      {:ok, released} = Operator.release(held, user)
      assert released.held_at == nil
      assert {:error, :not_on_hold} = Operator.release(released, user)
      assert "ticket.released" in types(ticket)
    end

    test "a second release from a stale struct is refused: one release happens", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user)
      {:ok, held} = Operator.hold(ticket, user)

      assert {:ok, _} = Operator.release(held, user)
      # The struct still says held; the row does not.
      assert held.held_at
      assert {:error, :not_on_hold} = Operator.release(held, user)
      assert length(Enum.filter(types(ticket), &(&1 == "ticket.released"))) == 1
    end

    test "a ticket that is not open cannot be held", %{project: project, user: user} do
      ticket = admit!(project, user)
      {:ok, _} = Engine.cancel(ticket, user.id)
      assert {:error, {:not_holdable, :cancelled}} = Operator.hold(Tickets.get!(ticket.id), user)
    end
  end

  describe "nothing starts on a ticket on hold" do
    test "its pending job is not offered and is not placed", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      assert job.id in Enum.map(Jobs.pending(), & &1.id)

      {:ok, held} = Operator.hold(ticket, user)
      refute job.id in Enum.map(Jobs.pending(), & &1.id)

      # The pass read the row before the hold: placing it is refused under the lock.
      assert {:error, {:changed, :held}} = Jobs.assign(job, worker)
      assert %Job{status: :pending} = Jobs.get!(job.id)

      {:ok, _} = Operator.release(held, user)
      assert job.id in Enum.map(Jobs.pending(), & &1.id)
    end

    test "a held ticket's pending job reserves none of the day's allowance", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user)
      reserved = Forge.Spend.committed()
      assert reserved > 0

      {:ok, held} = Operator.hold(ticket, user)
      assert Forge.Spend.committed() == reserved - 100_000

      {:ok, _} = Operator.release(held, user)
      assert Forge.Spend.committed() == reserved
    end

    test "a job resumed by an answer waits for the release", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      {:ok, _} = FakeWorker.run(job, worker, "blocking", doc: "refinement.md")
      assert [%Job{status: :waiting} = waiting] = Jobs.for_ticket(ticket.id)

      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      [%{key: key} | _] = Forge.Artifacts.open_questions(ticket.id)
      {:ok, _} = Operator.answer(held, user, key, %{choice: nil, text: "yes"})

      assert %Job{status: :pending} = Jobs.get!(waiting.id)
      refute waiting.id in Enum.map(Jobs.pending(), & &1.id)
    end

    test "entering a chat step opens no conversation while held; it opens at release", %{
      user: user
    } do
      workflow = """
      version: 1
      initial: refining
      states:
        refining:
          prompt: agents/refine.md
          produces: [refinement.md]
          budget: { turns: 20, tokens: 100k }
        talking:
          chat: true
          prompt: agents/plan.md
        finished: {}
      transitions:
        - { from: refining, to: talking }
        - { from: talking, to: finished }
      limits:
        ticket_tokens: 5M
      """

      repo = seeded_repo(%{".forge/workflow.yml" => workflow})

      {:ok, project} =
        register_owned!(%{name: "chat-#{System.unique_integer([:positive])}", repo_path: repo})

      join!(project, user)
      funded!(project)
      worker = FakeWorker.connect()

      ticket = admit!(project, user)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, held} = Operator.hold(ticket, user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      # The outcome is recorded; the transition waits, so no conversation is opened.
      held = Tickets.get!(held.id)
      assert held.state == "refining"
      assert %{"to" => "talking"} = held.held_transition
      assert Forge.Steps.live(held) == nil

      {:ok, released} = Operator.release(held, user)
      assert released.state == "talking"
      assert %Job{kind: :chat, state: "talking"} = Forge.Steps.live(released)
    end
  end

  describe "a run that finishes while its ticket is on hold" do
    test "its transition waits, with its outcome, and is taken at release", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)

      {:ok, _held} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "plan.md")

      waiting = Tickets.get!(ticket.id)
      assert waiting.state == "planning"
      assert waiting.status == :active
      assert %{"outcome" => _, "to" => "implementing", "job_id" => _} = waiting.held_transition
      assert pending(ticket) == []
      assert "transition.held" in types(ticket)
      assert %Job{status: :finished} = Jobs.get!(job.id)

      assert {:transition, "planning", "implementing", _} = Engine.waiting_on_release(waiting)

      {:ok, released} = Operator.release(waiting, user)
      assert released.state == "implementing"
      assert released.held_transition == nil
      assert [%Job{state: "implementing"}] = pending(ticket)

      # What the hold carried is gone from the row, not only from the struct the release returns:
      # a later hold and release in the same state must not replay it.
      assert %{held_at: nil, held_transition: nil, held_entry: nil} = Tickets.get!(ticket.id)
    end

    # Where the release's own clearing of `held_transition` is not redundant with the replay's: when
    # the job it names is not there, `put_replay` takes no transition and writes nothing to the
    # column.
    test "a waiting transition whose job is gone is dropped at release, not left on the row", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, _} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "plan.md")

      waiting = Tickets.get!(ticket.id)
      gone = Map.put(waiting.held_transition, "job_id", Ecto.UUID.generate())

      Forge.Repo.update_all(Forge.Tickets.Ticket,
        set: [held_transition: gone]
      )

      {:ok, _released} = Operator.release(Tickets.get!(ticket.id), user)
      assert %{state: "planning", held_transition: nil} = Tickets.get!(ticket.id)
    end

    test "a transition that needs approval becomes a pending approval, as it does today", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)

      {:ok, _} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      held = Tickets.get!(ticket.id)
      assert %{"to" => "planning"} = held.pending_transition
      assert held.held_transition == nil
      assert held.held_at
    end

    test "the engine's own retry edge waits too: no retry on a ticket on hold", %{
      user: user,
      worker: worker
    } do
      workflow = """
      version: 1
      initial: working
      states:
        working:
          prompt: agents/implement.md
          produces: [implementation.md]
          outcomes: [done]
          budget: { turns: 20, tokens: 100k }
        finished: {}
      transitions:
        - { from: working, to: working, when: budget_exhausted, max: 3 }
        - { from: working, to: finished }
      limits:
        ticket_tokens: 5M
      """

      repo = seeded_repo(%{".forge/workflow.yml" => workflow})

      {:ok, project} =
        register_owned!(%{name: "loop-#{System.unique_integer([:positive])}", repo_path: repo})

      join!(project, user)
      funded!(project)
      ticket = admit!(project, user)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, _} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "max_turns")

      waiting = Tickets.get!(ticket.id)
      assert waiting.held_transition
      assert pending(ticket) == []

      {:ok, _} = Operator.release(waiting, user)
      assert [%Job{attempt: 2}] = pending(ticket)
    end
  end

  describe "stop now" do
    test "stops the run, tells the machine, and release runs the state again", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      job_id = assignment["job_id"]

      assert {:error, :not_on_hold} = Operator.stop_now(Tickets.get!(ticket.id), user)
      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      assert Engine.stoppable?(held)

      {:ok, stopped} = Operator.stop_now(held, user)
      assert_receive {:cancel, ^job_id, :ticket_cancelled}, 1_000
      assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(job_id)
      assert stopped.held_entry["state"] == "planning"
      # Run again as a retry runs it, not as a state the ticket came back to.
      assert stopped.held_entry["came_back"] == false
      refute Engine.stoppable?(stopped)
      assert {:error, :nothing_running} = Operator.stop_now(stopped, user)
      assert "ticket.stopped" in types(ticket)

      # The worker's late report settles the run and changes nothing else.
      {:ok, _} = Jobs.hibernate(job_id, nil, "cancelled")
      assert Tickets.get!(ticket.id).state == "planning"

      {:ok, released} = Operator.release(Tickets.get!(ticket.id), user)
      assert released.state == "planning"
      assert [%Job{state: "planning", attempt: 2}] = pending(ticket)
      assert %{held_at: nil, held_transition: nil, held_entry: nil} = Tickets.get!(ticket.id)
    end
  end

  describe "a person's own moves on a ticket on hold" do
    test "a move by hand replaces the transition that waited and starts nothing", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, _} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "plan.md")
      assert Tickets.get!(ticket.id).held_transition

      {:ok, moved} = Operator.transition(Tickets.get!(ticket.id), user, "implementing")
      assert moved.state == "implementing"
      assert moved.held_transition == nil
      assert moved.held_at
      assert pending(ticket) == []
      assert moved.held_entry["state"] == "implementing"

      {:ok, released} = Operator.release(moved, user)
      assert released.state == "implementing"
      # One job, from the entry: the waiting transition was not taken as well.
      assert [%Job{state: "implementing"}] = pending(ticket)
    end

    test "retrying a state on a ticket on hold waits for the release", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      {:ok, _} = FakeWorker.run(job, worker, "invalid_document", doc: "plan.md")
      stuck = Tickets.get!(ticket.id)
      assert stuck.status == :stuck

      {:ok, held} = Operator.hold(stuck, user)
      {:ok, retried} = Operator.retry(held, user)
      assert retried.held_entry["state"] == "planning"
      assert pending(ticket) == []

      {:ok, _} = Operator.release(retried, user)
      assert [%Job{state: "planning"}] = pending(ticket)
    end
  end

  describe "cancelling and restoring" do
    test "cancelling drops a transition that waited, and restoring does not bring it back", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user) |> in_planning!(user, worker)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "plan.md")
      assert Tickets.get!(ticket.id).held_transition

      {:ok, cancelled} = Operator.cancel(Tickets.get!(held.id), user)
      assert %{held_at: held_at, held_transition: nil, held_entry: nil} = cancelled
      assert held_at

      {:ok, restored} = Operator.restore(cancelled, user)
      assert %{state: "planning", held_transition: nil} = Tickets.get!(restored.id)

      {:ok, released} = Operator.release(Tickets.get!(restored.id), user)
      assert released.state == "planning"
    end

    test "a restored ticket that was on hold is on hold again, and nothing waits", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user, on_hold: true)
      {:ok, cancelled} = Operator.cancel(ticket, user)
      assert cancelled.held_at
      assert cancelled.held_entry == nil
      assert {:error, {:not_releasable, :cancelled}} = Operator.release(cancelled, user)

      {:ok, restored} = Operator.restore(cancelled, user)
      assert restored.status == :stuck
      assert restored.held_at
    end
  end

  describe "the merge queue" do
    defp enqueue!(ticket, position) do
      Forge.Repo.insert!(%Entry{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        position: position,
        from_state: ticket.state,
        to_state: "merged",
        edge_outcome: "done",
        changeset_sha: String.duplicate("a", 40),
        changeset_version: 1,
        status: :waiting
      })
    end

    test "a held entry keeps its place and is skipped; released, it is the front again", %{
      project: project,
      user: user
    } do
      first = admit!(project, user)
      second = admit!(project, user, title: "Another")
      enqueue!(first, 1)
      enqueue!(second, 2)

      {:ok, held} = Operator.hold(first, user)
      assert %Entry{ticket_id: id} = MergeQueue.claim(project.id)
      assert id == second.id
      assert [%{ahead: 0}, _] = MergeQueue.with_places(project.id) |> Enum.map(&elem(&1, 1))

      # Put it back, as a merge that finished does not; then the held one is still next in line.
      Forge.Repo.update_all(Entry, set: [status: :waiting])
      Forge.Repo.delete_all(from_entry(second.id))
      assert MergeQueue.claim(project.id) == nil

      {:ok, _} = Operator.release(held, user)
      assert %Entry{ticket_id: id} = MergeQueue.claim(project.id)
      assert id == first.id
    end

    test "a held entry is not ahead of the one behind it", %{project: project, user: user} do
      first = admit!(project, user)
      second = admit!(project, user, title: "Second")
      third = admit!(project, user, title: "Third")

      for {ticket, position} <- [{first, 1}, {second, 2}, {third, 3}],
          do: enqueue!(ticket, position)

      assert %{first.id => 0, second.id => 1, third.id => 2} ==
               Map.new(MergeQueue.places(project.id), fn {id, place} -> {id, place.ahead} end)

      {:ok, _} = Operator.hold(first, user)

      assert %{first.id => 0, second.id => 0, third.id => 1} ==
               Map.new(MergeQueue.places(project.id), fn {id, place} -> {id, place.ahead} end)
    end

    defp from_entry(ticket_id), do: Ecto.Query.from(e in Entry, where: e.ticket_id == ^ticket_id)
  end

  describe "a ticket admitted on hold" do
    test "runs nothing and has asked nothing; release starts its first job", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user, on_hold: true)

      assert ticket.held_at
      assert Jobs.for_ticket(ticket.id) == []
      assert ticket.held_entry == %{"state" => "refining", "entered" => nil, "came_back" => false}
      assert Git.branch_exists?(Forge.Projects.repo_path(project), ticket.branch)
      refute Tickets.started?(ticket)

      {:ok, released} = Operator.release(ticket, user)
      assert [%Job{state: "refining", attempt: 1}] = pending(released)
    end

    test "never asks anything of anyone, in the queue or the push", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user, on_hold: true)
      refute Enum.any?(Forge.Queue.items(user), &(&1.ticket && &1.ticket.id == ticket.id))
      assert Forge.Queue.for_ticket(ticket) == []
      assert Forge.Queue.worker_status(user) == []
    end

    test "choosing neither is refused and writes nothing", %{project: project, user: user} do
      assert {:error, :start_or_hold} = Operator.admit(project, user, %{title: "x"})
      assert {:error, :start_or_hold} = Operator.admit(project, user, %{title: "x", on_hold: nil})
      assert Tickets.list(project) == []
    end
  end

  describe "the refresh at a first release" do
    test "the first step runs on the workflow and the head at release, not on admission's", %{
      project: project,
      user: user,
      repo: repo
    } do
      ticket = admit!(project, user, on_hold: true)
      admitted_base = ticket.base_commit

      head =
        commit_to_default(project, %{
          ".forge/agents/refine.md" => "Refine it the new way.\n",
          "README.md" => "# New\n"
        })

      {:ok, released} = Operator.release(ticket, user)

      assert released.base_commit == head
      assert released.workflow_commit == head
      assert {:ok, ^head} = Git.resolve(repo, "refs/heads/ticket/1")
      assert [%Job{} = job] = pending(released)
      assert Jobs.spec(job).prompt == "Refine it the new way.\n"

      assert %{payload: %{"from" => ^admitted_base, "to" => ^head}} =
               ticket.id |> Events.for_ticket() |> Enum.find(&(&1.type == "ticket.refreshed"))
    end

    test "a job made before the hold, never taken, is made again on the new pin", %{
      project: project,
      user: user
    } do
      ticket = admit!(project, user)
      [old] = pending(ticket)
      {:ok, held} = Operator.hold(ticket, user)
      commit_to_default(project, %{".forge/agents/refine.md" => "Newer words.\n"})

      {:ok, released} = Operator.release(held, user)

      assert %Job{status: :finished, outcome: :cancelled} = Jobs.get!(old.id)
      assert [%Job{id: id} = fresh] = pending(released)
      assert id != old.id
      assert Jobs.spec(fresh).prompt == "Newer words.\n"
    end

    test "each refusal changes nothing and leaves the ticket on hold", %{
      project: project,
      user: user,
      repo: repo
    } do
      ticket = admit!(project, user, on_hold: true)
      before_pin = {ticket.workflow, ticket.workflow_commit, ticket.base_commit}
      commit_to_default(project, %{"README.md" => "# moved\n"})

      refuse = fn expected ->
        assert {:error, ^expected} = Operator.release(ticket, user)
        again = Tickets.get!(ticket.id)
        assert again.held_at
        assert {again.workflow, again.workflow_commit, again.base_commit} == before_pin
        assert {:ok, base} = Git.resolve(repo, "refs/heads/ticket/1")
        assert base == ticket.base_commit
      end

      # The file is gone.
      commit_to_default(project, %{".forge/workflow.yml" => nil})
      assert {:error, {:no_workflow_file, _}} = Operator.release(ticket, user)
      assert Tickets.get!(ticket.id).held_at

      # The state is renamed.
      renamed =
        File.read!(Path.join(File.cwd!(), "../core/test/fixtures/workflow_example.yml"))
        |> String.replace("refining", "scoping")

      commit_to_default(project, %{
        ".forge/workflow.yml" => renamed,
        ".forge/agents/refine.md" => "x\n"
      })

      refuse.({:no_state, "refining"})

      # The branch was moved since admission.
      commit_to_default(project, %{
        ".forge/workflow.yml" =>
          File.read!(Path.join(File.cwd!(), "../core/test/fixtures/workflow_example.yml"))
      })

      moved = commit_to(repo, "ticket/1", %{"x.txt" => "someone's work\n"})
      assert {:error, :branch_moved} = Operator.release(ticket, user)
      assert {:ok, ^moved} = Git.resolve(repo, "refs/heads/ticket/1")
      assert Tickets.get!(ticket.id).held_at
    end

    test "a ticket that has started is released as it is, pin and branch unchanged", %{
      project: project,
      user: user,
      worker: worker,
      repo: repo
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      assert Tickets.started?(Tickets.get!(ticket.id))

      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      commit_to_default(project, %{".forge/agents/refine.md" => "Changed.\n"})
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "refinement.md")

      {:ok, released} = Operator.release(Tickets.get!(held.id), user)
      assert released.workflow_commit == ticket.workflow_commit
      assert released.base_commit == ticket.base_commit
      assert {:ok, base} = Git.resolve(repo, "refs/heads/ticket/1")
      assert base == ticket.base_commit
      refute "ticket.refreshed" in types(ticket)
    end
  end

  describe "the queue, the counts and the pushes" do
    test "a held ticket that never started is in no queue list, and holding it pushes nothing", %{
      project: project,
      user: user
    } do
      Forge.Push.TestSender.watch()
      key = fn bytes -> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false) end

      {:ok, _} =
        Forge.Push.subscribe(user, %{
          "endpoint" => "https://push.example/hold",
          "keys" => %{"p256dh" => key.(65), "auth" => key.(16)}
        })

      ticket = admit!(project, user)
      assert Enum.any?(Forge.Queue.worker_status(user), &(&1.ticket.id == ticket.id))

      {:ok, held} = Operator.hold(ticket, user)

      assert Forge.Queue.worker_status(user) == []
      refute Enum.any?(Forge.Queue.items(user), &(&1.ticket && &1.ticket.id == ticket.id))
      assert Forge.Queue.for_ticket(held) == []

      Forge.Push.Watch.changed(%{}, ticket.id)
      Forge.Push.flush()
      refute_receive {:push, _endpoint, _payload, _opts}, 200
    end

    test "a decision waiting on a held ticket that has started reaches the queue", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      assignment = FakeWorker.assign(job, worker)
      {:ok, _} = FakeWorker.finish(assignment, "success", doc: "refinement.md")
      assert Tickets.started?(Tickets.get!(ticket.id))

      {:ok, held} = Operator.hold(Tickets.get!(ticket.id), user)
      assert held.pending_transition

      assert [%{kind: :approval}] = Forge.Queue.for_ticket(held)
      assert Enum.any?(Forge.Queue.items(user), &(&1.ticket && &1.ticket.id == ticket.id))
    end

    test "a held ticket never started, moved by hand to where a person decides, asks nothing", %{
      user: user
    } do
      workflow = """
      version: 1
      initial: refining
      states:
        refining:
          prompt: agents/refine.md
          produces: [refinement.md]
          budget: { turns: 20, tokens: 100k }
        deciding: {}
        finished: {}
      transitions:
        - { from: refining, to: deciding }
        - { from: deciding, to: finished }
      limits:
        ticket_tokens: 5M
      """

      repo = seeded_repo(%{".forge/workflow.yml" => workflow})

      {:ok, project} =
        register_owned!(%{name: "decide-#{System.unique_integer([:positive])}", repo_path: repo})

      join!(project, user)
      ticket = admit!(project, user, on_hold: true)
      {:ok, moved} = Operator.transition(ticket, user, "deciding")
      assert moved.held_at

      assert Forge.Queue.for_ticket(moved) == []
      refute Enum.any?(Forge.Queue.items(user), &(&1.ticket && &1.ticket.id == ticket.id))

      # Released, it is an ordinary ticket waiting on a person to move it on.
      {:ok, released} = Operator.release(Tickets.get!(ticket.id), user)
      assert [%{kind: :review}] = Forge.Queue.for_ticket(released)
    end

    test "a held ticket's running job is in no count of running work", %{
      project: project,
      user: user,
      worker: worker
    } do
      ticket = admit!(project, user)
      [job] = pending(ticket)
      FakeWorker.assign(job, worker)

      summary = fn ->
        Forge.Projects.summaries(user) |> Enum.find(&(&1.project.id == project.id))
      end

      assert summary.().running == 1

      {:ok, _} = Operator.hold(Tickets.get!(ticket.id), user)
      assert summary.().running == 0
      assert Forge.Queue.worker_status(user) == []
    end
  end
end
