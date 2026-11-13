defmodule ForgeWeb.ProjectLiveTest do
  @moduledoc """
  One project (`docs/design/ui.md` § The project page): its open tickets, what waits on you
  first, its views, its workflow, `+ New` and the repository behind it.

  One distinction worth testing is the one the page exists to make legible — the workflow it
  shows is the repository's current one, which the *next* ticket will pin, while each ticket
  follows the workflow it was admitted with. Those differ the moment a workflow changes, and a
  page that conflated them would be wrong exactly when it mattered.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Projects, Tickets}

  # A message `ago` seconds old: events are append-only, so a time is chosen by adding one later
  # in the log, which is what a list reads as the last thing said.
  defp said_at(chat, text, ago) do
    Forge.Repo.insert!(%Forge.Events.Event{
      actor: %{"kind" => "system", "id" => nil},
      type: "chat.message",
      payload: %{"text" => text},
      job_id: chat.id,
      project_id: chat.project_id,
      inserted_at: DateTime.add(DateTime.utc_now(:second), -ago, :second)
    })
  end

  setup :register_and_log_in_user

  setup %{user: user} do
    repos = node_repos_dir()
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :repos_dir, repos))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    {:ok, project} =
      Projects.register(
        %{
          name: "proj-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    %{project: project}
  end

  test "shows the tickets, the workflow and the repository", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

    # The ticket on its row, in its state.
    assert has_element?(view, "#tickets-rest-#{ticket.number}", "Persist scores")
    assert has_element?(view, "#tickets-rest-#{ticket.number}", ticket.state)
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "1 open")

    # The workflow the next ticket will pin, read off the repository, scoped to the flow.
    assert html =~ "How a new ticket moves"
    assert html =~ "which the next ticket will pin"
    assert has_element?(view, "#workflow", "runs refine.md · writes refinement.md")
    assert has_element?(view, "#workflow", "20 turns")
    assert has_element?(view, "#details-facts dd", project.default_branch)

    # No raw event names, and no seed fact that only says there is none.
    refute has_element?(view, "#details-facts", "Latest activity")
    refute has_element?(view, "#details-facts", "worker seed")

    # And the one thing an operator has to leave the product for.
    assert has_element?(view, "#details-facts-clone-url", "/git/#{project.name}.git")
  end

  test "the workflow shown is the repository's, not the tickets'", %{
    conn: conn,
    project: project
  } do
    # The distinction the page is built around. The ticket pins `refining` at admission; the
    # repository then moves on, and the page has to show both truths at once.
    {:ok, ticket} = Tickets.admit(project, %{title: "Admitted before the change"}, :system)
    rewrite_workflow(project)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

    # The ticket's row is drawn on what it pinned.
    assert has_element?(view, "#tickets-rest-#{ticket.number}", "refining")
    # The flow is the repository's current workflow, which no ticket has ever been in.
    assert has_element?(view, "#workflow", "surveying")
    assert has_element?(view, "#workflow", "survey.md")
    refute has_element?(view, "#workflow", "refining")
  end

  # Commits a different workflow onto the project's default branch, so the repository's current
  # workflow and every pinned one disagree.
  defp rewrite_workflow(project) do
    commit_to_default(project, %{
      ".forge/agents/survey.md" => "Survey it.\n",
      ".forge/workflow.yml" => """
      version: 1
      initial: surveying
      states:
        surveying:
          prompt: agents/survey.md
          inputs: [ticket]
          produces: [survey.md]
          budget: { turns: 5, tokens: 20k }
        done_state: {}
      transitions:
        - { from: surveying, to: done_state }
      limits: { ticket_tokens: 200k }
      """
    })
  end

  test "an empty project says so rather than drawing an empty board", %{conn: conn, user: user} do
    {:ok, project} =
      Projects.register_named("bare-#{System.unique_integer([:positive])}", "main", user)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "No tickets yet"
    assert has_element?(view, "#tickets-none a[href='/tickets/new?project=#{project.name}']")
    # Registered but with nothing pushed: it cannot take a ticket, and the page says which.
    # The whole sentence, not the filename: `ForgeWeb.Operator.Admission` has two clauses for
    # this and both name `.forge/workflow.yml`, so the filename alone holds whichever fired.
    assert html =~ "cannot take a ticket"
    assert html =~ "there is no .forge/workflow.yml on its default branch"
  end

  # The other clause, which is a different fact and not a different wording of the same one: a
  # branch with no workflow file on it is a repository waiting for one commit, while a branch that
  # does not exist is a repository the platform cannot find its footing in at all. Told the wrong
  # one, an operator spends the afternoon pushing a file onto a branch that is not there.
  test "a project whose default branch is missing is told that, not that a file is", %{
    conn: conn,
    project: project
  } do
    {:ok, _out} =
      Forge.Git.run(Projects.repo_path(project), [
        "update-ref",
        "-d",
        "refs/heads/#{project.default_branch}"
      ])

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

    assert html =~ "nothing has been pushed to its #{project.default_branch} branch yet"
    refute html =~ "there is no .forge/workflow.yml on its default branch"
  end

  test "it reloads when a ticket changes", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")
    refute html =~ "Arrived later"

    {:ok, _ticket} = Tickets.admit(project, %{title: "Arrived later"}, :system)

    assert render(view) =~ "Arrived later"
  end

  # A project chat's changes are broadcast with no ticket, on the topic every ticket's are, and a
  # page that looked the id up read nil and crashed.
  test "a change with no ticket leaves the page as it is", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

    Forge.Events.notify(nil)

    assert render(view) =~ project.name
  end

  # `/chats` and this page share one row component, and it takes `project={false}` here. That attr
  # exists for this page alone: the name is already the heading and already the URL, so repeating
  # it on every row is noise on the one surface where it tells you nothing. Nothing page-wide can
  # see the difference — the name is in the heading either way — so both halves are scoped to the
  # row, and the second half is what stops the attr being "fixed" by always hiding the name.
  test "a chat row names its project only where that is news", %{conn: conn, project: project} do
    {:ok, chat} = Conversations.open(project, "about the parser")
    row = ~s(a[href="/chats/#{chat.id}"])

    {:ok, own_page, _html} = live(conn, ~p"/projects/#{project.name}")
    assert own_page |> element(row) |> render() =~ "about the parser"
    refute own_page |> element(row) |> render() =~ project.name

    {:ok, all_chats, _html} = live(conn, ~p"/chats")
    assert all_chats |> element(row) |> render() =~ project.name
  end

  # The same component and the same order as `/chats`, under the page's own heading, and woken
  # only by this project's conversations.
  test "the conversations are in sections, follow what is said, and only this project's", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, running} = Conversations.open(project, "still going")
    {:ok, finished} = Conversations.open(project, "all done")
    {:ok, _closed} = Conversations.ended(finished, nil, "closed")

    {:ok, other_project} =
      Projects.register(
        %{name: "other-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, elsewhere} = Conversations.open(other_project, "somewhere else")
    said_at(running, "old", 3600)
    said_at(finished, "newer", 1800)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

    assert has_element?(view, "#conversations-live h3", "Live · 1")
    assert has_element?(view, "#conversations-live #conversation-#{running.id}")
    assert has_element?(view, "#conversations-earlier h3", "Earlier")
    assert has_element?(view, "#conversations-earlier #conversation-#{finished.id}")
    refute has_element?(view, "#conversation-#{elsewhere.id}")

    # Named by what it was opened with, its last line beneath; no turns, no figure for them.
    assert has_element?(view, "#conversation-#{finished.id} .ui-row-title", "all done")
    assert has_element?(view, "#conversation-#{finished.id} .ui-row-latest", "newer")
    refute view |> element("#conversation-#{finished.id}") |> render() =~ "turns"

    # Another project's conversation does not wake it; this one's does.
    Forge.Repo.update_all(from(j in Forge.Jobs.Job, where: j.id == ^running.id), set: [turns: 7])
    {:ok, _event} = Conversations.send(elsewhere, "not here")
    refute render(view) =~ "7 turns"

    {:ok, _event} = Conversations.send(running, "here")
    assert render(view) =~ "7 turns"
    assert view |> element("#conversation-#{running.id}") |> render() =~ "now"
  end

  test "a chat nobody has answered yet does not say its opening twice", %{
    conn: conn,
    project: project
  } do
    {:ok, chat} = Conversations.open(project, "about the parser")
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")

    assert has_element?(view, "#conversation-#{chat.id} .ui-row-title", "about the parser")
    refute has_element?(view, "#conversation-#{chat.id} .ui-row-latest")
  end

  # A chat with no ticket is told on the chats topic only.
  test "an unscoped chat's end redraws the page", %{conn: conn, project: project} do
    {:ok, chat} = Conversations.open(project, "about the parser")

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
    assert has_element?(view, "#conversations-live #conversation-#{chat.id}")

    {:ok, _closed} = Conversations.ended(chat, nil, "closed")

    refute has_element?(view, "#conversations-live")
    assert has_element?(view, "#conversation-#{chat.id}")
  end

  test "an unknown project is a 404", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/no-such-project") end
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/projects/#{project.name}")
  end

  test "the projects page links to it, and so does a ticket", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, projects, _html} = live(conn, ~p"/projects")
    assert has_element?(projects, ~s(#project-rows a[href="/projects/#{project.name}"]))

    {:ok, _view, page} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert page =~ ~s(href="/projects/#{project.name}")
  end

  describe "ticket proposals" do
    setup %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
      [job | _] = Forge.Jobs.for_ticket(ticket.id)

      version =
        Forge.ForgeFixtures.proposal_fixture(%{
          job: job,
          title: "Extract the score table",
          body: "The plan assumes a module that is not there."
        })

      %{ticket: ticket, version: version}
    end

    test "are listed with what they say and where they came from", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Extract the score table"
      assert html =~ "The plan assumes a module that is not there."
      assert html =~ "ticket ##{ticket.number}"
      assert html =~ ~s(value="accepted")
      assert html =~ ~s(value="declined")
    end

    # A project with no ticket types has no type to choose, so Admit never waits for one — in the
    # reader or for a selection. The tests that submit the form directly ignore `disabled`, so
    # nothing saw Admit drawn disabled in every typeless project (review fixes 7, M3).
    test "Admit is offered at once where there are no types to choose", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{version.id}")

      assert has_element?(view, ~s(#proposal-reader button[value="accepted"]))
      refute has_element?(view, ~s(#proposal-reader button[value="accepted"][disabled]))
      refute has_element?(view, "#proposal-admit-why")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")
      view |> element("#proposal-lists + button", "Select") |> render_click()
      view |> form("#proposal-select") |> render_change(%{"ids" => [version.id]})

      assert has_element?(view, ~s(#proposal-bulk button[value="admit"]))
      refute has_element?(view, ~s(#proposal-bulk button[value="admit"][disabled]))
    end

    # `docs/design/ui.md` § The affordance rule: as a one-line input the comment submitted on
    # Enter with the form's first button, which is Accept. What is pinned is the box ExUnit can
    # see: a textarea on the composer's hook, Enter a new line at every pointer.
    test "Enter in a proposal's comment is a new line", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      box = view |> element("#proposal-comment-#{version.id}") |> render()
      assert box =~ "<textarea"
      assert box =~ ~s(data-newline-on="all")
      refute has_element?(view, "input[name=comment]")
    end

    test "accepting one admits a ticket and stops listing it", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      # Dispatched rather than submitted through the form: the decision is carried by the
      # button's own value, which `form/3` cannot set. The markup that offers both buttons is
      # asserted in the test above.
      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "accepted"
        })

      assert html =~ "Admitted as ticket"
      refute html =~ "propose-#{version.id}"

      assert Enum.any?(Tickets.list(project), &(&1.title == "Extract the score table"))
    end

    test "declining one records it and stops listing it", %{
      conn: conn,
      project: project,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "declined",
          "comment" => "out of scope"
        })

      assert has_element?(view, "#toast", "Declined")
      refute html =~ "Extract the score table"
      refute Enum.any?(Tickets.list(project), &(&1.title == "Extract the score table"))
    end

    # A page rendered minutes ago offers a button the context will refuse — the same trap
    # `conversations.md` names for a conversation that has stopped. The refusal has to be
    # legible rather than a crash or a silent no-op.
    test "deciding one that someone already decided says so", %{
      conn: conn,
      project: project,
      user: user,
      version: version
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      {:ok, _} = Forge.Proposals.decline(version.id, user.id, nil)

      html =
        render_submit(view, "decide_proposal", %{
          "version_id" => version.id,
          "decision" => "accepted"
        })

      assert html =~ "already decided"
    end

    # Nothing else in the product admits a ticket the operator did not type, so the page has to
    # say that accepting is what starts work — otherwise it reads as filing, not as spending.
    test "says plainly that nothing runs until one is accepted", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Nothing runs until you admit one."
    end
  end

  # On a wide screen every view is on one page: a view the address names is scrolled to, so a
  # link to the workflow lands on it. The default view names nothing to scroll to.
  test "a view named in the address is the one the wide page opens on", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=workflow")
    assert has_element?(view, ~s(#view-scroller[data-section="workflow"]))

    for path <- [~p"/projects/#{project.name}", ~p"/projects/#{project.name}?view=tickets"] do
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "#view-scroller")
    end
  end

  # A phone draws the flow, a wider screen the map; both are on the page and CSS shows one, so a
  # page never has to know its width (`docs/design/ui.md` § Workflow).
  test "the workflow is drawn as a flow and as a map", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

    assert has_element?(view, "ol#workflow li", "refining")
    assert has_element?(view, "svg#map-workflow", "refining")
  end

  describe "the tickets" do
    # Three open tickets: one stuck, so waiting on you, and changed longest ago; one changed an
    # hour ago; one changed a minute ago.
    setup %{project: project} do
      stuck = Forge.ProjectFixtures.ticket_in!(project, 1, "refining", status: :stuck, ago: 7200)
      older = Forge.ProjectFixtures.ticket_in!(project, 2, "refining", ago: 3600)
      newer = Forge.ProjectFixtures.ticket_in!(project, 3, "refining", ago: 60)
      %{stuck: stuck, older: older, newer: newer}
    end

    test "what waits on you comes first, then the rest by last change", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#tickets-waiting #tickets-waiting-1.ui-row--accent")
      refute has_element?(view, "#tickets-rest-1")
      assert has_element?(view, "#tickets-waiting-1", "Stuck in refining")
      assert has_element?(view, "#tickets-waiting-1", "stuck")

      # Amber is the waiting row's alone (`ui.md` § Colour): its track's current tick, and not the
      # ticks of a ticket that waits on nobody.
      assert has_element?(view, "#tickets-waiting-1 .ui-track--waiting")
      assert has_element?(view, "#tickets-rest-3 .ui-track")
      refute has_element?(view, "#tickets-rest-3 .ui-track--waiting")
      assert has_element?(view, "#tickets-table-1 .ui-track--waiting")
      refute has_element?(view, "#tickets-table-3 .ui-track--waiting")

      # The table draws them all in the same order: the waiting one, then newest change first.
      table = view |> element("#tickets-table") |> render()
      order = Regex.scan(~r/id="tickets-table-(\d+)"/, table) |> Enum.map(&List.last/1)
      assert order == ["1", "3", "2"]
    end

    test "the filter narrows to what waits, and a state chosen on the map to that state", %{
      conn: conn,
      project: project,
      newer: newer
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      view |> element(~s(#ticket-filter button[value="waiting"])) |> render_click()
      assert has_element?(view, "#tickets-waiting-1")
      refute has_element?(view, "#tickets-rest-3")

      Forge.Repo.update!(Ecto.Changeset.change(newer, state: "planning"))
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?state=planning")
      assert has_element?(view, "#ticket-state-filter", "in planning")
      assert has_element?(view, "#tickets-rest-3")
      refute has_element?(view, "#tickets-rest-2")
      refute has_element?(view, "#tickets-waiting-1")
    end

    test "a running ticket says so, and what its agent said last", %{
      conn: conn,
      project: project,
      newer: newer
    } do
      [job] = Forge.ProjectFixtures.jobs_running!(newer, 1)
      # A later job still waiting for a machine: the ticket is running while any of it is.
      Forge.ForgeFixtures.job_fixture(%{ticket: newer, attempt: 2, status: :pending})

      # The newest of the agent's own lines, whatever came before it.
      for {text, parent} <- [
            {"An older line.", nil},
            {"Reading the resize handler.", nil},
            {"a subagent's report", "t1"}
          ] do
        Forge.Repo.insert!(%Forge.Events.Event{
          actor: %{"kind" => "job", "id" => job.id},
          type: "job.harness.text",
          payload: %{"text" => text, "parent_tool_use_id" => parent},
          job_id: job.id,
          ticket_id: newer.id,
          project_id: project.id
        })
      end

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#tickets-rest-3 .ticket-doing--info", "running")
      assert has_element?(view, "#tickets-rest-3", "agent · Reading the resize handler.")
      refute has_element?(view, "#tickets-rest-3", "subagent")
      refute has_element?(view, "#tickets-rest-3", "An older line.")
    end

    test "a row whose doing-word carries an age does not say it again at its end", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      # Stuck carries its age (`stuck 2h`); an idle one says its age only at its end.
      assert has_element?(view, "#tickets-waiting-1 .ticket-doing", "stuck")
      # Stuck waits on you: amber, as a wait is (UX re-check #4).
      assert has_element?(view, "#tickets-waiting-1 .ticket-doing--accent", "stuck")
      refute has_element?(view, "#tickets-waiting-1 .ticket-row-age")
      assert has_element?(view, "#tickets-rest-3 .ticket-row-age")
    end

    test "Running counts and keeps the tickets with a job running now, nothing else", %{
      conn: conn,
      project: project,
      older: older,
      newer: newer
    } do
      Forge.ProjectFixtures.jobs_running!(newer, 1)
      # Waiting for a machine: drawn with the running ones on the map, but not running.
      Forge.ForgeFixtures.job_fixture(%{ticket: older, status: :pending})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert view |> element(~s(#ticket-filter button[value="running"] .ui-count)) |> render() =~
               ">1<"

      view |> element(~s(#ticket-filter button[value="running"])) |> render_click()
      assert has_element?(view, "#tickets-rest-3")
      refute has_element?(view, "#tickets-rest-2")
    end

    test "a phone row shows its spend only past half of what the ticket may spend", %{
      conn: conn,
      project: project,
      older: older,
      newer: newer
    } do
      cap = Forge.Tickets.workflow(newer).limits.ticket_tokens
      Forge.Repo.update!(Ecto.Changeset.change(newer, usage: round(cap * 0.6)))
      Forge.Repo.update!(Ecto.Changeset.change(older, usage: round(cap * 0.4)))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#tickets-rest-3 .ticket-usage--high")
      refute has_element?(view, "#tickets-rest-2 .ticket-usage")
      # The table keeps the column for every row, the high one in the warning colour.
      assert has_element?(view, "#tickets-table-2 .ticket-usage")
      refute has_element?(view, "#tickets-table-2 .ticket-usage--high")
      assert has_element?(view, "#tickets-table-3 .ticket-usage--high")

      # Nothing spent is no figure, never `0 windows`.
      Forge.Repo.update!(Ecto.Changeset.change(Forge.Repo.reload!(older), usage: 0))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      assert view |> element("#tickets-table-2 .ticket-usage") |> render() =~ "—"
    end

    # How long, in the sentence's own words under a minute: never "since now", "stuck now" or
    # "running now" (r3 L3).
    test "what a ticket is doing says under a minute in words", %{conn: conn, project: project} do
      stuck = Forge.ProjectFixtures.ticket_in!(project, 7, "planning", status: :stuck, ago: 20)
      Forge.ProjectFixtures.ticket_in!(project, 8, "planning", ago: 20)
      running = Forge.ProjectFixtures.ticket_in!(project, 9, "planning", ago: 20)
      Forge.ProjectFixtures.jobs_running!(running, 1)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      table = view |> element("#tickets-table") |> render() |> Floki.parse_fragment!()

      doing =
        &(table
          |> Floki.find("#tickets-table-#{&1} .ticket-doing")
          |> Floki.text()
          |> String.trim())

      assert doing.(stuck.number) == "stuck <1m"
      assert doing.(8) == "changed just now"
      assert doing.(running.number) =~ ~r/^running <1m/
    end

    # The mark is the state's topology and nothing else (`ui.md` § The three axes): a ticket stuck
    # in a job state still reads `▸`, and a finished one rests in a terminal state drawn `○`, the
    # status a muted word beside it, never a green `✓` that would call any end a success.
    test "a state's mark is its topology, whatever the ticket's status", %{
      conn: conn,
      project: project
    } do
      Forge.ProjectFixtures.ticket_in!(project, 4, "merged", status: :done, ago: 30)
      Forge.ProjectFixtures.ticket_in!(project, 5, "planning", status: :cancelled, ago: 30)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert view |> element("#tickets-waiting-1 .ui-state-mark") |> render() =~ "▸"

      done = view |> element("#history-4") |> render()
      assert done =~ ~r/class="ui-state-mark"[^>]*>○</
      assert done =~ ~r/class="ui-status\s*">\s*done/
      refute done =~ "✓"

      cancelled = view |> element("#history-5") |> render()
      assert cancelled =~ ~r/ui-state--running[^>]*><span[^>]*>▸</
      assert cancelled =~ ~r/class="ui-status\s*">\s*cancelled/
      refute cancelled =~ "✗"
    end
  end

  describe "the views and + New" do
    test "the view in the address is the one on screen, and an unknown one is Tickets", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=merge")
      assert has_element?(view, ~s(#project-page[data-view="merge"]))

      view |> element("#tab-chats") |> render_click()
      assert has_element?(view, ~s(#project-page[data-view="chats"]))
      assert has_element?(view, "form#chat-start[phx-change]")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=board")
      assert has_element?(view, ~s(#project-page[data-view="tickets"]))
    end

    test "+ New opens the sheet with a ticket and a chat for this project", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      refute has_element?(view, "#new-sheet-opener")
      assert has_element?(view, ~s(#top-bar a.ui-top-context[href*="new="]))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?new")
      assert has_element?(view, "#new-sheet-opener[data-sheet=new-sheet]")
      assert has_element?(view, ~s(#new-sheet a[href="/tickets/new?project=#{project.name}"]))
      assert has_element?(view, ~s(#new-sheet a[href="/chats/new?project=#{project.name}"]))
    end

    test "the Chats composer starts a chat about this project, and refuses an empty one", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")

      view |> form("#chat-start", %{"text" => "  "}) |> render_submit()
      assert has_element?(view, "#chat-start #chat-start-error", "Say what the chat is about")

      assert {:error, {:live_redirect, %{to: "/chats/" <> id}}} =
               view |> form("#chat-start", %{"text" => "Why is CI slow?"}) |> render_submit()

      assert Forge.Repo.get!(Forge.Jobs.Job, id).project_id == project.id
    end

    test "a conversation's row counts the proposals it wrote", %{conn: conn, project: project} do
      {:ok, chat} = Conversations.open(project, "ideas")
      Forge.ForgeFixtures.proposal_fixture(%{job: chat, title: "One", file: "one.md"})
      Forge.ForgeFixtures.proposal_fixture(%{job: chat, title: "Two", file: "two.md"})

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")
      assert has_element?(view, "#conversation-#{chat.id}", "2 proposals")
    end
  end

  describe "the Proposals view" do
    # Two jobs of one ticket, each writing proposals, and a chat writing one: three sources.
    setup %{project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Replace the font atlas"}, :system)
      [first | _] = Forge.Jobs.for_ticket(ticket.id)
      second = Forge.ForgeFixtures.job_fixture(%{ticket: ticket, attempt: 2})
      {:ok, chat} = Conversations.open(project, "Why is CI slow?")

      a = Forge.ForgeFixtures.proposal_fixture(%{job: first, file: "a.md", title: "Atlas A"})
      b = Forge.ForgeFixtures.proposal_fixture(%{job: first, file: "b.md", title: "Atlas B"})
      c = Forge.ForgeFixtures.proposal_fixture(%{job: second, file: "c.md", title: "Atlas C"})

      d =
        Forge.ForgeFixtures.proposal_fixture(%{job: chat, file: "d.md", title: "Cache textures"})

      %{ticket: ticket, first: first, second: second, chat: chat, a: a, b: b, c: c, d: d}
    end

    test "groups them by the job that wrote them, each naming its source", %{
      conn: conn,
      project: project,
      first: first,
      second: second,
      chat: chat,
      a: a,
      c: c
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")

      assert has_element?(view, "#source-#{first.id} #proposal-#{a.id}")
      # The same ticket's second job is a batch of its own.
      assert has_element?(view, "#source-#{second.id} #proposal-#{c.id}")
      refute has_element?(view, "#source-#{first.id} #proposal-#{c.id}")
      assert has_element?(view, "#source-#{chat.id}", "the chat “Why is CI slow?”")
      # One of the project's views: its title stays the project's, and the subline says what the
      # view holds.
      assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "4 proposals · 3 sources")
      assert has_element?(view, "#title-row h1", project.name)
    end

    test "Skip moves the reader on and writes nothing", %{conn: conn, project: project, a: a} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{a.id}")
      assert has_element?(view, ~s(#proposal-reader[data-version="#{a.id}"]))

      view |> element("#proposal-reader button", "Skip") |> render_click()

      refute has_element?(view, ~s(#proposal-reader[data-version="#{a.id}"]))
      assert Forge.Proposals.decision(a.id) == nil
      assert Enum.any?(Forge.Proposals.open(project.id), &(&1.version.id == a.id))
    end

    test "deciding one moves the reader to the next", %{conn: conn, project: project, a: a, b: b} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{a.id}")

      view
      |> element("#propose-#{a.id}")
      |> render_submit(%{"version_id" => a.id, "decision" => "declined", "comment" => "no"})

      assert_patch(view)
      assert Forge.Proposals.decision(a.id).decision == :declined
      assert has_element?(view, ~s(#proposal-reader[data-version="#{b.id}"]))
    end

    test "a group's box selects the whole group, and the bar declines them with one reason", %{
      conn: conn,
      project: project,
      first: first,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")
      view |> element("#proposal-lists + button", "Select") |> render_click()

      view |> element("#select-group-#{first.id}") |> render_click()
      assert has_element?(view, ~s(#select-group-#{first.id}[aria-checked="true"]))

      # Clearing one of the group's boxes leaves a dash.
      view |> form("#proposal-select") |> render_change(%{"ids" => [a.id]})
      assert has_element?(view, ~s(#select-group-#{first.id}[aria-checked="mixed"]))

      # An id the page does not list is not selected, whatever the form is sent.
      foreign = Forge.ForgeFixtures.proposal_fixture(%{file: "theirs.md"})
      view |> form("#proposal-select") |> render_change(%{"ids" => [a.id, b.id, foreign.id]})
      assert has_element?(view, "#proposal-bulk", "2 selected")

      view
      |> element("#proposal-bulk")
      |> render_submit(%{"bulk" => "decline", "reason" => "not this quarter"})

      for v <- [a, b], do: assert(Forge.Proposals.decision(v.id).comment == "not this quarter")
      assert Forge.Proposals.decision(c.id) == nil
      assert has_element?(view, "#toast", "Declined 2")
    end

    test "only a chat's proposal can be asked about, and asking sends to that chat", %{
      conn: conn,
      project: project,
      chat: chat,
      a: a,
      d: d
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{a.id}")
      refute has_element?(view, "#proposal-ask")
      # A ticket's job has no chat to ask, whatever the page is sent.
      render_submit(view, "proposal:ask", %{"version_id" => a.id, "text" => "Hello?"})
      assert has_element?(view, "#proposal-error", "could not be asked")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals&read=#{d.id}")

      view |> form("#proposal-ask", %{"text" => "Which step is slow?"}) |> render_submit()

      assert has_element?(view, "#toast", "Asked the chat")

      assert Forge.Repo.exists?(
               from e in Forge.Events.Event,
                 where: e.job_id == ^chat.id and e.type == "chat.message",
                 where: fragment("? ->> 'text'", e.payload) == "Which step is slow?"
             )
    end

    test "History keeps a declined one's reason and reopens it; an admitted one links its ticket",
         %{conn: conn, project: project, user: user, a: a, b: b} do
      {:ok, _} = Forge.Operator.decline_proposal(a.id, user, "needs a server first")
      {:ok, ticket} = Forge.Operator.accept_proposal(b.id, user)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")

      view |> element(~s(#proposal-lists button[value="admitted"])) |> render_click()

      assert has_element?(
               view,
               "#decided-#{b.id} a[href='/tickets/#{project.name}/#{ticket.number}']"
             )

      # The ticket's state by its topology (`refining` runs a job: `▸`), and its status, once it
      # has one, a word beside it — never a `✓` or `✗` standing for the state.
      assert view |> element("#decided-#{b.id} .ui-state-mark") |> render() =~ "▸"
      refute has_element?(view, "#decided-#{b.id} .ui-status")

      Forge.Repo.update!(Ecto.Changeset.change(ticket, status: :cancelled))
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")
      view |> element(~s(#proposal-lists button[value="admitted"])) |> render_click()
      assert has_element?(view, "#decided-#{b.id} .ui-status", "cancelled")
      assert view |> element("#decided-#{b.id} .ui-state-mark") |> render() =~ "▸"

      view |> element(~s(#proposal-lists button[value="declined"])) |> render_click()
      assert has_element?(view, "#decided-#{a.id}", "needs a server first")

      view |> element("#reopen-#{a.id}") |> render_click()

      assert has_element?(view, "#toast", "Reopened")
      refute has_element?(view, "#reopen-#{a.id}")
      assert has_element?(view, "#decided-#{a.id}", "reopened since")
      assert Enum.any?(Forge.Proposals.open(project.id), &(&1.artifact.name == "proposal-a.md"))
    end

    # A reopened proposal is open again. Its decline stays in History, but it is no longer one of
    # the declined: counted there too, it was in two lists at once.
    test "a reopened proposal counts as open and not as declined", %{
      conn: conn,
      project: project,
      user: user,
      a: a
    } do
      {:ok, _} = Forge.Operator.decline_proposal(a.id, user, "later")
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")

      assert tab_count(view, "open") == "3"
      assert tab_count(view, "declined") == "1"

      view |> element(~s(#proposal-lists button[value="declined"])) |> render_click()
      view |> element("#reopen-#{a.id}") |> render_click()

      assert tab_count(view, "open") == "4"
      assert tab_count(view, "declined") == "0"
      # Still in History, saying what became of it.
      assert has_element?(view, "#decided-#{a.id}.proposal-decided--reopened", "reopened since")
    end

    test "a bulk Decline with no reason declines them, the reason being optional", %{
      conn: conn,
      project: project,
      first: first,
      a: a,
      b: b
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=proposals")
      view |> element("#proposal-lists + button", "Select") |> render_click()
      view |> element("#select-group-#{first.id}") |> render_click()

      view |> element("#proposal-bulk") |> render_submit(%{"bulk" => "decline", "reason" => ""})

      for v <- [a, b] do
        assert %{decision: :declined, comment: nil} = Forge.Proposals.decision(v.id)
      end

      assert has_element?(view, "#toast", "Declined 2")
      refute has_element?(view, "#bulk-error")
    end
  end

  test "the bulk bar's Admit waits for a type where there is one to choose" do
    bulk = fn drafts ->
      render_component(&ForgeWeb.ProposalsView.bulk/1,
        count: 2,
        types: [%{name: "bug", parses: true}, %{name: "feature", parses: true}],
        drafts: drafts
      )
    end

    disabled? = fn html ->
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(button[value="admit"][disabled]))
      |> Enum.count() == 1
    end

    assert disabled?.(bulk.(%{}))
    refute disabled?.(bulk.(%{"bulk" => %{"ticket_type" => "bug"}}))
  end

  defp tab_count(view, value) do
    view
    |> element(~s(#proposal-lists button[value="#{value}"] .ui-count))
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end
end
