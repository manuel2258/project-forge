defmodule Forge.ChatStepTest do
  @moduledoc """
  A workflow step run as a conversation (`docs/design/conversations.md` § A conversation that is a
  step): entering it opens one, nothing an agent writes moves the ticket, and Accept is the
  person's one way out.
  """

  use Forge.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{
    Artifacts,
    Conversations,
    Engine,
    Events,
    Jobs,
    Operator,
    Queue,
    Repo,
    Steps,
    Tickets
  }

  alias Forge.Jobs.Job

  @workflow """
  version: 1
  initial: refining
  states:
    refining:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      outcomes: [done, needs_more]
    planning:
      prompt: agents/plan.md
      inputs: [refinement.md]
      produces: [plan.md]
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: refining, to: review_ready, when: needs_more }
    - { from: planning, to: review_ready }
    - { from: review_ready, to: refining }
  limits: { ticket_tokens: 5M }
  """

  setup do
    {:ok, project} =
      register_owned!(%{
        name: "step-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
      })

    user = member_fixture(project)
    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    %{project: project, user: user, ticket: ticket, chat: chat}
  end

  defp turn(index, cost \\ 0.01, documents \\ %{}) do
    %{
      "turn" => index,
      "commit" => String.duplicate("a", 40),
      "documents" => documents,
      "harness" => %{
        "turns" => 1,
        "usage" => cost && round(cost * 200_000),
        "cost_usd" => cost,
        "session_id" => "s",
        "subtype" => "success"
      }
    }
  end

  # The chat running and having answered, as it is when a person looks at what it wrote.
  defp answered(chat, index, documents) do
    run!(chat)
    {:ok, chat} = Conversations.record_turn(chat, turn(index, 0.01 * index, documents))
    chat
  end

  defp seen(ticket, names),
    do:
      Map.new(
        names,
        &{&1, Artifacts.latest(ticket.id, &1) && Artifacts.latest(ticket.id, &1).version}
      )

  defp accept(chat, user, outcome, seen) do
    Operator.accept_step(Repo.get!(Job, chat.id), user, outcome, seen)
  end

  test "entering a chat step opens a conversation of the step and runs no job", %{
    ticket: ticket,
    chat: chat
  } do
    assert Jobs.for_ticket(ticket.id) == []
    assert %Job{kind: :chat, state: "refining", attempt: 1, status: :pending, spec: nil} = chat
    assert Job.step?(chat)
    assert Conversations.opened_step(chat.id)["visit"] == 1
    assert Jobs.live?(ticket.id, "refining")
  end

  test "a step needs protocol 10 and another conversation 9", %{project: project, chat: chat} do
    assert protocol_before_usage(chat) == 10
    # The kind alone, since the archive asks 9 of every conversation and would hide a step's ask.
    assert Jobs.protocol_needs(chat)[:kind] == 10
    {:ok, plain} = Conversations.open(project, "hello")
    assert protocol_before_usage(plain) == 9
    assert Jobs.protocol_needs(plain)[:kind] == 8
  end

  test "an agent's transition request is refused and the ticket stays", %{
    ticket: ticket,
    chat: chat
  } do
    run!(chat)
    payload = Map.put(turn(1), "transition_request", %{"to" => "review_ready"})
    {:ok, _chat} = Conversations.record_turn(chat, payload)

    assert Tickets.get!(ticket.id).state == "refining"

    assert [%{payload: %{"reason" => reason}}] =
             chat.id |> Events.for_job() |> Enum.filter(&(&1.type == "chat.transition_refused"))

    assert reason =~ "Accept"
  end

  test "a step's turn adds its cost to the ticket, and a plain chat's does not", %{
    ticket: ticket,
    chat: chat,
    project: project
  } do
    answered(chat, 1, %{})
    assert Tickets.get!(ticket.id).usage == 2_000
    {:ok, chat} = Conversations.record_turn(Repo.get!(Job, chat.id), turn(2, 0.05))
    assert Tickets.get!(ticket.id).usage == 10_000
    assert chat.turns == 2

    {:ok, plain} = Conversations.open(project, "hello", ticket: ticket)
    run!(plain)
    {:ok, _} = Conversations.record_turn(plain, turn(1, 0.5))
    assert Tickets.get!(ticket.id).usage == 10_000
  end

  test "no by-hand transition while it is live, and one once its machine is released", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    assert {:error, {:step_live, "refining"}} =
             Engine.choose(Tickets.get!(ticket.id), user.id, "review_ready",
               outcome: "needs_more"
             )

    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")
    assert %Job{status: :finished} = Repo.get!(Job, chat.id)

    assert {:ok, %{state: "review_ready"}} =
             Engine.choose(Tickets.get!(ticket.id), user.id, "review_ready",
               outcome: "needs_more"
             )
  end

  test "a step is never run again as a job, live or released", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    assert {:error, {:no_job_in, "refining"}} = Engine.retry(Tickets.get!(ticket.id), user.id)
    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")
    assert {:error, {:no_job_in, "refining"}} = Engine.retry(Tickets.get!(ticket.id), user.id)
    refute Engine.retryable?(Tickets.get!(ticket.id))
    assert Repo.all(from j in Job, where: j.ticket_id == ^ticket.id and j.kind == :workflow) == []
  end

  describe "the secrets the step names" do
    # A step's secrets are the workflow's, like a job's, and not the person's pick like a plain
    # conversation's: one the project has not set keeps the conversation from starting, and says
    # so on its page, where a plain conversation would start without it.
    setup do
      workflow =
        String.replace(
          @workflow,
          "    chat: true\n",
          "    chat: true\n    secrets: [STRIPE_TEST_KEY]\n"
        )

      assert workflow != @workflow

      {:ok, project} =
        register_owned!(%{
          name: "secret-step-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        })

      user = member_fixture(project)
      funded!(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Needs a key"}, {:user, user.id})
      [chat] = Jobs.step_chats_for_ticket(ticket.id)
      %{secret_chat: chat, secret_ticket: ticket, secret_project: project}
    end

    test "a missing one is the conversation's wait reason and sticks nothing", %{
      secret_chat: chat,
      secret_ticket: ticket
    } do
      assert chat.secret_names == ["STRIPE_TEST_KEY"]
      start_supervised!(Forge.Jobs.Scheduler)

      assert Forge.Jobs.Scheduler.tick() == 0

      assert %{payload: %{"reason" => "no_secret", "text" => text}} =
               Jobs.current_wait(Repo.get!(Job, chat.id))

      assert text =~
               "the state `refining` names `STRIPE_TEST_KEY`, which this project has not set"

      assert Tickets.get!(ticket.id).status == :active
    end

    test "it is refused again when the assignment resolves it", %{
      secret_chat: chat,
      secret_project: project
    } do
      worker = Forge.FakeWorker.connect(project: project)

      assert {:error, {:no_secret, ["STRIPE_TEST_KEY"]}} =
               Jobs.assign(Repo.get!(Job, chat.id), worker)
    end
  end

  describe "Accept" do
    setup %{ticket: ticket, chat: chat} do
      chat = answered(chat, 1, %{"refinement.md" => "# Refinement\n\nOne.\n"})
      %{chat: chat, seen: seen(ticket, ["refinement.md"])}
    end

    test "moves the ticket, approves the version it was shown, and ends the conversation", %{
      ticket: ticket,
      user: user,
      chat: chat,
      seen: seen
    } do
      assert {:ok, moved} = accept(chat, user, "done", seen)

      assert moved.state == "planning"
      assert [%Job{state: "planning"}] = Jobs.for_ticket(ticket.id)
      version = Artifacts.latest(ticket.id, "refinement.md")
      assert [%{decision: :approved}] = Artifacts.approvals(version.id)

      assert %Job{status: :finished} = Repo.get!(Job, chat.id)

      # Its branch is dealt with as ending any conversation deals with it.
      assert Enum.any?(
               Events.for_job(chat.id),
               &(&1.type in ["chat.branch_deleted", "chat.branch_kept"])
             )

      assert [event] =
               ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "step.accepted"))

      assert event.actor == %{"kind" => "user", "id" => user.id}

      assert %{"outcome" => "done", "to" => "planning", "versions" => %{"refinement.md" => 1}} =
               event.payload
    end

    test "a version written since the page drew is refused, and approves nothing", %{
      ticket: ticket,
      user: user,
      chat: chat,
      seen: seen
    } do
      {:ok, _} =
        Conversations.record_turn(
          Repo.get!(Job, chat.id),
          turn(2, 0.02, %{"refinement.md" => "# Two\n"})
        )

      assert {:error, {:stale, ["refinement.md"]}} = accept(chat, user, "done", seen)
      assert Tickets.get!(ticket.id).state == "refining"
      assert Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id) == []
    end

    test "pressing it twice moves the ticket once", %{
      ticket: ticket,
      user: user,
      chat: chat,
      seen: seen
    } do
      assert {:ok, _} = accept(chat, user, "done", seen)
      assert {:error, _reason} = accept(chat, user, "done", seen)

      assert [_one] =
               ticket.id |> Events.for_ticket() |> Enum.filter(&(&1.type == "step.accepted"))

      assert [_one] = Jobs.for_ticket(ticket.id)
    end

    test "an outcome without an approval moves the ticket on, and an unknown one is refused", %{
      user: user,
      chat: chat,
      seen: seen
    } do
      assert {:error, {:unknown_outcome, "nope"}} = accept(chat, user, "nope", seen)
      assert {:ok, %{state: "review_ready"}} = accept(chat, user, "needs_more", seen)
    end

    # A queued ticket whose conflict route led into a chat step moves only once a person takes it
    # out, as `choose/4` refuses a queued ticket (`workflow-grammar-v1.md` § The merge queue). The
    # row stands in for the queue's own conflict route, which needs a merging state the step's
    # workflow does not have.
    test "a queued ticket refuses it until taken out", %{
      ticket: ticket,
      user: user,
      chat: chat,
      seen: seen
    } do
      Repo.insert!(%Forge.MergeQueue.Entry{
        project_id: ticket.project_id,
        ticket_id: ticket.id,
        status: :integrating,
        from_state: "refining",
        to_state: "planning",
        edge_outcome: "done"
      })

      assert {:error, :queued} = accept(chat, user, "done", seen)
      assert %{state: "refining"} = Repo.reload!(ticket)
      assert Steps.refusal(:queued) =~ "Take it out first"

      assert {:ok, _ticket} = Operator.take_out(Repo.reload!(ticket), user)
      assert {:ok, %{state: "planning"}} = accept(chat, user, "done", seen)
    end

    test "a turn in flight refuses it", %{user: user, chat: chat, seen: seen} do
      {:ok, _event} = Conversations.send(Repo.get!(Job, chat.id), "and another thing")
      assert {:error, :in_flight} = accept(chat, user, "done", seen)
    end

    test "a person whose standing changed since the page loaded is refused", %{
      user: user,
      chat: chat,
      seen: seen,
      ticket: ticket
    } do
      Repo.update_all(Ecto.Query.from(u in Forge.Accounts.User, where: u.id == ^user.id),
        set: [suspended_at: DateTime.utc_now(:second)]
      )

      # The struct the page holds still says active.
      assert {:error, :suspended} = accept(chat, user, "done", seen)
      assert Tickets.get!(ticket.id).state == "refining"
    end

    test "a non-member is refused", %{chat: chat, seen: seen, ticket: ticket} do
      stranger = Forge.AccountsFixtures.user_fixture()
      assert {:error, :forbidden} = accept(chat, stranger, "done", seen)
      assert Tickets.get!(ticket.id).state == "refining"
    end

    test "a conversation whose machine was released can be accepted if its documents exist", %{
      user: user,
      chat: chat,
      seen: seen
    } do
      {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")
      assert {:ok, %{state: "planning"}} = accept(chat, user, "done", seen)
    end

    test "it takes no message once the step is accepted", %{user: user, chat: chat, seen: seen} do
      {:ok, _} = accept(chat, user, "done", seen)
      assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
    end
  end

  test "nothing to accept before a document exists", %{user: user, chat: chat, ticket: ticket} do
    answered(chat, 1, %{})
    assert {:error, {:no_version, ["refinement.md"]}} = accept(chat, user, "done", %{})

    # Also through the outcome whose edge approves nothing: the step's own document is required
    # whatever the edge says, which is what a replayed event or the operator call would meet.
    assert {:error, {:no_version, ["refinement.md"]}} = accept(chat, user, "needs_more", %{})
    assert Tickets.get!(ticket.id).state == "refining"
    view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id))
    refute view.ready
    assert view.missing == ["refinement.md"]
  end

  test "returning to the step opens a new visit, and a message to the old one does not", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, _} = accept(chat, user, "needs_more", seen(ticket, ["refinement.md"]))
    {:ok, back} = Engine.choose(Tickets.get!(ticket.id), user.id, "refining")

    assert [%Job{attempt: 1}, %Job{attempt: 2} = second] = Jobs.step_chats_for_ticket(back.id)
    assert Conversations.opened_step(second.id)["entered"]["from"] == "review_ready"

    # The first visit is over; a message to it is refused and is not a new visit.
    assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
    assert length(Jobs.step_chats_for_ticket(back.id)) == 2
  end

  test "a step's assignment carries its contract and no way to move the ticket", %{chat: chat} do
    worker = Forge.FakeWorker.connect()
    assignment = Forge.FakeWorker.assign(chat, worker)
    spec = assignment["spec"]

    assert spec["moving"] == nil
    assert spec["step"]["state"] == "refining"
    assert spec["step"]["prompt"] =~ "Refine the ticket"
    assert spec["step"]["produces"] == ["refinement.md"]

    assert [%{"outcome" => "done", "to" => "planning", "approve" => ["refinement.md"]}, _] =
             spec["step"]["outcomes"]

    assert spec["prompt"] == Conversations.step_kickoff()
  end

  test "an older visit cannot be accepted once the ticket has come back to the step", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    seen = seen(ticket, ["refinement.md"])
    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")

    {:ok, _} =
      Engine.choose(Tickets.get!(ticket.id), user.id, "review_ready", outcome: "needs_more")

    {:ok, _} = Engine.choose(Tickets.get!(ticket.id), user.id, "refining")

    assert {:error, :superseded} = accept(chat, user, "done", seen)

    # Back in the step, but not the visit this conversation was: only the newer visit takes a message.
    assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
  end

  test "a conversation cannot be accepted after the ticket has left its step", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    seen = seen(ticket, ["refinement.md"])
    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")

    {:ok, _} =
      Engine.choose(Tickets.get!(ticket.id), user.id, "review_ready", outcome: "needs_more")

    assert {:error, {:not_in_step, "refining"}} = accept(chat, user, "done", seen)

    # Nothing accepted it and no newer visit exists: only the ticket's state says the step is over.
    assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
  end

  test "a step waiting for the person's reply is the ticket waiting on a person", %{
    ticket: ticket,
    chat: chat
  } do
    run!(chat)
    assert Forge.Queue.for_ticket(Tickets.get!(ticket.id)) == []

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{text: "What should it do?", parent_tool_use_id: nil}
      })

    {:ok, _} = Conversations.record_turn(Repo.get!(Job, chat.id), turn(1))

    assert [%{kind: :chat}] = Forge.Queue.for_ticket(Tickets.get!(ticket.id))
  end

  test "every reason Accept can be refused for is said in words a person can act on" do
    assert Steps.refusal({:stale, ["a.md"]}) =~ "changed while you were looking"
    assert Steps.refusal({:no_version, ["a.md", "b.md"]}) =~ ~s("a.md", "b.md")
    assert Steps.refusal(:in_flight) =~ "still replying"
    assert Steps.refusal({:max_spent, "done"}) =~ "as often as the workflow allows"
    assert Steps.refusal({:no_edge, "done"}) =~ "no way on"
    assert Steps.refusal({:not_in_step, "refining"}) =~ "already left"
    assert Steps.refusal(:suspended) =~ "suspended"
    assert Steps.refusal(:forbidden) =~ "not a member"
    assert Steps.refusal(:something_new) =~ "Could not accept"
  end

  # Cancelling is not ending: the conversation stops with its branch kept, a message to it is
  # refused while the ticket is cancelled, and once the ticket is restored a message carries the
  # same conversation on.
  test "cancelling stops the conversation, and restoring lets a message carry it on", %{
    ticket: ticket,
    user: user,
    chat: chat
  } do
    {:ok, cancelled} = Engine.cancel(ticket, user.id)
    assert %Job{status: :hibernated} = Repo.get!(Job, chat.id)
    refute Conversations.ended?(chat.id)
    before = length(Events.for_job(chat.id))
    assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
    assert length(Events.for_job(chat.id)) == before

    {:ok, _restored} = Engine.restore(cancelled, user.id)
    assert {:ok, _event} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
    assert %Job{status: :pending} = Repo.get!(Job, chat.id)
  end

  # Ending one only ever left the ticket stuck in the step with nobody to talk to, so it is
  # refused at the operation, for everyone, before anything is written.
  test "a step's conversation cannot be ended, by a member or a node admin", %{
    project: project,
    ticket: ticket,
    user: user,
    chat: chat
  } do
    # A node admin who is a member of the project: the rule is not one a role can lift.
    admin =
      project |> member_fixture() |> Ecto.Changeset.change(node_admin: true) |> Repo.update!()

    before = Events.for_job(chat.id)

    assert {:error, :step} = Conversations.close(chat)
    assert {:error, :step} = Forge.Operator.close_chat(chat, user)
    assert {:error, :step} = Forge.Operator.close_chat(chat, admin)

    # The caller's struct is not believed either: a step is a step by its row.
    assert {:error, :step} = Conversations.close(%{chat | state: nil})

    assert Events.for_job(chat.id) == before
    assert %Job{status: status} = Repo.get!(Job, chat.id)
    assert status in [:pending, :running]
    assert Tickets.get!(ticket.id).state == "refining"
  end

  test "Accept still ends a step's conversation, for good", %{
    user: user,
    chat: chat,
    ticket: ticket
  } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, _} = accept(chat, user, "done", seen(ticket, ["refinement.md"]))

    assert Conversations.ended?(chat.id)
    assert %Job{status: :finished} = Repo.get!(Job, chat.id)
  end

  test "a released step conversation whose agent spoke last is the ticket waiting on a person", %{
    ticket: ticket,
    chat: chat
  } do
    run!(chat)

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{text: "What should it do?", parent_tool_use_id: nil}
      })

    {:ok, _} = Conversations.record_turn(Repo.get!(Job, chat.id), turn(1))
    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")

    assert [%{kind: :chat, detail: %{lost: false}}] =
             Forge.Queue.for_ticket(Tickets.get!(ticket.id))
  end

  describe "a step conversation without a machine, in the queue" do
    setup %{user: user} do
      Forge.Push.TestSender.watch()
      key = fn bytes -> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false) end

      {:ok, _} =
        Forge.Push.subscribe(user, %{
          "endpoint" => "https://push.example/step",
          "keys" => %{"p256dh" => key.(65), "auth" => key.(16)}
        })

      :ok
    end

    defp reply!(chat, text) do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{text: text, parent_tool_use_id: nil}
        })

      {:ok, chat} = Conversations.record_turn(Repo.get!(Job, chat.id), turn(1))
      chat
    end

    defp running!(chat) do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

      chat
      |> Job.progress_changeset(%{status: :running, worker_id: worker.id})
      |> Repo.update!()
    end

    # With no stopped state a conversation whose agent spoke last is waiting on you whether or not
    # it holds a machine: the idle timeout changes nothing about whose turn it is.
    test "released with the agent's reply last, it is still waiting on you, once", %{
      user: user,
      ticket: ticket,
      chat: chat
    } do
      reply!(chat, "What should it do?")
      assert Queue.count(user) == 1

      {:ok, released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")
      refute Conversations.live?(released)

      assert [%{kind: :chat, detail: %{lost: false, chat_id: id}}] = Queue.items(user)
      assert id == chat.id
      assert Queue.count(user) == 1
      assert [%{kind: :chat}] = Queue.for_ticket(Tickets.get!(ticket.id))

      # It is an item, so it is not also a row in Open tickets.
      refute ticket.id in Enum.map(Queue.open_tickets(user, Queue.items(user)), & &1.id)
    end

    # Criterion 19: the agent's reply already sent a notification and the wait it started has not
    # changed, so a machine released by the idle timeout sends none.
    test "the idle timeout pushes nothing", %{chat: chat} do
      reply!(chat, "What should it do?")
      assert_receive {:push, _endpoint, _payload, _opts}, 2_000

      {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")

      refute_receive {:push, _endpoint, _payload, _opts}, 300
    end

    # The same promise seen from the push watch, which reads the ticket on every change and pushes
    # what is new: the released conversation's item has the key the reply's item had, so a machine
    # released changes nothing it would tell anyone.
    test "the push watch sees a released conversation's item as the one it already told", %{
      ticket: ticket,
      chat: chat
    } do
      chat = reply!(chat, "What should it do?")
      assert_receive {:push, _endpoint, _payload, _opts}, 2_000

      seen = Forge.Push.Watch.changed(%{}, ticket.id)
      assert_receive {:push, _endpoint, _payload, _opts}, 2_000

      {:ok, _released} = Conversations.ended(chat, nil, "idle")

      assert Forge.Push.Watch.changed(seen, ticket.id) == seen
      refute_receive {:push, _endpoint, _payload, _opts}, 300
    end

    test "the step moving on takes it out of the queue", %{user: user, chat: chat, ticket: ticket} do
      chat = reply!(chat, "What should it do?")
      {:ok, _released} = Conversations.ended(chat, nil, "idle")
      assert Queue.count(user) == 1

      {:ok, _} =
        Engine.choose(Tickets.get!(ticket.id), user.id, "review_ready", outcome: "needs_more")

      assert Queue.for_chat(Repo.get!(Job, chat.id)) == []
      assert Enum.filter(Queue.items(user), &(&1.kind == :chat)) == []
    end

    # The person's message is the last word and no reply came: the conversation says so, is not
    # started again by itself, and for a step is a queue item and a notification.
    test "a reply lost with its machine is an item that says so, and pushes", %{
      user: user,
      chat: chat
    } do
      chat = running!(chat)
      {:ok, _event} = Conversations.send(chat, "go on")
      refute_receive {:push, _endpoint, _payload, _opts}, 100

      {:ok, lost} = Jobs.requeue(chat.id, :worker_lost)

      assert lost.status == :hibernated
      assert [%{kind: :chat, detail: %{lost: true, text: text}}] = Queue.items(user)
      assert text =~ "lost with its machine"
      assert Queue.count(user) == 1

      assert_receive {:push, _endpoint, payload, _opts}, 2_000
      assert payload["title"] =~ "lost"

      # Never re-queued by itself: the platform restart's sweep leaves it where it is.
      assert Repo.get!(Job, chat.id).status == :hibernated
      assert {:ok, _event} = Conversations.send(Repo.get!(Job, chat.id), "go on")
      assert Repo.get!(Job, chat.id).status == :pending
      assert Enum.filter(Queue.items(user), &(&1.detail[:lost] == true)) == []
    end

    test "a platform restart that loses the machine says it too", %{user: user, chat: chat} do
      chat = running!(chat)
      {:ok, _event} = Conversations.send(chat, "go on")

      # A worker row that is gone, which is what `recover/0` looks for.
      Repo.update_all(Forge.Workers.Worker, set: [status: :destroyed])
      assert 1 = Jobs.recover()

      assert [%{kind: :chat, detail: %{lost: true}}] = Queue.items(user)
      assert_receive {:push, _endpoint, _payload, _opts}, 2_000
    end

    # A machine lost after the agent had replied leaves the item the reply made, which pushed when
    # it was made: nothing new has started waiting.
    test "a machine lost after the reply pushes nothing more", %{chat: chat} do
      chat = running!(chat)
      reply!(chat, "What should it do?")
      assert_receive {:push, _endpoint, _payload, _opts}, 2_000

      {:ok, _lost} = Jobs.requeue(chat.id, :worker_lost)

      refute_receive {:push, _endpoint, _payload, _opts}, 300
    end

    test "an ordinary conversation that lost its reply is in no queue and pushes nothing", %{
      project: project,
      user: user
    } do
      {:ok, plain} = Conversations.open(project, "hello")
      plain = running!(plain)
      {:ok, _event} = Conversations.send(plain, "go on")

      {:ok, _lost} = Jobs.requeue(plain.id, :worker_lost)

      assert Enum.filter(Queue.items(user), &(&1.detail[:chat_id] == plain.id)) == []
      refute_receive {:push, _endpoint, _payload, _opts}, 300
    end
  end
end
