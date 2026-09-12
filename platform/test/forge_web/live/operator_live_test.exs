defmodule ForgeWeb.OperatorLiveTest do
  @moduledoc "The operator pages, driven the way a phone would drive them."

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup do
    {:ok, project} =
      Projects.register(%{
        name: "ui-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, original) end)

    %{project: project}
  end

  defp scenario(name, doc) do
    config = Application.get_env(:forge, Forge.Jobs)

    Application.put_env(
      :forge,
      Forge.Jobs,
      Keyword.put(config, :extra_env, [{"FAKE_SCENARIO", name}, {"FAKE_DOC", doc}])
    )
  end

  defp run_pending(ticket_id) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {:ok, job} = Jobs.run(job)
    job
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
    assert render(view) =~ "refined"

    view
    |> form("#approval-#{ticket.id} form", %{"comment" => "fine"})
    |> render_submit(%{"decision" => "approved"})

    assert render(view) =~ "approved; now in planned"
    assert Tickets.get!(ticket.id).state == "planned"

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
             Enum.filter(Jobs.for_ticket(ticket.id), &(&1.state == "planned"))
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
    assert html =~ "refined"
    assert html =~ "#1"
    assert html =~ "refinement.md"
    assert html =~ "v1"
    assert html =~ "<h1>Plan</h1>"
    assert html =~ "Last four events"
    assert has_element?(view, "#hoisted-decision")

    view |> form("#approval-#{ticket.id} form") |> render_submit(%{"decision" => "rejected"})
    assert render(view) =~ "rejected; now in refined"
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

  test "the board groups tickets by state in workflow order", %{
    conn: conn,
    user: user,
    project: project
  } do
    {:ok, _} = Tickets.admit(project, %{title: "first"}, {:user, user.id})
    {:ok, _} = Tickets.admit(project, %{title: "second"}, {:user, user.id})

    {:ok, _view, html} = live(conn, ~p"/board")
    assert html =~ project.name
    assert html =~ "refined"
    assert html =~ "merged"
    assert :binary.match(html, "refined") < :binary.match(html, "merged")
  end
end
