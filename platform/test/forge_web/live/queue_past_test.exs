defmodule ForgeWeb.QueuePastTest do
  @moduledoc """
  What a queue item shows of the ticket it is about (`docs/design/ui.md` § What each kind shows):
  the steps it has been in and the loops that fired, a step's line opened in place, the last
  attempt by the kind of step it stuck in, ways forward that say what they start, and a way that
  approves or merges that is never taken here.

  The history is made by the engine — a fake worker answers each job — and not written as rows,
  because what is read is what the engine recorded.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Conversations, Engine, FakeWorker, Jobs, Projects, Repo, Tickets}

  setup :register_and_log_in_user

  @workflow """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      timeout: 20m
  states:
    planning:
      prompt: agents/plan.md
      inputs: [ticket]
      produces: [plan.md]
      budget: { turns: 40, tokens: 400k }
    implementing:
      prompt: agents/implement.md
      inputs: [ticket]
      produces: [implementation.md, changeset]
      outcomes: [done, plan_invalid]
      budget: { turns: 200, tokens: 2M }
    checking:
      invoke: [build]
      exit: { 0: done, "*": checks_failed }
    reviewing:
      prompt: agents/review.md
      inputs: [implementation.md]
      produces: [review.md, commit-message]
      outcomes: [done, changes_requested]
      budget: { turns: 60, tokens: 600k }
    human_testing:
      produces: [test-report.md]
    merged:
      on_enter: merge
  transitions:
    - { from: planning,      to: implementing }
    - { from: implementing,  to: checking }
    - { from: implementing,  to: planning,     when: plan_invalid }
    - { from: checking,      to: reviewing }
    - { from: checking,      to: implementing, when: checks_failed, max: 3 }
    - { from: reviewing,     to: human_testing }
    - { from: reviewing,     to: implementing, when: changes_requested, max: 2 }
    - { from: human_testing, to: merged,       approve: [changeset] }
    - { from: human_testing, to: implementing }
  limits:
    ticket_tokens: 5M
  """

  @chat_workflow """
  version: 1
  initial: refining
  states:
    refining:
      chat: true
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      outcomes: [done]
    planning:
      prompt: agents/plan.md
      inputs: [refinement.md]
      produces: [plan.md]
      budget: { turns: 5, tokens: 200k }
    review_ready: {}
  transitions:
    - { from: refining, to: planning, approve: [refinement.md] }
    - { from: planning, to: review_ready }
  limits: { ticket_tokens: 5M }
  """

  defp project!(user, workflow) do
    {:ok, project} =
      Projects.register(
        %{
          name: "past-#{System.unique_integer([:positive])}",
          repo_path:
            seeded_repo(%{
              ".forge/workflow.yml" => workflow,
              ".forge/agents/review.md" => "Review the change.\n",
              ".forge/commands/build.sh" => "#!/bin/sh\nexec make \"$@\"\n"
            })
        },
        user
      )

    funded!(project)

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    project
  end

  defp pending(ticket), do: ticket.id |> Jobs.for_ticket() |> Enum.find(&(&1.status == :pending))

  defp run(ticket, worker, name, outcome \\ "done") do
    job = pending(ticket)
    written = %{name => "---\noutcome: #{outcome}\n---\n# #{name}\n"}

    written =
      if job.state == "reviewing",
        do: Map.put(written, "commit-message", FakeWorker.commit_message()),
        else: written

    {:ok, _job} = FakeWorker.run(job, worker, "success", written: written)
    Tickets.get!(ticket.id)
  end

  defp check(ticket, worker, status, opts \\ []) do
    for job <- Jobs.commands_for_ticket(ticket.id), job.status == :pending do
      {:ok, _job} = job |> FakeWorker.assign(worker) |> FakeWorker.finish_command(status, opts)
    end

    Tickets.get!(ticket.id)
  end

  defp said(job, text) do
    Repo.insert!(%Forge.Events.Event{
      ticket_id: job.ticket_id,
      project_id: job.project_id,
      job_id: job.id,
      actor: %{"kind" => "job", "id" => job.id},
      type: "job.harness.text",
      payload: %{"text" => text}
    })
  end

  defp html(view, selector), do: view |> element(selector) |> render()

  # Where an element sits in the item, to say what comes before what.
  defp at(item, needle) do
    case :binary.match(item, needle) do
      {position, _length} -> position
      :nomatch -> flunk("#{needle} is not in the item")
    end
  end

  describe "a stuck ticket" do
    setup %{user: user} do
      project = project!(user, @workflow)
      {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, :system)
      %{project: project, ticket: ticket, worker: FakeWorker.connect()}
    end

    # `reviewing → implementing` may fire twice; the third `changes_requested` sticks the ticket.
    defp spend_review_loop(ticket, worker) do
      Enum.reduce(1..3, ticket, fn _round, ticket ->
        ticket = run(ticket, worker, "implementation.md")
        ticket = check(ticket, worker, 0)
        said(Forge.Jobs.get!(hd(Jobs.for_ticket(ticket.id)).id), "first words")
        run(ticket, worker, "review.md", "changes_requested")
      end)
    end

    test "shows its past between the card and the last attempt", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket = spend_review_loop(ticket, worker)
      assert ticket.status == :stuck

      {:ok, view, _html} = live(conn, ~p"/")
      item = html(view, "#queue-item")

      # Between the context card and the attempt (criterion 21), and inside the item itself, not
      # in the wide screen's column (22).
      assert at(item, ~s(class="queue-band")) < at(item, ~s(id="queue-past"))
      assert at(item, ~s(id="queue-past")) < at(item, ~s(id="queue-attempt"))
      assert at(item, ~s(id="queue-attempt")) < at(item, "Ways forward")
      refute has_element?(view, "#queue-aside #queue-past")

      assert html(view, "#queue-step-implementing") =~ "implementing · 3 runs · last done"
      assert html(view, "#queue-step-checking") =~ "checking · 3 runs · last done"
      assert html(view, "#queue-step-reviewing") =~ "reviewing · 3 runs · last changes_requested"

      assert html(view, "#queue-loops") =~ "reviewing → implementing on changes_requested"
      assert html(view, "#queue-loops") =~ "2 of 2"
      # A human step says how often it has been visited, not how often it ran.
      assert has_element?(view, "#ways-#{ticket.id}", "has not been visited yet")

      assert html(view, "#queue-item .queue-sentence") =~
               "the reviewing → implementing loop on changes_requested ran out (2 of 2)"

      # The old count line is gone and the budget says tokens as well as turns (criterion 11).
      refute item =~ "attempts in"
      assert html(view, "#queue-attempt .queue-budget") =~ "60 turns"
      assert html(view, "#queue-attempt .queue-budget") =~ "·"
    end

    test "a step's line opens in place, one at a time, and the current step's does not", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket = spend_review_loop(ticket, worker)
      key = "stuck-#{ticket.id}"
      {:ok, view, _html} = live(conn, ~p"/")
      form = "#queue-past-#{key}"

      refute has_element?(view, "#queue-run")
      assert has_element?(view, "#queue-step-implementing input[type=checkbox]")
      # Its latest run is the last attempt drawn below, so the line does not open (criterion 4).
      refute has_element?(view, "#queue-step-reviewing input[type=checkbox]")

      view |> element(form) |> render_change(%{"item" => key, "open" => ["implementing"]})
      assert has_element?(view, "#queue-step-implementing #queue-run", "#3")
      # The line that is open is marked, which is what the chevron turns on, and only that one.
      assert has_element?(view, "#queue-step-implementing[data-open]")
      refute has_element?(view, "#queue-step-checking[data-open]")
      assert has_element?(view, ~s(#queue-step-implementing input[checked]))
      assert has_element?(view, "#queue-step-implementing #queue-run a", "The job")

      # Opening another closes the first: the form carries both boxes, the newest one wins.
      view
      |> element(form)
      |> render_change(%{"item" => key, "open" => ["implementing", "checking"]})

      refute has_element?(view, "#queue-step-implementing #queue-run")
      refute has_element?(view, "#queue-step-implementing[data-open]")
      assert has_element?(view, "#queue-step-checking #queue-run", "build")
      assert has_element?(view, "#queue-step-checking #queue-run", "exit 0")

      # It stays open while the page reads again (a ticket change on the node).
      Forge.Events.notify(ticket.id)
      assert has_element?(view, "#queue-step-checking #queue-run")

      # Unchecking the box sends the form with no box checked; a test cannot uncheck a box, so
      # the same event is sent as the browser sends it.
      render_hook(view, "queue:step", %{"item" => key})
      refute has_element?(view, "#queue-run")
      refute has_element?(view, "#queue-past [data-open]")

      # A crafted `open` that is not a list of names opens nothing and does not take the page down.
      render_hook(view, "queue:step", %{"item" => key, "open" => [1]})
      render_hook(view, "queue:step", %{"item" => key, "open" => %{"a" => "b"}})
      refute has_element?(view, "#queue-run")
    end

    # Criterion 24: with nothing fired the loop list is left out, not drawn empty.
    test "draws no loop list when no loop has fired", %{conn: conn, ticket: ticket} do
      {:ok, ticket} = Engine.stick(ticket, "no machine could take it")
      {:ok, view, _html} = live(conn, ~p"/?item=stuck-#{ticket.id}")

      assert has_element?(view, "#queue-past")
      refute has_element?(view, "#queue-loops")
    end

    # Criterion 3: a person's move along the edge is a round, and the list shows the count as the
    # engine has it, past the limit, never clamped to it.
    test "a loop a person moved along reads past its limit", %{
      conn: conn,
      user: user,
      ticket: ticket,
      worker: worker
    } do
      ticket = spend_review_loop(ticket, worker)
      {:ok, ticket} = Engine.choose(ticket, user.id, "implementing")
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      ticket = run(ticket, worker, "review.md", "changes_requested")
      assert ticket.status == :stuck

      {:ok, view, _html} = live(conn, ~p"/")
      assert html(view, "#queue-loops") =~ "3 of 2"
      assert html(view, "#queue-item .queue-sentence") =~ "(3 of 2)"
    end

    test "a form about another item, or a step with nothing to open, opens nothing", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket = spend_review_loop(ticket, worker)
      key = "stuck-#{ticket.id}"
      {:ok, view, _html} = live(conn, ~p"/")
      form = "#queue-past-#{key}"

      render_hook(view, "queue:step", %{
        "item" => "stuck-somewhere-else",
        "open" => ["implementing"]
      })

      refute has_element?(view, "#queue-run")

      # The current step of a stuck item, and a step the ticket never visited.
      view |> element(form) |> render_change(%{"item" => key, "open" => ["reviewing"]})
      refute has_element?(view, "#queue-run")
      view |> element(form) |> render_change(%{"item" => key, "open" => ["planning"]})
      refute has_element?(view, "#queue-run")
    end

    test "moving to another item folds the open line, and so does a new page", %{
      conn: conn,
      project: project,
      ticket: ticket,
      worker: worker
    } do
      ticket = spend_review_loop(ticket, worker)
      key = "stuck-#{ticket.id}"

      {:ok, other} = Tickets.admit(project, %{title: "Another", body: "."}, :system)
      {:ok, other} = Engine.stick(other, "the job failed")

      {:ok, view, _html} = live(conn, ~p"/?item=#{key}")

      view
      |> element("#queue-past-#{key}")
      |> render_change(%{"item" => key, "open" => ["implementing"]})

      assert has_element?(view, "#queue-run")

      render_patch(view, ~p"/?item=stuck-#{other.id}")
      refute has_element?(view, "#queue-run")
      # Back on it, the line is closed: moving on dropped it.
      render_patch(view, ~p"/?item=#{key}")
      refute has_element?(view, "#queue-run")

      view
      |> element("#queue-past-#{key}")
      |> render_change(%{"item" => key, "open" => ["implementing"]})

      {:ok, fresh, _html} = live(conn, ~p"/?item=#{key}")
      refute has_element?(fresh, "#queue-run")
    end

    # Criterion 14: a ticket stuck in a command step shows the batch it ran, never *No job ran*.
    test "stuck in a command step shows its batch and the end of the failed log", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket =
        Enum.reduce(1..4, ticket, fn _round, ticket ->
          ticket = run(ticket, worker, "implementation.md")
          log = String.duplicate("compiling\n", 700) <> "error: boom <b>bold</b>\n"
          check(ticket, worker, 2, log: log)
        end)

      assert %{state: "checking", status: :stuck} = ticket

      {:ok, view, _html} = live(conn, ~p"/")
      item = html(view, "#queue-item")

      refute item =~ "No job ran"
      assert html(view, "#queue-attempt-batch") =~ "build"
      assert html(view, "#queue-attempt-batch") =~ "exit 2"
      tail = html(view, "#queue-attempt-batch .ticket-tail")
      assert tail =~ "bytes cut"
      assert tail =~ "error: boom &lt;b&gt;bold&lt;/b&gt;"
      # Text, never markup.
      refute tail =~ "<b>"

      assert html(view, "#queue-step-checking") =~ "checking · 4 runs · last checks_failed"
      refute has_element?(view, "#queue-step-checking input[type=checkbox]")
      assert html(view, "#queue-loops") =~ "checking → implementing on checks_failed"
      assert html(view, "#queue-loops") =~ "3 of 3"
    end

    test "each way forward says what it starts and how often that has run", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket =
        Enum.reduce(1..4, ticket, fn _round, ticket ->
          ticket = run(ticket, worker, "implementation.md")
          check(ticket, worker, 1)
        end)

      assert ticket.state == "checking"
      {:ok, view, _html} = live(conn, ~p"/")
      ways = "#ways-#{ticket.id}"

      assert has_element?(view, ways <> " label", "Retry checking")
      assert has_element?(view, ways, "starts run 5 of checking")
      assert has_element?(view, ways, "starts a job in reviewing · has not run yet")
      assert has_element?(view, ways, "starts a job in implementing · has run 4 times")
    end

    # A step the ticket is in whose job never started is not a run (criterion 6).
    test "a step whose job no machine started reads not run yet", %{conn: conn, ticket: ticket} do
      {:ok, ticket} = Engine.stick(ticket, "no machine could take it")

      {:ok, view, _html} = live(conn, ~p"/?item=stuck-#{ticket.id}")
      assert html(view, "#queue-step-implementing") =~ "implementing · not run yet"
      assert html(view, "#queue-attempt") =~ "implementing has not run yet"
      refute has_element?(view, "#queue-step-implementing input[type=checkbox]")
    end

    test "a pinned workflow that cannot be read still lists the steps, and no limits", %{
      conn: conn,
      ticket: ticket,
      worker: worker
    } do
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 1)
      ticket = run(ticket, worker, "implementation.md")
      {:ok, ticket} = Engine.stick(ticket, "the job failed")
      ticket |> Ecto.Changeset.change(workflow: %{}) |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/?item=stuck-#{ticket.id}")
      assert html(view, "#queue-step-implementing") =~ "implementing · 2 runs"
      assert html(view, "#queue-step-checking") =~ "checking · 1 run"
      # Every fired edge, with its count and no limit.
      assert html(view, "#queue-loops") =~ "checking → implementing on checks_failed"
      refute html(view, "#queue-loops") =~ " of "
    end

    test "agent text is drawn as text", %{conn: conn, ticket: ticket, worker: worker} do
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.state == "implementing"))
      said(job, "all done <script>alert(1)</script>")
      {:ok, ticket} = Engine.stick(ticket, "the job <i>failed</i>")

      key = "stuck-#{ticket.id}"
      {:ok, view, _html} = live(conn, ~p"/?item=#{key}")

      view
      |> element("#queue-past-#{key}")
      |> render_change(%{"item" => key, "open" => ["implementing"]})

      run = html(view, "#queue-run")
      assert run =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute run =~ "<script>"
      refute html(view, "#queue-item .queue-sentence") =~ "<i>"
    end
  end

  describe "a ticket ready to merge" do
    setup %{user: user} do
      project = project!(user, @workflow)
      {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, :system)
      worker = FakeWorker.connect()
      ticket = run(ticket, worker, "implementation.md")
      ticket = check(ticket, worker, 0)
      ticket = run(ticket, worker, "review.md")
      assert ticket.state == "human_testing"

      {:ok, head} = Forge.Git.resolve(Projects.repo_path(project), "refs/heads/main")
      changeset!(ticket, head)
      %{project: project, ticket: ticket}
    end

    test "shows the change it would merge and leads to it, never merging in place", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/")
      assert html(view, "#queue-item .queue-eyebrow") =~ "review ready"

      assert has_element?(view, "#queue-changeset")
      assert has_element?(view, "#queue-commit-message")
      assert html(view, "#queue-step-human_testing") =~ "human_testing · 1 visit"

      # The merge is not a row; what is left is the way back to work, and the link to the change.
      refute has_element?(view, ~s(#way-#{ticket.id}-to\\:merged))
      refute html(view, "#ways-#{ticket.id}") =~ "merged"
      assert has_element?(view, "#ways-#{ticket.id} label", "Move to implementing")

      link = "#review-#{ticket.id}-0"
      assert has_element?(view, link, "Review the changeset")

      assert html(view, link) =~
               ~s(href="/tickets/#{project.name}/#{ticket.number}?tab=changes&amp;sub=files")
    end

    test "leads to the presentation when there is one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _version} =
        Artifacts.record_version(ticket.id, "deck", :presentation, :system, %{content: "# Deck\n"})

      {:ok, view, _html} = live(conn, ~p"/")
      link = "#review-#{ticket.id}-0"
      assert has_element?(view, link, "Read the presentation")

      assert html(view, link) =~
               ~s(href="/tickets/#{project.name}/#{ticket.number}?tab=changes&amp;sub=presentation")
    end

    # Criterion 10, at the operation: sent by a page drawn before this rule or crafted, the way is
    # refused in words and nothing is merged, approved or moved.
    test "a way that merges is refused when it is sent anyway", %{conn: conn, ticket: ticket} do
      {:ok, view, _html} = live(conn, ~p"/")
      before = length(Forge.Events.for_ticket(ticket.id))

      view
      |> element("#ways-#{ticket.id}")
      |> render_submit(%{"ticket" => ticket.id, "way" => "to:merged"})

      assert has_element?(view, "#queue-refusal", "approves or merges")
      assert %{state: "human_testing", status: :active} = Tickets.get!(ticket.id)

      render_hook(view, "transition", %{"ticket" => ticket.id, "to" => "merged"})
      assert has_element?(view, "#queue-refusal", "approves or merges")
      assert %{state: "human_testing", status: :active} = Tickets.get!(ticket.id)

      assert length(Forge.Events.for_ticket(ticket.id)) == before
      assert html(view, "#queue-item") =~ ~s(data-key="review-#{ticket.id}")
      refute has_element?(view, "#item-review-#{ticket.id}[data-decided]")
    end

    test "a way that sends it back is taken here", %{conn: conn, ticket: ticket} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#ways-#{ticket.id}")
      |> render_submit(%{"ticket" => ticket.id, "way" => "to:implementing"})

      assert %{state: "implementing"} = Tickets.get!(ticket.id)
    end
  end

  describe "conversations and documents" do
    setup %{user: user} do
      project = project!(user, @chat_workflow)
      {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, :system)
      [chat] = Jobs.step_chats_for_ticket(ticket.id)
      %{project: project, ticket: ticket, chat: chat}
    end

    defp reply(chat, text, documents \\ %{}) do
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

      run!(chat)

      {:ok, chat} =
        Conversations.record_turn(chat, %{
          "turn" => System.unique_integer([:positive]),
          "commit" => String.duplicate("a", 40),
          "documents" => documents,
          "harness" => %{
            "turns" => 1,
            "usage" => 2_000,
            "cost_usd" => 0.01,
            "subtype" => "success"
          }
        })

      chat
    end

    test "a step's conversation shows its whole reply and the documents it wrote", %{
      conn: conn,
      project: project,
      ticket: ticket,
      chat: chat
    } do
      long = Enum.map_join(1..7, "\n", &"line #{&1} of what it said")
      reply(chat, long, %{"refinement.md" => "# Refinement\n\nThe whole of it.\n"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert html(view, "#queue-item") =~ ~s(data-key="chat-#{chat.id}")

      reply = html(view, "#queue-reply-said")
      assert reply =~ "line 7 of what it said"
      assert has_element?(view, "#queue-reply-said.queue-said--clamped")
      assert has_element?(view, "#queue-reply-said-more", "more")

      assert html(view, "#queue-produced-refinement\\.md") =~
               "/tickets/#{project.name}/#{ticket.number}/artifacts/refinement.md/1"

      assert has_element?(view, "#queue-produced-refinement\\.md", "Read refinement.md v1")
      assert html(view, "#queue-step-refining") =~ "refining · 1 run"
    end

    test "one that has written nothing yet links no document", %{conn: conn, chat: chat} do
      reply(chat, "What should it be called?")

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, ~s(a[id^="queue-produced-"]))
      refute has_element?(view, "#queue-reply-said-more")
    end

    test "a conversation about a project has no past", %{conn: conn, project: project} do
      {:ok, chat} = Conversations.open(project, "what is this?")
      reply(chat, "It is a game.")

      {:ok, view, _html} = live(conn, ~p"/?item=chat-#{chat.id}")
      assert html(view, "#queue-item") =~ ~s(data-key="chat-#{chat.id}")
      refute has_element?(view, "#queue-past")
    end

    # Criterion 16: every document the approval pins, rendered, in a box that scrolls.
    test "a document approval renders the document it pins", %{conn: conn, ticket: ticket} do
      {:ok, _version} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Refinement\n\nThe whole **plan**.\n"
        })

      ticket
      |> Ecto.Changeset.change(
        pending_transition: %{
          "from" => "refining",
          "to" => "planning",
          "outcome" => "done",
          "approve" => ["refinement.md"]
        }
      )
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/?item=approval-#{ticket.id}")

      assert has_element?(
               view,
               ~s(#queue-pinned-refinement\\.md .queue-pinned .doc strong),
               "plan"
             )

      assert has_element?(view, "#queue-pinned-refinement\\.md", "v1")
      assert html(view, "#review-#{ticket.id}") =~ "tab=docs"
      assert has_element?(view, "#review-#{ticket.id}", "Review refinement.md v1")
      assert has_element?(view, "#queue-past")
    end

    # The same reading as a merge: a way that approves documents leads to Docs, and is no row.
    test "a stuck conversation step's approving way leads to Docs", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _version} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "# Refinement\n"
        })

      {:ok, ticket} = Engine.stick(ticket, "stuck by hand")

      {:ok, view, _html} = live(conn, ~p"/?item=stuck-#{ticket.id}")

      refute has_element?(view, ~s(#way-#{ticket.id}-to\\:planning))
      assert has_element?(view, "#queue-ways-on-ticket")
      refute has_element?(view, "#queue-take")

      assert html(view, "#review-#{ticket.id}-0") =~
               ~s(href="/tickets/#{project.name}/#{ticket.number}?tab=docs")

      assert has_element?(view, "#review-#{ticket.id}-0", "Review refinement.md v1")
    end
  end

  # Criteria 4 and 6: a human step has no run to open, nor has a step that never ran, nor on a stuck
  # item the step it is stuck in — whose run is the last attempt drawn below.
  test "only a step with a run to show opens" do
    open = &ForgeWeb.QueuePast.openable?(&1, %{kind: :review})

    assert open.(%{kind: :agent, runs: 2, current: false})
    refute open.(%{kind: :agent, runs: 0, current: false})
    refute open.(%{kind: :command, runs: 0, current: false})
    refute open.(%{kind: :human, runs: 3, current: false})
    refute ForgeWeb.QueuePast.openable?(%{kind: :agent, runs: 2, current: true}, %{kind: :stuck})
    assert ForgeWeb.QueuePast.openable?(%{kind: :agent, runs: 2, current: true}, %{kind: :review})
  end

  test "questions link the version they are about, whoever wrote it", %{user: user, conn: conn} do
    project = project!(user, @workflow)
    {:ok, ticket} = Tickets.admit(project, %{title: "Save scores", body: "."}, :system)

    {:ok, version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: backend
        text: Which backend?
        options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
        blocking: true
        ```
        """
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#queue-read-version", "Read plan.md v#{version.version}")

    assert html(view, "#queue-read-version") =~
             "/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md/#{version.version}"

    assert has_element?(view, "#queue-past")
  end
end
