defmodule Forge.ChatStepGuardsTest do
  @moduledoc """
  The guards on a chat step's Accept that `Forge.ChatStepTest` leaves to a workflow with a
  different shape: a step with no `outcomes:` (the commonest), an optional document, a document
  the step's edge approves that the step does not write, and a ticket that is not open.
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures

  import Ecto.Query, only: [from: 2]
  alias Forge.{Artifacts, Conversations, Engine, Events, Jobs, Operator, Repo, Steps, Tickets}
  alias Forge.Jobs.Job

  @workflow """
  version: 1
  initial: scoping
  states:
    scoping:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [notes.md, extras.md]
      optional: [extras.md]
    drafting:
      prompt: agents/plan.md
      produces: [refinement.md]
      budget: { turns: 5, cost: 1 }
    finished: {}
  transitions:
    - { from: scoping, to: finished, approve: [notes.md, refinement.md] }
    - { from: finished, to: drafting }
    - { from: finished, to: scoping, approve: [refinement.md] }
    - { from: drafting, to: scoping }
  limits: { ticket_cost: 25 }
  """

  # The same step with two ways out, one of them back through `drafting` and into the step again.
  @looping @workflow
           |> String.replace(
             "    optional: [extras.md]\n",
             "    optional: [extras.md]\n    outcomes: [done, more]\n"
           )
           |> String.replace(
             "  - { from: drafting, to: scoping }",
             "  - { from: scoping, to: drafting, when: more }\n  - { from: drafting, to: scoping }"
           )

  # The same, with the optional document among those the edge approves.
  @approving_optional String.replace(
                        @workflow,
                        "approve: [notes.md, refinement.md]",
                        "approve: [notes.md, refinement.md, extras.md]"
                      )

  setup context do
    workflow =
      cond do
        context[:looping] -> @looping
        context[:approves_optional] -> @approving_optional
        true -> @workflow
      end

    assert workflow != @workflow or context[:looping] != true

    {:ok, project} =
      register_owned!(%{
        name: "guards-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
      })

    user = member_fixture(project)
    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Scope it"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    %{project: project, user: user, ticket: ticket, chat: chat}
  end

  defp turn(index, documents) do
    %{
      "turn" => index,
      "commit" => String.duplicate("a", 40),
      "documents" => documents,
      "harness" => %{"turns" => 1, "cost_usd" => 0.01 * index, "session_id" => "s"}
    }
  end

  defp write!(ticket, name, content) do
    {:ok, version} =
      Artifacts.record_version({:ticket, ticket.id}, name, :document, {:user, "someone"}, %{
        content: content,
        parse: false
      })

    version
  end

  defp seen(ticket, names),
    do: Map.new(names, &{&1, (v = Artifacts.latest(ticket.id, &1)) && v.version})

  defp accept(chat, user, outcome, seen),
    do: Operator.accept_step(Repo.get!(Job, chat.id), user, outcome, seen)

  # A chat that has answered once, and the earlier state's document its edge approves.
  defp ready(%{ticket: ticket, chat: chat}, documents \\ %{"notes.md" => "# Notes\n"}) do
    write!(ticket, "refinement.md", "# Refinement\n")
    run!(chat)
    {:ok, chat} = Conversations.record_turn(chat, turn(1, documents))
    chat
  end

  test "a step with no outcomes: is accepted as `done`", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)

    assert {:ok, %{state: "finished"}} =
             accept(chat, user, "done", seen(ticket, ["notes.md", "extras.md", "refinement.md"]))
  end

  test "an optional document nobody wrote does not stop Accept", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)
    view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id))

    assert view.missing == []
    assert view.ready
    # Not sent at all, as a page sends nothing for a document it drew as not written.
    assert {:ok, _} = accept(chat, user, "done", seen(ticket, ["notes.md", "refinement.md"]))
  end

  test "a document the page did not send a version for is refused as changed", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)

    assert {:error, {:stale, ["notes.md"]}} = accept(chat, user, "done", %{"refinement.md" => 1})
    assert Tickets.get!(ticket.id).state == "scoping"
  end

  @tag approves_optional: true
  test "an optional document the edge approves must exist", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)
    drawn = seen(ticket, ["notes.md", "extras.md", "refinement.md"])

    assert {:error, {:no_version, ["extras.md"]}} = accept(chat, user, "done", drawn)
    assert Tickets.get!(ticket.id).state == "scoping"
  end

  test "a plain member may press it", %{project: project, ticket: ticket} = context do
    member = member_fixture(project, :member)
    chat = ready(context)

    assert {:ok, %{state: "finished"}} =
             accept(chat, member, "done", seen(ticket, ["notes.md", "refinement.md"]))
  end

  test "a conversation that is not a step is refused", %{project: project, user: user} do
    {:ok, plain} = Conversations.open(project, "hello")
    assert {:error, :not_a_step} = Operator.accept_step(plain, user, "done", %{})
  end

  test "a cancelled ticket cannot be accepted", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)
    seen = seen(ticket, ["notes.md", "refinement.md"])
    {:ok, _cancelled} = Engine.cancel(Tickets.get!(ticket.id), user.id)

    assert {:error, {:not_active, :cancelled}} = accept(chat, user, "done", seen)
    assert Tickets.get!(ticket.id).state == "scoping"
    assert Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id) == []
  end

  @tag looping: true
  test "accepting twice on an edge back into the step says it was accepted", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)
    write!(ticket, "refinement.md", "# Again\n")
    seen = seen(ticket, ["notes.md", "refinement.md"])

    assert {:ok, %{state: "drafting"}} = accept(chat, user, "more", seen)

    Repo.update_all(from(j in Job, where: j.ticket_id == ^ticket.id and j.kind == :workflow),
      set: [status: :finished]
    )

    {:ok, _} = Engine.choose(Tickets.get!(ticket.id), user.id, "scoping")
    assert [_first, %Job{attempt: 2}] = Jobs.step_chats_for_ticket(ticket.id)

    # The first visit is both accepted and no longer the latest; accepted is the truer answer.
    assert Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id)).over == :accepted
    assert {:error, :already_accepted} = accept(chat, user, "done", seen)
  end

  test "a reopen is refused in the window between Accept's commit and its new visit", context do
    %{ticket: ticket} = context
    chat = ready(context)

    # What Accept has recorded by the time it has not yet closed or replaced the conversation.
    {:ok, _event} =
      Events.append("step.accepted", {:user, "x"}, %{
        ticket_id: ticket.id,
        job_id: chat.id,
        payload: %{}
      })

    :ok = Conversations.close(Repo.get!(Job, chat.id), "idle")
    assert {:error, :step_over} = Conversations.reopen(Repo.get!(Job, chat.id))
  end

  describe "a document the step's edge approves but the step does not write" do
    test "is listed and pinned: a version written after the page drew is refused", context do
      %{ticket: ticket, user: user, project: project} = context
      chat = ready(context)

      view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id))

      assert [%{name: "notes.md", own: true}, %{name: "extras.md", own: true}, shown] =
               view.documents

      assert %{name: "refinement.md", own: false, version: 1} = shown

      # Whoever writes it meanwhile — a plain chat, here — the press carries the version drawn.
      {:ok, plain} = Conversations.open(project, "hello", ticket: ticket, actor: {:user, user.id})
      run!(plain)
      {:ok, _} = Conversations.record_turn(plain, turn(1, %{"refinement.md" => "# Unseen\n"}))
      drawn = %{"notes.md" => 1, "extras.md" => nil, "refinement.md" => 1}

      assert {:error, {:stale, ["refinement.md"]}} = accept(chat, user, "done", drawn)
      assert Tickets.get!(ticket.id).state == "scoping"

      assert {:ok, _} = accept(chat, user, "done", %{drawn | "refinement.md" => 2})
      approved = Artifacts.latest(ticket.id, "refinement.md")
      assert approved.content == "# Unseen\n"
      assert [%{decision: :approved}] = Artifacts.approvals(approved.id)
    end

    test "can be written by the step's own agent, and is then shown and approved", context do
      %{ticket: ticket, user: user} = context
      run!(context.chat)

      {:ok, chat} =
        Conversations.record_turn(
          context.chat,
          turn(1, %{"notes.md" => "# Notes\n", "refinement.md" => "# By the agent\n"})
        )

      assert Conversations.unrecorded(chat.id) == %{}
      view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id))
      assert Enum.find(view.documents, &(&1.name == "refinement.md")).this_visit
      assert view.ready

      assert {:ok, _} =
               accept(
                 chat,
                 user,
                 "done",
                 seen(ticket, ["notes.md", "extras.md", "refinement.md"])
               )
    end
  end

  describe "a turn that lands after Accept" do
    test "records its cost and neither a document nor a running status", context do
      %{ticket: ticket, user: user} = context
      chat = ready(context)
      {:ok, _} = accept(chat, user, "done", seen(ticket, ["notes.md", "refinement.md"]))
      assert %Job{status: :finished} = Repo.get!(Job, chat.id)

      late = Repo.get!(Job, chat.id)
      late_documents = %{"notes.md" => "# Too late\n", "other.md" => "# Not declared\n"}
      {:ok, _} = Conversations.record_turn(late, turn(2, late_documents))

      assert Artifacts.latest(ticket.id, "notes.md").content == "# Notes\n"
      assert Artifacts.latest(ticket.id, "other.md") == nil

      # Said, so the page does not let the person think they were kept.
      assert %{"notes.md" => reason, "other.md" => _} = Conversations.unrecorded(chat.id)
      assert reason =~ "after the step was accepted"
      assert %Job{status: :finished, turns: 2} = Repo.get!(Job, chat.id)
    end
  end

  test "an agent asking a plain ticket chat to move a ticket whose step is live is told to Accept",
       %{project: project, ticket: ticket, user: user} do
    {:ok, plain} =
      Conversations.open(project, "hello", ticket: ticket, actor: {:user, user.id})

    run!(plain)
    payload = Map.put(turn(1, %{}), "transition_request", %{"to" => "finished"})
    {:ok, _} = Conversations.record_turn(plain, payload)

    assert [%{payload: %{"reason" => reason}}] =
             plain.id |> Events.for_job() |> Enum.filter(&(&1.type == "chat.transition_refused"))

    assert reason =~ "Accept"
    assert Tickets.get!(ticket.id).state == "scoping"
  end

  describe "the assignment" do
    setup do
      workflow = String.replace(@workflow, "    chat: true\n", "    chat: true\n    env: ci\n")
      assert workflow != @workflow

      {:ok, project} =
        register_owned!(%{
          name: "assign-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        })

      user = member_fixture(project)
      funded!(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Scope it"}, {:user, user.id})
      [chat] = Jobs.step_chats_for_ticket(ticket.id)
      %{env_chat: chat}
    end

    test "carries the step's env and every part of its contract", %{env_chat: chat} do
      worker = Forge.FakeWorker.connect()
      spec = Forge.FakeWorker.assign(chat, worker)["spec"]

      assert spec["env"] == "ci"

      assert %{
               "state" => "scoping",
               "visit" => 1,
               "prompt" => prompt,
               "inputs" => ["ticket"],
               "produces" => ["notes.md", "extras.md"],
               "optional" => ["extras.md"],
               "entered" => nil
             } = spec["step"]

      assert prompt =~ "Refine the ticket"
    end
  end

  describe "an edge into a merging state" do
    setup do
      workflow = """
      version: 1
      initial: scoping
      states:
        scoping:
          chat: true
          prompt: agents/refine.md
          inputs: [ticket]
          produces: [notes.md]
        coding:
          prompt: agents/plan.md
          produces: [changeset, commit-message]
          budget: { turns: 5, cost: 1 }
        merged: { on_enter: [merge] }
      transitions:
        - { from: scoping, to: merged, approve: [changeset] }
        - { from: merged, to: coding }
        - { from: coding, to: scoping }
      limits: { ticket_cost: 25 }
      """

      {:ok, project} =
        register_owned!(%{
          name: "mergeedge-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        })

      user = member_fixture(project)
      funded!(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Scope it"}, {:user, user.id})
      [chat] = Jobs.step_chats_for_ticket(ticket.id)
      %{merge_chat: chat, merge_ticket: ticket, merge_user: user}
    end

    test "is checked before the ticket moves, and refused when nothing can be merged", %{
      merge_chat: chat,
      merge_ticket: ticket,
      merge_user: user
    } do
      run!(chat)
      {:ok, chat} = Conversations.record_turn(chat, turn(1, %{"notes.md" => "# N\n"}))

      assert {:error, {:merge_impossible, _reason}} =
               accept(chat, user, "done", seen(ticket, ["notes.md", "refinement.md"]))

      assert Tickets.get!(ticket.id).state == "scoping"
      assert Conversations.live?(Repo.get!(Job, chat.id))
    end
  end
end
