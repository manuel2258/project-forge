defmodule ForgeWeb.ChatStepLiveTest do
  @moduledoc """
  The Accept area of a chat step (`docs/design/ui.md` § The Accept area), on the conversation's
  page and on the ticket's Decide tab: what it says before anything is written, while a reply is
  in flight, and when it can be pressed — and that a press sends what the page showed.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{Artifacts, Conversations, Jobs, Projects, Repo, Tickets}
  alias Forge.Jobs.Job

  setup :register_and_log_in_user

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
      budget: { turns: 5, cost: 1 }
    review_ready: {}
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: refining, to: review_ready, when: needs_more }
    - { from: planning, to: review_ready }
  limits: { ticket_cost: 25 }
  """

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "stepui-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => @workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "<b>Persist</b> scores"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    %{project: project, ticket: ticket, chat: chat}
  end

  defp answered(chat, index, documents) do
    run!(chat)

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "commit" => String.duplicate("a", 40),
        "documents" => documents,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01 * index, "session_id" => "s"}
      })

    chat
  end

  test "before anything is written it says what is expected, and draws no button", %{
    conn: conn,
    chat: chat
  } do
    answered(chat, 1, %{})
    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#step-banner", "refining")
    # Markup in the ticket title is text.
    assert html =~ "&lt;b&gt;Persist&lt;/b&gt; scores"
    assert has_element?(view, "#step-nothing-yet", "refinement.md")
    refute has_element?(view, "#step-accept-form")
  end

  test "a reply in flight says it is waiting, with no button", %{conn: conn, chat: chat} do
    # Nothing recorded yet: the opening is in flight.
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#step-waiting", "Waiting for the reply")
    refute has_element?(view, "#step-accept-form")
  end

  test "several outcomes preselect none, and Accept is a second step that moves the ticket", %{
    conn: conn,
    chat: chat,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#step-accept-form input[type=radio][value=done]")
    assert has_element?(view, "#step-accept-form input[type=radio][value=needs_more]")
    refute has_element?(view, "#step-accept-form input[type=radio][checked]")
    assert has_element?(view, "button[phx-click='step:review'][disabled]")
    assert has_element?(view, "#step-accept-form input[name=confirming][value=false]")
    assert has_element?(view, "#step-documents", "version 1, written in this visit")
    refute has_element?(view, "#step-confirm")

    view |> form("#step-accept-form", %{"outcome" => "done"}) |> render_change()
    refute has_element?(view, "button[phx-click='step:review'][disabled]")
    view |> element("button[phx-click='step:review']") |> render_click()
    assert has_element?(view, "#step-confirm", "approves the latest version of refinement.md")
    assert has_element?(view, "#step-confirm button[type=submit][phx-disable-with]")
    # What the form carries is what a rejoin gives back: the open confirm rides in a field.
    assert has_element?(view, "#step-accept-form input[name=confirming][value=true]")

    view |> form("#step-accept-form") |> render_submit()

    assert Tickets.get!(ticket.id).state == "planning"
    assert has_element?(view, "#step-over", "accepted")
    refute has_element?(view, "#step-accept-form")
    # A finished step is not offered Reopen: it would be refused.
    refute has_element?(view, "button[phx-click=reopen]")
  end

  test "an outcome whose edge has no allowance left is drawn disabled and refused", %{
    conn: conn,
    user: user
  } do
    workflow =
      @workflow
      |> String.replace("when: needs_more }", "when: needs_more, max: 1 }")
      |> String.replace("limits:", "  - { from: review_ready, to: refining }\nlimits:")

    {:ok, project} =
      Projects.register(
        %{
          name: "stepmax-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Twice"}, {:user, user.id})
    [first] = Jobs.step_chats_for_ticket(ticket.id)
    answered(first, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{first.id}")

    # Nothing was picked on this page: the press carries the outcome it was made with.
    render_hook(view, "step:accept", %{
      "outcome" => "needs_more",
      "seen" => %{"refinement.md" => "1"}
    })

    assert Tickets.get!(ticket.id).state == "review_ready"
    {:ok, _} = Forge.Engine.choose(Tickets.get!(ticket.id), user.id, "refining")
    [_first, second] = Jobs.step_chats_for_ticket(ticket.id) |> Enum.sort_by(& &1.attempt)
    answered(second, 1, %{"refinement.md" => "# R2\n"})

    {:ok, again, _html} = live(conn, ~p"/chats/#{second.id}")
    assert has_element?(again, "#step-accept-form input[type=radio][value=needs_more][disabled]")
    assert has_element?(again, "#step-accept-form", "already taken as often as allowed")
    # One outcome is spent and the other is not: the form is there, and the card for a step with
    # nothing left to press is not.
    refute has_element?(again, "#step-blocked")
    refute has_element?(again, "#step-accept-form input[type=radio][value=done][disabled]")

    render_hook(again, "step:accept", %{
      "outcome" => "needs_more",
      "seen" => %{"refinement.md" => "2"}
    })

    assert Tickets.get!(ticket.id).state == "refining"
    assert has_element?(again, "#step-error", "as often as the workflow allows")
  end

  test "a step with one way out draws no picker and has it picked", %{conn: conn, user: user} do
    workflow =
      @workflow
      |> String.replace("      outcomes: [done, needs_more]\n", "")
      |> String.replace("  - { from: refining, to: review_ready, when: needs_more }\n", "")

    {:ok, project} =
      Projects.register(
        %{
          name: "stepone-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "One way"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#step-accept-form input[type=radio]")
    assert has_element?(view, "#step-accept-form input[type=hidden][name=outcome][value=done]")
    refute has_element?(view, "button[phx-click='step:review'][disabled]")
  end

  test "what was picked and the open confirm come back on a rejoin", %{conn: conn, chat: chat} do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    # The client re-pushes the form's change event with what it held; a fresh mount given that
    # event draws the pick and the confirm again.
    {:ok, fresh, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(fresh, "step:pick", %{"outcome" => "needs_more", "confirming" => "true"})

    assert has_element?(fresh, "#step-confirm")
    assert has_element?(fresh, "#step-accept-form input[type=radio][value=needs_more][checked]")
    refute has_element?(view, "#step-confirm")
  end

  test "a version written after the page drew is refused with the reason, and the page redraws",
       %{
         conn: conn,
         chat: chat,
         ticket: ticket
       } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    view |> form("#step-accept-form", %{"outcome" => "done"}) |> render_change()

    {:ok, _} =
      Conversations.record_turn(Repo.get!(Job, chat.id), %{
        "turn" => 2,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"refinement.md" => "# Two\n"},
        "harness" => %{"turns" => 1, "cost_usd" => 0.02, "session_id" => "s"}
      })

    # The press carries the version the person's screen showed. The page has since been told of
    # version 2, but a press already in flight from the old draw still says 1.
    render_hook(view, "step:accept", %{"outcome" => "done", "seen" => %{"refinement.md" => "1"}})

    assert Tickets.get!(ticket.id).state == "refining"
    assert has_element?(view, "#step-error", "changed while you were looking")
    assert has_element?(view, "#step-documents", "version 2")
    assert Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id) == []
  end

  test "the ticket's Decide tab shows the same area and links to the conversation", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert has_element?(view, "#step-card", "This step is a conversation")
    assert has_element?(view, "#step-card a[href='/chats/#{chat.id}']")
    assert has_element?(view, "#step-accept-form input[type=radio][value=done]")
    refute has_element?(view, "button", "Run refining again")
  end

  test "a stuck ticket is offered no by-hand move while its conversation is live, and is once dormant",
       %{conn: conn, chat: chat, project: project, ticket: ticket} do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, _} = Forge.Engine.stick(Tickets.get!(ticket.id), "cost cap")

    {:ok, live_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(live_view, "#transitions-#{ticket.id}")

    :ok = Conversations.close(Repo.get!(Job, chat.id), "idle")
    {:ok, dormant, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert has_element?(dormant, "#transitions-#{ticket.id}")
  end

  test "a dormant step offers Reopen and not a run again", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    chat = answered(chat, 1, %{})
    :ok = Conversations.close(chat, "idle")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "button[phx-click=reopen]", "Reopen")
    assert has_element?(view, "#step-dormant")

    {:ok, page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(page, "button", "Run refining again")
  end

  test "a step whose only way out is spent says so, and draws no button", %{
    conn: conn,
    user: user
  } do
    workflow = """
    version: 1
    initial: refining
    states:
      refining:
        chat: true
        prompt: agents/refine.md
        inputs: [ticket]
        produces: [refinement.md]
      review_ready: {}
    transitions:
      - { from: refining, to: review_ready, max: 1 }
      - { from: review_ready, to: refining }
    limits: { ticket_cost: 25 }
    """

    {:ok, project} =
      Projects.register(
        %{
          name: "stepspent-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Once"}, {:user, user.id})
    [first] = Jobs.step_chats_for_ticket(ticket.id)
    answered(first, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{first.id}")
    render_hook(view, "step:accept", %{"outcome" => "done", "seen" => %{"refinement.md" => "1"}})
    {:ok, _} = Forge.Engine.choose(Tickets.get!(ticket.id), user.id, "refining")
    [_first, second] = ticket.id |> Jobs.step_chats_for_ticket() |> Enum.sort_by(& &1.attempt)
    answered(second, 1, %{"refinement.md" => "# R2\n"})

    {:ok, again, _html} = live(conn, ~p"/chats/#{second.id}")
    assert has_element?(again, "#step-blocked", "already taken as often as allowed")
    refute has_element?(again, "#step-accept-form")
    refute has_element?(again, "#step-confirm")

    # The card is for a step that is open and quiet: the earlier visit is over, with every way out
    # spent as well, and says it is over; a reply in flight says it is waiting.
    {:ok, old, _html} = live(conn, ~p"/chats/#{first.id}")
    assert has_element?(old, "#step-over", "accepted")
    refute has_element?(old, "#step-blocked")

    {:ok, _event} = Conversations.send(Repo.get!(Job, second.id), "and another thing")
    {:ok, busy, _html} = live(conn, ~p"/chats/#{second.id}")
    assert has_element?(busy, "#step-waiting")
    refute has_element?(busy, "#step-blocked")
  end

  test "a document an earlier state was to write is said, then written by the agent and shown",
       %{conn: conn, user: user} do
    workflow = """
    version: 1
    initial: refining
    states:
      refining:
        chat: true
        prompt: agents/refine.md
        inputs: [ticket]
        produces: [notes.md]
      drafting:
        prompt: agents/plan.md
        produces: [refinement.md]
        budget: { turns: 5, cost: 1 }
      finished: {}
    transitions:
      - { from: refining, to: finished, approve: [refinement.md] }
      - { from: finished, to: drafting }
      - { from: drafting, to: refining }
    limits: { ticket_cost: 25 }
    """

    {:ok, project} =
      Projects.register(
        %{
          name: "stepappr-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Never drafted"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    chat = answered(chat, 1, %{})

    # Nothing written yet: that is what the area says, not a list of blocked outcomes.
    {:ok, empty, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(empty, "#step-nothing-yet")
    refute has_element?(empty, "#step-blocked")

    chat = answered(chat, 2, %{"notes.md" => "# N\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(
             view,
             "#step-blocked",
             "approves refinement.md, which nobody has written yet. Ask the agent to write it"
           )

    assert has_element?(view, "#step-documents", "not written yet, and an outcome approves it")
    refute has_element?(view, "#step-accept-form")

    # Which the agent can: the document is then listed with its version, sent back as drawn, and
    # the button is there.
    answered(chat, 3, %{"refinement.md" => "# R\n"})
    {:ok, ready, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(ready, "#step-blocked")
    assert has_element?(ready, "#step-documents", "version 1, written in this visit")
    assert has_element?(ready, "#step-accept-form input[name='seen[refinement.md]'][value='1']")
  end

  test "a name the client sends is shown as text, cut to the line, in the refusal", %{
    conn: conn,
    chat: chat
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    outcome = "<img src=x onerror=alert(1)>" <> String.duplicate("x", 200)

    html =
      render_hook(view, "step:accept", %{
        "outcome" => outcome,
        "seen" => %{"refinement.md" => "1"}
      })

    assert has_element?(view, "#step-error", "is not an outcome of this step")
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    assert view |> element("#step-error") |> render() =~ "overflow-wrap:anywhere"
  end

  test "the paragraphs that carry document names wrap at phone width", %{conn: conn, chat: chat} do
    answered(chat, 1, %{})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert view |> element("#step-nothing-yet") |> render() =~ "overflow-wrap:anywhere"

    answered(chat, 2, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    view |> form("#step-accept-form", %{"outcome" => "done"}) |> render_change()
    view |> element("button[phx-click='step:review']") |> render_click()
    assert view |> element("#step-confirm p") |> render() =~ "overflow-wrap:anywhere"
  end

  test "an accept pressed after the page has no step is a redraw, not a crash", %{
    conn: conn,
    project: project
  } do
    {:ok, plain} = Conversations.open(project, "hello")
    {:ok, view, _html} = live(conn, ~p"/chats/#{plain.id}")

    render_hook(view, "step:accept", %{"outcome" => "done"})
    assert Process.alive?(view.pid)
  end

  test "the Decide tab keeps a pick and an open confirm across a rejoin", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    render_hook(view, "step:pick", %{"outcome" => "needs_more", "confirming" => "true"})
    assert has_element?(view, "#step-confirm")
    assert has_element?(view, "#step-accept-form input[type=radio][value=needs_more][checked]")

    {:ok, fresh, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(fresh, "#step-confirm")
    render_hook(fresh, "step:pick", %{"outcome" => "needs_more", "confirming" => "true"})
    assert has_element?(fresh, "#step-confirm")
  end

  test "the timeline shows the accepted step with its outcome, as a job's row does", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")
    render_hook(view, "step:accept", %{"outcome" => "done", "seen" => %{"refinement.md" => "1"}})

    {:ok, page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")
    assert has_element?(page, "#step-accepted-#{chat.id} span.whitespace-nowrap", "done")
    assert has_element?(page, "#step-accepted-#{chat.id}", "planning")
  end

  test "a cancelled ticket draws no step card", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket,
    user: user
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, _} = Forge.Engine.cancel(Tickets.get!(ticket.id), user.id)
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")
    refute has_element?(view, "#step-card")
  end

  test "a step waiting for a missing secret says why on the ticket page too", %{
    conn: conn,
    user: user
  } do
    workflow =
      String.replace(
        @workflow,
        "    chat: true\n",
        "    chat: true\n    secrets: [STRIPE_TEST_KEY]\n"
      )

    assert workflow != @workflow

    {:ok, project} =
      Projects.register(
        %{
          name: "stepwait-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
        },
        user
      )

    funded!(project)
    {:ok, ticket} = Tickets.admit(project, %{title: "Needs a key"}, {:user, user.id})
    [chat] = Jobs.step_chats_for_ticket(ticket.id)
    start_supervised!(Forge.Jobs.Scheduler)
    Forge.Jobs.Scheduler.tick()

    {:ok, timeline, _html} =
      live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")

    assert has_element?(timeline, "#job-#{chat.id}-waiting", "STRIPE_TEST_KEY")

    {:ok, decide, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")
    assert has_element?(decide, "#step-waiting-reason", "STRIPE_TEST_KEY")
  end

  test "a by-hand move while the step is live is refused in words that say to Accept", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    html =
      render_hook(view, "transition", %{
        "ticket" => ticket.id,
        "to" => "review_ready",
        "outcome" => "needs_more"
      })

    assert html =~ "refining is a conversation; Accept it to move on"
    assert Tickets.get!(ticket.id).state == "refining"
  end

  test "the API names a live step as one, not as an internal error" do
    conn =
      ForgeWeb.Api.FallbackController.call(
        Phoenix.ConnTest.build_conn(),
        {:error, {:step_live, "refining"}}
      )

    assert %{"error" => %{"reason" => "step_live", "detail" => detail}} = json_response(conn, 409)
    assert detail =~ "Accept"
  end
end
