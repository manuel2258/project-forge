defmodule ForgeWeb.TicketJumpLiveTest do
  @moduledoc """
  The fold of other states on a ticket's Steps (`docs/design/ui.md` § Steps): every state no arrow
  reaches, each a jump, behind a fold below the ways forward, on the phone's dock too, kept across
  a reconnect, and read back in Steps (ticket 56, criteria 14 to 18, 22, 23).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.MergeFixtures

  alias Forge.{Artifacts, Jobs, Projects, Repo, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "jl-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo(jump_files()),
          default_branch: "main"
        },
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, ticket: ticket}
  end

  defp page(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}"

  # The ticket stuck where it is with its job over, and the document its one edge approves.
  defp stuck!(ticket, state \\ "refining", status \\ :stuck) do
    for job <- Jobs.for_ticket(ticket.id) do
      job |> Ecto.Changeset.change(status: :finished, outcome: :converged) |> Repo.update!()
    end

    {:ok, _v} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    ticket |> Ecto.Changeset.change(state: state, status: status) |> Repo.update!()
  end

  defp html_of(view, selector), do: view |> element(selector) |> render()

  # What a person does: open the fold, and then pick a row in it.
  defp open_fold(view, way \\ nil) do
    view |> form("#ways-forward", %{"other" => "open"}) |> render_change()

    if way,
      do: view |> form("#ways-forward", %{"other" => "open", "way" => way}) |> render_change()
  end

  test "the fold sits under the arrows, closed, and lists every other state when opened", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)
    {:ok, view, _html} = live(conn, page(project, ticket))

    # The arrow to `planning` is as it was; the other states are behind the fold.
    assert has_element?(view, ~s(#ways-forward input[value="to:planning"]))
    assert has_element?(view, "#ways-other-toggle")
    assert has_element?(view, "#ways-other", "Other states")
    refute has_element?(view, ~s(#ways-forward input[value^="jump:"]))

    open_fold(view)

    for state <- ~w(implementing review_ready chatting merged integrating) do
      assert has_element?(view, ~s(#ways-forward input[value="jump:#{state}"])), state
    end

    # Closing it hides them again: the checkbox is the fold's state, not a one-way latch.
    render_hook(view, "forward:pick", %{})
    refute has_element?(view, ~s(#ways-forward input[value^="jump:"]))
    open_fold(view)

    # Not the arrow's own target, and not the state it rests in unless nothing leads to it.
    refute has_element?(view, ~s(#ways-forward input[value="jump:planning"]))
    assert has_element?(view, "#way-jump\\:review_ready", "")
    assert render(view) =~ "no transition leads here"
    assert render(view) =~ "Jump to review_ready"
  end

  test "a jump with something missing is listed, disabled, and says what and who can write it",
       ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)
    {:ok, view, _html} = live(conn, page(project, ticket))
    open_fold(view)

    assert has_element?(view, ~s(input[value="jump:implementing"][disabled]))
    html = render(view)
    assert html =~ "plan.md has no version yet — a ticket chat can write it"
    # The changeset and the message are written by the states that produce them.
    assert has_element?(view, ~s(input[value="jump:merged"][disabled]))
    assert html =~ "changeset has no version yet — implementing, integrating writes it"
    assert html =~ "commit-message has no version yet — implementing writes it"
    refute has_element?(view, ~s(input[value="jump:review_ready"][disabled]))
  end

  test "the button of a row that cannot be taken is disabled, in the dock and under the rows",
       ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)
    {:ok, view, _html} = live(conn, page(project, ticket))
    open_fold(view, "jump:review_ready")
    refute has_element?(view, "#forward-button-inline[disabled]")
    refute has_element?(view, "#forward-button[disabled]")

    # `implementing` needs `plan.md`, which has no version, so its row cannot be chosen; what can
    # arrive is a pick replayed on a rejoin (`forward:pick`), and it takes nothing.
    render_hook(view, "forward:pick", %{"other" => "open", "way" => "jump:implementing"})
    assert has_element?(view, "#forward-button-inline[disabled]", "Jump to implementing")
    assert has_element?(view, "#forward-button[disabled]", "Jump to implementing")
  end

  # Criterion 10 on the page: what a person reads under Changes for a reopened ticket is what the
  # branch changed since the merge, not the work that landed.
  test "a reopened ticket's Changes show only what came after its merge", ctx do
    %{conn: conn, project: project, ticket: ticket, user: user} = ctx

    sha =
      commit_file_on_branch(project, ticket.branch, "landed.txt", "already on the default branch")

    changeset!(ticket, sha)
    commit_message!(ticket, "Land the first piece\n")
    ready = stuck!(ticket, "review_ready", :active)

    assert {:ok, %{status: :done}} = Forge.Operator.transition(ready, user, "merged")

    {:ok, _v} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# P\n"
      })

    assert {:ok, _} = Forge.Operator.transition(Tickets.get!(ticket.id), user, "implementing")
    commit_file_on_branch(project, ticket.branch, "after.txt", "new work")

    {:ok, view, _html} = live(conn, page(project, ticket) <> "?tab=changes")
    html = render(view)
    assert html =~ "after.txt"
    refute html =~ "landed.txt"
  end

  test "a jump into a state that merges is drawn as the approval it records", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    sha = commit_file_on_branch(project, ticket.branch, "a.txt", "contents")
    changeset!(ticket, sha)
    commit_message!(ticket, "Add a.txt\n\nBecause the test says so.\n")
    stuck!(ticket)

    {:ok, view, _html} = live(conn, page(project, ticket))
    open_fold(view)

    assert render(view) =~ "merges, approving the changeset v1 in your name"
    row = ~s(#ways-forward label[for="way-jump:merged"])
    assert has_element?(view, row, "merges, approving")
    assert has_element?(view, row, "· no transition leads here")
    refute has_element?(view, row, "rests there")

    # The words for a state that merges are the state's, wherever they are drawn (the queue too).
    assert ForgeWeb.TicketViews.leads(Tickets.workflow(ticket), "merged") ==
             "merges the ticket's branch"

    refute has_element?(view, "#jump-commit")

    open_fold(view, "jump:merged")
    assert has_element?(view, "#jump-commit")
    assert render(view) =~ "Because the test says so."
  end

  test "taking a jump moves the ticket, says so, and Steps reads it as a jump", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)
    {:ok, view, _html} = live(conn, page(project, ticket))
    open_fold(view, "jump:review_ready")

    assert has_element?(view, "#forward-button-inline", "Jump to review_ready")
    assert has_element?(view, ".ticket-dock--forward #forward-button", "Jump to review_ready")

    html = view |> form("#ways-forward") |> render_submit()
    assert html =~ "Jumped to review_ready"
    assert %{state: "review_ready"} = Tickets.get!(ticket.id)

    assert has_element?(view, ".ticket-step--jump", "Jumped from refining to review_ready")
    # Between the visit it left and the state it arrived in, in the order it happened.

    assert html_of(view, "#step-0") =~ "refining"
    assert html_of(view, "#step-1") =~ "Jumped from"
    assert html_of(view, "#step-2") =~ "review_ready"
    assert has_element?(view, ".ticket-step--jump", "· you")
    # The ticket's own state is still the last step.
    assert has_element?(view, "#steps-list li:last-child.ticket-step--current")
  end

  test "who made a jump is you or a member, never an address", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    other = Forge.ForgeFixtures.member_fixture(project)
    ticket = stuck!(ticket)
    {:ok, _} = Forge.Operator.transition(ticket, other, "review_ready")

    {:ok, view, _html} = live(conn, page(project, ticket))
    assert has_element?(view, ".ticket-step--jump", "· a member")
    refute render(view) =~ other.email

    {:ok, activity, _html} = live(conn, page(project, ticket) <> "?tab=activity")
    assert has_element?(activity, ".work-act-detail", "jumped from refining to review_ready")
    assert has_element?(activity, ".work-act-detail", "a member")

    # The merge line's own move has no person behind it, and says so.
    Forge.Events.append("transition.taken", :system, %{
      ticket_id: ticket.id,
      payload: %{"from" => "implementing", "to" => "merged", "jump" => true}
    })

    {:ok, again, _html} = live(conn, page(project, ticket) <> "?tab=activity")
    assert has_element?(again, ".work-act-detail", "the engine")

    # A token is named by its name, which is not an address either.
    Forge.Events.append("transition.taken", {:api, "tok", "deploy-bot"}, %{
      ticket_id: ticket.id,
      payload: %{"from" => "refining", "to" => "chatting", "jump" => true}
    })

    {:ok, token, _html} = live(conn, page(project, ticket) <> "?tab=activity")
    assert has_element?(token, ".work-act-detail", "API · deploy-bot")
    {:ok, steps, _html} = live(conn, page(project, ticket))
    assert has_element?(steps, ".ticket-step--jump", "API · deploy-bot")
  end

  test "a jump that reopens a done ticket says so in Steps, and its sentence is no mono row",
       ctx do
    %{conn: conn, project: project, ticket: ticket, user: user} = ctx
    done = stuck!(ticket, "merged", :done)

    {:ok, _v} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# P\n"
      })

    {:ok, _} = Forge.Operator.transition(done, user, "implementing", comment: "plan skipped")
    {:ok, view, _html} = live(conn, page(project, ticket))

    assert has_element?(view, ".ticket-step--jump", "Jumped from merged to implementing")
    assert has_element?(view, ".ticket-step--jump", "(reopened)")
    assert has_element?(view, ".ticket-step--jump", "plan skipped")
    # What a person wrote is not set in mono, and the row opens nothing (`ui.md`).
    assert has_element?(view, ".ticket-step--jump p.ticket-step-jump")
    refute has_element?(view, ".ticket-step--jump .ticket-step-row")
  end

  test "two visits to a state either side of a jump are two steps", ctx do
    %{conn: conn, project: project, ticket: ticket, user: user} = ctx
    ticket = stuck!(ticket)

    {:ok, _v} =
      Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# P\n"
      })

    {:ok, first} = Forge.Operator.transition(ticket, user, "implementing")

    for job <- Jobs.for_ticket(ticket.id), job.status == :pending do
      job |> Ecto.Changeset.change(status: :finished, outcome: :converged) |> Repo.update!()
    end

    stuck = first |> Ecto.Changeset.change(status: :stuck) |> Repo.update!()
    {:ok, _again} = Forge.Operator.transition(stuck, user, "refining")

    {:ok, view, _html} = live(conn, page(project, ticket))

    # refining, jump, implementing, jump, refining: the state it left is two steps, not one
    assert has_element?(view, "#step-4")
    refute has_element?(view, "#step-5")
    assert has_element?(view, "#step-1.ticket-step--jump")
    assert has_element?(view, "#step-3.ticket-step--jump")
    assert html_of(view, "#step-0") =~ "refining"
    assert html_of(view, "#step-2") =~ "implementing"
    assert html_of(view, "#step-4") =~ "refining"
  end

  test "the fold's open state and the pick come back together on a rejoin", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)

    # What the client replays on a rejoin is the form's change, whole.
    {:ok, view, _html} = live(conn, page(project, ticket))
    open_fold(view, "jump:review_ready")
    assert has_element?(view, ~s(#ways-other-toggle[checked]))
    assert has_element?(view, ~s(input[value="jump:review_ready"][checked]))

    {:ok, fresh, _html} = live(conn, page(project, ticket))
    refute has_element?(fresh, ~s(input[value="jump:review_ready"]))
    render_hook(fresh, "forward:pick", %{"other" => "open", "way" => "jump:review_ready"})
    assert has_element?(fresh, ~s(input[value="jump:review_ready"][checked]))
  end

  test "a done ticket has the fold and no arrows, and a cancelled one has neither", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket, "merged", :done)
    {:ok, view, _html} = live(conn, page(project, ticket))

    refute has_element?(view, ~s(#ways-forward input[value^="to:"]))
    assert has_element?(view, "#ways-other", "Other states")

    ticket |> Ecto.Changeset.change(status: :cancelled) |> Repo.update!()
    {:ok, cancelled, _html} = live(conn, page(project, ticket))
    refute has_element?(cancelled, "#ways-other")
  end

  # Between a job's end and what the engine does with it the ticket is active in a state that runs
  # work, and resting; a person is offered nothing then, jumps included.
  test "an active ticket in a state that runs work has no fold", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket, "refining", :active)
    {:ok, view, _html} = live(conn, page(project, ticket))
    refute has_element?(view, "#ways-other")
  end

  test "a press drawn as an arrow whose target is now a jump is refused in words", ctx do
    %{conn: conn, project: project, ticket: ticket} = ctx
    stuck!(ticket)
    {:ok, view, _html} = live(conn, page(project, ticket))

    html =
      render_hook(view, "transition", %{
        "ticket" => ticket.id,
        "to" => "chatting",
        "jump" => "false"
      })

    assert html =~ "is a jump now, not a transition"
    assert %{state: "refining"} = Tickets.get!(ticket.id)
  end
end
