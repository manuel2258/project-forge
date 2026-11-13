defmodule ForgeWeb.JobLiveTest do
  @moduledoc """
  The job page (`docs/design/ui.md` § The job page, `6e`, `21a`, `21b`): inside its ticket's
  frame, the outcome as the headline, Stream · Manifest · Wrote behind a switch, and where the job
  stands — its plan, its facts, the attempts at its state in this visit — beside it.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Jobs, Projects, Repo, Tickets}
  alias Forge.Jobs.{Job, Run}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "job-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
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

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, ticket: ticket}
  end

  defp page(project, ticket, job),
    do: ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"

  # The worker is this process (`Forge.FakeWorker`): it takes the assignment and answers it.
  defp run_pending(ticket, scenario \\ "success", doc \\ "plan.md") do
    [job] = Enum.filter(Jobs.for_ticket(ticket.id), &(&1.status == :pending))
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), scenario, doc: doc)
    job
  end

  defp progress!(job, attrs),
    do: job |> Job.progress_changeset(attrs) |> Repo.update!()

  defp harness!(job, type, payload),
    do: :ok = Jobs.record_harness_event(job.id, %{type: type, payload: payload})

  defp bash!(job, id, command, error? \\ false) do
    harness!(job, "job.harness.tool_use", %{
      id: id,
      name: "Bash",
      input: %{"command" => command}
    })

    harness!(job, "job.harness.tool_result", %{
      tool_use_id: id,
      is_error: error?,
      excerpt: if(error?, do: "1 failure", else: "ok"),
      bytes: 2
    })
  end

  # An event recorded at a moment of the test's choosing: the table is append-only, so it is
  # written with its time rather than moved to one.
  defp event_at!(job, type, payload, at) do
    Repo.insert!(%Forge.Events.Event{
      actor: %{"kind" => "job", "id" => job.id},
      type: type,
      payload: payload,
      job_id: job.id,
      ticket_id: job.ticket_id,
      project_id: job.project_id,
      inserted_at: at
    })
  end

  defp text(view, selector), do: view |> element(selector) |> render() |> strip()

  defp strip(html),
    do:
      html |> Floki.parse_fragment!() |> Floki.text(sep: " ") |> String.split() |> Enum.join(" ")

  describe "the headline" do
    test "the declared outcome is the headline and the engine's is beside it, captioned", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket) |> progress!(%{declared_outcome: "done", outcome: :error})

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      # The largest thing on the page is the agent's own word; the engine's is the smaller one.
      assert text(view, "#job-headline .job-outcome") == "done"
      assert text(view, "#job-headline") =~ "done error"

      assert text(view, "#job-caption") ==
               "What the agent declared, then what the engine concluded."
    end

    test "with nothing declared the engine's outcome is the headline and the caption says so", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket) |> progress!(%{declared_outcome: nil, outcome: :did_not_converge})

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert text(view, "#job-headline .job-outcome") == "did_not_converge"
      assert text(view, "#job-caption") == "The engine's outcome. The agent declared nothing."
    end

    test "a running job has no outcome to caption", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      job = progress!(job, %{status: :running})

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert text(view, "#job-headline") == "running"
      refute has_element?(view, "#job-caption")
    end

    test "the three figures are one line: turns, usage from the run ledger, duration", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket)
      now = DateTime.utc_now(:second)

      # The job's own column says one thing and its runs another: the figure is the runs'
      # (`Forge.Jobs.Runs`, where spend is read from since `credentials.md` § Spend).
      job =
        progress!(job, %{
          turns: 30,
          usage: 19_800_000,
          started_at: DateTime.add(now, -700, :second),
          finished_at: now
        })

      # The machine FakeWorker ran it on, for the runs put in place of its own.
      [%{worker_id: worker} | _] = Forge.Jobs.Runs.for_job(job.id)
      Repo.delete_all(from r in Run, where: r.job_id == ^job.id)

      # Two runs, 620k weighted tokens between them, at the configured 1M a window.
      for usage <- [300_000, 320_000] do
        Repo.insert!(%Run{
          job_id: job.id,
          worker_id: worker,
          started_at: now,
          finished_at: now,
          usage: usage
        })
      end

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert text(view, "#job-figures") =~ ~r/^30 turns · 0\.62 windows · 11m 40s$/

      # Where it ran: the latest run's machine.
      assert text(view, "#job-facts") =~ "worker machine #{String.slice(worker, 0, 8)}"
    end
  end

  describe "the ticket's frame" do
    test "the strip is the ticket's, leading back to its views with its counts", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket, "success", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      {:ok, ticket_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      for tab <- ~w(steps changes docs activity) do
        assert has_element?(
                 view,
                 ~s(#tab-#{tab}[href="/tickets/#{project.name}/#{ticket.number}?tab=#{tab}"])
               )

        # The same count the ticket's own strip draws.
        assert text(view, "#tab-#{tab}") == text(ticket_view, "#tab-#{tab}")
      end

      assert text(view, "#tab-docs") =~ ~r/Docs \d/
      assert text(view, "#tab-activity") =~ ~r/Activity \d/
    end

    # The same builder as the ticket's own (`TicketViews.strip/5`): while the ticket has a live
    # conversation, its job's page offers Talk as the ticket's page does.
    test "the strip carries Talk while the ticket has a conversation", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket, "success", "refinement.md")
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      refute has_element?(view, "#tab-talk")

      {:ok, chat} =
        Forge.Conversations.open(project, "about this", ticket: Tickets.get!(ticket.id))

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      {:ok, ticket_view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      assert has_element?(view, ~s(#tab-talk[href="/chats/#{chat.id}"]))
      assert has_element?(ticket_view, ~s(#tab-talk[href="/chats/#{chat.id}"]))
    end

    test "the chip points at the job running now while another is read", %{
      conn: conn,
      user: user,
      project: project,
      ticket: ticket
    } do
      failed = run_pending(ticket, "max_turns", "refinement.md")
      {:ok, _retried} = Forge.Engine.retry(Tickets.get!(ticket.id), user.id)
      [_failed, second] = Jobs.for_ticket(ticket.id)
      second = progress!(second, %{status: :running})

      {:ok, view, _html} = live(conn, page(project, ticket, failed))
      assert has_element?(view, ~s(#job-chip[href="#{page(project, ticket, second)}"]))

      # Reading the running one itself, the chip would point at the page it is on.
      {:ok, running, _html} = live(conn, page(project, ticket, second))
      refute has_element?(running, "#job-chip")
    end
  end

  describe "where it stands" do
    test "the attempts at this state in this visit are listed, the others linked", %{
      conn: conn,
      user: user,
      project: project,
      ticket: ticket
    } do
      first = run_pending(ticket, "max_turns", "refinement.md")
      {:ok, _retried} = Forge.Engine.retry(Tickets.get!(ticket.id), user.id)
      second = run_pending(ticket, "max_turns", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, second))

      assert has_element?(view, "#attempt-#{first.id} a[href='#{page(project, ticket, first)}']")
      assert has_element?(view, "#attempt-#{second.id}", "this one")
      refute has_element?(view, "#attempt-#{second.id} a")
    end

    test "a job of another state is not an attempt at this one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      refining = run_pending(ticket, "max_turns", "refinement.md")

      other =
        Forge.ForgeFixtures.job_fixture(%{ticket: ticket, state: "planning", status: :running})

      {:ok, view, _html} = live(conn, page(project, ticket, other))

      refute has_element?(view, "#attempt-#{refining.id}")
      refute has_element?(view, "#job-attempts")
    end

    test "its plan is the agent's latest TodoWrite", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      job = progress!(job, %{status: :running})

      for {id, todos} <- [
            {"p1", [%{"content" => "Write the schema", "status" => "in_progress"}]},
            {"p2",
             [
               %{"content" => "Write the schema", "status" => "completed"},
               %{"content" => "Run the full check", "status" => "pending"}
             ]}
          ] do
        harness!(job, "job.harness.tool_use", %{
          id: id,
          name: "TodoWrite",
          input: %{"todos" => todos}
        })
      end

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      plan = text(view, "#job-plan")
      assert plan =~ "Run the full check"
      assert plan =~ "☑ Write the schema"
    end

    test "a running job's start is its current run's, not its first", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      now = DateTime.utc_now(:second)
      job = progress!(job, %{status: :running, started_at: DateTime.add(now, -3 * 3600, :second)})

      Repo.insert!(%Run{
        job_id: job.id,
        started_at: DateTime.add(now, -3 * 3600, :second),
        finished_at: DateTime.add(now, -2 * 3600, :second)
      })

      Repo.insert!(%Run{job_id: job.id, started_at: DateTime.add(now, -300, :second)})

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert text(view, "#job-facts") =~ ~r/started \d\d:\d\d · 5m/
    end
  end

  describe "Stream · Manifest · Wrote" do
    test "the manifest and what it wrote are a tap away; the stream is first", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      # `refining` declares refinement.md, and this run writes it.
      job = run_pending(ticket, "success", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      assert has_element?(view, "#job-events")
      refute has_element?(view, "#job-manifest")

      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()
      manifest = text(view, "#job-manifest")
      assert manifest =~ "Pinned manifest"
      assert manifest =~ "Inputs, at their exact version"
      assert manifest =~ "20 turns per run"
      assert manifest =~ "refinement.md"
      refute manifest =~ "not written"

      view |> element(~s(#job-panes button[value="wrote"])) |> render_click()

      # What the run produced, linked to its exact version, with its type's tile.
      assert has_element?(
               view,
               ~s(#job-wrote a[href$="/artifacts/refinement.md/1"] [data-file-type="markdown"])
             )
    end

    test "a pane the switch does not draw changes nothing", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, job))

      render_click(view, "pane", %{"value" => "elsewhere"})
      render_click(view, "show", %{"value" => "elsewhere"})

      assert has_element?(view, "#job-events")
    end

    test "a job that did not write what it declared says so", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      # The default scenario writes plan.md, which `refining` does not declare, so the
      # refinement.md it *did* declare is missing — the case the two lists exist to tell apart.
      job = run_pending(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()

      assert text(view, "#job-manifest") =~ "refinement.md not written"
    end

    # A document that did not parse is not kept, so the job page is where why is said.
    test "a refused document says why", %{conn: conn, project: project, ticket: ticket} do
      job = run_pending(ticket, "invalid_document", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()

      assert view |> element("#refused-refinement\\.md") |> render() =~
               Jobs.refusals(job)["refinement.md"]

      assert Jobs.refusals(job)["refinement.md"] =~ "front_matter: is not closed"
      refute text(view, "#job-manifest") =~ "not written"
    end

    # One switch on the page (UX pass, B14): the raw log is a toggle in the stream's head, and the
    # prompt, an input, is the Manifest's first section.
    test "the stream toggles to the raw log; the prompt is the Manifest's", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket, "success", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      # What the harness said, drawn as the transcript draws it.
      assert text(view, "#job-events") =~ "Reading the plan."
      refute has_element?(view, "#job-shows")
      assert has_element?(view, "#job-panes")
      refute has_element?(view, "#state-prompt")
      assert has_element?(view, ~s(#job-raw-toggle[aria-pressed="false"]))

      view |> element("#job-raw-toggle") |> render_click()
      assert text(view, "#job-raw") =~ "job.harness.started fake-model · session sess-42"
      refute has_element?(view, "#job-events")
      assert has_element?(view, ~s(#job-raw-toggle[aria-pressed="true"]))

      view |> element("#job-raw-toggle") |> render_click()
      assert has_element?(view, "#job-events")
      refute has_element?(view, "#job-raw")

      # The prompt is not a show of the stream any longer.
      render_click(view, "show", %{"value" => "prompt"})
      refute has_element?(view, "#state-prompt")
      assert has_element?(view, "#job-events")

      view |> element(~s(#job-panes button[value="manifest"])) |> render_click()

      assert [prompt] =
               view
               |> element("#job-manifest")
               |> render()
               |> Floki.parse_fragment!()
               |> Floki.find("#job-manifest > details#job-prompt")

      assert Floki.attribute(prompt, "open") == []

      assert text(view, "#job-prompt #state-prompt") =~
               "Refine the ticket into a crisp problem statement."
    end
  end

  describe "the stream" do
    test "reads in order, newest at the bottom", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)
      job = progress!(job, %{status: :running})
      bash!(job, "a", "mix compile")
      bash!(job, "b", "mix test")

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      stream = text(view, "#job-events")
      assert :binary.match(stream, "mix compile") < :binary.match(stream, "mix test")
    end

    test "First error leads to the first failure on screen", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      job = progress!(job, %{status: :running})
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      refute has_element?(view, "#job-first-error")

      bash!(job, "a", "mix compile")
      bash!(job, "b", "mix test", true)
      bash!(job, "c", "mix test again", true)

      [first | _] =
        job.id
        |> Forge.Events.for_job()
        |> Enum.filter(&(&1.type == "job.harness.tool_use" and &1.payload["id"] != "a"))

      {:ok, view, _html} = live(conn, page(project, ticket, job))
      # A link in the stream's head, saying how many failed (UX pass, B15).
      assert has_element?(
               view,
               ~s(.job-stream-head #job-first-error[href="#job-events-#{first.seq}"]),
               "✗ 2 failed · first ↑"
             )
    end

    # On a phone the time is said once a minute (UX pass, B5): a row opens its minute only when
    # it is not the row above's, which the CSS draws as a divider.
    test "marks the row that opens each minute", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)
      job = progress!(job, %{status: :running})
      # Each call and its result a second apart: a at 12:00:10, b at 12:00:30, c at 12:01:10.
      at = ~U[2026-09-15 12:00:10Z]

      [a, b, c] =
        for {id, offset} <- [{"a", 0}, {"b", 20}, {"c", 60}] do
          use =
            event_at!(
              job,
              "job.harness.tool_use",
              %{"id" => id, "name" => "Bash", "input" => %{"command" => "mix #{id}"}},
              DateTime.add(at, offset)
            )

          event_at!(
            job,
            "job.harness.tool_result",
            %{"tool_use_id" => id, "bytes" => 2},
            DateTime.add(at, offset + 1)
          )

          use
        end

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert has_element?(view, ~s(#job-events-#{a.seq}[data-minute="12:00"]))
      refute has_element?(view, "#job-events-#{b.seq}[data-minute]")
      assert has_element?(view, ~s(#job-events-#{c.seq}[data-minute="12:01"]))

      view |> element("#job-raw-toggle") |> render_click()
      assert has_element?(view, ~s(#job-raw-#{a.seq}[data-minute="12:00"]))
      refute has_element?(view, "#job-raw-#{b.seq}[data-minute]")
    end

    test "a finished job's stream ends with its outcome", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket, "max_turns", "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert text(view, "#job-stream-end") =~ ~r/^finished · budget_exhausted · \d\d:\d\d:\d\d$/
    end

    # Claude Code turns every `system` message into a `notice`, and `thinking_tokens` alone
    # outnumbered everything else in the stream on the dev node. Recorded, and behind their count.
    test "hides the harness's own telemetry until asked", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      job = run_pending(ticket, "success", "refinement.md")

      harness!(job, "job.harness.notice", %{
        "subtype" => "thinking_tokens",
        "raw" => %{"tokens" => 128}
      })

      {:ok, view, html} = live(conn, page(project, ticket, job))

      refute html =~ "thinking_tokens"
      assert html =~ "Show 1 harness notices"
      assert html =~ "Reading the plan."

      shown = render_click(view, "notices")

      assert shown =~ "thinking_tokens"
      assert shown =~ "Hide 1 harness notices"
    end
  end
end
