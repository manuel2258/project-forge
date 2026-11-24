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
      budget: { turns: 5, tokens: 200k }
    finished: {}
  transitions:
    - { from: scoping, to: finished, approve: [notes.md, refinement.md] }
    - { from: finished, to: drafting }
    - { from: finished, to: scoping, approve: [refinement.md] }
    - { from: drafting, to: scoping }
  limits: { ticket_tokens: 5M }
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

  # The step also declares a page, which is required as a document is unless it is optional.
  @paged String.replace(
           @workflow,
           "produces: [notes.md, extras.md]",
           "produces: [notes.md, extras.md, form@]"
         )
  @paged_optional String.replace(@paged, "optional: [extras.md]", "optional: [extras.md, form]")

  # The same, with a command that produces a log and a group of files, whose names a chat's page
  # may not take.
  @commanded String.replace(
               @workflow,
               "states:\n",
               """
               commands:
                 build:
                   run: .forge/commands/build.sh
                   produces: [build.log, package/*]
                   timeout: 5m
               states:
               """,
               global: false
             )

  setup context do
    workflow =
      cond do
        context[:commanded] -> @commanded
        context[:paged] -> @paged
        context[:paged_optional] -> @paged_optional
        context[:looping] -> @looping
        context[:approves_optional] -> @approving_optional
        true -> @workflow
      end

    assert workflow != @workflow or context[:looping] != true

    {:ok, project} =
      register_owned!(%{
        name: "guards-#{System.unique_integer([:positive])}",
        repo_path:
          seeded_repo(%{
            ".forge/workflow.yml" => workflow,
            ".forge/commands/build.sh" => "#!/bin/sh\nexec make\n"
          })
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
      "harness" => %{
        "turns" => 1,
        "usage" => 2_000 * index,
        "cost_usd" => 0.01 * index,
        "session_id" => "s"
      }
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
  defp ready(
         %{ticket: ticket, chat: chat},
         documents \\ %{"notes.md" => "# Notes\n"},
         pages \\ %{}
       ) do
    write!(ticket, "refinement.md", "# Refinement\n")
    run!(chat)
    {:ok, chat} = Conversations.record_turn(chat, Map.put(turn(1, documents), "pages", pages))
    chat
  end

  # What a worker reports for a page it found in `out/`: refused before any file is read.
  defp page_files, do: %{"index.html" => %{"hash" => String.duplicate("a", 64)}}

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

  @tag paged: true
  test "a page the step declares must have a version before Accept", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)
    drawn = seen(ticket, ["notes.md", "refinement.md"])
    view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id))

    assert view.missing == ["form@"]
    refute view.ready
    assert {:error, {:no_version, ["form@"]} = refusal} = accept(chat, user, "done", drawn)
    assert Steps.refusal(refusal) =~ ~s("form@")
    assert Tickets.get!(ticket.id).state == "scoping"

    ForgeWeb.PageDoorFixtures.published!({:ticket, ticket.id}, "form")
    assert Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, chat.id)).ready
    assert {:ok, %{state: "finished"}} = accept(chat, user, "done", drawn)
  end

  @tag paged_optional: true
  test "an optional page nobody wrote does not stop Accept", context do
    %{ticket: ticket, user: user} = context
    chat = ready(context)

    assert {:ok, _} = accept(chat, user, "done", seen(ticket, ["notes.md", "refinement.md"]))
  end

  @tag paged: true
  test "a chat may publish a page the workflow declares", context do
    chat = ready(context, %{"notes.md" => "# Notes\n"}, %{"form" => page_files()})

    refute Map.has_key?(Conversations.unrecorded(chat.id), "form")
  end

  describe "a chat's page and a document may not share a name" do
    @tag commanded: true
    test "a page cannot take the name of a command's log or group of files", context do
      pages = %{"package" => page_files(), "build.log" => page_files()}
      chat = ready(context, %{"notes.md" => "# Notes\n"}, pages)

      refused = Conversations.unrecorded(chat.id)
      assert refused["package"] =~ "group of files"
      assert refused["build.log"] =~ "command log"
    end

    @tag paged: true
    test "a document cannot take the name of a page the workflow declares", context do
      chat = ready(context, %{"notes.md" => "# Notes\n", "form" => "# Form\n"})

      assert Conversations.unrecorded(chat.id)["form"] =~ "is a page here, not a document"
      assert Artifacts.latest(context.ticket.id, "form") == nil
    end

    test "a document cannot take the name of a page the ticket already holds", context do
      ForgeWeb.PageDoorFixtures.published!({:ticket, context.ticket.id}, "gallery")
      chat = ready(context, %{"notes.md" => "# Notes\n", "gallery" => "# Gallery\n"})

      assert Conversations.unrecorded(chat.id)["gallery"] =~ "is a page here, not a document"
      assert Artifacts.latest(context.ticket.id, "gallery") == nil
    end
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

  test "a send is refused in the window between Accept's commit and its new visit", context do
    %{ticket: ticket} = context
    chat = ready(context)

    # What Accept has recorded by the time it has not yet closed or replaced the conversation.
    {:ok, _event} =
      Events.append("step.accepted", {:user, "x"}, %{
        ticket_id: ticket.id,
        job_id: chat.id,
        payload: %{}
      })

    {:ok, _released} = Conversations.ended(Repo.get!(Job, chat.id), nil, "idle")
    assert {:error, :step_over} = Conversations.send(Repo.get!(Job, chat.id), "carry on")
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
          budget: { turns: 5, tokens: 200k }
        merged: { on_enter: [merge] }
      transitions:
        - { from: scoping, to: merged, approve: [changeset] }
        - { from: merged, to: coding }
        - { from: coding, to: scoping }
      limits: { ticket_tokens: 5M }
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

  # A chat step may be a merging state's `on_conflict` target (`workflow-grammar-v1.md` § Merging),
  # and Accept there takes the edge into the merge as the rebase state's edge is taken: it approves
  # the changeset whether the edge lists it or not.
  describe "an edge out of a chat step that is an integrating state" do
    test "approves the changeset, listed or not" do
      workflow = """
      version: 1
      initial: coding
      states:
        coding:
          prompt: agents/plan.md
          produces: [changeset, commit-message]
          budget: { turns: 5, tokens: 200k }
        review_ready: {}
        scoping:
          chat: true
          prompt: agents/refine.md
          inputs: [ticket]
          produces: [notes.md]
        merged: { on_enter: [merge], on_conflict: scoping }
      transitions:
        - { from: coding, to: review_ready }
        - { from: review_ready, to: merged, approve: [changeset] }
        - { from: scoping, to: merged }
      limits: { ticket_tokens: 5M }
      """

      {:ok, project} =
        register_owned!(%{
          name: "rebasechat-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        })

      user = member_fixture(project)
      funded!(project)
      {:ok, ticket} = Tickets.admit(project, %{title: "Scope it"}, {:user, user.id})
      {:ok, parsed} = Tickets.parsed_workflow(ticket)

      assert {:ok, edge} = Engine.accepted_edge(ticket, parsed, %{state: "scoping"}, "done")
      assert edge.to == "merged"
      assert edge.approve == ["changeset"]

      # What a conversation is told taking it records, and what the Accept area says it does.
      ticket |> Ecto.Changeset.change(state: "scoping") |> Repo.update!()

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
          blob_uri: "git:" <> String.duplicate("a", 40)
        })

      {:ok, chat} = Conversations.open(project, "about this", ticket: Tickets.get!(ticket.id))
      spec = Jobs.assignment(chat, Tickets.get!(ticket.id), project, "token")["spec"]
      assert [%{"to" => "merged", "approve" => ["changeset"]}] = spec["moving"]["transitions"]

      # And the step's own conversation, which is what the Accept area draws its outcomes from.
      {:ok, %{step: step}} =
        Ecto.Multi.new()
        |> Jobs.put_create_step(:step, Tickets.get!(ticket.id), parsed, "scoping", %{})
        |> Repo.transaction()

      view = Steps.view(Tickets.get!(ticket.id), Repo.get!(Job, step.id))
      assert [%{to: "merged", approve: ["changeset"]}] = view.outcomes

      # ... and what the step's own assignment tells the agent each outcome approves.
      step_spec =
        Jobs.assignment(Repo.get!(Job, step.id), Tickets.get!(ticket.id), project, "token")[
          "spec"
        ]

      assert [%{"outcome" => "done", "to" => "merged", "approve" => ["changeset"]}] =
               step_spec["step"]["outcomes"]
    end
  end
end
