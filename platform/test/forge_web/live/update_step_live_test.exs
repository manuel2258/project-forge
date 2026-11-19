defmodule ForgeWeb.UpdateStepLiveTest do
  @moduledoc """
  What a person sees of an update step (`docs/design/ui.md` § Steps, § The details, § Activity,
  § The queue, § Workflow): a visit drawn in Steps with what it did, the re-pin under it, the notice
  that says why the engine did not re-pin, the words in Activity, the stuck item in the queue, and
  the platform's own mark on the map. Every value in them is a contributor's and is drawn as text.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.GitFixtures
  import Forge.MergeFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Engine, Events, Jobs, Projects, Repo, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} = context do
    bare =
      seeded_repo(%{
        ".forge/workflow.yml" => update_workflow(Map.get(context, :workflow, [])),
        ".forge/agents/integrate.md" => "Merge the default branch in.\n",
        ".forge/agents/implement.md" => "Implement.\n"
      })

    {:ok, project} =
      Projects.register(
        %{name: "step-#{System.unique_integer([:positive])}", repo_path: bare},
        user
      )

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Practice timer", body: "."}, {:user, user.id})

    commit_message!(ticket)
    %{project: project, bare: bare, ticket: ticket}
  end

  defp finish!(ticket, state \\ "implementing") do
    job =
      ticket.id
      |> Jobs.for_ticket()
      |> Enum.filter(&(&1.state == state))
      |> List.last()
      |> Ecto.Changeset.change(
        status: :finished,
        outcome: :converged,
        declared_outcome: "done",
        started_at: DateTime.utc_now(:second)
      )
      |> Repo.update!()

    {:ok, ticket} = Engine.after_job(Tickets.get!(ticket.id), job, "done")
    ticket
  end

  defp page(project, ticket, query \\ ""), do: "/tickets/#{project.name}/#{ticket.number}#{query}"

  defp merged_by_ticket!(bare, ticket, title, file) do
    sha = commit_to(bare, "main", %{file => "x\n"}, "Merge ticket/#{ticket.number}: #{title}")

    {:ok, _} =
      Events.append("ticket.merged", :system, %{
        ticket_id: ticket.id,
        payload: %{"sha" => sha, "already" => false}
      })

    sha
  end

  describe "chunk_visits/1" do
    # Consecutive jobs of one state are one visit, of different states two; an update visit is
    # always its own.
    test "folds the jobs of one state and only those" do
      items = [
        {:job, %{state: "a", id: 1}},
        {:job, %{state: "a", id: 2}},
        {:job, %{state: "b", id: 3}},
        {:update, %{"state" => "refresh"}},
        {:update, %{"state" => "refresh"}},
        {:job, %{state: "b", id: 4}}
      ]

      assert [
               {:jobs, [%{id: 1}, %{id: 2}]},
               {:jobs, [%{id: 3}]},
               {:update, _first},
               {:update, _second},
               {:jobs, [%{id: 4}]}
             ] = ForgeWeb.TicketLive.chunk_visits(items)
    end
  end

  describe "Steps" do
    test "a visit that changed nothing is still drawn, in one line", context do
      %{conn: conn, project: project, ticket: ticket} = context
      ticket = finish!(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#steps-list", "refresh")

      assert has_element?(
               view,
               "#steps-list .ticket-step-detail",
               "already up to date with main at"
             )

      assert has_element?(view, "#update-visit-refresh", "already up to date with main at")
      # Not a job's step, and not a person's: the platform's own mark.
      assert has_element?(view, "#steps-list .ui-state-mark", "↻")
    end

    test "a merge says what it brought in, by ticket number, newest first", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context

      {:ok, other} = Tickets.admit(project, %{title: "Settings screen", body: "."}, :system)
      merged_by_ticket!(bare, other, "Settings screen", "a.txt")
      {:ok, two} = Tickets.admit(project, %{title: "Home <b>bold</b>", body: "."}, :system)
      merged_by_ticket!(bare, two, "Home", "b.txt")
      commit_to(bare, "main", %{"c.txt" => "c\n"}, "no record of <i>this</i> one")

      chat_sha = commit_to(bare, "main", %{"d.txt" => "d\n"}, "Merge chat: <u>notes</u>")

      {:ok, _} =
        Events.append("chat.merged", :system, %{
          project_id: project.id,
          payload: %{"chat" => "chat-1", "sha" => chat_sha}
        })

      commit_over_http(project, ticket.branch, "feature.txt", "mine")

      ticket = finish!(ticket)
      {:ok, view, html} = live(conn, page(project, ticket))

      assert has_element?(view, "#update-visit-refresh", "merged main at")
      assert has_element?(view, "#update-visit-refresh", "bringing in 4 merges")
      assert has_element?(view, "#update-visit-refresh", "a conversation's merge")

      items = view |> element("#update-visit-refresh") |> render()
      newest = :binary.match(items, "no record of") |> elem(0)
      older = :binary.match(items, "Home") |> elem(0)
      oldest = :binary.match(items, "Settings screen") |> elem(0)
      assert newest < older and older < oldest
      assert items =~ "##{two.number}"
      # Escaped, not interpreted.
      assert html =~ "Home &lt;b&gt;bold&lt;/b&gt;"
      refute html =~ "Home <b>bold</b>"
      # A subject nothing recorded, and a conversation's, are drawn as text as well.
      assert html =~ "no record of &lt;i&gt;this&lt;/i&gt; one"
      refute html =~ "<i>this</i>"
      assert html =~ "Merge chat: &lt;u&gt;notes&lt;/u&gt;"
      refute html =~ "<u>notes</u>"
    end

    test "at most ten merges are listed, then how many more", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      for n <- 1..13, do: commit_to(bare, "main", %{"n#{n}.txt" => "x\n"}, "Merge chat: #{n}")

      ticket = finish!(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#update-visit-refresh", "and 3 more")
      assert has_element?(view, "#update-visit-refresh", "bringing in 13 merges")
    end

    test "a conflict says where it went, with the first path, hostile names as text", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      path = "<script>alert(1)</script>.md"
      commit_over_http(project, ticket.branch, path, "mine")
      commit_to(bare, "main", %{path => "trunk\n"}, "another ticket")

      ticket = finish!(ticket)
      {:ok, view, html} = live(conn, page(project, ticket))

      assert ticket.state == "resolving"

      # In the order they happened: the job, the visit, then the job the conflict sent it to.
      assert has_element?(view, "#step-0 .ui-state", "implementing")
      assert has_element?(view, "#step-1 .ui-state", "refresh")
      assert has_element?(view, "#step-2 .ui-state", "resolving")
      assert has_element?(view, "#update-visit-refresh", "conflicted with main in")
      assert has_element?(view, "#update-visit-refresh", "went to resolving")
      refute html =~ "<script>alert(1)"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;.md"
    end

    test "says what became of the pin, under it", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      main = commit_to(bare, "main", %{".forge/agents/implement.md" => "Implement, newer.\n"})
      pinned = ticket.workflow_commit

      ticket = finish!(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(
               view,
               "#update-visit-refresh",
               "re-pinned from #{String.slice(pinned, 0, 12)} to #{String.slice(main, 0, 12)}"
             )
    end

    test "a held ticket resting in the step says it runs when released", context do
      %{conn: conn, project: project, ticket: ticket, user: user} = context
      ticket = ticket |> Ecto.Changeset.change(state: "asking") |> Repo.update!()
      {:ok, held} = Engine.hold(ticket, {:user, user.id})
      {:ok, _} = Engine.choose(held, user.id, "refresh")
      ticket = Tickets.get!(ticket.id)

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(
               view,
               "#steps-list .ticket-step-detail",
               "brings the branch up to date when released"
             )
    end
  end

  describe "the details" do
    test "say why the engine did not re-pin, and go once it has", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context

      commit_to(bare, "main", %{
        ".forge/workflow.yml" =>
          "version: 1\ninitial: nowhere\nstates: {}\ntransitions: []\nlimits:\n  ticket_tokens: 5M\n"
      })

      ticket = finish!(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))

      assert has_element?(view, "#pin-drift")
      assert has_element?(view, "#pin-drift-skipped", "The update step did not re-pin it")
      assert has_element?(view, "#pin-drift-skipped", "does not validate")

      assert has_element?(
               view,
               "#pin-drift-skipped",
               "Re-pinning by hand would meet the same refusal"
             )
    end

    # Only where the reason is the file's: a hand re-pin asks that the ticket's own state exist
    # there, which it may where the step itself is what is missing.
    test "do not promise a refusal where the step is what is missing", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context

      without = """
      version: 1
      initial: implementing
      states:
        implementing:
          prompt: agents/implement.md
          produces: [implementation.md, changeset, commit-message]
          budget: { turns: 10, tokens: 200k }
        review_ready: {}
        merged:
          on_enter: merge
      transitions:
        - { from: implementing, to: review_ready }
        - { from: review_ready, to: merged, approve: [changeset] }
      limits:
        ticket_tokens: 5M
      """

      commit_to(bare, "main", %{".forge/workflow.yml" => without})
      ticket = finish!(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#pin-drift-skipped", "has no state refresh")
      refute has_element?(view, "#pin-drift-skipped", "same refusal")
    end

    test "carry no skipped reason once a re-pin has come after it", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare, user: user} = context

      commit_to(bare, "main", %{
        ".forge/workflow.yml" =>
          "version: 1\ninitial: nowhere\nstates: {}\ntransitions: []\nlimits:\n  ticket_tokens: 5M\n"
      })

      ticket = finish!(ticket)
      # The default branch is mended and the ticket re-pinned by a person; then it moves again.
      commit_to(bare, "main", %{".forge/workflow.yml" => update_workflow()})
      {:ok, _} = Engine.repin(Tickets.get!(ticket.id), user.id)
      commit_to(bare, "main", %{".forge/agents/implement.md" => "Later words.\n"})

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#pin-drift")
      refute has_element?(view, "#pin-drift-skipped")
    end

    test "carry no skipped reason when the pin is only behind", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      ticket = finish!(ticket)
      commit_to(bare, "main", %{".forge/agents/implement.md" => "Later words.\n"})

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#pin-drift")
      refute has_element?(view, "#pin-drift-skipped")
    end
  end

  describe "Activity" do
    test "says what the step did, in words and never a payload's keys", context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      main = commit_to(bare, "main", %{".forge/agents/implement.md" => "Newer.\n"})
      pinned = ticket.workflow_commit
      ticket = finish!(ticket)

      {:ok, view, html} = live(conn, page(project, ticket, "?tab=activity"))

      assert has_element?(view, "#activity", "moved forward to #{String.slice(main, 0, 12)}")

      assert has_element?(
               view,
               "#activity",
               "re-pinned from #{String.slice(pinned, 0, 12)} to #{String.slice(main, 0, 12)}"
             )

      assert has_element?(view, "#activity", "base moved")
      refute html =~ "result="
      refute html =~ "default_branch="
    end
  end

  describe "the queue" do
    @tag workflow: [conflict: false]
    test "a step that stuck says why in words, with the paths, as an ordinary stuck item",
         context do
      %{conn: conn, project: project, ticket: ticket, bare: bare} = context
      commit_over_http(project, ticket.branch, "README.md", "mine")
      commit_to(bare, "main", %{"README.md" => "trunk\n"}, "another ticket")
      ticket = finish!(ticket)
      assert ticket.status == :stuck

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#queue-item", "conflicted in README.md")
      # And in the line *since you last looked*, in the visit's own sentence.
      assert has_element?(view, ".queue-since-line", "conflicted with main in README.md; stuck")
      assert has_element?(view, "#queue-item", "refresh")
      # In its past it is a step with visits, as a human state's are, and not a run.
      assert has_element?(view, "#queue-past", "refresh · 1 visit")
      assert has_element?(view, "#queue-past", "last conflicted with main in README.md")
      refute has_element?(view, "#queue-past", "refresh · 1 run")
      assert project.name
    end
  end

  describe "the workflow, on the project page" do
    test "draws the step as the platform's own work, in words, and where a conflict goes",
         context do
      %{conn: conn, project: project} = context

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=workflow")

      assert has_element?(view, ".wf-flow", "brings the branch up to date with main")
      assert has_element?(view, ".wf-flow", "conflicts go to resolving")
      assert has_element?(view, ".wf-map-box--update .wf-map-mark", "↻")
      assert has_element?(view, ".wf-map-box--update", "up to date with main")
      assert has_element?(view, ".wf-map-box--update", "conflict → resolving")
      assert has_element?(view, ~s(.wf-map-edge[data-from="refresh"][data-to="resolving"]))
    end
  end
end
