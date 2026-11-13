defmodule ForgeWeb.ChatStepLiveTest do
  @moduledoc """
  The Accept area of a chat step (`docs/design/ui.md` § The Accept area), on the conversation's
  page and on the ticket's: what it says before anything is written, while a reply is in flight,
  and when it can be pressed — the decision row and its panel (§ The decision row) — and that a
  press sends what the page showed.
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
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: refining, to: review_ready, when: needs_more }
    - { from: planning, to: review_ready }
  limits: { ticket_tokens: 5M }
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
        "harness" => %{
          "turns" => 1,
          "usage" => 2_000 * index,
          "cost_usd" => 0.01 * index,
          "session_id" => "s"
        }
      })

    chat
  end

  # The row's button drops the panel; the panel holds the form.
  defp count_of(view, tab) do
    view
    |> element("#tab-#{tab}")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(".ui-count")
    |> Floki.text()
    |> String.trim()
  end

  defp open!(view) do
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    assert has_element?(view, "#decision-panel")
    view
  end

  test "before anything is written it says what is expected, and draws no button", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{})
    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    # The ticket's frame (`docs/design/ui.md` § The Accept area): its title, its state and visit
    # — the subline the ticket's own page draws, mark and all, and the visit after it (UX pass,
    # B28).
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "refining · visit 1")
    {:ok, ticket_page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    ticket_sub =
      ticket_page
      |> element("#title-row .frame-subline")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.trim()

    chat_sub =
      view
      |> element("#top-bar .ui-top-title > .ui-top-sub")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.text()
      |> String.trim()

    assert chat_sub == ticket_sub <> " · visit 1"
    # Markup in the ticket title is text.
    assert html =~ "&lt;b&gt;Persist&lt;/b&gt; scores"
    assert has_element?(view, "#step-nothing-yet", "refinement.md")
    # Nothing to accept, so no row and nothing amber (`16e`).
    refute has_element?(view, "#decision-row")
  end

  # The conversation's page draws the ticket's frame (§ The Accept area): titled by the ticket,
  # Talk this page, and every other view the ticket's own, so Steps, Changes, Docs and Activity
  # are the ticket's whatever the address asked for.
  test "draws the ticket's frame, with the other views the ticket's", %{
    conn: conn,
    chat: chat,
    ticket: ticket,
    project: project
  } do
    answered(chat, 1, %{"refinement.md" => "# Refinement\n\nThe leaderboard.\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

    assert has_element?(view, "#top-bar .ui-top-name", "<b>Persist</b> scores")
    assert has_element?(view, ~s(#tab-talk[href="/chats/#{chat.id}"]))

    {:ok, ticket_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    for tab <- ~w(steps changes docs activity) do
      assert has_element?(
               view,
               ~s(#tab-#{tab}[href="/tickets/#{project.name}/#{ticket.number}?tab=#{tab}"])
             )

      # With the counts the ticket's own strip draws, from the one builder the job page uses.
      assert count_of(view, tab) == count_of(ticket_view, tab)
    end

    assert count_of(view, "docs") =~ ~r/^\d+$/

    # Talk, whatever the address said: the other views are not this page's.
    assert has_element?(view, "#messages")
    refute has_element?(view, "#docs")

    # A wide screen reads the step's document beside the conversation (`16i`).
    assert has_element?(view, "#aside-document", "refinement.md v1")
    assert has_element?(view, "#aside-document", "The leaderboard.")
    refute has_element?(view, "#chat-aside-branch")
  end

  # The strip reads the ticket's jobs, its documents and a diff of its whole branch, so it is
  # built when the page loads and when the ticket changes — never per streamed block, which a
  # step's conversation renders on (r3 M1); and so, for the same reason, are the details' model
  # and effort, a query each when the conversation names none. The view's own queries, counted where they run: the
  # telemetry handler runs in the process that queried, so only the page's are seen. A subagent's
  # blocks, so that nothing but the stream arrives: the agent's own words also tell the frame's
  # counts that a conversation may now be waiting, and those are read again (`Frame.follow`).
  test "streamed blocks redraw the transcript and read nothing for the strip", %{
    conn: conn,
    chat: chat
  } do
    answered(chat, 1, %{"refinement.md" => "# Refinement\n\nThe leaderboard.\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    test = self()
    handler = "chat-strip-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:forge, :repo, :query],
      fn _event, _measurements, meta, pid ->
        if self() == pid, do: send(test, {:queried, meta.source})
      end,
      view.pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for n <- 1..5 do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{text: "block #{n}", parent_tool_use_id: "toolu_1"}
        })
    end

    # The page holds every block, and redrew for each.
    held = :sys.get_state(view.pid).socket.assigns.events
    assert Enum.count(held, &(&1.payload["parent_tool_use_id"] == "toolu_1")) == 5
    refute_received {:queried, _source}
  end

  test "a reply in flight says it is waiting, with no button", %{conn: conn, chat: chat} do
    # Nothing recorded yet: the opening is in flight.
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#step-waiting", "Waiting for the reply")
    refute has_element?(view, "#decision-row")
  end

  test "several outcomes preselect none, and Accept is a second step that moves the ticket", %{
    conn: conn,
    chat: chat,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    # The row, amber, with the document and its version; the panel only once it is pressed.
    assert has_element?(view, "#decision-row:not(.ui-decision--neutral)", "refinement.md v1")
    refute has_element?(view, "#decision-panel")
    open!(view)

    assert has_element?(view, "#decision-form input[type=radio][value=done]")
    assert has_element?(view, "#decision-form input[type=radio][value=needs_more]")
    # None preselected (plan.md § 6, `ui.md` § The Accept area), and Accept waits for a pick.
    refute has_element?(view, "#decision-form input[type=radio][checked]")
    # Until a pick, the button says why it does nothing (UX pass, B20).
    assert has_element?(view, "#decision-form button[type=submit][disabled]", "Pick an outcome")
    assert has_element?(view, "#step-documents", "version 1, written in this visit")

    view |> form("#decision-form", %{"outcome" => "done"}) |> render_change()
    refute has_element?(view, "#decision-form button[type=submit][disabled]")
    assert has_element?(view, "#decision-form button[type=submit]", "Accept")
    refute has_element?(view, "#decision-form button[type=submit]", "Pick an outcome")
    assert has_element?(view, "#decision-panel", "approves the latest version of refinement.md")
    assert has_element?(view, "#decision-form button[type=submit][phx-disable-with]")

    view |> form("#decision-form") |> render_submit()

    assert Tickets.get!(ticket.id).state == "planning"
    assert has_element?(view, "#step-over", "accepted")
    refute has_element?(view, "#decision-row")
    assert has_element?(view, "#toast", "Accepted step refining")
    # A finished step is not offered Reopen: it would be refused.
    refute has_element?(view, "button[phx-click=reopen]")
  end

  test "open questions are warned of and never answerable in the panel", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    run!(chat)

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{
          text: """
          Two things are open.

          ```question
          key: rows
          text: How many rows?
          ```

          ```question
          key: rank
          text: Show the rank?
          options:
            - {label: yes, detail: Rank and score}
            - {label: no, detail: Only the score}
          ```
          """
        }
      })

    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    open!(view)

    assert has_element?(
             view,
             "#decision-panel .ui-notice",
             "2 open questions will stay unanswered"
           )

    assert has_element?(view, "#decision-panel .ui-notice", "How many rows?")
    assert has_element?(view, "#decision-panel .ui-notice", "Show the rank?")
    # Never answered in here: the panel has no question's options and no answer box.
    refute has_element?(view, "#decision-panel input[name^=answers]")
    refute has_element?(view, "#decision-panel textarea[name^=answers]")
    assert has_element?(view, "#decision-form button[type=submit][disabled]", "Pick an outcome")
    view |> form("#decision-form", %{"outcome" => "done"}) |> render_change()
    assert has_element?(view, "#decision-form button[type=submit]", "Accept anyway")

    # Answer first folds the panel, and the question card is there under it.
    view |> element("#decision-form button", "Answer first") |> render_click()
    refute has_element?(view, "#decision-panel")
    assert has_element?(view, "#answer-rows", "How many rows?")

    # On the ticket's page the same warning, and Answer first goes to the conversation.
    {:ok, page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    open!(page)

    assert has_element?(
             page,
             "#decision-panel .ui-notice",
             "2 open questions will stay unanswered"
           )

    assert has_element?(page, ~s(#decision-form a[href="/chats/#{chat.id}"]), "Answer first")
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
    render_hook(view, "decision:accept", %{
      "outcome" => "needs_more",
      "seen" => %{"refinement.md" => "1"}
    })

    assert Tickets.get!(ticket.id).state == "review_ready"
    {:ok, _} = Forge.Engine.choose(Tickets.get!(ticket.id), user.id, "refining")
    [_first, second] = Jobs.step_chats_for_ticket(ticket.id) |> Enum.sort_by(& &1.attempt)
    answered(second, 1, %{"refinement.md" => "# R2\n"})

    {:ok, again, _html} = live(conn, ~p"/chats/#{second.id}")
    open!(again)
    assert has_element?(again, "#decision-form input[type=radio][value=needs_more][disabled]")
    assert has_element?(again, "#decision-form", "already taken as often as allowed")
    # One outcome is spent and the other is not: the form is there, and the card for a step with
    # nothing left to press is not.
    refute has_element?(again, "#step-blocked")
    refute has_element?(again, "#decision-form input[type=radio][value=done][disabled]")

    render_hook(again, "decision:accept", %{
      "outcome" => "needs_more",
      "seen" => %{"refinement.md" => "2"}
    })

    assert Tickets.get!(ticket.id).state == "refining"
    # Refused inside the panel, which stays open (`ui.md` § Errors stay where you acted).
    assert has_element?(
             again,
             "#decision-panel #decision-error",
             "as often as the workflow allows"
           )
  end

  # The page stays connected after its viewer leaves the project: the press is checked against
  # who they are when it arrives (`Forge.Operator.accept_step/4`).
  test "a press by somebody no longer in the project accepts nothing", %{
    chat: chat,
    ticket: ticket,
    project: project,
    user: admin
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    member = Forge.AccountsFixtures.user_fixture()
    {:ok, _} = Projects.put_member(project, member, :member, admin)
    {:ok, view, _html} = live(log_in_user(build_conn(), member), ~p"/chats/#{chat.id}")

    :ok = Projects.remove_member(project, member, admin)

    render_hook(view, "decision:accept", %{
      "outcome" => "done",
      "seen" => %{"refinement.md" => "1"}
    })

    assert Tickets.get!(ticket.id).state == "refining"
    assert render(view) =~ "You are not a member of this project."
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
    open!(view)

    refute has_element?(view, "#decision-form input[type=radio]")
    assert has_element?(view, "#decision-form input[type=hidden][name=outcome][value=done]")
    refute has_element?(view, "#decision-form button[type=submit][disabled]")
  end

  test "what was picked and the open panel come back on a rejoin", %{conn: conn, chat: chat} do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    # The client re-pushes the form's change event with what it held; a fresh mount given that
    # event draws the open panel and the pick again.
    {:ok, fresh, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_hook(fresh, "decision:change", %{"outcome" => "needs_more"})

    assert has_element?(fresh, "#decision-panel")
    assert has_element?(fresh, "#decision-form input[type=radio][value=needs_more][checked]")
    refute has_element?(view, "#decision-panel")
  end

  test "a version written after the page drew is refused with the reason, and the page redraws",
       %{
         conn: conn,
         chat: chat,
         ticket: ticket
       } do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    open!(view)
    view |> form("#decision-form", %{"outcome" => "done"}) |> render_change()

    {:ok, _} =
      Conversations.record_turn(Repo.get!(Job, chat.id), %{
        "turn" => 2,
        "commit" => String.duplicate("a", 40),
        "documents" => %{"refinement.md" => "# Two\n"},
        "harness" => %{"turns" => 1, "usage" => 4_000, "cost_usd" => 0.02, "session_id" => "s"}
      })

    # The press carries the version the person's screen showed. The page has since been told of
    # version 2, but a press already in flight from the old draw still says 1.
    render_hook(view, "decision:accept", %{
      "outcome" => "done",
      "seen" => %{"refinement.md" => "1"}
    })

    assert Tickets.get!(ticket.id).state == "refining"
    assert has_element?(view, "#decision-error", "changed while you were looking")
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
    open!(view)
    assert has_element?(view, "#decision-form input[type=radio][value=done]")
    refute has_element?(view, "button", "Run refining again")
  end

  test "a stuck ticket is offered no by-hand move while its conversation is live, and is once dormant",
       %{conn: conn, chat: chat, project: project, ticket: ticket} do
    chat = answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, _} = Forge.Engine.stick(Tickets.get!(ticket.id), "cost cap")

    {:ok, live_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(live_view, ~s(#ways-forward input[value^="to:"]))

    :ok = Conversations.close(Repo.get!(Job, chat.id), "idle")
    {:ok, dormant, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert has_element?(dormant, ~s(#ways-forward input[value^="to:"]))
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
    assert has_element?(view, "#step-status #step-dormant")

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
    limits: { ticket_tokens: 5M }
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

    render_hook(view, "decision:accept", %{
      "outcome" => "done",
      "seen" => %{"refinement.md" => "1"}
    })

    {:ok, _} = Forge.Engine.choose(Tickets.get!(ticket.id), user.id, "refining")
    [_first, second] = ticket.id |> Jobs.step_chats_for_ticket() |> Enum.sort_by(& &1.attempt)
    answered(second, 1, %{"refinement.md" => "# R2\n"})

    {:ok, again, _html} = live(conn, ~p"/chats/#{second.id}")
    open!(again)
    assert has_element?(again, "#step-blocked", "already taken as often as allowed")
    refute has_element?(again, "#decision-form button[type=submit]")

    # The card is for a step that is open and quiet: the earlier visit is over, with every way out
    # spent as well, and says it is over; a reply in flight says it is waiting.
    {:ok, old, _html} = live(conn, ~p"/chats/#{first.id}")
    assert has_element?(old, "#step-over", "accepted")
    refute has_element?(old, "#step-blocked")

    {:ok, _event} = Conversations.send(Repo.get!(Job, second.id), "and another thing")
    {:ok, busy, _html} = live(conn, ~p"/chats/#{second.id}")
    # The row stays, its button disabled until the reply has finished.
    assert has_element?(busy, "#decision-row button[disabled]")
    assert has_element?(busy, "#decision-row", "waiting for the reply to finish")
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
        budget: { turns: 5, tokens: 200k }
      finished: {}
    transitions:
      - { from: refining, to: finished, approve: [refinement.md] }
      - { from: finished, to: drafting }
      - { from: drafting, to: refining }
    limits: { ticket_tokens: 5M }
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
    open!(view)

    assert has_element?(
             view,
             "#step-blocked",
             "approves refinement.md, which nobody has written yet. Ask the agent to write it"
           )

    assert has_element?(view, "#step-documents", "not written yet, and an outcome approves it")
    refute has_element?(view, "#decision-form button[type=submit]")

    # Which the agent can: the document is then listed with its version, sent back as drawn, and
    # the button is there.
    answered(chat, 3, %{"refinement.md" => "# R\n"})
    {:ok, ready, _html} = live(conn, ~p"/chats/#{chat.id}")
    open!(ready)
    refute has_element?(ready, "#step-blocked")
    assert has_element?(ready, "#step-documents", "version 1, written in this visit")
    assert has_element?(ready, "#decision-form input[name='seen[refinement.md]'][value='1']")
    assert has_element?(ready, "#decision-form button[type=submit]")
  end

  test "a name the client sends is shown as text, cut to the line, in the refusal", %{
    conn: conn,
    chat: chat
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    outcome = "<img src=x onerror=alert(1)>" <> String.duplicate("x", 200)

    html =
      render_hook(view, "decision:accept", %{
        "outcome" => outcome,
        "seen" => %{"refinement.md" => "1"}
      })

    assert has_element?(view, "#decision-error", "is not an outcome of this step")
    assert html =~ "&lt;img src=x onerror=alert(1)&gt;"
    refute html =~ "<img src=x"
    # The one refusal in place, whose rule wraps anywhere (`.ui-error-note`, components.css).
    assert view |> element("#decision-error") |> render() =~ "ui-error-note"
  end

  test "the paragraphs that carry document names wrap at phone width", %{conn: conn, chat: chat} do
    answered(chat, 1, %{})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert view |> element("#step-nothing-yet") |> render() =~ "overflow-wrap:anywhere"

    answered(chat, 2, %{})
    :ok = Conversations.close(Repo.get!(Job, chat.id), "idle")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert view |> element("#step-dormant") |> render() =~ "overflow-wrap:anywhere"
  end

  test "an accept pressed after the page has no step is a redraw, not a crash", %{
    conn: conn,
    project: project
  } do
    {:ok, plain} = Conversations.open(project, "hello")
    {:ok, view, _html} = live(conn, ~p"/chats/#{plain.id}")

    render_hook(view, "decision:accept", %{"outcome" => "done"})
    assert Process.alive?(view.pid)
  end

  test "the ticket's page keeps a pick and an open panel across a rejoin", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    render_hook(view, "decision:change", %{"outcome" => "needs_more"})
    assert has_element?(view, "#decision-panel")
    assert has_element?(view, "#decision-form input[type=radio][value=needs_more][checked]")

    {:ok, fresh, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(fresh, "#decision-panel")
    render_hook(fresh, "decision:change", %{"outcome" => "needs_more"})
    assert has_element?(fresh, "#decision-form input[type=radio][value=needs_more][checked]")
  end

  test "Steps shows the accepted step with its outcome, as a job's row does", %{
    conn: conn,
    chat: chat,
    project: project,
    ticket: ticket
  } do
    answered(chat, 1, %{"refinement.md" => "# R\n"})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")

    render_hook(view, "decision:accept", %{
      "outcome" => "done",
      "seen" => %{"refinement.md" => "1"}
    })

    {:ok, page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")
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
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")
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

    {:ok, steps, _html} =
      live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")

    assert has_element?(steps, "#job-#{chat.id}-waiting", "STRIPE_TEST_KEY")
    assert has_element?(steps, "#step-card #step-waiting-reason", "STRIPE_TEST_KEY")
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
