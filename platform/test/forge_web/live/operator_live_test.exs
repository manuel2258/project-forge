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
    # What the run actually produced, linked to its exact version.
    assert html =~ "refinement.md"
    assert html =~ ~s(/artifacts/refinement.md/1)
    refute html =~ "not written"
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

    view |> element("button[phx-value-key=backend][phx-value-choice=b]") |> render_click()
    assert render(view) =~ "Answered backend: b"
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

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
    assert html =~ "Persist scores"
    assert html =~ "They vanish."
    assert html =~ "refining"
    assert html =~ "#1"
    assert html =~ "refinement.md"
    assert html =~ "v1"
    assert html =~ "<h1>Plan</h1>"
    assert html =~ "Last four events"
    assert has_element?(view, "#hoisted-decision")

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
