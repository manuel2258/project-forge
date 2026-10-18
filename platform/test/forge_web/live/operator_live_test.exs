defmodule ForgeWeb.OperatorLiveTest do
  @moduledoc "The operator pages, driven the way a phone would drive them."

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

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

  defp run_pending(ticket_id) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {name, doc} = Process.get(:scenario, {"success", "plan.md"})
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), name, doc: doc)
    job
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
    link =
      view
      |> element(~s(article > a[href="/tickets/#{project.name}/#{ticket.number}"]))
      |> render()

    assert link =~ "QUESTION" or link =~ "question"
    refute link =~ "<form"
    refute link =~ "phx-submit"
  end

  test "a job page shows what it declared and what it wrote", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    # `refining` declares refinement.md; the file's default scenario writes plan.md.
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    assert html =~ "Declares"
    assert html =~ "Wrote"

    # A running job's page reloads on its events; the prompt a reader opened stays open.
    assert [mounted] =
             html
             |> Floki.parse_document!()
             |> Floki.find("details#state-prompt")
             |> Floki.attribute("phx-mounted")

    assert mounted =~ "ignore_attrs"
    # What the run actually produced, linked to its exact version.
    assert html =~ "refinement.md"
    assert html =~ ~s(/artifacts/refinement.md/1)
    refute html =~ "not written"

    # Each row of what it wrote says what kind of file it is (`ui.md` § Artifact types).
    assert html
           |> Floki.parse_document!()
           |> Floki.find(~s(a[href$="/artifacts/refinement.md/1"] [data-file-type="markdown"]))
           |> length() == 1

    # Wider than the review page it is laid out like, for the stream's lines
    # (`docs/design/ui.md` § Space, measure and targets).
    assert html =~ "max-width: 96rem"
  end

  test "a job that did not write what it declared says so", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    # The default scenario writes plan.md, which `refining` does not declare, so the
    # refinement.md it *did* declare is missing — the case the two lists exist to tell apart.
    job = run_pending(ticket.id)

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    assert html =~ "not written"
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
    assert html =~ ~s(href="/projects/#{project.name}")
  end

  # `docs/design/ui.md` § The queue item: an approval shows what it approves. The pinned version
  # is rendered between the sentence naming it and Approve, under a link to its source, wherever
  # the card is drawn — the queue and the ticket's Decide.
  test "an approval card renders the document it pins, before Approve", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    for path <- [~p"/", ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"] do
      {:ok, view, _html} = live(conn, path)

      pinned = view |> element(~s([id="approving-#{ticket.id}-refinement.md"])) |> render()
      assert pinned =~ "<h1>Plan</h1>"
      assert pinned =~ "Do the thing."

      assert pinned =~
               ~s(href="/tickets/#{project.name}/#{ticket.number}/artifacts/refinement.md/1")

      # Read, then approve: the document is between the sentence naming it and the button that
      # pins it, in a box that scrolls inside itself.
      card = view |> element("#approval-#{ticket.id}") |> render()
      [before, _after] = String.split(card, ~s(value="approved"), parts: 2)
      [sentence, document] = String.split(before, "<h1>Plan</h1>", parts: 2)
      assert sentence =~ "Approving pins"
      refute document =~ "Approving pins"
      assert pinned =~ "max-h-[50vh]"
      assert pinned =~ "overflow-y-auto"
    end
  end

  # `docs/design/ui.md` § The affordance rule: Enter never commits a decision. As a one-line input
  # the comment submitted on Enter with the form's first button, which is Approve. A key press is
  # a browser event ExUnit cannot drive, so what is pinned is the box: a
  # textarea, which Enter cannot submit, on the composer's hook with the query every pointer
  # matches, and no hint saying Enter sends.
  test "Enter in an approval's comment is a new line", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("success", "refinement.md")
    run_pending(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/")

    box = view |> element("#approval-#{ticket.id} textarea[name=comment]") |> render()
    assert box =~ ~s(data-newline-on="all")
    refute has_element?(view, "#approval-#{ticket.id} input[type=text]")
    refute has_element?(view, "#approval-#{ticket.id} [data-hint]")
  end

  # A blob is never laid out: an approval pinning one names it and links to its bytes, and draws
  # no document box. The changeset, a blob too, is not drawn at all (ticket_work_screen_test).
  test "an approval card draws a blob as its link alone" do
    version = %Forge.Artifacts.Version{version: 3, content: nil, blob_uri: "file:build.tar"}
    pin = ForgeWeb.Operator.Components.pinned("game", %{number: 7}, "build.tar", version)

    assert pin.href == "/tickets/game/7/artifacts/build.tar/3"
    assert pin.body == nil

    html =
      render_component(&ForgeWeb.Operator.Components.approval_card/1,
        ticket: %{id: "t1"},
        pending: %{"to" => "shipping"},
        approve: [pin],
        drafts: %{}
      )

    assert html =~ ~s(href="/tickets/game/7/artifacts/build.tar/3")
    refute html =~ ~s(class="doc")
    refute html =~ "tabindex"

    # Its link row carries its type, as every artifact row does (`ui.md` § Artifact types).
    assert html
           |> Floki.parse_fragment!()
           |> Floki.find(~s(a[href$="/build.tar/3"] [data-file-type="archive"]))
           |> length() == 1
  end

  # `docs/design/ui.md` § Documents: what an approval pins is drawn as its name says it is, so a
  # log is read line by line rather than joined into one paragraph by Markdown.
  test "an approval card draws a text document as it was written" do
    version = %Forge.Artifacts.Version{version: 2, content: "# step 1\nok\n"}
    pin = ForgeWeb.Operator.Components.pinned("game", %{number: 7}, "check.log", version)

    html =
      render_component(&ForgeWeb.Operator.Components.approval_card/1,
        ticket: %{id: "t1"},
        pending: %{"to" => "shipping"},
        approve: [pin],
        drafts: %{}
      )

    assert [pre] =
             html |> Floki.parse_fragment!() |> Floki.find(~s([id="approving-t1-check.log"] pre))

    assert Floki.text(pre) == "# step 1\nok\n"
    refute html =~ "<h1>"
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
    assert render(view) =~ "approval"
    assert render(view) =~ "refining"
    # The card names the exact version it pins, from what the pending transition awaits.
    assert view |> element("#approval-#{ticket.id}") |> render() =~ "refinement.md v1"

    view
    |> form("#approval-#{ticket.id} form", %{"comment" => "fine"})
    |> render_submit(%{"decision" => "approved"})

    assert render(view) =~ "approved; now in planning"
    assert Tickets.get!(ticket.id).state == "planning"

    scenario("blocking", "plan.md")
    run_pending(ticket.id)
    html = render(view)
    assert html =~ "blocking question"
    assert html =~ "Which backend?"

    # a human edit in between makes the question live on a new version; answering still works
    plan = Forge.Artifacts.latest(ticket.id, "plan.md")

    {:ok, _} =
      Forge.Operator.edit(Tickets.get!(ticket.id), user, "plan.md", plan.content <> "\nEdited.\n")

    assert render(view) =~ "Which backend?"

    # Choosing only locks it in; Send is what answers, and the page's form is for the new version.
    view
    |> element("form[phx-submit='questions:send']")
    |> render_submit(%{"answers" => %{"backend" => %{"choice" => "b", "text" => ""}}})

    assert render(view) =~ "Sent 1 answer"
    refute render(view) =~ "blocking question"

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

  test "the ticket page shows jobs, artifacts and the timeline, and renders documents", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "They vanish."}, {:user, user.id})

    scenario("success", "refinement.md")
    run_pending(ticket.id)

    # Waiting on an approval, so it opens on Decide; the rest is a tab away.
    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert html =~ "Persist scores"
    assert html =~ "Last four events"
    assert has_element?(view, "#hoisted-decision")

    {:ok, _timeline, html} =
      live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")

    assert html =~ "They vanish."
    assert html =~ "refining"
    assert html =~ "#1"
    assert html =~ "refinement.md"
    assert html =~ "v1"

    {:ok, _docs, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
    assert html =~ "<h1>Plan</h1>"

    view |> form("#approval-#{ticket.id} form") |> render_submit(%{"decision" => "rejected"})
    assert render(view) =~ "rejected; now in refining"
  end

  # Why a pending job has not gone out, under its own row on the timeline — and on a page that
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
    assert view |> element("#approval-#{ticket.id}") |> render() =~ "refinement.md v1"

    view |> form("#approval-#{ticket.id} form") |> render_submit(%{"decision" => "rejected"})

    refute has_element?(view, "#approval-#{ticket.id}")

    # And what replaces it is the thing the design says rejection hands over: the transitions
    # out of the state the ticket stayed in.
    assert has_element?(view, "#hoisted-decision [phx-value-to='planning']")
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
    assert has_element?(queue, "#retry-#{ticket.id}", "Run refining again")
    refute has_element?(queue, "[phx-value-to='planning']")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, "#hoisted-decision [phx-value-to='planning']")

    assert view |> element("#retry-#{ticket.id}") |> render_click() =~ "Running refining again"

    assert Tickets.get!(ticket.id).status == :active

    assert [%{attempt: 2, status: :pending}] =
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
  end

  # A document that did not parse is not kept, so the job page is where why is said.
  test "a job page says why a document was refused", %{conn: conn, user: user, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    scenario("invalid_document", "refinement.md")
    run_pending(ticket.id)
    [job] = Jobs.for_ticket(ticket.id)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    assert view |> element("#refused-refinement\\.md") |> render() =~
             Jobs.refusals(job)["refinement.md"]

    assert Jobs.refusals(job)["refinement.md"] =~ "front_matter: is not closed"
    refute render(view) =~ "not written"
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

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert has_element?(view, "#retry-#{ticket.id}")

    {:ok, queue, _html} = live(conn, ~p"/")
    refute has_element?(queue, "#retry-#{ticket.id}")
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
    assert has_element?(queue, "#transitions-#{ticket.id}")
    refute has_element?(queue, "#retry-#{ticket.id}")
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

    # And the rail's last events say what the conflict was, beside its type.
    assert render(view) =~ "README.md conflicted on the way into merged"
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

    assert view |> element("#integrate-ticket") |> render() =~
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

    assert view
           |> form("#approval-#{ticket.id} form")
           |> render_submit(%{"decision" => "approved"}) =~
             "it conflicts with the default branch in README.md"

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

    # The rail says each stick's reason beside its event, the older one included.
    assert html =~ "an older reason"
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

  test "a ticket is cancelled from its page, leaves the board, and is restored there", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Never mind"}, {:user, user.id})

    {:ok, board, _html} = live(conn, ~p"/projects/#{project.name}")
    assert render(board) =~ "Never mind"

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    refute has_element?(view, "#restore-ticket")
    assert view |> element("#cancel-ticket") |> render_click() =~ "Ticket cancelled"
    assert Tickets.get!(ticket.id).status == :cancelled

    {:ok, board, _html} = live(conn, ~p"/projects/#{project.name}")
    refute render(board) =~ "Never mind"

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

    {:ok, _ticket} = Forge.Engine.cancel(ticket, user.id)

    assert render_hook(view, "cancel-ticket", %{"ticket" => ticket.id}) =~
             "a cancelled ticket cannot be cancelled"

    assert render_hook(view, "transition", %{"ticket" => ticket.id, "to" => "planning"}) =~
             "the ticket is cancelled; restore it first"
  end

  test "the job page shows the pinned manifest and harness events", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")
    assert html =~ "Pinned manifest"
    assert html =~ "Inputs, at their exact version"
    assert html =~ "ticket"
    assert html =~ "refinement.md"
    # Consumption reads as capacity, never money: see docs/design/capacity.md.
    assert html =~ "20 turns"
    assert html =~ "windows"
    refute html =~ "$0.5"
    assert html =~ "Refine the ticket into a crisp problem statement."
    assert html =~ "fake-model · session sess-42"
    assert html =~ "Reading the plan."
  end

  # Claude Code turns every `system` message into a `notice`, and `thinking_tokens` alone
  # outnumbered everything else in the stream on the dev node — the page became a telemetry feed
  # with the work buried in it, which is the "streaming log … nothing that invites watching agents
  # work" `docs/design/ui.md` rules out. They are still recorded: the event log is the record, and
  # the toggle is for the one time someone is debugging the harness itself.
  test "the job stream hides the harness's own telemetry until asked", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "x"}, {:user, user.id})
    scenario("success", "refinement.md")
    job = run_pending(ticket.id)

    # Recorded through the path the channel uses, with the type the wire actually carries:
    # `ForgeWorker.Job.Runner` prefixes the driver's bare `notice` with `job.harness.`.
    :ok =
      Forge.Jobs.record_harness_event(job.id, %{
        type: "job.harness.notice",
        payload: %{"subtype" => "thinking_tokens", "raw" => %{"tokens" => 128}}
      })

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}")

    refute html =~ "thinking_tokens"
    assert html =~ "Show 1 harness notices"
    # The work itself is still there — this hides telemetry, not the stream.
    assert html =~ "Reading the plan."

    shown = render_click(view, "notices")

    assert shown =~ "thinking_tokens"
    assert shown =~ "Hide 1 harness notices"
  end

  test "the board groups tickets by state in workflow order", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, _} = Tickets.admit(project, %{title: "first"}, {:user, user.id})
    {:ok, _} = Tickets.admit(project, %{title: "second"}, {:user, user.id})

    {:ok, _view, html} = live(conn, ~p"/board")
    assert html =~ project.name
    assert html =~ "refining"
    assert html =~ "merged"
    assert :binary.match(html, "refining") < :binary.match(html, "merged")
  end
end
