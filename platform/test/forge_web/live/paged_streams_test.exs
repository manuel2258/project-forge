defmodule ForgeWeb.PagedStreamsTest do
  @moduledoc """
  A job's stream, a ticket's and a conversation's Activity, and Talk, read a page at a time
  (`docs/design/ui.md` § Activity, § The job page, § Talk; `docs/design/storage.md` § Retention):
  **no read of `events` returns more than a page**, what is drawn is the newest page in order, the
  next page is what reaching the old end loads, a call and its result are one line whichever pages
  they fall on, and a dropped socket reads back only as far as it had been, only in its own job.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.ForgeFixtures, only: [job_fixture: 1, chat_fixture: 1]
  import Forge.GitFixtures
  import Phoenix.LiveViewTest

  alias Forge.{Conversations, EventReads, Events, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "page-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    job = job_fixture(%{ticket: ticket, attempt: 2, status: :running})
    %{project: project, ticket: ticket, job: job}
  end

  defp page(project, ticket, job),
    do: ~p"/tickets/#{project.name}/#{ticket.number}/jobs/#{job.id}"

  defp record(job, type, payload) do
    {:ok, event} =
      Events.append(type, {:job, job.id}, %{
        job_id: job.id,
        ticket_id: job.ticket_id,
        project_id: job.project_id,
        payload: payload
      })

    event
  end

  defp say(job, text), do: record(job, "job.harness.text", %{"text" => text})

  defp call(job, id, name, input) do
    record(job, "job.harness.tool_use", %{"id" => id, "name" => name, "input" => input})
  end

  defp result(job, id, error? \\ false) do
    record(job, "job.harness.tool_result", %{
      "tool_use_id" => id,
      "is_error" => error?,
      "excerpt" => if(error?, do: "1 failure", else: "ok"),
      "bytes" => 2
    })
  end

  # Three hundred events: a hundred calls with their results, and a hundred sentences between —
  # two hundred entries.
  defp three_hundred(job) do
    for n <- 1..100 do
      say(job, "sentence #{n}")
      call(job, "t#{n}", "Bash", %{"command" => "run #{n}"})
      result(job, "t#{n}")
    end
  end

  defp ids(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Enum.map(&(&1 |> Floki.attribute("id") |> hd()))
  end

  describe "the job page's stream" do
    test "opens on the newest page and no read returns more than a page",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      three_hundred(job)
      EventReads.watch()

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      # 50 entries, in reading order, the newest at the bottom; the count is the whole job's.
      entries = ids(view, "#job-events > li")
      assert length(entries) == 50

      assert entries ==
               Enum.sort_by(
                 entries,
                 &(String.replace_prefix(&1, "job-events-", "") |> String.to_integer())
               )

      assert has_element?(view, "#job-panes", "Stream 200")
      assert has_element?(view, "#job-earlier", "150 earlier")
      assert render(view) =~ "sentence 100"
      refute render(view) =~ "sentence 1<"

      # A page's rows and no more: 300 events are in the log.
      assert EventReads.most() <= 100
    end

    test "reaching the old end loads the next page, and the count of what is behind falls",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      three_hundred(job)
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      EventReads.watch()

      view |> element("#job-earlier") |> render_click()

      assert length(ids(view, "#job-events > li")) == 100
      assert has_element?(view, "#job-earlier", "100 earlier")
      assert EventReads.most() <= 120

      view |> element("#job-earlier") |> render_click()
      view |> element("#job-earlier") |> render_click()
      assert length(ids(view, "#job-events > li")) == 200

      # The start of the stream: no control, nothing further to load.
      refute has_element?(view, "#job-earlier")
    end

    test "a call and its result are one line whichever pages they fall on",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      for n <- 1..60, do: say(job, "before #{n}")
      call(job, "split", "Bash", %{"command" => "mix test --split"})
      for n <- 1..30, do: say(job, "between #{n}")
      result(job, "split")
      for n <- 1..20, do: say(job, "after #{n}")

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      # The newest 50 entries start after the call; its result is not a row of its own here, and
      # the call is not drawn yet either.
      refute has_element?(view, ~s([data-activity="action"]))
      refute render(view) =~ "tool_result"

      view |> element("#job-earlier") |> render_click()

      assert has_element?(view, ~s([data-activity="action"]), "mix test --split")

      assert view
             |> render()
             |> Floki.parse_document!()
             |> Floki.find(~s(#job-events [data-activity="action"]))
             |> length() == 1

      refute render(view) =~ "tool_result"
    end

    test "a result with no call is drawn alone", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      result(job, "never-called")
      result(job, nil)

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      assert render(view) =~ "tool_result"
      assert length(ids(view, "#job-events > li")) == 2
    end

    test "what it says of the whole job is not taken from the page it holds",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      # The oldest events: a plan, a memory warning, the secrets held and a failure.
      call(job, "plan", "TodoWrite", %{
        "todos" => [%{"content" => "Write the thing", "status" => "pending"}]
      })

      record(job, "job.harness.memory", %{
        "what" => "oom_kill",
        "oom_kills" => 2,
        "peak" => 100,
        "ceiling" => 200
      })

      record(job, "job.secrets", %{
        "held" => [%{"name" => "STRIPE_TEST_KEY", "version" => 2}],
        "gone" => []
      })

      first = call(job, "bad", "Bash", %{"command" => "false"})
      result(job, "bad", true)
      three_hundred(job)

      {:ok, view, _html} = live(conn, page(project, ticket, job))

      refute has_element?(view, ~s(#job-events [data-activity="action"]), "false")
      assert has_element?(view, "#job-plan", "Write the thing")
      assert has_element?(view, "#job-memory")
      assert render(view) =~ "STRIPE_TEST_KEY v2"
      assert has_element?(view, "#job-first-error", "1 failed")

      # Pressed, it reads back to the first failure and says where to scroll.
      view |> element("#job-first-error") |> render_click()

      assert_push_event(view, "scroll-to", %{id: id})
      assert id == "job-events-#{first.seq}"
      assert has_element?(view, "##{id}")
    end

    test "events arrive at the new end without reading what is shown",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      three_hundred(job)
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      EventReads.watch()

      :ok =
        Forge.Jobs.record_harness_event(job.id, %{
          type: "job.harness.text",
          payload: %{"text" => "arrived just now"}
        })

      assert render(view) =~ "arrived just now"
      assert has_element?(view, "#job-panes", "Stream 201")
      assert EventReads.most() <= 2
    end

    test "the raw log is paged the same way", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      three_hundred(job)
      {:ok, view, _html} = live(conn, page(project, ticket, job))

      view |> element("#job-raw-toggle") |> render_click()

      assert length(ids(view, "#job-raw > li")) == 50
      assert has_element?(view, "#job-raw-earlier", "earlier")

      view |> element("#job-raw-earlier") |> render_click()
      assert length(ids(view, "#job-raw > li")) == 100
    end
  end

  describe "a rejoin" do
    test "reads back as far as the stream had been, in one query bounded by it",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      three_hundred(job)

      # Two hundred events in: a hundred remain to be read, and no more of the log.
      position = Enum.at(Events.for_job(job.id), 200).seq
      EventReads.watch()

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"reach" => %{"activity" => "#{job.id}:#{position}"}})
        |> live(page(project, ticket, job))

      entries = length(ids(view, "#job-events > li"))
      assert entries > 60 and entries < 100
      assert EventReads.most() <= 120
    end

    test "takes no position of another job's, and none that is not a whole number",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      other = job_fixture(%{ticket: ticket, attempt: 3, status: :running})
      for n <- 1..80, do: say(other, "of another job #{n}")
      three_hundred(job)
      foreign = Events.for_job(other.id) |> hd() |> Map.fetch!(:seq)

      for reach <- [
            "#{other.id}:#{foreign}",
            "#{job.id}:abc",
            "#{job.id}:1.5",
            "#{job.id}:-3",
            "#{job.id}:#{String.duplicate("9", 25)}",
            "#{job.id}:0",
            "#{job.id}",
            "not a position"
          ] do
        {:ok, view, _html} =
          conn
          |> put_connect_params(%{"reach" => %{"activity" => reach}})
          |> live(page(project, ticket, job))

        # Only the newest page of this job, and nothing of the other.
        assert length(ids(view, "#job-events > li")) == 50
        refute render(view) =~ "of another job"
      end
    end
  end

  describe "a swept job" do
    test "draws its line once the sweep has recorded it, and not before",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      three_hundred(job)
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      refute has_element?(view, "[data-swept]")

      record(job, "job.swept", %{
        "removed" => 200,
        "days" => 30,
        "ended" => "2026-10-01T00:00:00Z"
      })

      send(view.pid, {:ticket_changed, ticket.id})

      assert has_element?(view, "[data-swept]", "removed 30 days after this job ended")
      assert has_element?(view, "[data-swept]", "No transcript of it was recorded")
    end
  end

  describe "the figures and a rejoin, on the stream itself" do
    alias ForgeWeb.JobStream

    test "a notice read by a reload is not counted again when its own broadcast comes", %{
      job: job
    } do
      say(job, "one")
      record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      stream = JobStream.open(JobStream.new(job.id))
      assert stream.notice_count == 1

      # Committed, then the page reloads on something else, then the notice's own broadcast.
      second = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      stream = JobStream.reload(stream)
      assert stream.notice_count == 2

      assert JobStream.add(stream, second) == :seen

      # One that really is new is counted.
      third = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      assert {:ok, %JobStream{notice_count: 3}} = JobStream.add(stream, third)
    end

    test "the position a count of notices covers is the newest notice, not the newest event", %{
      job: job
    } do
      record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      second = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      say(job, "later words")

      stream = JobStream.open(JobStream.new(job.id))
      assert stream.notices_to == second.seq
      assert stream.counted_to > second.seq
    end

    test "a result heard live goes with its call, held or on a page not read", %{job: job} do
      call(job, "held", "Bash", %{"command" => "one"})
      stream = JobStream.open(JobStream.new(job.id))
      assert stream.count == 1

      # The call is held: the result is held beside it and is no entry of its own.
      answer = result(job, "held")
      assert {:ok, %JobStream{count: 1} = with_result} = JobStream.add(stream, answer)
      assert answer.seq in Enum.map(with_result.events, & &1.seq)

      # The call is on an older page: its result is read with that page, and is not an entry here.
      old = call(job, "old", "Bash", %{"command" => "two"})
      for n <- 1..60, do: say(job, "filler #{n}")
      stream = JobStream.open(JobStream.new(job.id))
      assert stream.more
      refute old.seq in Enum.map(stream.events, & &1.seq)

      late = result(job, "old")
      assert {:ok, %JobStream{} = after_late} = JobStream.add(stream, late)
      refute late.seq in Enum.map(after_late.events, & &1.seq)
      assert after_late.count == stream.count
    end

    test "the raw log holds and counts a result whose call is on a page not read", %{job: job} do
      call(job, "old", "Bash", %{"command" => "one"})
      for n <- 1..60, do: say(job, "filler #{n}")
      raw = JobStream.open(JobStream.new(job.id, :raw))
      assert raw.more
      count = raw.count

      late = result(job, "old")
      assert {:ok, %JobStream{} = after_late} = JobStream.add(raw, late)
      assert late.seq in Enum.map(after_late.events, & &1.seq)
      assert after_late.count == count + 1
    end

    test "a stream not opened does not count again what its count read", %{job: job} do
      say(job, "one")
      two = say(job, "two")
      stream = JobStream.new(job.id)
      assert stream.count == 2

      assert JobStream.add(stream, two) == :seen
      assert {:ok, %JobStream{count: 3}} = JobStream.add(stream, say(job, "three"))
    end

    test "a rejoin redraws under the notices setting the page had", %{job: job} do
      first = say(job, "one")
      notice = record(job, "job.harness.notice", %{"subtype" => "plugin_install"})
      say(job, "two")

      shown = JobStream.rejoin(%{JobStream.new(job.id) | notices: true}, first.seq)
      assert notice.seq in Enum.map(shown.events, & &1.seq)

      hidden = JobStream.rejoin(JobStream.new(job.id), first.seq)
      refute notice.seq in Enum.map(hidden.events, & &1.seq)
    end

    test "a rejoin of the raw log redraws from the position, and a malformed one the newest page",
         %{conn: conn, project: project, ticket: ticket, job: job} do
      events = for n <- 1..120, do: say(job, "raw #{n}")
      raw = JobStream.new(job.id, :raw)

      rejoined = JobStream.rejoin(raw, Enum.at(events, 9).seq)
      assert length(rejoined.events) == 111
      refute rejoined.more == true and rejoined.events == []
      assert length(JobStream.rejoin(raw, :nonsense).events) == JobStream.page()

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"reach" => %{"raw" => "#{job.id}:#{Enum.at(events, 9).seq}"}})
        |> live(page(project, ticket, job))

      view |> element("#job-raw-toggle") |> render_click()
      html = render(view)
      assert html =~ "raw 10"
      refute html =~ "raw 9<"
    end
  end

  describe "a job swept while its page is open" do
    setup %{job: job} do
      at = DateTime.utc_now() |> DateTime.add(-40 * 86_400) |> DateTime.truncate(:second)

      job =
        job
        |> Forge.Jobs.Job.progress_changeset(%{
          status: :finished,
          outcome: :converged,
          finished_at: at
        })
        |> Forge.Repo.update!()

      for n <- 1..5 do
        say(job, "sentence #{n}")
        call(job, "t#{n}", "Bash", %{"command" => "run-the-thing #{n}"})
        result(job, "t#{n}")
      end

      %{job: job}
    end

    test "the job page forgets the tool calls the sweep deleted", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      assert render(view) =~ "run-the-thing 3"
      refute has_element?(view, "[data-swept]")

      assert {n, 1} = Forge.Events.Retention.sweep()
      assert n == 10

      html = render(view)
      refute html =~ "run-the-thing"
      assert html =~ "sentence 3"
      assert has_element?(view, "[data-swept]", "removed 30 days after this job ended")
    end

    test "the page is read again as far back as it had been, not only the newest page", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      for n <- 1..70, do: say(job, "later #{n}")
      {:ok, view, _html} = live(conn, page(project, ticket, job))
      refute render(view) =~ "sentence 1<"

      view |> element("#job-earlier") |> render_click()
      assert render(view) =~ "sentence 1<"

      assert {10, 1} = Forge.Events.Retention.sweep()

      # Seventy-five sentences are what is left, more than the newest page of fifty.
      assert render(view) =~ "sentence 1<"
      refute render(view) =~ "run-the-thing"
    end

    test "the ticket's Activity forgets them too", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")
      assert render(view) =~ "run-the-thing 3"

      assert {10, 1} = Forge.Events.Retention.sweep()

      refute render(view) =~ "run-the-thing"
      assert has_element?(view, "[data-swept]", "removed 30 days after this job ended")
    end
  end

  describe "a conversation swept while its page is open" do
    setup %{project: project} do
      chat = chat_fixture(%{project: project})
      at = DateTime.utc_now() |> DateTime.add(-40 * 86_400) |> DateTime.truncate(:second)

      chat =
        chat
        |> Forge.Jobs.Job.progress_changeset(%{status: :finished, finished_at: at})
        |> Forge.Repo.update!()

      for n <- 1..3 do
        record(chat, "chat.message", %{"text" => "question #{n}"})
        call(chat, "c#{n}", "Bash", %{"command" => "run-the-thing #{n}"})
        result(chat, "c#{n}")
        say(chat, "answer #{n}")
        record(chat, "chat.turn", %{"turn" => n})
      end

      %{chat: chat}
    end

    test "Talk and its Activity forget the tool calls", %{conn: conn, chat: chat} do
      {:ok, talk, _html} = live(conn, ~p"/chats/#{chat.id}")
      {:ok, activity, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")
      assert render(activity) =~ "run-the-thing 2"
      assert render(talk) =~ "1 action"

      assert {6, 1} = Forge.Events.Retention.sweep()

      refute render(talk) =~ "1 action"

      refute render(activity) =~ "run-the-thing"
      assert has_element?(activity, "[data-swept]", "removed 30 days after this job ended")
      assert has_element?(talk, "[data-swept]", "removed 30 days after this job ended")
      assert render(talk) =~ "answer 3"
    end
  end

  describe "a conversation's Talk" do
    setup %{project: project} do
      chat = chat_fixture(%{project: project})
      %{chat: chat}
    end

    defp turn(chat, n, extra \\ 0) do
      record(chat, "chat.message", %{"text" => "question #{n}"})
      say(chat, "answer #{n}")

      for k <- 1..extra//1 do
        call(chat, "c#{n}-#{k}", "Bash", %{"command" => "step #{k}"})
        result(chat, "c#{n}-#{k}")
      end

      record(chat, "chat.turn", %{"turn" => n})
    end

    test "opens on the latest ten turns and loads ten more at the top", %{conn: conn, chat: chat} do
      for n <- 1..60, do: turn(chat, n)
      EventReads.watch()

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      html = render(view)
      assert html =~ "answer 60<" and html =~ "answer 51<"
      refute html =~ "answer 50<"
      assert has_element?(view, "#talk-earlier")
      # Sixty turns are a hundred and eighty events; what was read is the ten turns' and no more.
      assert EventReads.most() <= 100

      view |> element("#talk-earlier") |> render_click()
      html = render(view)
      assert html =~ "answer 41<" and html =~ "answer 51<"
      refute html =~ "answer 40<"
      assert EventReads.most() <= 100

      for _older <- 1..4, do: view |> element("#talk-earlier") |> render_click()
      assert render(view) =~ "answer 1<"
      refute has_element?(view, "#talk-earlier")
    end

    test "a turn of over a hundred events is whole, whichever page it is on",
         %{conn: conn, chat: chat} do
      for n <- 1..12 do
        turn(chat, n, if(n == 2, do: 58, else: 0))
      end

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # Turn two is on the older page: not read, then read whole — its fifty-eight calls one run.
      assert render(view) =~ "answer 3<"
      refute render(view) =~ "58 actions"
      view |> element("#talk-earlier") |> render_click()
      assert render(view) =~ "answer 1<"
      assert render(view) =~ "58 actions"
    end

    test "what it draws about the whole conversation is not from the turns held",
         %{conn: conn, chat: chat} do
      record(chat, "chat.message", %{"text" => "the first thing said"})

      call(chat, "plan", "TodoWrite", %{
        "todos" => [%{"content" => "An old plan item", "status" => "pending"}]
      })

      record(chat, "chat.turn", %{"turn" => 1})
      for n <- 2..30, do: turn(chat, n)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # The title is the conversation's first message, which no turn held reaches; the plan is its
      # latest `TodoWrite` wherever it is.
      assert has_element?(view, ".frame-h1", "the first thing said")
      assert [%{"content" => "An old plan item"}] = :sys.get_state(view.pid).socket.assigns.plan
      assert Conversations.last_said(chat.id).text =~ "answer 30"
    end

    test "events arrive live in the turn in progress", %{conn: conn, chat: chat} do
      for n <- 1..12, do: turn(chat, n)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      :ok =
        Forge.Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{"text" => "mid-turn words"}
        })

      assert render(view) =~ "mid-turn words"
    end

    test "a rejoin reads back as far as it had been, only in its own conversation",
         %{conn: conn, project: project, chat: chat} do
      for n <- 1..25, do: turn(chat, n)
      other = chat_fixture(%{project: project})
      for n <- 1..25, do: turn(other, n)
      position = Events.for_job(chat.id) |> hd() |> Map.fetch!(:seq)
      foreign = Events.for_job(other.id) |> hd() |> Map.fetch!(:seq)

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"reach" => %{"talk" => "#{chat.id}:#{position}"}})
        |> live(~p"/chats/#{chat.id}")

      refute has_element?(view, "#talk-earlier")
      assert render(view) =~ "answer 1<"

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"reach" => %{"talk" => "#{other.id}:#{foreign}"}})
        |> live(~p"/chats/#{chat.id}")

      assert has_element?(view, "#talk-earlier")
      refute render(view) =~ "answer 1<"
    end
  end

  describe "a ticket's Activity" do
    test "reads nothing of the stream until it is on screen, then a page at a time", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      three_hundred(job)
      EventReads.watch()

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

      # Counted for the tab, and not read: 300 events are in the log, a page of the stream is 50
      # entries, and the ticket's own events a handful.
      assert EventReads.most() <= 15
      assert render(view) =~ ">200<"
      refute has_element?(view, "#job-events")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")
      assert length(ids(view, "#job-events > li")) == 50
      assert has_element?(view, "#activity-pane[data-load-root]")

      view |> element("#job-events-more") |> render_click()
      assert length(ids(view, "#job-events > li")) == 100
      assert EventReads.most() <= 120

      # What arrives is at the top, without reading what is shown.
      EventReads.rows()

      :ok =
        Forge.Jobs.record_harness_event(job.id, %{
          type: "job.harness.text",
          payload: %{"text" => "fresh words"}
        })

      assert render(view) =~ "fresh words"
      assert EventReads.most() <= 2
      assert render(view) =~ ">201<"
    end

    test "reads back as far as it had been after a rejoin, and only in its own job", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job
    } do
      three_hundred(job)
      position = Events.for_job(job.id) |> Enum.at(30) |> Map.fetch!(:seq)
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity"

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{"reach" => %{"activity" => "#{job.id}:#{position}"}})
        |> live(path)

      assert length(ids(view, "#job-events > li")) > 150

      {:ok, view, _html} =
        conn
        |> put_connect_params(%{
          "reach" => %{"activity" => "#{Ecto.UUID.generate()}:#{position}"}
        })
        |> live(path)

      assert length(ids(view, "#job-events > li")) == 50
    end

    test "says a swept job's tool calls were removed, and links each transcript", %{
      conn: conn,
      project: project,
      ticket: ticket,
      job: job,
      user: user
    } do
      say(job, "kept")
      record(job, "job.swept", %{"removed" => 5, "days" => 30, "ended" => "2026-10-01T00:00:00Z"})

      key = "job/#{job.id}/transcript-1.jsonl"
      {:ok, _info} = Forge.Storage.put(key, "{}\n")

      for _run <- 1..2 do
        {:ok, _version} =
          Forge.Artifacts.record_version(
            ticket.id,
            "transcript-#{job.state}-#{job.attempt}.jsonl",
            :blob,
            {:user, user.id},
            %{blob_uri: Forge.Storage.uri(key)}
          )
      end

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")

      assert has_element?(view, "[data-swept]", "removed 30 days after this job ended")
      base = "/tickets/#{project.name}/#{ticket.number}/artifacts/transcript-refining-2.jsonl"
      assert has_element?(view, ~s([data-swept] a[href="#{base}/1"]))
      assert has_element?(view, ~s([data-swept] a[href="#{base}/2"]))
      refute has_element?(view, "[data-swept]", "No transcript")
    end
  end

  describe "a swept conversation" do
    test "says so where its tool calls were and links its transcripts", %{
      conn: conn,
      project: project
    } do
      chat = chat_fixture(%{project: project})
      record(chat, "chat.message", %{"text" => "hello"})
      say(chat, "hi there")
      record(chat, "chat.turn", %{"turn" => 1})

      record(chat, "job.swept", %{"removed" => 4, "days" => 30, "ended" => "2026-10-01T00:00:00Z"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "[data-swept]", "removed 30 days after this job ended")
      assert has_element?(view, "[data-swept]", "No transcript of it was recorded")
      # Neither side's words: it is not drawn as a message of either.
      refute render(view) =~ ~s(data-said="swept")

      key = "job/#{chat.id}/transcript-1.jsonl"
      {:ok, _info} = Forge.Storage.put(key, "{}\n")
      {:ok, _chat} = Conversations.ended(chat, nil, "idle", result: %{"transcript" => key})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(
               view,
               ~s([data-swept] a[href="/chats/#{chat.id}/artifacts/transcript-chat.jsonl/1"])
             )

      refute has_element?(view, "[data-swept]", "No transcript")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")
      assert has_element?(view, "[data-swept]", "removed 30 days")
    end
  end
end
