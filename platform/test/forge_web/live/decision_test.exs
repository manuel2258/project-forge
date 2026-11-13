defmodule ForgeWeb.DecisionTest do
  @moduledoc """
  The decision row and its panel on a ticket (`docs/design/ui.md` § The decision row): pinned in
  the frame on every view, and a reject that needs a note — disabled on the page while the note
  is blank, refused by the operation when it arrives anyway, and said inside the panel.
  """

  use ForgeWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Artifacts, Jobs, Projects, Tickets}
  alias ForgeWeb.Operator.Decision

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "dr-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
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

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    worker = Forge.FakeWorker.connect()
    {:ok, _job} = Forge.FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")

    %{project: project, ticket: Tickets.get!(ticket.id), worker: worker}
  end

  defp pending(ticket) do
    [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    job
  end

  # Another person rejects v1, the state runs again, and its job writes v2: a new approval of the
  # same edge, on a page that is still open.
  defp replaced_elsewhere!(project, ticket, worker, admin) do
    other = Forge.AccountsFixtures.user_fixture()
    {:ok, _} = Projects.put_member(project, other, :member, admin)
    {:ok, rejected} = Forge.Operator.decide(Tickets.get!(ticket.id), other, :rejected, "No.")
    {:ok, _} = Forge.Engine.retry(rejected, other.id)
    {:ok, _} = Forge.FakeWorker.run(pending(ticket), worker, "success", doc: "refinement.md")
  end

  defp page(project, ticket, query \\ ""),
    do: "/tickets/#{project.name}/#{ticket.number}" <> query

  defp open!(view) do
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    assert has_element?(view, "#decision-panel")
    view
  end

  test "the row is pinned in the frame, on every view, and drops its panel", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    for tab <- ~w(decide timeline changes docs activity) do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=#{tab}"))
      assert has_element?(view, ".frame-decision #decision-row", "refinement.md v1")
      refute has_element?(view, "#decision-panel")
    end

    # Written moments ago, in the sentence's words: never "written now" (r3 L3); the age alone, as
    # `written just …` cut the one word that mattered (UX re-check #19).
    {:ok, view, _html} = live(conn, page(project, ticket))
    assert has_element?(view, "#decision-row", "· just now")
    refute has_element?(view, "#decision-row", "written")

    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)
    assert has_element?(view, "#decision-row button[aria-expanded=true]", "Approve ▴")

    # The row's button again, the handle at the panel's foot, or a tap on the scrim folds it.
    view |> element("#decision-row button[aria-expanded=true]") |> render_click()
    refute has_element?(view, "#decision-panel")
    open!(view)
    view |> element("#decision-panel button.frame-handle") |> render_click()
    refute has_element?(view, "#decision-panel")
    open!(view)
    view |> element("#decision-row .ui-drop-scrim") |> render_click()
    refute has_element?(view, "#decision-panel")
  end

  test "Reject is disabled until the note holds more than whitespace", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)

    assert has_element?(view, ~s(#decision-form button[value="rejected"][disabled]))
    # The label does not call the note optional beside a hint that needs it (UX pass, A18).
    assert has_element?(view, "#decision-panel", "Needed to reject.")
    refute has_element?(view, "#decision-panel label", "optional")

    view |> form("#decision-form", %{"note" => "  \n "}) |> render_change()
    assert has_element?(view, ~s(#decision-form button[value="rejected"][disabled]))

    view |> form("#decision-form", %{"note" => "Name the table."}) |> render_change()
    refute has_element?(view, ~s(#decision-form button[value="rejected"][disabled]))
    # Approve never waits for a note.
    refute has_element?(view, ~s(#decision-form button[value="approved"][disabled]))
  end

  test "a reject that reaches the server without a note is refused inside the panel", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)

    # Past the disabled button, as a stale page or a hand-sent event would be.
    view
    |> form("#decision-form", %{"note" => " "})
    |> render_submit(%{"decision" => "rejected"})

    assert has_element?(view, "#decision-panel #decision-error", "a reject needs a note")
    refute has_element?(view, "#toast")

    again = Tickets.get!(ticket.id)
    assert again.status == :active
    assert again.pending_transition != nil
    assert Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id) == []
  end

  test "a reject with a note is made, toasted, and the note is drawn with it", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)

    view
    |> form("#decision-form", %{"note" => "Say where the scores live."})
    |> render_submit(%{"decision" => "rejected"})

    assert has_element?(view, "#toast", "Rejected refinement.md v1")
    assert has_element?(view, "#toast", "the note goes to the next job")
    refute has_element?(view, "#decision-row")
    assert Tickets.get!(ticket.id).status == :stuck

    # Drawn with the rejection, in Activity's list of what happened to the ticket itself
    # (`docs/design/ui.md` § Activity).
    {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

    assert has_element?(
             view,
             "#ticket-events",
             "rejected refining → planning: Say where the scores live."
           )
  end

  # A refused press changes nothing, the view included. The review's scenario: the reader is on
  # Docs for a document approval, which is replaced by a merging one — whose default is Changes —
  # and the press is refused. Choosing the default again would move them off the panel holding
  # the refusal.
  test "a refused press does not move the reader to another view", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    assert has_element?(view, "#docs")
    open!(view)

    ticket
    |> Ecto.Changeset.change(
      state: "review_ready",
      pending_transition: %{
        "from" => "review_ready",
        "to" => "merged",
        "outcome" => nil,
        "approve" => ["refinement.md"]
      }
    )
    |> Forge.Repo.update!()

    render_submit(view, "decision:decide", %{
      "decision" => "approved",
      "shown" => "refining>planning:refinement.md@1"
    })

    assert has_element?(view, "#decision-panel #decision-error", "What waits changed")
    assert has_element?(view, "#docs")
    refute has_element?(view, "#changes")
  end

  # `ui.md` § The ticket: a rejection made here goes on to Steps, where the ways forward are, also
  # from a view the address names — the queue's link and every strip tab name one.
  test "a reject made on a named view goes on to Steps", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))
    assert has_element?(view, "#changes")
    open!(view)

    view
    |> form("#decision-form", %{"note" => "Say where the scores live."})
    |> render_submit(%{"decision" => "rejected"})

    assert_patch(view, page(project, ticket))
    assert has_element?(view, "#steps")
    refute has_element?(view, "#changes")
  end

  # `docs/design/ui.md` § The decision row: what the panel holds is the decision's it was opened
  # on. The review's scenario: a note typed on v1, v1 rejected by someone else, v2 arriving.
  test "a new approval arrives folded, with no note from the one before", %{
    conn: conn,
    project: project,
    ticket: ticket,
    worker: worker,
    user: user
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)
    view |> form("#decision-form", %{"note" => "my old note"}) |> render_change()

    replaced_elsewhere!(project, ticket, worker, user)

    assert has_element?(view, "#decision-row", "refinement.md v2")
    refute has_element?(view, "#decision-panel")

    open!(view)
    refute render(view) =~ "my old note"
    assert has_element?(view, ~s(#decision-form button[value="rejected"][disabled]))
  end

  # A press names the approval it was made on, and one on an approval since replaced decides
  # nothing; what waits now is drawn with the refusal.
  test "a press on an approval since replaced decides nothing and says so in the panel", %{
    conn: conn,
    project: project,
    ticket: ticket,
    worker: worker,
    user: user
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)
    shown = view |> element("#decision-form input[name=shown]") |> render()
    assert shown =~ "refinement.md@1"

    replaced_elsewhere!(project, ticket, worker, user)

    # The page drew v1 when the press was made; the socket hears of v2 only now.
    render_submit(view, "decision:decide", %{
      "decision" => "approved",
      "shown" => "refining>planning:refinement.md@1"
    })

    again = Tickets.get!(ticket.id)
    assert again.state == "refining"
    assert again.pending_transition != nil
    assert Forge.Artifacts.approvals(Forge.Artifacts.latest(ticket.id, "refinement.md").id) == []
    assert has_element?(view, "#decision-panel #decision-error", "What waits changed")
    assert has_element?(view, "#decision-row", "refinement.md v2")
    refute has_element?(view, "#toast")
  end

  # The page stays connected after its viewer leaves the project: the press is checked against
  # who they are when it arrives, not when the page mounted (`Forge.Operator.decide/4`).
  test "a press by somebody no longer in the project decides nothing", %{
    project: project,
    ticket: ticket,
    user: admin
  } do
    member = Forge.AccountsFixtures.user_fixture()
    {:ok, _} = Projects.put_member(project, member, :member, admin)
    {:ok, view, _html} = live(log_in_user(build_conn(), member), page(project, ticket))
    open!(view)

    :ok = Projects.remove_member(project, member, admin)

    log =
      capture_log(fn ->
        render_submit(view, "decision:decide", %{
          "decision" => "approved",
          "shown" => "refining>planning:refinement.md@1"
        })
      end)

    again = Tickets.get!(ticket.id)
    assert again.state == "refining"
    assert again.pending_transition != nil
    assert Artifacts.approvals(Artifacts.latest(ticket.id, "refinement.md").id) == []
    assert log =~ ":forbidden"
  end

  test "a press after someone else decided is refused where the row was", %{
    conn: conn,
    project: project,
    ticket: ticket,
    user: user
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    open!(view)

    {:ok, _} = Forge.Operator.decide(Tickets.get!(ticket.id), user, :approved, nil)

    render_submit(view, "decision:decide", %{
      "decision" => "approved",
      "shown" => "refining>planning:refinement.md@1"
    })

    refute has_element?(view, "#decision-row")
    assert has_element?(view, ".frame-decision #decision-gone", "Someone decided this")

    view |> element("#decision-gone button", "Dismiss") |> render_click()
    refute has_element?(view, "#decision-gone")
  end

  # `ui.md` § The ticket: the default view is chosen as the page is opened, not as it changes.
  test "an approval decided elsewhere does not move the reader off the view they opened on", %{
    conn: conn,
    project: project,
    ticket: ticket,
    user: user
  } do
    {:ok, view, _html} = live(conn, page(project, ticket))
    assert has_element?(view, "#docs")

    {:ok, _} = Forge.Operator.decide(Tickets.get!(ticket.id), user, :approved, nil)

    refute has_element?(view, "#decision-row")
    assert has_element?(view, "#docs")
    refute has_element?(view, "#steps")

    # The next visit lands where the ticket is now.
    {:ok, view, _html} = live(conn, page(project, ticket))
    assert has_element?(view, "#steps")
  end

  # `ui.md` § The end of the pass, and *All*: a socket rejoining the page sends back the look it
  # was opened with, and records none.
  test "a rejoin of the page draws from the look it was opened with and records none", %{
    conn: conn,
    project: project,
    ticket: ticket,
    user: user
  } do
    earlier = ~U[2026-11-01 08:00:00.000000Z]
    Forge.Tickets.Views.touch(user, ticket)

    Forge.Repo.update_all(Forge.Tickets.View, set: [viewed_at: earlier])

    conn
    |> put_connect_params(%{
      "look" => %{"ticket" => ticket.id, "since" => DateTime.to_iso8601(earlier)}
    })
    |> live(page(project, ticket))
    |> then(fn {:ok, view, _html} ->
      assert has_element?(view, ~s(#ticket-look[data-since="#{DateTime.to_iso8601(earlier)}"]))
    end)

    assert Forge.Tickets.Views.since(user, [ticket.id]) == %{ticket.id => earlier}

    # A look carried from another ticket's page is a new visit to this one, and records.
    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"look" => %{"ticket" => Ecto.UUID.generate(), "since" => ""}})
      |> live(page(project, ticket))

    assert has_element?(view, ~s(#ticket-look[data-since="#{DateTime.to_iso8601(earlier)}"]))
    refute Forge.Tickets.Views.since(user, [ticket.id]) == %{ticket.id => earlier}
  end

  # A later visit of a chat step is a conversation of its own, and the pick made on the first is
  # not a preselection on the second (plan § 6: nothing preselected). Asked of `put/2` directly:
  # on a page the ticket leaves the step between the two visits, and that reload folds the panel
  # anyway — unless both changes land before the page hears of either.
  test "a step's panel is the visit's it was opened on" do
    step = fn id -> %{kind: :step, step: %{chat: %{id: id}}, questions: [], answer: nil} end

    socket =
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      |> Decision.init()
      |> Decision.put(step.("visit-1"))
      |> Phoenix.Component.assign(decision_open: true, decision_pick: "done")

    kept = Decision.put(socket, step.("visit-1"))
    assert %{decision_open: true, decision_pick: "done"} = kept.assigns

    next = Decision.put(socket, step.("visit-2"))
    assert %{decision_open: false, decision_pick: nil, decision_note: ""} = next.assigns
  end
end
