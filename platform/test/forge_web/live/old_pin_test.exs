defmodule ForgeWeb.OldPinTest do
  @moduledoc """
  A ticket admitted under 0.15.0, read by this release. Its stored pin has no state producing
  `commit-message`, which 0.16.0's validator refuses, and the page validated the pin on every read
  (`Tickets.parsed_workflow/1` was `Parser.from_map/1`), so every such ticket gave a 500. A pin is
  read as it was admitted (`docs/design/workflow-grammar-v1.md` § Pinning).

  The rows here carry `Forge.ForgeFixtures.old_pin_map/0`, the definition 0.15.0 stored, and not
  one the current code would build.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.AccountsFixtures, only: [user_fixture: 0]
  import Forge.ForgeFixtures, only: [join!: 2, old_pin!: 1, old_pin!: 2]
  import Forge.MergeFixtures, only: [changeset!: 2, commit_message!: 2, pend_merge: 1]
  import ForgeWeb.Operator.Components, only: [commit_message_id: 1]

  alias Forge.{Artifacts, Conversations, Jobs, Projects, Repo, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "op-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, ticket: old_pin!(ticket)}
  end

  defp page(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}"

  # The work screen itself, and not the page a pin that cannot be built gets: both carry the title,
  # so the title says nothing about which one came back.
  defp assert_work_screen(view) do
    assert has_element?(view, "#work-frame")
    refute has_element?(view, "#unreadable-pin")
  end

  defp status!(ticket, status),
    do: ticket |> Ecto.Changeset.change(status: status) |> Repo.update!()

  describe "the ticket page" do
    test "draws the work screen: title, state, steps and facts", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, html} = live(conn, page(project, ticket))

      assert html =~ "Persist scores"
      assert_work_screen(view)
      assert has_element?(view, "#tab-timeline")
      assert html =~ "refining"
      assert html =~ ticket.branch
      assert html =~ "Facts"
    end

    for {state, status} <- [
          {"refining", :active},
          {"refining", :stuck},
          {"review_ready", :active},
          {"merged", :done},
          {"implementing", :cancelled}
        ] do
      test "opens in #{state} when #{status}", %{conn: conn, project: project, ticket: ticket} do
        ticket = old_pin!(ticket, unquote(state))
        status!(ticket, unquote(status))

        {:ok, view, html} = live(conn, page(project, ticket))
        assert html =~ "Persist scores"
        assert_work_screen(view)
      end
    end

    # A row from before types and pins: no type, and nothing to say where a value would come from.
    test "says nothing blank or nil where an old row has no type", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      assert is_nil(ticket.ticket_type)
      {:ok, view, html} = live(conn, page(project, ticket))

      refute has_element?(view, "#ticket-type")
      refute html =~ ~r/>\s*nil\s*</
    end

    test "escapes a title with markup in it, and survives a very long one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      title = "<script>alert(1)</script> " <> String.duplicate("long ", 400)
      ticket = ticket |> Ecto.Changeset.change(title: title) |> Repo.update!()

      {:ok, view, html} = live(conn, page(project, ticket))

      assert_work_screen(view)
      refute html =~ "<script>alert(1)"
      assert html =~ "&lt;script&gt;alert(1)"
    end

    test "a ticket that does not exist, or a number that is not one, is a 404", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      assert_raise Ecto.NoResultsError, fn -> live(conn, "/tickets/#{project.name}/9999") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, "/tickets/#{project.name}/abc") end
      assert {:ok, _view, _html} = live(conn, page(project, ticket))
    end

    test "is refused to a person outside the project exactly as a new ticket is", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      join!(Forge.ForgeFixtures.project_fixture(), outsider = user_fixture())
      {:ok, new} = Tickets.admit(project, %{title: "A new one"}, :system)

      for t <- [ticket, new] do
        assert_raise Ecto.NoResultsError, fn ->
          conn |> log_in_user(outsider) |> live(page(project, t))
        end
      end
    end

    test "is open to a member who is not an admin", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      member = user_fixture()
      join!(project, member)

      assert {:ok, view, html} = conn |> log_in_user(member) |> live(page(project, ticket))
      assert html =~ "Persist scores"
      assert_work_screen(view)
    end

    test "cancels, and is restored", %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = live(conn, page(project, ticket))

      view |> element("#cancel-ticket") |> render_click()
      assert Tickets.get!(ticket.id).status == :cancelled

      view |> element("#restore-ticket") |> render_click()
      assert Tickets.get!(ticket.id).status == :stuck
    end

    test "opens a chat about it", %{conn: conn, project: project, ticket: ticket} do
      {:ok, chat} = Conversations.open(project, "why did it fail?", ticket: ticket)

      {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")
      assert html =~ "About this ticket"

      {:ok, _view, html} =
        live(conn, ~p"/chats/new?project=#{project.name}&ticket=#{ticket.number}")

      assert html =~ "Persist scores"
    end

    test "keeps an unsent comment across a reconnect", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      ticket = ticket |> old_pin!("review_ready") |> pend_merge()
      changeset!(ticket, "a" <> String.duplicate("0", 39))

      {:ok, view, html} = live(conn, page(project, ticket))
      assert html =~ ~s(id="approve-#{ticket.id}")
      assert html =~ ~s(phx-change="draft:change")

      view
      |> form("#approve-#{ticket.id}", %{"comment" => "typed before it dropped"})
      |> render_change()

      {:ok, view, _html} = live(conn, page(project, ticket))

      view
      |> form("#approve-#{ticket.id}", %{"comment" => "typed before it dropped"})
      |> render_change()

      assert view |> element("#approval-#{ticket.id} textarea[name=comment]") |> render() =~
               "typed before it dropped"
    end

    test "has its facts as the details sheet", %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert view |> element("dialog#details") |> render() =~ "Facts"
      assert view |> element("dialog#details") |> render() =~ "Cancel ticket"
    end
  end

  # The same pages with something on them to draw, and the gestures a person makes there.
  describe "what is on its page, and what can be done there" do
    defp job_of(ticket), do: ticket |> Map.fetch!(:id) |> Jobs.for_ticket() |> hd()

    defp write!(ticket, name, content) do
      {:ok, version} =
        Artifacts.record_version(ticket.id, name, :document, {:job, job_of(ticket).id}, %{
          content: content
        })

      version
    end

    test "draws its documents, its step and its facts", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      write!(ticket, "refinement.md", "---\noutcome: done\n---\n# Refined\n")

      {:ok, view, _html} = live(conn, page(project, ticket) <> "?tab=docs")
      assert has_element?(view, "#docs #doc-refinement\\.md", "refinement.md")
      assert has_element?(view, "#docs #doc-ticket")

      {:ok, view, _html} = live(conn, page(project, ticket) <> "?tab=timeline")
      assert has_element?(view, "#tab-timeline")
      assert render(view) =~ "refining"
      assert render(view) =~ "refinement.md"
      assert render(view) =~ "Facts"
    end

    test "answers a question", %{conn: conn, project: project, ticket: ticket} do
      write!(ticket, "refinement.md", """
      ---
      outcome: done
      ---
      # Refined

      ```question
      key: backend
      text: Which backend?
      options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
      blocking: true
      ```
      """)

      {:ok, view, html} = live(conn, page(project, ticket))
      assert html =~ "Which backend?"

      view
      |> element("form[phx-submit='questions:send']")
      |> render_submit(%{"answers" => %{"backend" => %{"choice" => "b", "text" => ""}}})

      # What was stored, not what was submitted: "Sent 1 answer" is said from the form.
      assert render(view) =~ "Sent 1 answer"
      refute render(view) =~ "Which backend?"
      assert Artifacts.open_questions(ticket.id) == []
    end

    test "approves its merge from the page, and the merge is made", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      sha = Forge.Git.resolve(Projects.repo_path(project), "refs/heads/main") |> elem(1)
      changeset!(ticket, sha)
      ticket = ticket |> old_pin!("review_ready") |> pend_merge()

      {:ok, view, _html} = live(conn, page(project, ticket))

      view
      |> form("#approval-#{ticket.id} form", %{"comment" => "fine"})
      |> render_submit(%{"decision" => "approved"})

      assert render(view) =~ "approved; now in merged"
      assert Tickets.get!(ticket.id).status == :done
    end

    # Not a merge, so nothing about a message: the card for any other approval on an old pin
    # draws no sentence about one.
    test "approves something that is not a merge without a word about a message", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      write!(ticket, "refinement.md", "---\noutcome: done\n---\n# Refined\n")

      ticket =
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

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, ~s(#approval-#{ticket.id} button[value="approved"]))
      refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]))
      refute render(view) =~ "pinned before merges"
    end

    test "offers a re-pin once the default branch has moved, and takes it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      Repo.update_all(from(j in Jobs.Job, where: j.ticket_id == ^ticket.id),
        set: [status: :finished]
      )

      head = commit_to_default(project, %{".forge/agents/refine.md" => "Refine it better.\n"})
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#pin-drift")

      assert view |> element("#repin-ticket") |> render_click() =~
               "Re-pinned at #{String.slice(head, 0, 12)}"

      assert Tickets.get!(ticket.id).workflow_commit == head
      refute has_element?(view, "#pin-drift")
    end

    test "marks a chat's document unapproved where the pin approves it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, chat} = Conversations.open(project, "tidy the refinement", ticket: ticket)

      {:ok, _chat} =
        Conversations.record_turn(chat, %{
          "turn" => 1,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"},
          "documents" => %{"refinement.md" => "# Refined\n"}
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")
      assert has_element?(view, "#doc-refinement\\.md", "unapproved")
    end
  end

  describe "the other places a ticket is read" do
    test "the queue and the board draw it", %{conn: conn, project: project, ticket: ticket} do
      stuck = status!(ticket, :stuck)

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ stuck.title

      {:ok, _view, html} = live(conn, ~p"/board")
      assert html =~ stuck.title

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")
      assert html =~ stuck.title
    end

    test "the job page and the workers page open with its job on a worker", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      [job | _] = Jobs.for_ticket(ticket.id)

      {:ok, _job} =
        Repo.update(Jobs.Job.progress_changeset(job, %{status: :running, worker_id: worker.id}))

      {:ok, _view, html} =
        live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

      assert html =~ "Persist scores"

      # The workers page reads neither a ticket nor its pin; it is here because a job of an old
      # ticket is what is running on the worker.
      assert {:ok, _view, _html} = live(conn, ~p"/workers")
    end
  end

  # What a merge says is the pin's to decide (`Forge.Merge.legacy_message?/1`), and the card at
  # every approval surface follows the same question.
  describe "approving its merge" do
    setup %{project: project, ticket: ticket} do
      sha = Forge.Git.resolve(Projects.repo_path(project), "refs/heads/main") |> elem(1)
      changeset!(ticket, sha)
      %{ticket: ticket |> old_pin!("review_ready") |> pend_merge(), sha: sha}
    end

    test "says what the merge will carry and offers Approve, on the ticket and the review page",
         %{
           conn: conn,
           project: project,
           ticket: ticket
         } do
      for path <- [page(project, ticket), page(project, ticket) <> "/review", "/"] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, ~s([id="#{commit_message_id(ticket)}"]), "pinned before merges")
        assert has_element?(view, ~s(#approval-#{ticket.id} button[value="approved"]))
      end
    end

    test "a current pin with no message written has no Approve, as before", %{
      conn: conn,
      project: project
    } do
      current = Tickets.admit(project, %{title: "A current one"}, :system) |> elem(1)

      changeset!(current, "b" <> String.duplicate("0", 39))

      current = pend_merge(current)

      {:ok, view, _html} = live(conn, page(project, current))

      refute has_element?(view, ~s(#approval-#{current.id} button[value="approved"]))
      refute has_element?(view, ~s([id="#{commit_message_id(current)}"]), "pinned before merges")
    end

    test "a message written on an old pin is the one it shows", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      commit_message!(ticket, "Written by hand\n")
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, ~s([id="#{commit_message_id(ticket)}"]), "Written by hand")
      refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]), "pinned before merges")
    end
  end

  # A pin the grammar can no longer build is the one case left that cannot be drawn as a work
  # screen: it says so, and offers the way on.
  describe "a pin that cannot be built" do
    setup %{ticket: ticket} do
      %{
        ticket:
          ticket
          |> Ecto.Changeset.change(workflow: %{"no longer" => "a workflow"})
          |> Repo.update!()
      }
    end

    test "says so in plain words and offers no work screen", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, html} = live(conn, page(project, ticket))

      assert has_element?(view, "#unreadable-pin", "can no longer be read")
      assert html =~ "Persist scores"
      refute has_element?(view, "#work-frame")
      refute has_element?(view, "#tab-timeline")
    end

    # Each event goes to a page of its own, with the parameters its handler matches. One of the
    # wrong shape is an unknown action and is dropped before it reaches the workflow, and a flash
    # left by an earlier event would satisfy the assertion for a later one.
    test "refuses what needs the workflow, whatever the event carries", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      id = ticket.id

      events = [
        {"retry", %{"ticket" => id}},
        {"decide", %{"ticket" => id, "decision" => "approved"}},
        {"transition", %{"ticket" => id, "to" => "implementing"}},
        {"integrate", %{"ticket" => id}},
        {"write_document", %{"ticket" => id, "name" => "plan.md", "content" => "x"}},
        {"ask", %{"ref" => "x"}}
      ]

      for {event, params} <- events do
        {:ok, view, _html} = live(conn, page(project, ticket))
        assert render_click(view, event, params) =~ "not available while this ticket"
      end

      assert Tickets.get!(id).status == :active
      assert Tickets.get!(id).state == ticket.state
    end

    test "can be cancelled and restored", %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#cancel-ticket")
      refute has_element?(view, "#restore-ticket")

      view |> element("#cancel-ticket") |> render_click()
      assert Tickets.get!(ticket.id).status == :cancelled
      refute has_element?(view, "#cancel-ticket")

      view |> element("#restore-ticket") |> render_click()
      assert Tickets.get!(ticket.id).status == :stuck
      assert has_element?(view, "#cancel-ticket")
      refute has_element?(view, "#restore-ticket")
    end

    test "offers a re-pin only once the default branch has moved, and takes it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      # The job the ticket was admitted with has ended, as it would have before the pin was lost;
      # a re-pin is refused while one is live.
      Repo.update_all(from(j in Forge.Jobs.Job, where: j.ticket_id == ^ticket.id),
        set: [status: :finished]
      )

      {:ok, view, _html} = live(conn, page(project, ticket))
      refute has_element?(view, "#pin-drift")

      head = commit_to_default(project, %{".forge/agents/refine.md" => "Refine it better.\n"})

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#unreadable-pin #pin-drift")

      assert view |> element("#repin-ticket") |> render_click() =~
               "Re-pinned at #{String.slice(head, 0, 12)}"

      assert Tickets.get!(ticket.id).workflow_commit == head
      assert has_element?(view, "#work-frame")
      refute has_element?(view, "#unreadable-pin")
    end

    # Re-pin is refused on a ticket that is not open (`Engine.repin/2`), and the page does not
    # offer it there either.
    test "offers no re-pin on a cancelled ticket", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      status!(ticket, :cancelled)
      commit_to_default(project, %{".forge/agents/refine.md" => "Refine it better.\n"})

      {:ok, view, _html} = live(conn, page(project, ticket))

      refute has_element?(view, "#pin-drift")
      refute has_element?(view, "#repin-ticket")
      assert has_element?(view, "#restore-ticket")
    end

    test "draws the reason, the documents and the history", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#unreadable-pin pre", ~r/\S/)
      assert has_element?(view, "#ticket-state", "refining")
      assert has_element?(view, "#docs #doc-ticket")
      assert has_element?(view, "#timeline li", "ticket.admitted")
    end

    test "sends the review page to the ticket's own page", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, page(project, ticket) <> "/review")

      assert to == page(project, ticket)
    end

    test "a chat about it still opens", %{conn: conn, project: project, ticket: ticket} do
      {:ok, chat} = Conversations.open(project, "why did it fail?", ticket: ticket)
      assert {:ok, _view, _html} = live(conn, ~p"/chats/#{chat.id}")
    end
  end
end
