defmodule ForgeWeb.OperatorLiveTest do
  @moduledoc "The operator pages, driven the way a phone would drive them."

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.ForgeFixtures, only: [pool!: 2, credential_fixture: 1]
  import Forge.MergeFixtures, only: [changeset!: 2]
  import ForgeWeb.Operator.Components, only: [commit_message_id: 1]

  import Ecto.Query, only: [from: 2]

  alias Forge.{Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "ui-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    Process.put(:worker, Forge.FakeWorker.connect())

    %{project: project}
  end

  # The worker is a machine on the far end of a channel now, and in these tests it is this
  # process: it takes assignments out of its own mailbox and answers them. Its handle and the
  # scenario it is to play live in the process dictionary because they belong to this process
  # in exactly the same way. See Forge.FakeWorker.
  defp scenario(name, doc), do: Process.put(:scenario, {name, doc})

  # The queue page hears a change through the frame (`ForgeWeb.Frame.follow/3`), which counts the
  # first change in a second at once and the rest at the second's end, and a job's changes are
  # announced from processes of their own: so the page is waited on, up to three seconds, until
  # it draws `selector`.
  defp heard(view, selector, attempts \\ 150) do
    cond do
      has_element?(view, selector) -> :ok
      attempts == 0 -> flunk("the queue page never drew #{selector}")
      true -> Process.sleep(20) && heard(view, selector, attempts - 1)
    end
  end

  defp run_pending(ticket_id) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {name, doc} = Process.get(:scenario, {"success", "plan.md"})
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), name, doc: doc)
    job
  end

  # The row's button drops the panel, which holds the decision's form.
  defp open!(view) do
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    assert has_element?(view, "#decision-panel")
    view
  end

  test "a queue item's link stops before the thing that commits", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("blocking", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/")

    # docs/design/ui.md § The affordance rule: a navigating region never encloses a control that
    # commits, or "read this" and "approve this" become the same gesture. A regression that
    # wrapped the answer affordance inside the link is the precise failure this pins.
    row = view |> element(~s(#queue-decisions a[href^="/?item=questions-"])) |> render()
    assert row =~ "question"
    refute row =~ "<form"
    refute row =~ "phx-submit"

    link =
      view
      |> element(~s(#queue-item a[href="/tickets/#{project.name}/#{ticket.number}"]))
      |> render()

    refute link =~ "<form"
    assert has_element?(view, ~s(#queue-pane form[phx-submit="questions:send"]))
  end

  # The rail names what this ticket's jobs proposed and sends the decision to the project page,
  # so a proposal has one place to be decided rather than two. Without the naming half, a ticket
  # whose refinement raised three follow-ups shows no trace of them anywhere near it.
  test "a ticket page names what its jobs proposed, and sends the decision elsewhere", %{
    conn: conn,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    [job | _] = Jobs.for_ticket(ticket.id)

    Forge.ForgeFixtures.proposal_fixture(%{job: job, title: "Extract the score table"})

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert html =~ "Proposed here"
    assert html =~ "Extract the score table"

    # Named, not decided: the affordance that commits lives on the project page.
    refute html =~ "Accept as a ticket"
    # To the view that decides them, not the project's Tickets.
    assert html =~ ~s(href="/projects/#{project.name}?view=proposals")
  end

  # `docs/design/ui.md` § The decision row: the queue never decides, it links to the ticket, where
  # the row is beside what it approves; the panel names the version and links to it.
  test "an approval is decided on its ticket, with a link to what it pins", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    {:ok, queue, _html} = live(conn, ~p"/")
    # Nothing in the queue decides: no form posts a decision, and the item is a link.
    refute has_element?(queue, "form[phx-submit*=decide]")
    refute has_element?(queue, ~s(button[value="approved"]))

    assert has_element?(
             queue,
             ~s(#review-#{ticket.id}[href="/tickets/#{project.name}/#{ticket.number}?tab=docs"]),
             "Review refinement.md v1"
           )

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
    assert has_element?(view, "#decision-row", "refinement.md v1")
    assert has_element?(view, "#decision-row", "refining → planning")
    open!(view)

    assert has_element?(
             view,
             ~s(#decision-pins a[href="/tickets/#{project.name}/#{ticket.number}/artifacts/refinement.md/1"])
           )

    # This approval does not merge, so the panel draws no box for what a merge would say.
    refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]))
    assert has_element?(view, ~s(#decision-form button[value="approved"]), "Approve v1")
  end

  # `docs/design/ui.md` § The affordance rule: Enter never commits a decision. The note is a box
  # Enter breaks a line in, not a one-line input whose Enter submits the form with its first button.
  test "Enter in an approval's note is a new line", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    open!(view)

    assert has_element?(view, "#decision-form textarea[name=note]")
    refute has_element?(view, "#decision-form input[type=text]")
  end

  test "pages require login", %{project: _project} do
    conn = build_conn()
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end

  test "the queue shows an approval and takes it, then a question and answers it", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#queue-end")

    scenario("success", "refinement.md")
    run_pending(ticket.id)
    # the page refreshes on its own when the job finishes
    heard(view, "#queue-item[data-key^='approval-']")
    assert render(view) =~ "approval"
    assert render(view) =~ "refining"
    # The item names the exact version it pins, from what the pending transition awaits, and
    # leads to its ticket, where it is decided.
    assert has_element?(view, "#review-#{ticket.id}", "refinement.md v1")

    {:ok, page, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    open!(page)

    page
    |> form("#decision-form", %{"note" => "fine"})
    |> render_submit(%{"decision" => "approved"})

    assert has_element?(page, "#toast", "Approved refinement.md v1")
    assert has_element?(page, "#toast", "planning started")
    assert Tickets.get!(ticket.id).state == "planning"

    assert [%{comment: "fine"}] =
             Forge.Artifacts.approvals(Forge.Artifacts.latest(ticket.id, "refinement.md").id)

    scenario("blocking", "plan.md")
    run_pending(ticket.id)
    heard(view, "#queue-gone")

    # Decided on its ticket while on screen here: it stays, saying so, until the person moves on
    # — and the question that arrived meanwhile is next.
    assert has_element?(view, "#queue-gone")
    view |> element("#queue-later") |> render_click()
    html = render(view)
    assert html =~ "blocking question"
    assert html =~ "Which backend?"

    # a human edit in between makes the question live on a new version; answering still works
    plan = Forge.Artifacts.latest(ticket.id, "plan.md")

    {:ok, _} =
      Forge.Operator.edit(Tickets.get!(ticket.id), user, "plan.md", plan.content <> "\nEdited.\n")

    assert render(view) =~ "Which backend?"

    # The version on screen stopped waiting; the new one is next in the pass.
    heard(view, "#queue-gone")
    view |> element("#queue-later") |> render_click()

    # Choosing only locks it in; Send is what answers, and the page's form is for the new version.
    view
    |> element("form[phx-submit='questions:send']")
    |> render_submit(%{"answers" => %{"backend" => %{"choice" => "b", "text" => ""}}})

    assert render(view) =~ "Sent 1 answer"
    # Answered, the pass is over: the item stays only as a decided row.
    refute has_element?(view, "#queue-item")
    assert has_element?(view, "#queue-decisions [data-decided]", "blocking question")

    assert [%{status: :pending}] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.state == "planning"))
  end

  test "the queue offers notifications and stores a browser subscription", %{
    conn: conn,
    user: user
  } do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Notify me"
    assert html =~ ~s(data-vapid-key="test-public")

    render_hook(view, "push:subscribe", %{
      "endpoint" => "https://push.example/x",
      "keys" => %{
        "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
        "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }
    })

    assert render(view) =~ "will be notified"
    assert [%{user_id: user_id}] = Forge.Push.subscriptions()
    assert user_id == user.id

    render_hook(view, "push:unsubscribe", %{"endpoint" => "https://push.example/x"})
    assert Forge.Push.subscriptions() == []
  end

  test "the ticket page shows jobs, artifacts and its steps, and renders documents", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    scenario("success", "refinement.md")
    run_pending(ticket.id)

    # Waiting on a document's approval, so it opens on Docs; the rest is a tab away.
    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert html =~ "Persist scores"
    assert has_element?(view, ~s(#tab-docs[aria-current="page"]))
    assert has_element?(view, "#decision-row", "refinement.md v1")

    {:ok, _steps, html} =
      live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")

    assert html =~ "They vanish."
    assert html =~ "refining"
    assert html =~ "#1"
    assert html =~ "refinement.md"
    assert html =~ "v1"

    {:ok, _docs, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
    assert html =~ "<h1>Plan</h1>"

    open!(view)

    view
    |> form("#decision-form", %{"note" => "Say where the scores live."})
    |> render_submit(%{"decision" => "rejected"})

    assert has_element?(view, "#toast", "Rejected refinement.md v1")
    assert Tickets.get!(ticket.id).state == "refining"
  end

  # Why a pending job has not gone out, under its own row under Steps — and on a page that
  # was already open when the reason changed, because that is how an operator waiting on a
  # machine is looking at it (`docs/design/ui.md` § A job waiting for a machine).
  test "a pending job says why it is waiting, and an open page hears when that changes", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [job] = Jobs.for_ticket(ticket.id)

    row =
      ~s(a[href="/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"] ) <>
        ~s([id="job-#{job.id}-waiting"])

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, row)

    :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: every machine is busy.")
    assert has_element?(view, row, "Waiting for room")
  end

  # Under the job that is waiting, and only there. With one job on the ticket, a page that drew
  # every wait under the first row it had looked right; a ticket has several jobs by its second
  # state, and the reason belongs to the one still pending.
  test "a wait is drawn under the waiting job, not the ticket's first", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    refining = run_pending(ticket.id)
    {:ok, _ticket} = Forge.Engine.decide(Tickets.get!(ticket.id), user.id, :approved, nil)
    [planning] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    :ok = Jobs.record_wait(planning, "at_capacity", "Waiting for room: every machine is busy.")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert has_element?(
             view,
             ~s(a[href$="/jobs/#{planning.id}"] [id="job-#{planning.id}-waiting"]),
             "Waiting for room"
           )

    refute has_element?(view, ~s(a[href$="/jobs/#{refining.id}"] [id$="-waiting"]))
  end

  # A job can leave the queue without ever starting — the scheduler fails one that raised on its
  # way to a worker — and the last thing it waited on is then not why it is anything.
  test "a job that is no longer pending says nothing about waiting", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    [job] = Jobs.for_ticket(ticket.id)
    :ok = Jobs.record_wait(job, "at_capacity", "Waiting for room: every machine is busy.")
    {:ok, _job} = Jobs.fail(job.id, {:assign_raised, "boom"})

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, ~s([id="job-#{job.id}-waiting"]))
  end

  # The symptom as an operator met it on the dev node: reject, and the card stays. The decision
  # had been answered, but `pending_transition` was only ever cleared on the approved path, so
  # the page kept offering the same approve-or-reject and the chooser behind
  # `!@ticket.pending_transition` could never appear — there was no way forward from the page at
  # all. Asserted through the surface that showed it, not just on the row.
  test "rejecting closes the card and offers the choice instead", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert has_element?(view, "#decision-row", "refinement.md v1")
    open!(view)

    view
    |> form("#decision-form", %{"note" => "Not yet."})
    |> render_submit(%{"decision" => "rejected"})

    refute has_element?(view, "#decision-row")

    # And what replaces it is the thing the design says rejection hands over: the transitions
    # out of the state the ticket stayed in, as its ways forward.
    assert has_element?(view, ~s(#ways-forward input[value="to:planning"]))
    assert Tickets.get!(ticket.id).status == :stuck
  end

  # The production case, through the surfaces that showed it: a refinement that failed left its
  # ticket offering `planning`, which approves a refinement that was never written and failed when
  # taken. What it offers now is the state again, and taking that makes the next attempt.
  test "a ticket stuck on a failed job offers its state again, not a transition it cannot take",
       %{
         conn: conn,
         user: user,
         project: project
       } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("invalid_document", "refinement.md")
    run_pending(ticket.id)
    assert Tickets.get!(ticket.id).status == :stuck

    {:ok, queue, _html} = live(conn, ~p"/")
    assert has_element?(queue, "label[for='way-#{ticket.id}-retry']", "Retry refining")
    refute has_element?(queue, "input[value='to:planning']")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, ~s(#ways-forward input[value="to:planning"]))

    assert view |> form("#ways-forward", %{"way" => "again"}) |> render_submit() =~
             "Running refining again"

    assert Tickets.get!(ticket.id).status == :active

    assert [%{attempt: 2, status: :pending}] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
  end

  # Offered after a success as well, on the ticket page — redoing a refinement before approving
  # it is a choice made while reading it — and not in the queue, which lists only what waits.
  test "a ticket awaiting approval offers its state again on its page, not in the queue", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")
    assert has_element?(view, "#ways-forward #way-again")
    assert has_element?(view, "#ways-forward", "Run refining again")

    {:ok, queue, _html} = live(conn, ~p"/")
    refute has_element?(queue, "#retry-#{ticket.id}")
    refute has_element?(queue, "#way-#{ticket.id}-retry")
  end

  # Stuck while its job is still pending — the scheduler could not place it — the state cannot
  # be run again: its job has not run yet. The card offers what it can and not that.
  test "a ticket stuck with its job still pending is not offered its state again", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    {:ok, _stuck} = Forge.Engine.stick(ticket, "no machine", :placement)

    {:ok, queue, _html} = live(conn, ~p"/")
    assert has_element?(queue, "#queue-item[data-key='stuck-#{ticket.id}']")
    refute has_element?(queue, "#way-#{ticket.id}-retry")
  end

  # A fix on the default branch never reaches a ticket already pinned before it; the rail says what
  # changed there under `.forge/`, and re-pinning takes it (`workflow-grammar-v1.md` § Pinning).
  test "a ticket whose pin the default branch moved past says so, and re-pins", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("invalid_document", "refinement.md")
    run_pending(ticket.id)
    assert Tickets.get!(ticket.id).status == :stuck

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, "#pin-drift")

    head =
      commit_to_default(project, %{
        ".forge/agents/refine.md" => "Refine it better.\n"
      })

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert view |> element("#pin-drift") |> render() =~ ".forge/agents/refine.md"

    assert view |> element("#repin-ticket") |> render_click() =~
             "Re-pinned at #{String.slice(head, 0, 12)}"

    assert Tickets.get!(ticket.id).workflow_commit == head
    refute has_element?(view, "#pin-drift")
  end

  # A merge moved the default branch into conflict with a ticket nobody has approved yet: the rail
  # says so, naming the merge, and sends the ticket down its conflict route only when asked
  # (`docs/design/ui.md` § Decide and Timeline).
  test "a ticket a merge put in conflict says so, and is sent to integrate", %{
    conn: conn,
    user: user
  } do
    {:ok, project} =
      Projects.register(
        %{
          name: "ui-conflict-#{System.unique_integer([:positive])}",
          repo_path:
            seeded_repo(%{
              ".forge/workflow.yml" => conflict_workflow(:b),
              ".forge/agents/integrate.md" => "Merge the default branch in.\n"
            })
        },
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Settings"}, {:user, user.id})
    sha = commit_over_http(project, ticket.branch, "README.md", "the ticket's")

    {:ok, _version} =
      Forge.Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
        blob_uri: "git:" <> sha
      })

    ticket |> Ecto.Changeset.change(state: "review_ready") |> Forge.Repo.update!()
    path = ~p"/tickets/#{project.name}/#{ticket.number}"

    {:ok, view, _html} = live(conn, path)
    refute has_element?(view, "#merge-conflict")

    head = commit_to_default(project, %{"README.md" => "the trunk's\n"})
    [_found] = Forge.Merge.Watch.check(project.id, head, %{"ticket" => 4})

    # Said on the page that was already open: the check announces what it found.
    notice = view |> element("#merge-conflict") |> render()
    assert notice =~ "main no longer merges with this ticket"
    assert notice =~ "since #4 merged"
    assert notice =~ "README.md"
    assert notice =~ "A job starts there to merge main into its branch"

    assert view |> element("#integrate-ticket") |> render_click() =~ "Sent to integrating"
    assert Tickets.get!(ticket.id).state == "integrating"
    refute has_element?(view, "#merge-conflict")

    # And Activity says what the conflict was, beside its type.
    {:ok, activity, _html} = live(conn, path <> "?tab=activity")
    assert has_element?(activity, "#ticket-events", "README.md conflicted on the way into merged")
  end

  # The other things the notice says: a conversation's merge, a conflict no merge caused, and a
  # target that is a person's state, which starts no job.
  test "a conflict notice names what caused it, or nothing, and what sending costs", %{
    conn: conn,
    user: user
  } do
    {:ok, project} =
      Projects.register(
        %{
          name: "ui-human-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => conflict_workflow(:human)})
        },
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Settings"}, {:user, user.id})
    path = ~p"/tickets/#{project.name}/#{ticket.number}"

    record = fn content ->
      sha = commit_over_http(project, ticket.branch, "README.md", content)

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
          blob_uri: "git:" <> sha
        })
    end

    record.("the ticket's")
    ticket |> Ecto.Changeset.change(state: "review_ready") |> Forge.Repo.update!()
    head = commit_to_default(project, %{"README.md" => "the trunk's\n"})

    [_found] = Forge.Merge.Watch.check(project.id, head, %{"chat" => Ecto.UUID.generate()})
    {:ok, view, _html} = live(conn, path)
    notice = view |> element("#merge-conflict") |> render()
    assert notice =~ "since a conversation merged"

    assert view |> element("#integrate-ticket-confirm") |> render() =~
             "Send this ticket to integrating? It waits there for a person."

    record.("the ticket's, again")
    [_found] = Forge.Merge.Watch.check(project.id, head, nil)
    {:ok, view, _html} = live(conn, path)
    notice = view |> element("#merge-conflict") |> render()
    assert notice =~ "no longer merges with this ticket"
    refute notice =~ "since"

    # The default branch came round to the ticket's own text meanwhile: the notice was stale, and
    # pressing it says so rather than sending the ticket anywhere.
    commit_to_default(project, %{"README.md" => "the ticket's, again\n"})

    assert view |> element("#integrate-ticket") |> render_click() =~
             "it merges cleanly now, so there is nothing to integrate"

    assert Tickets.get!(ticket.id).state == "review_ready"
  end

  # A workflow from before `on_conflict`: the approval is refused as it always was, and the page
  # now says why rather than that something went wrong.
  test "an approval a conflict refuses says which paths", %{conn: conn, user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "ui-plain-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(%{".forge/workflow.yml" => conflict_workflow(:plain)})
        },
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Settings"}, {:user, user.id})
    sha = commit_over_http(project, ticket.branch, "README.md", "the ticket's")

    {:ok, _version} =
      Forge.Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{
        blob_uri: "git:" <> sha
      })

    head = commit_to_default(project, %{"README.md" => "the trunk's\n"})

    ticket
    |> Ecto.Changeset.change(
      state: "review_ready",
      pending_transition: %{
        "from" => "review_ready",
        "to" => "merged",
        "outcome" => nil,
        "approve" => ["changeset"]
      }
    )
    |> Forge.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    open!(view)
    view |> form("#decision-form") |> render_submit(%{"decision" => "approved"})

    # Refused inside the panel, which stays open (`ui.md` § Errors stay where you acted).
    assert has_element?(
             view,
             "#decision-panel #decision-error",
             "it conflicts with the default branch in README.md"
           )

    assert Tickets.get!(ticket.id).state == "review_ready"

    # Found after a merge, it is said here too — with nowhere to send it, so with no button.
    [_found] = Forge.Merge.Watch.check(project.id, head, nil)
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert view |> element("#merge-conflict") |> render() =~ "README.md"
    refute has_element?(view, "#integrate-ticket")
  end

  # "Stuck" alone sends a person to the event log to learn whether a job failed, a `max` ran out or
  # nothing matched. The queue, the ticket's Decide and its rail say which, from the latest stick.
  test "a stuck ticket says why, on the queue and on its page", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    {:ok, stuck} = Forge.Engine.stick(ticket, "an older reason")
    {:ok, _stuck} = Forge.Engine.stick(stuck, "transition to implementing already fired 2 times")

    {:ok, queue, _html} = live(conn, ~p"/")

    assert render(queue) =~
             "Persist scores is stuck: transition to implementing already fired 2 times."

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    html = render(view)
    assert html =~ "Stuck: transition to implementing already fired 2 times. Waiting for you"
    refute html =~ "an older reason. Waiting"

    # Activity says each stick's reason beside its event, the older one included.
    {:ok, activity, _html} =
      live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")

    assert has_element?(activity, "#ticket-events", "an older reason")
  end

  # A stale page can still send a transition the surfaces no longer offer; the refusal says
  # which document has nothing to approve rather than "something went wrong".
  test "taking a transition with nothing to approve says what is missing", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("invalid_document", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert render_hook(view, "transition", %{"ticket" => ticket.id, "to" => "planning"}) =~
             "refinement.md has no version to approve"
  end

  test "a ticket is cancelled from its page, leaves the open tickets, and is restored there", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Never mind"}, {:user, user.id})

    {:ok, board, _html} = live(conn, ~p"/projects/#{project.name}")
    assert has_element?(board, "#tickets-rest-#{ticket.number}", "Never mind")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, "#restore-ticket")
    assert view |> element("#cancel-ticket") |> render_click() =~ "Ticket cancelled"
    assert Tickets.get!(ticket.id).status == :cancelled

    # Out of the open tickets, and into the history, where a cancelled ticket is drawn so.
    {:ok, board, _html} = live(conn, ~p"/projects/#{project.name}")
    refute has_element?(board, "#tickets-rest-#{ticket.number}")
    assert has_element?(board, "#history-#{ticket.number} .ui-state", "refining")
    assert has_element?(board, "#history-#{ticket.number} .ui-status", "cancelled")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, "#cancel-ticket")
    assert view |> element("#restore-ticket") |> render_click() =~ "stuck in refining"
    assert Tickets.get!(ticket.id).status == :stuck
  end

  # Offered on a stuck ticket too, which is where a failed one rests; never on a done one.
  test "Cancel is on an open ticket's rail only", %{conn: conn, user: user, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})

    for {status, offered} <- [stuck: true, done: false] do
      Tickets.get!(ticket.id) |> Ecto.Changeset.change(status: status) |> Forge.Repo.update!()
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert has_element?(view, "#cancel-ticket") == offered
      refute has_element?(view, "#restore-ticket")
    end
  end

  # What each refusal says, through the page that sends it. A stale page can send any of these.
  test "a refused cancel, restore, retry or transition says why", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert render_hook(view, "restore-ticket", %{"ticket" => ticket.id}) =~
             "only a cancelled ticket can be restored"

    assert has_element?(view, "#details-refusal")

    # The next thing done replaces it: a cancel that goes through leaves no refusal behind.
    render_hook(view, "cancel-ticket", %{"ticket" => ticket.id})
    assert Tickets.get!(ticket.id).status == :cancelled
    refute has_element?(view, "#details-refusal")

    assert render_hook(view, "cancel-ticket", %{"ticket" => ticket.id}) =~
             "a cancelled ticket cannot be cancelled"

    assert render_hook(view, "transition", %{"ticket" => ticket.id, "to" => "planning"}) =~
             "the ticket is cancelled; restore it first"

    # Each where it was sent from: the details' own buttons in the details, a way forward under
    # the ways forward — and the last refusal only, never a pile.
    assert has_element?(view, "#forward-refusal[role=alert]", "restore it first")
    refute has_element?(view, "#details-refusal")

    render_hook(view, "cancel-ticket", %{"ticket" => ticket.id})
    assert has_element?(view, "#ticket-details #details-refusal", "cannot be cancelled")
    refute has_element?(view, "#forward-refusal")
  end

  # **A job's turns were drawn against a ceiling they are not measured against.** `job.turns` is
  # the harness's `num_turns` summed over every invocation the job has had; `spec.budget.turns` is
  # the `--max-turns` each single invocation gets. This job is stopped by its credential's limit,
  # resumed on a free one, and converges — 18 turns then 15, against a per-run ceiling of 20 it
  # never breached. Drawn as a fraction the page said `33/20 converged`: a cap breached by
  # thirteen that was never breached at all.
  test "a resumed job's turns are not drawn as a fraction of a per-run ceiling", %{
    conn: conn,
    user: user,
    project: project
  } do
    # Two credentials in the pool: the first is the one the limit stops, the second is where the
    # resume lands — a job with nowhere to move waits instead of running again.
    pool!(project, credential_fixture(user))
    pool!(project, credential_fixture(user))
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))

    job
    |> Forge.FakeWorker.assign(Process.get(:worker))
    |> Forge.FakeWorker.finish("rate_limited", doc: "refinement.md", harness: %{"turns" => 18})

    assert %{status: :pending, turns: 18} = Jobs.get!(job.id)

    Jobs.get!(job.id)
    |> Forge.FakeWorker.assign(Process.get(:worker))
    |> Forge.FakeWorker.finish("success", doc: "refinement.md", harness: %{"turns" => 15})

    assert %{turns: 33, outcome: :converged} = Jobs.get!(job.id)

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    # The turns it used, and the ceiling named as what it bounds — never the two as one figure.
    assert html =~ "20 turns per run"

    # The figure's whole text, not a substring of the page: `33<span>/20</span>` reads as one
    # figure to anyone looking at it while `html =~ "33/20"` is false, which is how a fraction
    # could come back unnoticed.
    assert html
           |> Floki.parse_document!()
           |> Floki.find("#job-turns")
           |> Floki.text()
           |> String.trim() == "33 turns"
  end

  # **`budget_exhausted` says a job ran out; only this says out of what** (`capacity.md` § Four
  # exhaustions, three treatments). The distinction was decided in `Outcome.budget_stop?/2` and
  # thrown away on the spot: both ceilings produced the same outcome and the same `nil`, and the
  # only record was the free text of an event. "Ran out of money" and "ran out of turns" want
  # different responses from whoever reads the row.
  for {scenario, word, other} <- [
        {"max_turns", "turns", "tokens"},
        {"max_budget", "tokens", "turns"}
      ] do
    test "a job stopped by the #{word} ceiling says which one, on every row that draws it", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
      scenario(unquote(scenario), "refinement.md")
      job = run_pending(ticket.id)

      assert %{outcome: :budget_exhausted} = Jobs.get!(job.id)

      # **A second attempt, so the exhausted job is an earlier one.** The "Earlier jobs" list
      # drops the latest and is drawn only for a ticket with more than one job, so the first
      # version of this test — one job, one attempt — could not reach that row at all, and
      # deleting the ceiling from it left the whole suite green.
      {:ok, _retried} = Forge.Engine.retry(Tickets.get!(ticket.id), user.id)
      assert length(Jobs.for_ticket(ticket.id)) == 2

      # Every row that draws a job's outcome, by the address a person reaches it at: the job
      # page's header badge, the ticket Steps's row, and the activity tab's earlier jobs.
      # All three read only `outcome` before, so a turn-exhausted and a cost-exhausted job were
      # one word.
      for page <- [
            ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}",
            ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps",
            ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity"
          ] do
        {:ok, _view, html} = live(conn, page)

        ceilings =
          html
          |> Floki.parse_document!()
          |> Floki.find("[data-ceiling]")
          |> Floki.attribute("data-ceiling")

        assert unquote(word) in ceilings, "#{page} drew #{inspect(ceilings)}"
        refute unquote(other) in ceilings
      end

      # And the event stream's own record of it, beside the free text it used to be buried in.
      assert %{"outcome" => "budget_exhausted", "exhausted" => unquote(word)} =
               job.id
               |> Forge.Events.for_job()
               |> Enum.find(&(&1.type == "job.finished"))
               |> Map.fetch!(:payload)
    end
  end

  # **The third of the three words, and the only one no harness result produces**: the engine's
  # wall clock kills the process and the worker reports `killed: :wall_clock` with no subtype to
  # read. Written to the row directly, which also proves the column's enum accepts it — the two
  # scenarios above exercise `:turns` and `:cost` and would pass with `:wall_clock` unstorable
  # and undrawn.
  test "a job the wall clock stopped says so too", %{conn: conn, user: user, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("max_turns", "refinement.md")
    job = run_pending(ticket.id)

    {:ok, job} =
      Forge.Repo.update(
        Forge.Jobs.Job.progress_changeset(Jobs.get!(job.id), %{
          status: :finished,
          outcome: :budget_exhausted,
          exhausted: :wall_clock
        })
      )

    assert job.exhausted == :wall_clock

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    assert html
           |> Floki.parse_document!()
           |> Floki.find("[data-ceiling]")
           |> Floki.attribute("data-ceiling") == ["wall clock"]
  end

  # Windows are an estimate on a placeholder constant; what was counted is the weighted tokens, and
  # a figure converted from dollars at the migration says so (`docs/design/capacity.md`).
  test "usage is drawn in windows with the exact weighted tokens behind it", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)
    assert Jobs.get!(job.id).usage == 3150

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    # Below a hundredth of a window the figure says so; the exact count is in its title.
    assert html =~ "&lt;0.01 windows"
    assert view |> element("#job-usage") |> render() =~ "3,150 weighted tokens"
    refute html =~ "converted from dollars"

    {:ok, _} = Forge.Repo.update(Ecto.Changeset.change(Jobs.get!(job.id), usage_converted: true))
    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    assert html =~ "converted from dollars"

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert view |> element("#ticket-usage") |> render() =~ "3,150 weighted tokens"
    refute has_element?(view, "#ticket-usage-converted")

    # The ticket's own total says so too (criterion 12), not only the job it came from.
    {:ok, _} =
      Forge.Repo.update(Ecto.Changeset.change(Tickets.get!(ticket.id), usage_converted: true))

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert has_element?(view, "#ticket-usage-converted", "converted from dollars")
  end

  test "a job page says which harness ran it", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    assert view |> element("#job-harness") |> render() =~ "Claude Code"

    Forge.Repo.update!(Ecto.Changeset.change(Jobs.get!(job.id), harness: "codex"))

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    assert view |> element("#job-harness") |> render() =~ "Codex"
  end

  # Criterion 32: the harness is named beside its model, on the page and on the ticket's row, and
  # the model is the project's for that harness when the job names none.
  test "a job's row and page say Codex · <model>", %{conn: conn, user: user, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    [job] = Jobs.for_ticket(ticket.id)

    Forge.Repo.update!(Ecto.Changeset.change(job, harness: "codex"))
    Forge.Repo.update!(Ecto.Changeset.change(project, codex_model: "gpt-look-5", model: "opus"))

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    assert view |> element("#job-harness") |> render() =~ "Codex · gpt-look-5"
    refute render(view) =~ "opus"

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert view |> element("#job-#{job.id}-harness") |> render() =~ "Codex · gpt-look-5"
    refute render(view) =~ "opus"
  end

  # Criterion 30: a run's detail gives its tokens by kind, and a converted run, which has none,
  # says where its figure came from instead.
  test "the job page lists each run with its tokens by kind", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)

    Forge.Repo.delete_all(from r in Forge.Jobs.Run, where: r.job_id == ^job.id)

    Forge.ForgeFixtures.run!(Jobs.get!(job.id),
      usage: 123_456,
      tokens: %{
        "input" => 120_000,
        "cache_write" => 0,
        "cache_read" => 3_000_000,
        "output" => 90_000
      }
    )

    Forge.ForgeFixtures.run!(Jobs.get!(job.id),
      usage: 50_000,
      started_at: DateTime.add(DateTime.utc_now(:second), 60)
    )
    |> Ecto.Changeset.change(converted: true)
    |> Forge.Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    runs = view |> element("#job-runs") |> render()
    assert runs =~ "120k fresh input · 0 cache write · 3M cache read · 90k output"
    assert runs =~ "123,456 weighted tokens"
    assert runs =~ "converted from dollars"
    assert length(Regex.scan(~r/converted from dollars/, runs)) == 1
  end

  test "the board groups tickets by state in workflow order", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, _} = Tickets.admit(project, %{title: "first"}, {:user, user.id})
    {:ok, _} = Tickets.admit(project, %{title: "second"}, {:user, user.id})

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")
    assert html =~ "refining"
    assert html =~ "merged"
    assert :binary.match(html, "refining") < :binary.match(html, "merged")
  end

  # **Whether the card shows the message is the workflow's answer, not the pinned names'.**
  # Reading it off "does this approval pin the changeset" was right for the three workflows
  # shipped here and wrong for either shape that can be written beside them
  # (`ForgeCore.Workflow.merges_on_enter?/2` is what the entry action asks).
  describe "an approval whose pinned names do not say whether it merges" do
    setup %{project: project, user: user} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
      %{ticket: ticket}
    end

    defp pending!(ticket, to, approve) do
      ticket
      |> Ecto.Changeset.change(
        state: "review_ready",
        status: :active,
        pending_transition: %{
          "from" => "review_ready",
          "to" => to,
          "outcome" => nil,
          "approve" => approve
        }
      )
      |> Forge.Repo.update!()
    end

    # It enters the merging state, so the commit it will make is drawn and Approve waits for a
    # message — whatever the approval happens to pin.
    test "a merging approval of something else still shows the message", context do
      %{conn: conn, project: project, ticket: ticket} = context

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Refinement\n"
        })

      pending!(ticket, "merged", ["refinement.md"])

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      open!(view)

      assert view |> element(~s([id="#{commit_message_id(ticket)}"])) |> render() =~
               "nothing to merge yet"

      refute has_element?(view, ~s(button[value="approved"]))

      {:ok, _version} =
        Forge.Artifacts.record_version(ticket.id, "commit-message", :document, :system, %{
          content: "Persist the scores\n"
        })

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      open!(view)

      assert view |> element(~s([id="#{commit_message_id(ticket)}"])) |> render() =~
               "Persist the scores"

      assert has_element?(view, ~s(button[value="approved"]))
    end

    # And it does not merge, so there is nothing for a message to say and Approve is offered:
    # withholding it here left the operator nowhere to approve from, since all four surfaces
    # draw this one card.
    test "a non-merging approval of the changeset shows none, and still approves", context do
      %{conn: conn, project: project, ticket: ticket} = context
      sha = commit_over_http(project, ticket.branch, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)
      pending!(ticket, "verifying", ["changeset"])

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      open!(view)

      refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]))
      assert has_element?(view, ~s(button[value="approved"]))
    end
  end
end
