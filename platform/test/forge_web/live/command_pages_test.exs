defmodule ForgeWeb.CommandPagesTest do
  @moduledoc """
  A command's page (`docs/design/ui.md` § The job page, ticket 84, criteria 11 and 23 to 27): its
  steps in order with the longest emphasised and a skipped one saying why, the two sentences for a
  command with none, its output with the time of each line — live while it runs, from the log and
  the times beside it after — and the way into the explorer.

  Made from finished and running commands as the platform holds them, so these tests read the page
  and not the recording (`Forge.Jobs.Steps` and `Forge.Jobs.CommandLog` have their own).
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.BuildFixtures
  import Forge.GitFixtures, only: [tmp_dir: 1]

  alias Forge.{FakeWorker, Jobs, Storage}
  alias Forge.Jobs.Lines
  alias ForgeCore.Job.Result

  setup :register_and_log_in_user

  setup %{user: user} do
    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    worker = FakeWorker.connect()
    {project, ticket} = ticket_on(user)
    %{worker: worker, project: project, ticket: ticket}
  end

  defp page(project, ticket, job), do: "/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"

  @steps [
    %{"name" => "snapshot", "at" => 1_700_000_000_000, "ms" => 1_200, "source" => "copy"},
    %{"name" => "fetch", "at" => 1_700_000_001_200, "ms" => 500},
    %{"name" => "reset", "at" => 1_700_000_001_700, "ms" => 300},
    %{"name" => "own", "at" => 1_700_000_002_000, "ms" => 200},
    %{"name" => "devshell", "at" => 1_700_000_002_200, "skipped" => "unmeasured"},
    %{"name" => "script", "at" => 1_700_000_002_200, "ms" => 60_000},
    %{"name" => "ignored", "at" => 1_700_000_062_200, "ms" => 80},
    %{"name" => "hand_back", "at" => 1_700_000_062_280, "ms" => 100},
    %{"name" => "keep", "at" => 1_700_000_062_380, "skipped" => "status"},
    %{"name" => "upload", "at" => 1_700_000_062_380, "ms" => 300},
    %{"name" => "discard", "at" => 1_700_000_062_680, "ms" => 50},
    %{"name" => "sweep", "at" => 1_700_000_062_730, "ms" => 10},
    %{"name" => "other", "at" => 1_700_000_062_740, "ms" => 40}
  ]

  describe "the steps" do
    test "are in order, the longest emphasised, a skipped one saying why, and they add up", ctx do
      [command] = invoke_builds(ctx.ticket, ctx.worker, [[]])
      job = keep(command, ctx.worker)
      :ok = record_steps(job, @steps)
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, job))

      html = view |> element("#job-steps") |> render()

      names =
        ~w(snapshot fetch reset own devshell script ignored hand_back keep upload discard sweep other)

      positions = Enum.map(names, &(:binary.match(html, ~s(id="job-step-#{&1}")) |> elem(0)))
      assert positions == Enum.sort(positions)

      assert has_element?(view, ~s(#job-step-script[data-longest="true"]), "1 min 0 s")
      refute has_element?(view, ~s(#job-step-snapshot[data-longest]))
      refute has_element?(view, ~s(#job-step-other[data-longest]))

      assert has_element?(view, "#job-step-snapshot", "from this ticket's warm build")
      assert has_element?(view, "#job-step-devshell", "not measured on its own")
      assert has_element?(view, "#job-step-keep", "nothing kept")
      refute has_element?(view, "#job-step-keep", "0 ms")
      assert has_element?(view, "#job-step-other", "40 ms")

      # 1200 + 500 + 300 + 200 + 60000 + 80 + 100 + 300 + 50 + 10 + 40 = 62780 ms.
      assert has_element?(view, "#job-steps-total", "1 min 2 s")
    end

    test "say a machine's release predates them, for a command it ran without reporting any",
         %{conn: conn, user: user} do
      old = FakeWorker.connect(protocol: 17)
      {project, ticket} = ticket_on(user)
      [command] = invoke_builds(ticket, old, [[]])
      job = keep(command, old)

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert has_element?(
               view,
               "#job-steps-unrecorded",
               "not recorded: machine #{String.slice(old.id, 0, 8)}'s release predates step timings"
             )

      refute has_element?(view, "#job-steps li")
    end

    test "say a command ran before forge recorded steps, and never draw a zero", ctx do
      [command] = invoke_builds(ctx.ticket, ctx.worker, [[]])
      job = keep(command, ctx.worker)
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, job))

      assert has_element?(
               view,
               "#job-steps-unrecorded",
               "not recorded: it ran before forge recorded steps"
             )

      refute has_element?(view, "#job-steps-total")
      refute has_element?(view, "#job-steps li")
    end
  end

  describe "the way into the explorer" do
    test "is on the page of a command whose build was kept, and on no other", ctx do
      [kept, unkept] = invoke_builds(ctx.ticket, ctx.worker, [[], ["--no"]])
      kept = keep(kept, ctx.worker)
      {:ok, _} = unkept |> FakeWorker.assign(ctx.worker) |> FakeWorker.finish_command(2)

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, kept))

      assert has_element?(
               view,
               ~s(#job-explore[href$="/builds/#{kept.id}"]),
               "Explore this build"
             )

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, unkept))
      refute has_element?(view, "#job-explore")
    end

    test "is not on the page of a copy a later command's build replaced on the same machine",
         ctx do
      [first, second] = invoke_builds(ctx.ticket, ctx.worker, [[], ["--later"]])
      first = keep(first, ctx.worker)
      second = keep(second, ctx.worker)

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, first))
      refute has_element?(view, "#job-explore")
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, second))
      assert has_element?(view, "#job-explore")
    end
  end

  describe "the output while the command runs" do
    setup ctx do
      [command] = invoke_builds(ctx.ticket, ctx.worker, [[]])
      FakeWorker.assign(command, ctx.worker)
      %{job: Jobs.get!(command.id)}
    end

    test "say its steps are recorded when it ends, not that they never were", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))

      assert has_element?(view, "#job-steps-pending", "Recorded when the command ends.")
      refute has_element?(view, "#job-steps-unrecorded")
    end

    test "shows what has arrived with each line's time, and follows it", ctx do
      :ok =
        Lines.put(ctx.job.id, 0, [[0, "compiling"], [1_000, "linking"], [3_000, "a <b>x</b>"]])

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))

      assert has_element?(view, "#job-log-0 .job-entry-time", "0 s")
      assert has_element?(view, "#job-log-2 .job-entry-time", "3 s")
      assert has_element?(view, "#job-output-head", "live")
      # A line is text, never markup.
      assert view |> element("#job-log-2") |> render() =~ "a &lt;b&gt;x&lt;/b&gt;"

      :ok = Lines.put(ctx.job.id, 3, [[4_000, "done at last"]])
      assert has_element?(view, "#job-log-3", "done at last")
    end

    test "marks a silence of ten seconds or more between two lines, and not one of nine", ctx do
      :ok = Lines.put(ctx.job.id, 0, [[0, "a"], [9_000, "b"], [51_000, "c"]])
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))

      refute has_element?(view, "#job-log-silence-1")
      assert has_element?(view, "#job-log-silence-2", "+42 s")
    end

    test "opens each minute with a divider on the row that begins it, for a phone", ctx do
      :ok = Lines.put(ctx.job.id, 0, [[0, "a"], [59_000, "b"], [61_000, "c"]])
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))

      assert has_element?(view, ~s(#job-log-0[data-minute="+0 min"]))
      refute has_element?(view, "#job-log-1[data-minute]")
      assert has_element?(view, ~s(#job-log-2[data-minute="+1 min"]))
    end

    test "says there is nothing yet when nothing has arrived", ctx do
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))
      assert has_element?(view, "#job-output-empty", "No output yet.")
    end

    test "shows the last thousand lines and loads the earlier ones on request", ctx do
      lines = for n <- 0..1_199, do: [n * 10, "line #{n}"]
      :ok = Lines.put(ctx.job.id, 0, lines)
      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, ctx.job))

      refute has_element?(view, "#job-log-199")
      assert has_element?(view, "#job-log-200")
      assert has_element?(view, "#job-log-1199")
      assert has_element?(view, "#job-log-earlier", "200 earlier")

      view |> element("#job-log-earlier") |> render_click()
      assert has_element?(view, "#job-log-0", "line 0")
      refute has_element?(view, "#job-log-earlier")
    end
  end

  describe "the output after the command ends" do
    test "still shows each line's time and the silences, from the log and the times beside it",
         ctx do
      [command] = invoke_builds(ctx.ticket, ctx.worker, [[]])
      assignment = FakeWorker.assign(command, ctx.worker)

      {:ok, _} = Storage.put(assignment["store"]["log_key"], "one\ntwo\nthree\n")
      {:ok, _} = Storage.put(assignment["store"]["times_key"], "0\n2000\n32000\n")

      {:ok, _job} =
        Jobs.complete(command.id, %Result{
          status: :finished,
          outcome: :converged,
          exit_status: 0,
          duration_ms: 33_000,
          log: assignment["store"]["log_key"],
          times: assignment["store"]["times_key"]
        })

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, command))

      assert has_element?(view, "#job-log-2 .job-entry-time", "32 s")
      assert has_element?(view, "#job-log-silence-2", "+30 s")
      assert has_element?(view, "#job-log-1", "two")
      refute has_element?(view, "#job-output-head", "live")
    end

    test "shows the lines without times when none were kept", ctx do
      [command] = invoke_builds(ctx.ticket, ctx.worker, [[]])
      assignment = FakeWorker.assign(command, ctx.worker)
      {:ok, _} = FakeWorker.finish_command(assignment, 0, log: "one\ntwo\n")

      {:ok, view, _html} = live(ctx.conn, page(ctx.project, ctx.ticket, command))

      assert has_element?(view, "#job-log-1", "two")
      refute has_element?(view, "#job-log-1 .job-entry-time")
      refute has_element?(view, "#job-log-silence-1")
    end
  end
end
