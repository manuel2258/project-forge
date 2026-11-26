defmodule ForgeWeb.TakeoverLiveTest do
  @moduledoc """
  A taken-over ticket on its page and in the lists (`docs/design/ui.md` § The ticket,
  `docs/design/outside-work.md`): the band with who, since when and the line to fetch the branch;
  **Take over** in the details, asking what to do with a run that is going; **Hand back** with its
  step picker and note, refusing in place; the stuck item of a branch that moved under a job
  (criteria 23 to 27, 30, 31).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.ForgeFixtures
  import Forge.GitFixtures

  alias Forge.{FakeWorker, Git, Jobs, Operator, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "tl-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    funded!(project)

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    {:ok, ticket} = Operator.admit(project, user, %{title: "Persist scores", on_hold: false})
    %{project: project, ticket: ticket}
  end

  defp page(project, ticket), do: "/tickets/#{project.name}/#{ticket.number}"

  defp take_over(view), do: view |> element("#take-over-ticket") |> render_click()

  describe "taking over" do
    test "the details offer it, and the band says who, since when and how to fetch", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#take-over-ticket", "Take over")
      refute has_element?(view, "#hold-band")

      take_over(view)

      assert has_element?(view, "#hold-band")
      assert has_element?(view, "#takeover-word", "Taken over by you")
      assert has_element?(view, "#takeover-pushed", "nothing pushed")
      assert has_element?(view, "#hand-back-open", "Hand back")
      refute has_element?(view, "#take-over-ticket")

      fetch = view |> element("#takeover-fetch") |> render()
      assert fetch =~ "git fetch #{Git.Url.for(project)} #{ticket.branch}"
      # The line is the address and the branch, never a credential.
      refute fetch =~ "@"
    end

    test "commits pushed since are counted, and said to be recorded on hand-back", ctx do
      %{conn: conn, project: project, ticket: ticket, user: user} = ctx
      {:ok, _} = Operator.take_over(ticket, user)
      commit_file_on_branch(project, ticket.branch, "a.txt", "one")
      commit_file_on_branch(project, ticket.branch, "b.txt", "two")

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#takeover-pushed", "2 commits pushed")
      assert has_element?(view, "#takeover-pushed", "recorded when it is handed back")
    end

    test "with a run going it asks, neither preselected, and presses nothing for the person",
         ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
      assignment = FakeWorker.assign(job, FakeWorker.connect())

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#take-over-choice")
      refute has_element?(view, "#take-over-ticket")
      refute has_element?(view, "#hold-band")
      assert has_element?(view, "#take-over-stop")
      assert has_element?(view, "#take-over-finish")

      view |> element("#take-over-stop") |> render_click()
      job_id = assignment["job_id"]
      assert_receive {:cancel, ^job_id, :ticket_cancelled}, 1_000
      assert has_element?(view, "#hold-band")
    end

    test "another member's page shows the band with their address, not *you*", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      other = member_fixture(project)
      {:ok, _} = Operator.take_over(ticket, other)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#takeover-word", "Taken over by #{other.email}")
    end

    test "a ticket taken over by a token says so as the API names it", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx

      {:ok, _secret, writer} =
        Forge.Git.Tokens.issue(project, name: "my-pc", git: :developer, api: :write)

      {:ok, _} = Operator.take_over(ticket, writer, via: :mcp)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#takeover-word", "API · my-pc")
    end
  end

  describe "handing back (criteria 24, 31)" do
    setup %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = live(conn, page(project, ticket))
      take_over(view)
      %{view: view}
    end

    test "lists every step, preset to where it rests, each marked and naming what it lacks",
         %{view: view, ticket: ticket} do
      steps = Forge.Tickets.workflow(Tickets.get!(ticket.id)) |> ForgeCore.Workflow.state_names()
      assert length(steps) > 2

      for name <- steps, do: assert(has_element?(view, "#hand-back-step-#{name}"), name)

      assert has_element?(view, ~s(#hand-back-step-refining input[checked]))
      assert has_element?(view, "#hand-back-step-refining", "where it rests")
      assert has_element?(view, "#hand-back-step-implementing", "needs")
    end

    test "hands back, the band goes and what was pushed is the change", ctx do
      %{view: view, project: project, ticket: ticket} = ctx
      sha = commit_file_on_branch(project, ticket.branch, "mine.txt", "from my pc")

      view
      |> form("#hand-back-form", %{"to" => "refining", "note" => "polished"})
      |> render_submit()

      refute has_element?(view, "#hold-band")
      assert {:ok, %{sha: ^sha}} = Forge.Merge.changeset(Tickets.get!(ticket.id))
    end

    test "a step missing a document is refused where it was pressed, naming it, and stays taken over",
         %{view: view, ticket: ticket} do
      typed = %{"to" => "implementing", "note" => "<b>hi</b>"}
      view |> form("#hand-back-form", typed) |> render_change()
      view |> form("#hand-back-form", typed) |> render_submit()

      assert has_element?(view, "#hold-band")
      assert has_element?(view, "#hold-refusal", "no version yet")
      assert Tickets.get!(ticket.id).takeover_id
      # The note is text: drawn escaped, and kept for the next try.
      assert render(view) =~ "&lt;b&gt;hi&lt;/b&gt;"
      refute render(view) =~ "<b>hi</b>"
    end

    test "a note over the limit is refused with the limit, never cut", %{view: view} = ctx do
      note = String.duplicate("x", Forge.Tickets.Takeover.note_limit() + 1)

      typed = %{"to" => "refining", "note" => note}
      view |> form("#hand-back-form", typed) |> render_change()
      view |> form("#hand-back-form", typed) |> render_submit()

      assert has_element?(view, "#hold-refusal", "2000")
      assert has_element?(view, "#hand-back-note", String.slice(note, 0, 50))
      assert Tickets.get!(ctx.ticket.id).takeover_id
    end
  end

  describe "in the lists (criterion 26)" do
    test "a row says who has it, and the milestone's release is a hand-back", ctx do
      %{conn: conn, project: project, ticket: ticket, user: user} = ctx
      {:ok, _} = Operator.take_over(ticket, user)

      {:ok, view, _html} = live(conn, "/projects/#{project.name}")
      assert render(view) =~ "taken over · #{user.email}"
    end
  end

  describe "Activity (criterion 27)" do
    test "says who took it over and who handed it back, the commits, the note as text", ctx do
      %{conn: conn, project: project, ticket: ticket, user: user} = ctx
      {:ok, taken} = Operator.take_over(ticket, user, via: :page)
      commit_file_on_branch(project, ticket.branch, "mine.txt", "Fix the parser")
      {:ok, _back} = Operator.hand_back(taken, user, note: "<b>by hand</b>", via: :api)

      Forge.Events.append("ticket.work_kept", {:user, user.id}, %{
        ticket_id: ticket.id,
        payload: %{
          "merged" => true,
          "from" => String.duplicate("a", 40),
          "to" => String.duplicate("b", 40),
          "via" => "page"
        }
      })

      {:ok, view, _html} = live(conn, page(project, ticket) <> "?tab=activity")

      assert has_element?(
               view,
               "#ticket-events",
               "took it over in refining to work outside forge"
             )

      assert has_element?(view, "#ticket-events", "handed it back to refining")
      assert has_element?(view, "#ticket-events", "1 commit(s) pushed meanwhile")
      assert has_element?(view, "#ticket-events", "Fix the parser")
      assert has_element?(view, "#ticket-events", "kept the work of a job whose branch had moved")
      assert has_element?(view, "#ticket-events", "<b>by hand</b>")
      refute render(view) =~ "<b>by hand</b>"
    end
  end

  describe "a branch that moved under a job (criterion 30)" do
    # The ticket stuck as the platform leaves it: the job's own commit kept at its ref, and
    # somebody else's on the branch.
    defp stuck_for_moved_branch!(ctx, arrived, pushers \\ []) do
      %{project: project, ticket: ticket} = ctx
      repo = Projects.repo_path(project)
      [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
      assignment = FakeWorker.assign(job, FakeWorker.connect())
      lease = elem(Git.resolve(repo, "refs/heads/" <> ticket.branch), 1)
      kept = commit_beside(repo, lease, "same.txt", "the job's")
      {:ok, _} = Git.run(repo, ["update-ref", "refs/forge/kept/#{job.id}", kept])
      {path, content} = arrived

      for pusher <- pushers,
          do:
            Forge.Events.append("branch.pushed", pusher, %{
              ticket_id: ticket.id,
              payload: %{"ref" => "refs/heads/" <> ticket.branch, "from" => lease, "to" => lease}
            })

      theirs = commit_file_on_branch(project, ticket.branch, path, content)

      FakeWorker.put_transcript(assignment)
      result = FakeWorker.result(assignment, "success", doc: "refinement.md")

      moved = %{
        "lease" => lease,
        "kept" => kept,
        "remote" => theirs,
        "outcome" => result.declared_outcome
      }

      {:ok, _} = Jobs.complete(job.id, %{result | branch_moved: moved})
      %{job: job, kept: kept, theirs: theirs}
    end

    test "says what arrived, where the work is kept and offers the ways out", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      run = stuck_for_moved_branch!(ctx, {"theirs.txt", "from a person"})

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#moved-branch")
      assert has_element?(view, "#moved-arrived", "1 commit arrived")
      assert has_element?(view, "#moved-commits", String.slice(run.theirs, 0, 8))
      fetch = view |> element("#moved-fetch") |> render()
      assert fetch =~ "refs/forge/kept/#{run.job.id}"
      refute fetch =~ "@"
      assert has_element?(view, "#keep-work", "Keep the job's work")
      assert has_element?(view, "#moved-take-over")
      assert has_element?(view, "#ways-forward")
    end

    test "names who pushed: a member by address, a token by its name, on the page and in the queue",
         ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      colleague = member_fixture(project)
      {:ok, _secret, writer} = Forge.Git.Tokens.issue(project, name: "my-pc", git: :developer)

      stuck_for_moved_branch!(
        ctx,
        {"theirs.txt", "from a person"},
        [{:user, colleague.id}, {:api, writer.id, "my-pc"}]
      )

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#moved-arrived", "Pushed by #{colleague.email}, API · my-pc")

      {:ok, queue, _html} = live(conn, "/")
      assert has_element?(queue, "#moved-arrived", "Pushed by #{colleague.email}, API · my-pc")
      assert has_element?(queue, "#keep-work")
    end

    test "a take-over refused from the queue's item says why, in the queue", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      stuck_for_moved_branch!(ctx, {"theirs.txt", "from a person"})
      colleague = member_fixture(project)

      {:ok, queue, _html} = live(conn, "/")
      assert has_element?(queue, "#moved-take-over")

      # Somebody else took it over meanwhile; what this page presses is stale.
      {:ok, _} = Operator.take_over(Tickets.get!(ticket.id), colleague)
      render_click(queue, "take-over", %{"ticket" => ticket.id})

      assert has_element?(queue, "#queue-refusal", "already taken over")
    end

    test "keeps the job's work when it does not clash, and the item goes", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      stuck_for_moved_branch!(ctx, {"theirs.txt", "from a person"})

      {:ok, view, _html} = live(conn, page(project, ticket))
      view |> element("#keep-work") |> render_click()

      refute has_element?(view, "#moved-branch")
      refute Tickets.get!(ticket.id).status == :stuck
    end

    test "a clash is refused naming the paths and every way out stays", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      stuck_for_moved_branch!(ctx, {"same.txt", "the person's"})

      {:ok, view, _html} = live(conn, page(project, ticket))
      view |> element("#keep-work") |> render_click()

      assert has_element?(view, "#keep-work-refusal", "same.txt")
      assert has_element?(view, "#keep-work")
      assert has_element?(view, "#moved-take-over")
      assert Tickets.get!(ticket.id).status == :stuck
    end

    test "take it over from the item holds the ticket", ctx do
      %{conn: conn, project: project, ticket: ticket} = ctx
      stuck_for_moved_branch!(ctx, {"theirs.txt", "from a person"})

      {:ok, view, _html} = live(conn, page(project, ticket))
      view |> element("#moved-take-over") |> render_click()
      assert has_element?(view, "#hold-band")
    end
  end
end
