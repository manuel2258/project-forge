defmodule ForgeWeb.ChatWorkScreenTest do
  @moduledoc """
  A conversation as a work screen (`docs/design/ui.md` § The work screen): the frame, the tabs
  in the URL, the transcript as the turn in order, and what each of Changes, Docs and Activity
  holds.

  What no test here can reach is the browser: whether the frame fills the viewport, whether the
  keyboard pushes the composer up, whether a sheet opens. What is pinned is the markup those
  depend on, and each assertion is aimed at the rule rather than at the page happening to
  contain a word.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "work-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, chat} = Conversations.open(project, "fix the parser")
    %{project: project, chat: chat}
  end

  defp harness(chat, type, payload),
    do: :ok = Jobs.record_harness_event(chat.id, %{type: type, payload: payload})

  defp text(chat, text), do: harness(chat, "job.harness.text", %{text: text})

  defp tool(chat, id, name, input, result \\ nil) do
    harness(chat, "job.harness.tool_use", %{id: id, name: name, input: input})

    case result do
      nil ->
        :ok

      {error?, excerpt} ->
        harness(chat, "job.harness.tool_result", %{
          tool_use_id: id,
          is_error: error?,
          bytes: byte_size(excerpt),
          excerpt: excerpt
        })
    end
  end

  defp turn(chat, index) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })
  end

  defp running!(chat) do
    {:ok, running} =
      chat |> Jobs.Job.progress_changeset(%{status: :running}) |> Forge.Repo.update()

    running
  end

  describe "the frame" do
    # The viewport exactly, with the body the only scroller: the page never scrolls as a whole,
    # so the box you type in is never below the fold. The hook is what sizes it where the
    # browser ignores `interactive-widget`.
    test "is the work frame, sized from the visual viewport", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      frame = view |> element("#work-frame") |> render()
      assert frame =~ ~s(phx-hook="ForgeWeb.Layouts.ViewportFrame")
      assert frame =~ "h-dvh"
    end

    test "declares that the keyboard resizes the content", %{conn: conn, chat: chat} do
      html = conn |> get(~p"/chats/#{chat.id}") |> html_response(200)

      assert html =~ "interactive-widget=resizes-content"
    end

    # On a phone the bar is not drawn on a work screen: the back affordance and the composer
    # take its place, as in any messaging app. Every other page keeps it.
    test "draws no bottom bar, where every other page does", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "nav.fixed.bottom-0")

      {:ok, chats, _html} = live(conn, ~p"/chats")
      assert has_element?(chats, "nav.fixed.bottom-0")
    end

    # Below `lg` the rail is the details sheet, reached from the context strip; the sheet is a
    # native dialog and holds everything the rail does, End it included.
    test "puts the facts, and ending, in the details sheet the strip opens", %{
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "dialog#details.modal.modal-bottom")
      assert has_element?(view, ~s(dialog#details button[phx-click="close"]), "End it")
      assert has_element?(view, "dialog#details dd", "chat/#{chat.id}")

      strip = view |> element("#context-strip") |> render()
      assert strip =~ "forge:sheet-open"
      assert strip =~ "#details"
    end
  end

  describe "the tabs" do
    # The tab is in the URL, so back, reload and a pushed link land on it.
    test "follow the URL, and default to Talk", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, ~s(#tab-talk[aria-current="page"]))
      assert has_element?(view, "#messages")
      refute has_element?(view, "#changes")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")
      assert has_element?(view, ~s(#tab-changes[aria-current="page"]))
      assert has_element?(view, "#changes")
      refute has_element?(view, "#messages")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=nonsense")
      assert has_element?(view, ~s(#tab-talk[aria-current="page"]))
    end

    test "patch rather than navigate", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> element("#tab-activity") |> render_click()

      assert_patch(view, ~p"/chats/#{chat.id}?tab=activity")
      assert has_element?(view, "#activity")
    end

    # A count of zero is drawn muted and never hidden, so the tabs never move.
    test "draw a zero muted rather than hiding it", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      docs = view |> element("#tab-docs") |> render()
      assert docs =~ ~r/opacity-40[^>]*>\s*0\s*</
    end
  end

  describe "the transcript" do
    # The turn in the order it happened: what it said, what it did, what it said next — two
    # boxes, not one run-on message.
    test "is each text block in its own box, with the actions between them", %{
      conn: conn,
      chat: chat
    } do
      text(chat, "Let me look at the parser.")
      tool(chat, "t1", "Bash", %{"command" => "mix test"}, {false, "ok"})
      text(chat, "Found it.")
      turn(chat, 1)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      html = view |> element("#said-1") |> render()

      assert [_first, _second] = Regex.scan(~r/data-said="agent"/, html)

      {said, rest} = split_at(html, "Let me look at the parser.")
      assert said != ""
      {between, _after} = split_at(rest, "Found it.")
      assert between =~ ~s(data-run=)
    end

    # A micro label heads each speaker's run, not every box.
    test "labels each speaker's run once", %{conn: conn, chat: chat} do
      {:ok, _} = Conversations.send(chat, "and the lexer")
      text(chat, "One.")
      text(chat, "Two.")
      turn(chat, 1)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # Two user messages in a row, one label; one agent turn with two boxes, one label.
      assert view |> element("#said-0") |> render() =~ ">you<"
      refute view |> element("#said-1") |> render() =~ ">you<"
      agent = view |> element("#said-2") |> render()
      assert agent =~ ">agent<"
      # Two blocks said one after the other are still two things said: two boxes.
      assert [_one, _two] = Regex.scan(~r/data-said="agent"/, agent)
    end

    # A single newline is a break in a chat message, where Markdown joins the lines. The HTML
    # keeps the newline inside the paragraph; `msg` is what draws it (`app.css`).
    test "keeps the line breaks a message was written with", %{conn: conn, project: project} do
      {:ok, chat} = Conversations.open(project, "first line\nsecond line")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      box = view |> element(~s(#said-0 [data-said="you"] .msg)) |> render()
      assert box =~ "first line\nsecond line"
    end

    test "draws the person's boxes on the second surface and the agent's bordered", %{
      conn: conn,
      chat: chat
    } do
      text(chat, "Hello.")
      turn(chat, 1)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert view |> element(~s([data-said="you"])) |> render() =~ "bg-base-200"
      agent = view |> element(~s([data-said="agent"])) |> render()
      assert agent =~ "border"
      refute agent =~ "bg-base-200"
    end
  end

  describe "action lines" do
    test "draw each kind of call as its line", %{conn: conn, chat: chat} do
      running!(chat)

      tool(
        chat,
        "e1",
        "Edit",
        %{"file_path" => "/w/lib/parser.ex", "old_string" => "a", "new_string" => "b\nc"},
        {false, "ok"}
      )

      tool(chat, "b1", "Bash", %{"command" => "mix test"}, {true, "1 test, 1 failure\nboom"})
      tool(chat, "r1", "Read", %{"file_path" => "/w/lib/a.ex"}, {false, "x"})
      tool(chat, "r2", "Read", %{"file_path" => "/w/lib/b.ex"}, {false, "x"})
      tool(chat, "g1", "Grep", %{"pattern" => "lex"}, {false, "x"})
      tool(chat, "w1", "WebFetch", %{"url" => "https://example.com/doc"}, {false, "x"})
      tool(chat, "s1", "WebSearch", %{"query" => "elixir lexer"}, {false, "x"})
      tool(chat, "k1", "Task", %{"description" => "find the lexer"}, {false, "x"})
      tool(chat, "o1", "Frobnicate", %{"level" => 3}, {false, "x"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, ~s([data-action="edit"]), "parser.ex")
      assert has_element?(view, ~s([data-action="edit"]), "+2 −1")
      assert has_element?(view, ~s([data-action="bash"].text-error), "$ mix test")
      assert has_element?(view, ~s([data-action="bash"]), "✗")
      # A failure shows its excerpt's first lines without being asked.
      assert has_element?(view, "[data-failure]", "1 test, 1 failure")
      # Reads and searches in a row are one line for the run.
      assert has_element?(view, ~s([data-action="look"]), "read 2 files · searched 1×")
      assert has_element?(view, ~s([data-action="fetch"]), "↗ https://example.com/doc")
      assert has_element?(view, ~s([data-action="search"]), "? elixir lexer")
      assert has_element?(view, ~s([data-action="task"]), "⤷ find the lexer")
      assert has_element?(view, ~s([data-action="other"]), "Frobnicate")
    end

    # A plan is drawn once per turn, as its latest version, rather than once per update.
    test "draw a turn's plan once, as it stands now", %{conn: conn, chat: chat} do
      running!(chat)
      todos = fn status -> [%{"content" => "Write the parser", "status" => status}] end
      tool(chat, "p1", "TodoWrite", %{"todos" => todos.("pending")}, {false, "ok"})
      tool(chat, "b1", "Bash", %{"command" => "mix test"}, {false, "ok"})
      tool(chat, "p2", "TodoWrite", %{"todos" => todos.("completed")}, {false, "ok"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      html = view |> element("#messages") |> render()

      assert [_one] = Regex.scan(~r/data-action="todo"/, html)
      assert html =~ "☑"
      refute html =~ "☐"
    end

    # Live, every line; once the turn ends, each run between two boxes is one line that
    # expands — and a failure in it stays visible beneath the fold.
    test "fold once the turn has ended, keeping failures visible", %{conn: conn, chat: chat} do
      running!(chat)
      text(chat, "Running the tests.")
      tool(chat, "b1", "Bash", %{"command" => "mix test"}, {true, "1 failure"})
      tool(chat, "b2", "Bash", %{"command" => "mix test"}, {false, "0 failures"})

      tool(
        chat,
        "e1",
        "Write",
        %{"file_path" => "/w/lib/lexer.ex", "content" => "x"},
        {false, ""}
      )

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, ~s([data-run="live"]))
      refute has_element?(view, ~s([data-run="folded"]))

      text(chat, "Fixed.")
      turn(chat, 1)

      folded = view |> element(~s([data-run="folded"])) |> render()
      assert folded =~ "3 actions · edited lexer.ex · mix test ✗→✓"
      assert view |> element("[data-run-errors]") |> render() =~ "1 failure"
      refute has_element?(view, ~s([data-run="live"]))
    end

    # The mechanism under live lines: a call appears as its event arrives.
    test "appear as their events arrive", %{conn: conn, chat: chat} do
      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, ~s([data-action="bash"]))

      tool(chat, "b1", "Bash", %{"command" => "mix compile"})
      assert has_element?(view, ~s([data-action="bash"]), "$ mix compile")
    end
  end

  # The page appends what the harness streams to the log it read at mount. An event can be in
  # both — written before the read, broadcast after it — and appending it again would draw the
  # call twice.
  test "an event the page already has is not drawn twice", %{conn: conn, chat: chat} do
    running!(chat)
    tool(chat, "b1", "Bash", %{"command" => "mix compile"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    [event] =
      chat.id |> Forge.Events.for_job() |> Enum.filter(&(&1.type == "job.harness.tool_use"))

    send(view.pid, {:job_event, chat.id, event})

    html = view |> element("#messages") |> render()
    assert [_once] = Regex.scan(~r/\$ mix compile/, html)
  end

  # The agent wrote every tool input, and a model sometimes sends a field in the wrong type.
  # The call stays in the log for ever, so a page that raised on one would never mount again.
  test "draws calls whose inputs have the wrong types, on Talk and on Activity", %{
    conn: conn,
    chat: chat
  } do
    running!(chat)
    tool(chat, "m1", "MultiEdit", %{"file_path" => "/w/a.ex", "edits" => "[{\"old_string\":1}]"})
    tool(chat, "b1", "Bash", %{"command" => ["mix", "test"]})
    tool(chat, "f1", "WebFetch", %{"url" => 42})
    tool(chat, "s1", "WebSearch", %{"query" => %{"q" => 1}})
    tool(chat, "e1", "Edit", %{"file_path" => 7, "old_string" => [], "new_string" => %{}})
    tool(chat, "r1", "Read", %{"file_path" => %{"x" => 1}})
    tool(chat, "k1", "Task", %{"description" => %{"x" => 1}})

    tool(chat, "p1", "TodoWrite", %{
      "todos" => [%{"content" => %{"x" => 1}, "status" => "pending"}, "x"]
    })

    harness(chat, "job.harness.tool_use", %{id: "z1", name: "Odd", input: "not a map"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, ~s([data-action="bash"]))

    {:ok, activity, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")
    assert has_element?(activity, "#job-events")
  end

  # The Activity tab draws each call on its own row, with the same lines the transcript uses: a
  # read is the read line, not the catch-all, and a failure shows its excerpt there too.
  test "Activity draws a lone read as the read line, with its failure", %{
    conn: conn,
    chat: chat
  } do
    tool(chat, "r1", "Read", %{"file_path" => "/w/lib/gone.ex"}, {true, "File does not exist."})
    tool(chat, "k1", "Task", %{"description" => "find the lexer"}, {false, "done"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")

    assert has_element?(view, ~s(#job-events [data-action="look"]), "read 1 file")
    refute has_element?(view, ~s(#job-events [data-action="other"]))
    assert has_element?(view, "#job-events [data-failure]", "File does not exist.")
    # With its subagent's calls on rows of their own, a Task has nothing to expand to.
    assert has_element?(view, ~s(#job-events div[data-action="task"]), "find the lexer")
  end

  # An event announced out of order — written in one transaction, committed after a later one —
  # is drawn where it belongs rather than dropped for having the lower number.
  test "draws an event heard out of order", %{conn: conn, chat: chat} do
    running!(chat)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    {:ok, first} =
      Forge.Events.append("job.harness.tool_use", {:job, chat.id}, %{
        job_id: chat.id,
        payload: %{"id" => "b1", "name" => "Bash", "input" => %{"command" => "mix first"}}
      })

    {:ok, second} =
      Forge.Events.append("job.harness.tool_use", {:job, chat.id}, %{
        job_id: chat.id,
        payload: %{"id" => "b2", "name" => "Bash", "input" => %{"command" => "mix second"}}
      })

    send(view.pid, {:job_event, chat.id, second})
    send(view.pid, {:job_event, chat.id, first})

    html = view |> element("#messages") |> render()
    assert html =~ "$ mix first"
    assert html =~ "$ mix second"
    assert :binary.match(html, "mix first") < :binary.match(html, "mix second")
  end

  # A turn that only acted — stopped before it said anything — is not a reply to wait on: the
  # queue does not list it and nothing is pushed, and the page says the same.
  test "does not say it waits on you after a turn that said nothing", %{conn: conn, chat: chat} do
    running!(chat)
    tool(chat, "b1", "Bash", %{"command" => "mix test"}, {false, "ok"})
    turn(chat, 1)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute render(view) =~ "It is waiting on you."
    refute Enum.any?(Forge.Queue.items(), &(&1.kind == :chat and &1.detail.chat_id == chat.id))
  end

  # `docs/design/capacity.md` § Memory, which a job holds rather than spends: in the context
  # strip, only when memory was the trouble — from its events, or from what a turn ended with.
  test "the strip says memory was the trouble, and only when it was", %{conn: conn, chat: chat} do
    running!(chat)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(view, "#chat-memory")

    harness(chat, "job.harness.memory", %{
      what: "ceiling",
      peak: 2 * 1024 ** 3,
      ceiling: 2 * 1024 ** 3
    })

    assert has_element?(view, "#chat-memory", "⚠ reached its ceiling · peak 2.0 GiB of 2 GiB")

    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "harness" => %{
          "turns" => 1,
          "cost_usd" => 0.01,
          "memory" => %{"ceiling" => 2 * 1024 ** 3, "peak" => 2 * 1024 ** 3, "oom_kills" => 1}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#chat-memory", "⚠ 1 OOM kill · peak 2.0 GiB of 2 GiB")
  end

  describe "the now line" do
    test "says, in words, the call that has no result yet", %{conn: conn, chat: chat} do
      running!(chat)
      tool(chat, "r1", "Read", %{"file_path" => "/w/lib/router.ex"}, {false, "ok"})
      tool(chat, "b1", "Bash", %{"command" => "mix test --failed"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#now-line", "running mix test --failed")

      harness(chat, "job.harness.retry", %{attempt: 2, max_retries: 10})
      assert has_element?(view, "#now-line", "retrying (2 of 10)")
    end

    # What memory did, until the agent does something else (`docs/design/ui.md` § Talk).
    test "says what memory did when that is the latest thing the turn reported", %{
      conn: conn,
      chat: chat
    } do
      running!(chat)
      tool(chat, "b1", "Bash", %{"command" => "gradle build"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      harness(chat, "job.harness.memory", %{
        what: "oom_kill",
        oom_kills: 1,
        new_kills: 1,
        peak: 2 * 1024 ** 3,
        ceiling: 2 * 1024 ** 3
      })

      assert has_element?(
               view,
               "#now-line",
               "a process was killed for memory (1 OOM kill · peak 2.0 GiB of 2 GiB)"
             )

      tool(chat, "b2", "Bash", %{"command" => "gradle build --max-workers=1"})
      assert has_element?(view, "#now-line", "running gradle build --max-workers=1")
    end

    test "carries the plan above it, collapsed to its current item", %{conn: conn, chat: chat} do
      running!(chat)

      tool(
        chat,
        "p1",
        "TodoWrite",
        %{
          "todos" => [
            %{"content" => "Read the parser", "status" => "completed"},
            %{
              "content" => "Fix the lexer",
              "activeForm" => "Fixing the lexer",
              "status" => "in_progress"
            },
            %{"content" => "Run the tests", "status" => "pending"}
          ]
        },
        {false, "ok"}
      )

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      summary = view |> element("#plan summary") |> render()

      assert summary =~ "1/3"
      assert summary =~ "Fixing the lexer"

      # Redrawn as the plan moves, and opened by the reader: each patch leaves it open.
      assert view |> element("#plan") |> render() =~ ~s(phx-mounted="[[&quot;ignore_attrs&quot;)
    end

    # The plan is where the agent is in the turn it is taking. Once the turn has ended it is in
    # the transcript, where the agent wrote it, and not held above a composer that is yours.
    test "carries no plan once the turn has ended", %{conn: conn, chat: chat} do
      running!(chat)

      tool(
        chat,
        "p1",
        "TodoWrite",
        %{"todos" => [%{"content" => "Fix the lexer", "status" => "in_progress"}]},
        {false, "ok"}
      )

      text(chat, "Done.")
      turn(chat, 1)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#plan")
    end

    test "is not drawn when no turn is open", %{conn: conn, chat: chat} do
      running!(chat)
      text(chat, "Done.")
      turn(chat, 1)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#now-line")
    end
  end

  # The answer is under the thumb: the form docked above the composer, in the footer that does not
  # scroll, not somewhere in the transcript.
  test "docks the question form above the composer", %{conn: conn, chat: chat} do
    text(chat, """
    ```question
    key: backend
    text: Which backend should it use?
    options: [{label: postgres, detail: About postgres}, {label: sqlite, detail: About sqlite}]
    ```
    """)

    turn(chat, 1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#messages-pane #answer-rows")
    assert has_element?(view, "#answer-rows form label", "postgres")

    footer = render(view) |> String.split(~s(id="answer-rows")) |> List.last()
    assert footer =~ ~s(id="say")
  end

  describe "Changes" do
    setup %{project: project, chat: chat} do
      sha =
        commit_over_http(
          project,
          Jobs.chat_branch(chat),
          "lib/parser.ex",
          "defmodule Parser do\nend",
          "Add the parser"
        )

      %{sha: sha}
    end

    test "lists the files, each expanding to its own patch", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")

      row = view |> element(~s(#changes-files li[data-path="lib/parser.ex"])) |> render()
      assert row =~ "<details"
      # The tab is drawn again as the branch moves; a row the reader opened stays open.
      assert row =~ ~s(phx-mounted="[[&quot;ignore_attrs&quot;)
      assert row =~ "+defmodule Parser do"
      assert row =~ ~s(data-hunk="1")

      assert view |> element("#tab-changes") |> render() =~ ~r/>\s*1\s*</
    end

    test "counts the files changed on its tab", %{conn: conn, chat: chat, project: project} do
      commit_over_http(project, Jobs.chat_branch(chat), "lib/lexer.ex", "defmodule Lexer do\nend")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")
      # And sums the change up on the strip, whichever tab is open.
      assert has_element?(view, "#context-strip", "+4 −0 over 2 files")

      assert view
             |> element("#changes-files")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find("li[data-path]")
             |> length() == 2

      assert view |> element("#tab-changes") |> render() =~ ~r/>\s*2\s*</
    end

    test "lists the commits on the branch", %{conn: conn, chat: chat, sha: sha} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")

      commits = view |> element("#commits") |> render()
      assert commits =~ String.slice(sha, 0, 7)
      assert commits =~ "Add the parser"
    end

    # Ask about this puts the reference in the draft and moves to Talk. Nothing is sent: the
    # draft is the person's to finish.
    test "asks about a hunk by putting it in the draft", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")

      view
      |> element(~s(#changes-files [data-hunk="1"] button), "Ask")
      |> render_click()

      assert_patch(view, ~p"/chats/#{chat.id}?tab=talk")
      assert view |> element("#draft") |> render() =~ "lib/parser.ex:1"
      assert length(Conversations.messages(chat.id)) == 1
    end

    # What is typed is the person's, and a reference is added to it rather than put in its
    # place: on its own line, with a space after it to go on typing.
    test "adds the reference to what is already typed", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      view |> form("#say", text: "Why this?  ") |> render_change()

      view |> element("#tab-changes") |> render_click()

      view
      |> element(~s(#changes-files [data-hunk="1"] button), "Ask")
      |> render_click()

      assert draft(view) == "Why this?\nlib/parser.ex:1 "
    end

    # The ticket's Changes tab sends its reference in the address. An address with none — or
    # with something that is not text — leaves the draft as it was. Read from what *Interrupt
    # and send* would send, since a textarea holding one space is drawn as an empty one.
    test "takes a reference from the address, and nothing from an empty one", %{
      conn: conn,
      chat: chat
    } do
      running!(chat)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?ask=lib/parser.ex:1")
      assert sent_by_interrupt(view) == "lib/parser.ex:1 "

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?ask=")
      assert sent_by_interrupt(view) == ""

      {:ok, view, _html} = live(conn, "/chats/#{chat.id}?ask[]=lib/parser.ex:1")
      assert sent_by_interrupt(view) == ""
    end

    test "offers Ask beside each file row and each hunk header", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")

      row = view |> element(~s(#changes-files li[data-path="lib/parser.ex"])) |> render()
      assert [_file, _hunk] = Regex.scan(~r/phx-value-ref="lib\/parser.ex:1"/, row)

      # Beside the summary, never inside it: the summary is a control of its own.
      refute row =~ ~r/<summary[^>]*>(?:(?!<\/summary>).)*phx-click="ask"/s
    end

    # A commit arrives mid-turn with a call's result; the tab catches up with the branch shortly
    # after, without the page reading everything again for every event.
    test "catches up with a commit made mid-turn", %{conn: conn, chat: chat, project: project} do
      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")
      refute has_element?(view, ~s(#changes-files li[data-path="lib/lexer.ex"]))

      commit_over_http(project, Jobs.chat_branch(chat), "lib/lexer.ex", "defmodule Lexer do\nend")
      tool(chat, "b1", "Bash", %{"command" => "git push"}, {false, "ok"})

      assert eventually(fn ->
               has_element?(view, ~s(#changes-files li[data-path="lib/lexer.ex"]))
             end)
    end

    # Merging reports a conflict on the page, and a turn streaming on is not a reason to take
    # the sentence away: what the harness streams is added to the page, not a reload of it.
    test "keeps a merge's conflict sentence while a turn streams", %{
      conn: conn,
      chat: chat,
      project: project
    } do
      commit_over_http(project, Jobs.chat_branch(chat), "README.md", "the branch's version")
      diverge_main(project, "README.md", "the trunk's version")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")
      view |> element(~s(button[phx-click="merge"])) |> render_click()
      assert has_element?(view, "#changes", "It does not merge cleanly")

      text(chat, "Still thinking.")
      assert has_element?(view, "#changes", "It does not merge cleanly")
    end

    test "carries the merge", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")

      assert has_element?(view, ~s(#changes button[phx-click="merge"]))
    end
  end

  describe "Docs" do
    defp wrote(chat, index, documents) do
      {:ok, _chat} =
        Conversations.record_turn(chat, %{
          "turn" => index,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"},
          "documents" => documents
        })
    end

    # Rendered, which until now a conversation's documents never were: the rail could only
    # link their source.
    test "renders the latest of each document and links the earlier", %{conn: conn, chat: chat} do
      wrote(chat, 1, %{"notes.md" => "# First notes\n"})
      wrote(chat, 2, %{"notes.md" => "# Better notes\n\nWith *emphasis*.\n"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")
      docs = view |> element("#docs") |> render()

      assert docs =~ "<h1>Better notes</h1>"
      refute docs =~ "*emphasis*"
      refute docs =~ "First notes"
      assert has_element?(view, ~s(#docs a[href="/chats/#{chat.id}/artifacts/notes.md/1"]), "v1")
      assert view |> element("#tab-docs") |> render() =~ ~r/>\s*1\s*</
    end

    test "links the earlier versions newest first, and not the latest", %{conn: conn, chat: chat} do
      wrote(chat, 1, %{"notes.md" => "# One\n"})
      wrote(chat, 2, %{"notes.md" => "# Two\n"})
      wrote(chat, 3, %{"notes.md" => "# Three\n"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

      links =
        view
        |> element("#docs")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("a")
        |> Enum.map(&String.trim(Floki.text(&1)))

      assert links == ["v3 ›", "v2", "v1"]
    end

    # Approval is a ticket's, and a project conversation's documents belong to no ticket: there
    # is nothing to approve them for, so nothing says they are not.
    test "marks nothing unapproved in a project conversation", %{conn: conn, chat: chat} do
      wrote(chat, 1, %{"plan.md" => "# Plan\n"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

      assert has_element?(view, "#docs", "Plan")
      refute render(view) =~ "unapproved"
    end
  end

  describe "Activity" do
    # The count on the tab is what the tab draws: a call and its result are one row, and the
    # notices are behind their own count.
    test "counts on its tab the rows it draws", %{conn: conn, chat: chat} do
      tool(chat, "b1", "Bash", %{"command" => "mix format"}, {false, "ok"})
      tool(chat, "b2", "Bash", %{"command" => "mix test"}, {true, "1 failure"})
      harness(chat, "job.harness.notice", %{subtype: "thinking_tokens"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")

      rows =
        view |> element("#job-events") |> render() |> Floki.parse_fragment!() |> Floki.find("li")

      assert length(rows) > 2
      assert view |> element("#tab-activity") |> render() =~ ~r/>\s*#{length(rows)}\s*</
    end

    test "draws events newest first, calls as action lines", %{conn: conn, chat: chat} do
      tool(chat, "b1", "Bash", %{"command" => "mix format"}, {false, "ok"})
      harness(chat, "job.harness.started", %{model: "opus", session_id: "s-1"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")
      html = view |> element("#job-events") |> render()

      assert html =~ ~s(data-activity="action")
      assert html =~ "$ mix format"
      # The result is on the call's line, not a row of its own.
      refute html =~ "tool_result"
      {newest, _rest} = split_at(html, "started")
      refute newest =~ "mix format"
    end

    test "keeps notices behind their count", %{conn: conn, chat: chat} do
      harness(chat, "job.harness.notice", %{subtype: "thinking_tokens"})

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")
      refute view |> element("#job-events") |> render() =~ "notice"

      view |> element("#job-notices", "Show 1 harness notices") |> render_click()
      assert view |> element("#job-events") |> render() =~ "notice"
    end

    test "loads a page at a time", %{conn: conn, chat: chat} do
      for n <- 1..(ForgeWeb.JobStream.page() + 5), do: text(chat, "#{n}")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")

      rows = fn ->
        view |> element("#job-events") |> render() |> Floki.parse_fragment!() |> Floki.find("li")
      end

      assert length(rows.()) == ForgeWeb.JobStream.page()

      view |> element(~s(button[phx-click="more"])) |> render_click()

      assert length(rows.()) > ForgeWeb.JobStream.page()
    end

    test "is live", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=activity")

      tool(chat, "b1", "Bash", %{"command" => "mix deps.get"})

      assert view |> element("#job-events") |> render() =~ "$ mix deps.get"
    end
  end

  defp draft(view) do
    [_whole, content] = Regex.run(~r|<textarea[^>]*>(.*?)</textarea>|s, render(view))
    String.replace_prefix(content, "\n", "")
  end

  defp sent_by_interrupt(view) do
    view
    |> element(~s(button[phx-click="force"]))
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute("phx-value-text")
    |> List.first()
  end

  defp eventually(check, tries \\ 40) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && eventually(check, tries - 1)
    end
  end

  # The default branch moved on under the conversation — pushed the way the platform's own merge
  # pushes, since nothing else may write it.
  defp diverge_main(project, path, content) do
    dir = Path.join(tmp_dir("trunk"), "trunk")
    bare = Projects.repo_path(project)
    {:ok, _out} = Forge.Git.run(Path.dirname(dir), ["clone", "--quiet", bare, dir])
    File.write!(Path.join(dir, path), content <> "\n")

    {:ok, _out} =
      Forge.Git.run(dir, ["-c", "user.name=t", "-c", "user.email=t@f", "commit", "-qam", content])

    {:ok, _out} =
      Forge.Git.run(dir, ["push", "--quiet", bare, "HEAD:refs/heads/main"],
        env: [{"FORGE_INTERNAL", "1"}]
      )
  end

  defp split_at(html, marker) do
    case String.split(html, marker, parts: 2) do
      [before, rest] -> {before, rest}
      [_none] -> flunk("#{inspect(marker)} is not in the page")
    end
  end
end
