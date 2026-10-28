defmodule ForgeWeb.MergeQueueLiveTest do
  @moduledoc """
  What a person sees of the merge queue (`docs/design/ui.md` § Decide and Timeline, § The project
  page): the card on a queued ticket, the list on the project page, the flag on the boards, the
  words a too-late *Take out* is refused in — and that none of it is drawn under the operator's
  queue, nor to anyone who is not a member.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import Forge.GitFixtures
  import Forge.MergeFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Engine, MergeQueue, Operator, Projects, Repo, Tickets}
  alias Forge.MergeQueue.Entry

  setup :register_and_log_in_user

  setup %{user: user} = context do
    workflow =
      if context[:plain],
        do: conflict_workflow(:b),
        else:
          String.replace(
            conflict_workflow(:b),
            "{ from: review_ready, to: merged, approve: [changeset] }",
            "{ from: review_ready, to: merged, approve: [changeset], queue: true }"
          )

    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => workflow,
        ".forge/agents/integrate.md" => "Merge the default branch in.\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "mq-#{System.unique_integer([:positive])}", repo_path: bare},
        user
      )

    %{project: project, bare: bare}
  end

  defp queued!(project, user, title, file) do
    {:ok, ticket} = Tickets.admit(project, %{title: title, body: "do it"}, {:user, user.id})
    changeset!(ticket, commit_over_http(project, ticket.branch, file, "contents of #{file}"))
    commit_message!(ticket, "Add #{file}\n")
    {:ok, _queued} = Operator.decide(pend_merge(ticket), user, :approved, "ship it")
    Tickets.get!(ticket.id)
  end

  # A row without the work behind it, for the pages that only draw it.
  defp row!(project, ticket, status \\ :waiting) do
    Repo.insert!(%Entry{
      project_id: project.id,
      ticket_id: ticket.id,
      from_state: "review_ready",
      to_state: "merged",
      edge_outcome: "done",
      status: status
    })
  end

  defp titled(project, title) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, :system)
    ticket
  end

  describe "the ticket page" do
    test "says the ticket is queued, its place and what is happening, in place of the approval",
         %{conn: conn, project: project, user: user} do
      first = queued!(project, user, "First change", "a.txt")
      second = queued!(project, user, "Second change", "b.txt")

      {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{second.number}")

      assert html =~ "In the merge queue"
      assert has_element?(view, "#merge-queue-place", "2nd of 2")
      assert has_element?(view, "#merge-queue-doing", "Waiting for 1 ahead")
      assert has_element?(view, "#merge-queue-#{second.id}")
      assert has_element?(view, "#take-out-#{second.id}", "Take out of queue")

      # What the confirm promises about an integration already running.
      assert render(view) =~ "will finish, but will not merge"

      # Nothing offers to approve what is approved, or to move a ticket the line owns.
      refute has_element?(view, ~s|button[phx-value-decision="approved"]|)
      refute has_element?(view, "#transitions-#{second.id}")
      refute has_element?(view, "#integrate-ticket")
      refute has_element?(view, "#retry-#{second.id}")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{first.number}")
      assert has_element?(view, "#merge-queue-place", "1st of 2")
      assert has_element?(view, "#merge-queue-doing", "Next to be merged")
    end

    test "says when it is being merged and when it is being integrated",
         %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Under way", "a.txt")

      set_status =
        &(MergeQueue.entry(ticket) |> Ecto.Changeset.change(status: &1) |> Repo.update!())

      set_status.(:integrating)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert has_element?(view, "#merge-queue-place", "being integrated")
      assert has_element?(view, "#merge-queue-doing", "keeps its place")

      set_status.(:merging)
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")
      assert has_element?(view, "#merge-queue-place", "being merged now")
      assert has_element?(view, "#merge-queue-doing", "Being merged")
    end

    test "tells the queue's story on the timeline", %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Story", "a.txt")
      {:ok, _out} = Operator.take_out(ticket, user)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")

      assert has_element?(view, "#queue-history li", "queued to merge into merged")
      assert has_element?(view, "#queue-history li", "taken out of the merge queue")

      # Oldest first.
      html = render(view)
      {queued, _} = :binary.match(html, "queued to merge into merged")
      {out, _} = :binary.match(html, "taken out of the merge queue; its approval")
      assert queued < out
    end

    @tag plain: true
    test "draws no merge queue on the timeline of a ticket the queue never held",
         %{conn: conn, project: project, user: user} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Plain", body: "x"}, {:user, user.id})
      changeset!(ticket, commit_over_http(project, ticket.branch, "a.txt", "contents"))
      commit_message!(ticket, "Add a.txt\n")
      assert {:ok, merged} = Operator.decide(pend_merge(ticket), user, :approved, nil)
      assert merged.state == "merged"

      {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")

      refute has_element?(view, "#queue-history")
      refute html =~ "Merge queue"
    end

    test "says on the timeline that it merged", %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Merged story", "a.txt")
      assert {:merged, _id} = Engine.advance_queue(project.id)

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=timeline")

      assert has_element?(view, "#queue-history li", "merged as")
      assert has_element?(view, "#queue-history li", "merged, and left the merge queue")
    end

    test "takes it out, and the choice is back", %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Take me out", "a.txt")
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      view |> element("#take-out-#{ticket.id}") |> render_click()

      assert MergeQueue.entry(ticket) == nil
      refute has_element?(view, "#merge-queue-#{ticket.id}")
      assert has_element?(view, "#transitions-#{ticket.id}")
    end

    test "refuses a take-out that is too late in words, not an error page",
         %{conn: conn, project: project, user: user} do
      merged = queued!(project, user, "Already merged", "a.txt")
      gone = queued!(project, user, "Taken out elsewhere", "b.txt")
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{merged.number}")
      {:ok, other, _html} = live(conn, ~p"/tickets/#{project.name}/#{gone.number}")

      assert {:merged, _id} = Engine.advance_queue(project.id)
      {:ok, _ticket} = Operator.take_out(gone, user)

      assert render_click(view, "take-out", %{"ticket" => merged.id}) =~
               "it has already merged"

      assert render_click(other, "take-out", %{"ticket" => gone.id}) =~
               "someone has already taken it out"

      assert Tickets.get!(merged.id).state == "merged"
    end

    test "is not shown to a stranger", %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Private", "a.txt")
      outsider = user_fixture()
      join!(project_fixture(), outsider)

      assert_raise Ecto.NoResultsError, fn ->
        conn |> log_in_user(outsider) |> live(~p"/tickets/#{project.name}/#{ticket.number}")
      end
    end
  end

  describe "the project page" do
    test "lists the line in order, with the way out", %{conn: conn, project: project, user: user} do
      first = queued!(project, user, "First change", "a.txt")
      second = queued!(project, user, "Second change", "b.txt")

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "Merge queue"
      assert [first.id, second.id] == queue_ids(view)
      assert has_element?(view, "#queue-#{first.id}", "next to be merged")
      assert has_element?(view, "#queue-#{second.id}", "2nd of 2")

      view |> element("#queue-#{first.id} button", "Take out") |> render_click()

      assert queue_ids(view) == [second.id]
      assert MergeQueue.entry(first) == nil
    end

    test "shows the ticket's own state beside its place", %{conn: conn, project: project} do
      ticket = titled(project, "Integrating one")
      row!(project, ticket, :integrating)
      ticket |> Ecto.Changeset.change(state: "integrating") |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#queue-#{ticket.id}", "integrating · being integrated")
      # A target a thumb can hit below `sm`, not a 12px link to hunt for.
      assert view |> element("#queue-#{ticket.id} a") |> render() =~ "min-h-[46px]"
    end

    test "draws a long title wrapped and markup as text", %{
      conn: conn,
      project: project
    } do
      long = String.duplicate("long ", 40)
      marked = titled(project, "<b>bold</b> <script>alert(1)</script>")
      row!(project, titled(project, long))
      row!(project, marked)

      {:ok, view, html} = live(conn, ~p"/projects/#{project.name}")

      assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "<b>bold</b>"
      refute html =~ "<script>alert"
      assert has_element?(view, "#merge-queue-list span.break-words", String.trim(long))
    end

    test "folds a long line behind 'N more'", %{conn: conn, project: project} do
      for n <- 1..12, do: row!(project, titled(project, "Queued #{n}"))

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#merge-queue-expand", "4 more")
      assert has_element?(view, "#merge-queue-list li", "Queued 1")
      refute has_element?(view, "#merge-queue-list li", "Queued 9")
      assert has_element?(view, "#merge-queue-more li", "Queued 9")
    end

    test "empty, names the edge that would fill it", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#merge-queue-empty", "review_ready → merged")
      assert has_element?(view, "#merge-queue-empty", "Approving a ticket on")
    end

    @tag plain: true
    test "empty, for a workflow that queues nothing, says only that nothing waits",
         %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      assert has_element?(view, "#merge-queue-empty", "Nothing is waiting to merge.")
      refute has_element?(view, "#merge-queue-empty", "Approving")
    end
  end

  describe "the boards and the operator's queue" do
    test "flag a queued ticket without moving it from its column",
         %{conn: conn, project: project, user: user} do
      ticket = queued!(project, user, "Flagged", "a.txt")

      {:ok, view, _html} = live(conn, ~p"/board")
      assert has_element?(view, ~s|[id^="column-"]|, "queued 1/1")
      assert has_element?(view, ~s|[id^="column-"]|, ticket.title)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")
      assert has_element?(view, ~s|[id^="column-"]|, "queued 1/1")
    end

    test "the operator's queue lists no decision for a queued ticket and draws no merge queue",
         %{conn: conn, project: project, user: user} do
      queued!(project, user, "Zebra change", "a.txt")

      {:ok, view, html} = live(conn, ~p"/")

      # Its first job was never run here, so it is "under way" as any fresh ticket is; what must
      # not be there is a decision, because its approval is given.
      refute has_element?(view, "#queue-decisions", "Zebra change")
      refute html =~ "Merge queue"
    end
  end

  defp queue_ids(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("#merge-queue-list li", "id")
    |> Enum.map(&String.replace_prefix(&1, "queue-", ""))
  end
end
