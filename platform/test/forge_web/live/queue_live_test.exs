defmodule ForgeWeb.QueueLiveTest do
  @moduledoc """
  The home screen, on the things its own doc says it is: one item per screen, oldest first, one
  interruption per stopped job rather than one per question, and a pass that ends somewhere
  definite.

  Most of these are properties of arrangement, and arrangement is what a page-wide `assert html =~`
  cannot see — every item is in the list column in any order, and every question is in the card
  whether or not its tab shows. So the assertions here are on position, on which item is on screen
  (`#queue-item`'s `data-key`), and on what is left open afterwards.

  `docs/design/ui.md` § The affordance rule and `ForgeWeb.QueueLive`'s moduledoc are the standard.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.GitFixtures
  import Forge.MergeFixtures
  import ForgeWeb.Operator.Components, only: [commit_message_id: 1]
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Jobs, Projects, Repo, Tickets}
  alias Forge.Artifacts.Question

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "queue-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    %{project: project}
  end

  defp admit(project, title) do
    {:ok, ticket} = Tickets.admit(project, %{title: title}, :system)
    ticket
  end

  # A document as an agent writes one, with the question blocks it left behind. Recorded rather
  # than run, because what these tests are about is the queue's arrangement of questions and not
  # the harness that produced them.
  defp ask(ticket, blocks) do
    [job | _] = Jobs.for_ticket(ticket.id)

    content = """
    ---
    outcome: done
    ---
    # Plan

    #{Enum.join(blocks, "\n")}
    """

    {:ok, version} =
      Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
        content: content
      })

    version
  end

  defp blocking(key, text) do
    """
    ```question
    key: #{key}
    text: #{text}
    options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
    blocking: true
    ```
    """
  end

  defp non_blocking(key, text) do
    """
    ```question
    key: #{key}
    text: #{text}
    options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
    blocking: false
    assumption: went with a
    ```
    """
  end

  defp aged(version, seconds) do
    Repo.update_all(
      from(q in Question, where: q.artifact_version_id == ^version.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -seconds, :second)]
    )
  end

  # "Oldest first" is what makes the queue drainable: the operator works down it and the thing that
  # has been waiting longest is never at the bottom where a long list hides it. Reversing the order
  # leaves every item in the list, so only position — and which one the pass opens on — can tell
  # the two apart.
  test "items are oldest first", %{conn: conn, project: project} do
    older = admit(project, "Waiting since yesterday")
    newer = admit(project, "Only just arrived")

    older_version = ask(older, [blocking("backend", "Which backend?")])
    newer_version = ask(newer, [blocking("format", "Which format?")])

    aged(older_version, 3600)
    aged(newer_version, 60)

    {:ok, view, html} = live(conn, ~p"/")

    assert index(html, "item-questions-#{older_version.id}") <
             index(html, "item-questions-#{newer_version.id}")

    assert on_screen(view) == "questions-#{older_version.id}"
    # What the queue shows waits on you: the card's current step is the amber one (`ui.md`
    # § Colour), as it is nowhere a ticket waits on nobody.
    assert has_element?(view, "#queue-item .ui-context .ui-track.ui-track--waiting")
    # The whole queue is the top bar's right end on a phone, where the queue has no parent to
    # name — not a row of its own above the item (UX pass, A1).
    assert has_element?(view, "#top-bar button.ui-top-context", "All 2")
    # Nothing spent yet is left out, not drawn as `0 windows` (UX pass, A11).
    assert has_element?(view, "#queue-item .ui-context-facts", "1 job")
    refute view |> element("#queue-item .ui-context-facts") |> render() =~ "windows"
    # The card is the way to the ticket, and the only one in the item.
    ticket_page = ~p"/tickets/#{project.name}/#{older.number}"
    assert has_element?(view, ~s(#queue-item a.ui-context[href="#{ticket_page}"]))

    assert view
           |> element("#queue-item")
           |> render()
           |> String.split(~s(href="#{ticket_page}"))
           |> length() == 2
  end

  # What the agent said as it stopped, recorded as the harness records it.
  defp said(ticket, text) do
    [job | _] = Jobs.for_ticket(ticket.id)

    Repo.insert!(%Forge.Events.Event{
      ticket_id: ticket.id,
      project_id: ticket.project_id,
      job_id: job.id,
      actor: %{"kind" => "job", "id" => job.id},
      type: "job.harness.text",
      payload: %{"text" => text}
    })
  end

  describe "what the agent said" do
    # The passage the questions are about comes before the ticket's card: on a phone the card
    # under the sentence pushed it beneath the question card's split pane (UX pass, A1).
    test "is drawn before the ticket's card", %{conn: conn, project: project} do
      ticket = admit(project, "Shape the screen")
      ask(ticket, [blocking("rank", "Which rank?")])
      said(ticket, "Two things are open.")

      {:ok, view, _html} = live(conn, ~p"/")
      item = view |> element("#queue-item") |> render()

      [{agent, _}] = :binary.matches(item, ~s(id="queue-agent"))
      [{band, _}] = :binary.matches(item, ~s(class="queue-band"))
      assert agent < band
    end

    # Clamped to four lines on a phone with *more* at its end — and only when it is long enough
    # to be cut: a short passage offering *more* would offer what is already on screen.
    test "a long passage is clamped with more, a short one is not", %{
      conn: conn,
      project: project
    } do
      short = admit(project, "Short")
      ask(short, [blocking("a", "Short?")])
      said(short, "Two things are open.")

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#queue-said.queue-said--clamped")
      refute has_element?(view, "#queue-said-more")

      long = admit(project, "Long")
      version = ask(long, [blocking("b", "Long?")])
      said(long, String.duplicate("word ", 40))

      {:ok, view, _html} = live(conn, ~p"/?item=questions-#{version.id}")

      assert has_element?(view, "#queue-said.queue-said--clamped")
      assert has_element?(view, "#queue-said-more", "more")

      many = admit(project, "Many lines")
      version = ask(many, [blocking("c", "Many?")])
      said(many, "one\ntwo\nthree\nfour\nfive")

      {:ok, view, _html} = live(conn, ~p"/?item=questions-#{version.id}")
      assert has_element?(view, "#queue-said.queue-said--clamped")
    end
  end

  # A document's questions are one form (`docs/design/ui.md` § Answering questions): its
  # recommendations start chosen, so one Send answers the whole document — the assumption asked
  # beside the blocking pair included. It is in the form, drawn with its choice on its line, so
  # what Send records for it is what the operator was shown.
  test "one Send answers the document, recommendations and all", %{conn: conn, project: project} do
    ticket = admit(project, "Persist scores")

    version =
      ask(ticket, [
        blocking("backend", "Which backend?"),
        blocking("format", "Which format?"),
        non_blocking("naming", "What should the table be called?")
      ])

    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#form-#{version.id} button[type=submit]") |> render() =~
             "Send 3 answers"

    view |> element("#form-#{version.id}") |> render_submit()

    assert render(view) =~ "Sent 3 answers"
    assert Artifacts.open_questions(ticket.id) == []
  end

  # An assumption asked in the same document as a blocking question is in that document's form,
  # optional — but it is still not a decision: not counted on the item, the header or the badge,
  # and not a line in the digest as well, which would be a second place to answer it.
  test "a non-blocking question is not an interruption", %{conn: conn, project: project} do
    ticket = admit(project, "Persist scores")

    version =
      ask(ticket, [
        blocking("backend", "Which backend?"),
        non_blocking("naming", "What should the table be called?")
      ])

    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#queue-item .queue-eyebrow") |> render() =~
             "1 blocking question · 1 optional · plan.md v1"

    # The row names the document once, on its latest line; its kicker is the kind (UX pass, A24).
    row = view |> element("#item-questions-#{version.id}") |> render()
    assert row =~ ~r/ui-row-kicker-text">\s*1 blocking question\s*</
    assert row |> String.split("plan.md v1") |> length() == 2

    # Asked moments ago, in the sentence's words: never "waiting now" (r3 L3).
    assert has_element?(view, "#queue-item .queue-age", "waiting <1m")

    assert view |> element("#form-#{version.id}") |> render() =~
             "What should the table be called?"

    refute has_element?(view, "#queue-digest")
    assert subline(view) == "1 of 1 · 1 decision"
  end

  describe "the question form" do
    defp open_blocking(key, text) do
      """
      ```question
      key: #{key}
      text: #{text}
      options: [{label: a, detail: About a}, {label: b, detail: About b}]
      blocking: true
      ```
      """
    end

    # Which question the card shows: the others are in the form all the same, `hidden`, so whether
    # their radios are drawn says nothing about it.
    defp shown?(view, question), do: has_element?(view, question <> "[data-shown]")

    defp choose(view, version, key, choice, text \\ "") do
      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", key, "choice"],
        "answers" => %{key => %{"choice" => choice, "text" => text}}
      })
    end

    test "choosing locks an answer in and sends nothing", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [open_blocking("backend", "Which backend?")])

      {:ok, view, _html} = live(conn, ~p"/")
      choose(view, version, "backend", "b")

      assert [%{key: "backend"}] = Artifacts.open_questions(ticket.id)
      assert Artifacts.latest(ticket.id, "answers.md") == nil

      assert view |> element("#form-#{version.id} button[type=submit]") |> render() =~
               "Send 1 answer"
    end

    test "Send waits for every blocking question", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [
          open_blocking("backend", "Which backend?"),
          open_blocking("format", "Which?"),
          non_blocking("naming", "What should the table be called?")
        ])

      {:ok, view, _html} = live(conn, ~p"/")
      send = "#form-#{version.id} button[type=submit]"

      assert has_element?(view, send <> "[disabled]")

      assert view |> element("#form-#{version.id}-left") |> render() =~
               "2 blocking questions left"

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "backend", "choice"],
        "answers" => %{
          "backend" => %{"choice" => "a", "text" => ""},
          "format" => %{"choice" => "", "text" => ""}
        }
      })

      assert has_element?(view, send <> "[disabled]")
      assert view |> element("#form-#{version.id}-left") |> render() =~ "1 blocking question left"

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "format", "text"],
        "answers" => %{
          "backend" => %{"choice" => "a", "text" => ""},
          "format" => %{"choice" => "", "text" => "neither, use JSON"}
        }
      })

      refute has_element?(view, send <> "[disabled]")
      refute has_element?(view, "#form-#{version.id}-left")
    end

    # One question shows at a time, under its tab, in the order written; the card opens on the
    # first with nothing locked in, a tab shows its own question, and every other one is hidden
    # rather than gone.
    test "a tab shows its question and hides the others", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [blocking("backend", "Which backend?"), open_blocking("format", "Which?")])

      backend = "#question-#{version.id}-backend"
      format = "#question-#{version.id}-format"

      {:ok, view, _html} = live(conn, ~p"/")

      # The backend's recommendation is chosen, so the card opens where something is left.
      assert shown?(view, format)
      refute shown?(view, backend)
      assert has_element?(view, backend <> "[hidden]")
      assert has_element?(view, "#tab-#{version.id}-format[aria-selected=true]")
      assert view |> element("#tab-#{version.id}-backend") |> render() =~ "●"
      assert view |> element("#tab-#{version.id}-format") |> render() =~ "○"

      view |> element("#tab-#{version.id}-backend") |> render_click()

      assert shown?(view, backend)
      refute shown?(view, format)
      assert view |> element(backend) |> render() =~ "1 of 2"
    end

    # Locking an answer in does not move the card to another question under the thumb: the one
    # touched is the one that stays shown, though another is now the first with nothing locked.
    test "the question touched stays shown", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [
          open_blocking("backend", "Which backend?"),
          open_blocking("format", "Which?")
        ])

      {:ok, view, _html} = live(conn, ~p"/")
      assert shown?(view, "#question-#{version.id}-backend")

      choose(view, version, "backend", "b")

      assert shown?(view, "#question-#{version.id}-backend")
      refute shown?(view, "#question-#{version.id}-format")
    end

    test "a note rides the choice, and a cleared choice leaves your own words", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [blocking("backend", "Which backend?"), blocking("format", "Which format?")])

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#form-#{version.id}")
      |> render_submit(%{
        "answers" => %{
          "backend" => %{"choice" => "b", "text" => "and keep the old file"},
          "format" => %{"choice" => "", "text" => "JSON"}
        }
      })

      answers = Map.new(Artifacts.answered(ticket.id), &{&1.question.key, &1.answer})
      assert %{choice: "b", text: "and keep the old file"} = answers["backend"]
      assert %{choice: nil, text: "JSON"} = answers["format"]
    end

    # An assumption is optional: left with nothing chosen, it is not sent — rather than sent empty
    # and refusing the batch with it — and it stays open, for the digest or the ticket.
    test "an optional question left alone is not sent", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [
          blocking("backend", "Which backend?"),
          """
          ```question
          key: naming
          text: What should the table be called?
          options: [{label: a, detail: About a}, {label: b, detail: About b}]
          blocking: false
          assumption: went with a
          ```
          """
        ])

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#form-#{version.id}") |> render_submit()

      assert render(view) =~ "Sent 1 answer"
      assert [%{key: "naming"}] = Artifacts.open_questions(ticket.id)
    end

    # What is left on a sent form is drawn as the agent asked it: the draft that cleared the
    # recommendation went with the Send. On the ticket, where the assumption left over is drawn
    # again under the same version; the queue moves it to the digest, which draws no form.
    test "a sent form starts again from its recommendations", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [
          blocking("backend", "Which backend?"),
          non_blocking("naming", "What should the table be called?")
        ])

      naming = "#question-#{version.id}-naming"

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "naming", "choice"],
        "answers" => %{
          "backend" => %{"choice" => "a", "text" => ""},
          "naming" => %{"choice" => "", "text" => ""}
        }
      })

      refute has_element?(view, naming <> " input[value=a][checked]")

      view |> element("#form-#{version.id}") |> render_submit()

      assert [%{key: "naming"}] = Artifacts.open_questions(ticket.id)
      assert has_element?(view, naming <> " input[value=a][checked]")
    end

    # The job reads every answer, not whichever landed before the resume: one `answers.md`
    # version holds them all, and the job is resumed after it.
    test "the waiting job resumes once, with every answer", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      [job | _] = Jobs.for_ticket(ticket.id)
      {:ok, _job} = job |> Ecto.Changeset.change(status: :waiting) |> Repo.update()

      version =
        ask(ticket, [blocking("backend", "Which backend?"), blocking("format", "Which format?")])

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#form-#{version.id}") |> render_submit()

      assert %{version: 1, content: content} = Artifacts.latest(ticket.id, "answers.md")
      assert content =~ "## backend"
      assert content =~ "## format"
      assert Jobs.get!(job.id).status == :pending
    end

    # Stale because someone answered one of its questions: the same form is drawn again for what
    # is still asked, and what the person locked in for that is kept, not reset.
    test "a form made stale by another answer keeps its draft", %{conn: conn, project: project} do
      user = Forge.ForgeFixtures.member_fixture(project, :member)
      ticket = admit(project, "Persist scores")

      version =
        ask(ticket, [
          open_blocking("backend", "Which backend?"),
          open_blocking("format", "Which format?")
        ])

      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "format", "text"],
        "answers" => %{
          "backend" => %{"choice" => "a", "text" => ""},
          "format" => %{"choice" => "", "text" => "JSON, please"}
        }
      })

      # From the command line, say: nothing this page hears before the Send.
      {:ok, _ticket} = Forge.Operator.answer(ticket, user, "backend", %{choice: "b"})

      render_submit(view, "questions:send", %{
        "form" => version.id,
        "ticket" => ticket.id,
        "version" => version.id,
        "answers" => %{
          "backend" => %{"choice" => "a", "text" => ""},
          "format" => %{"choice" => "", "text" => "JSON, please"}
        }
      })

      assert render(view) =~ "were answered or changed since the page showed them"
      assert [%{question: %{key: "backend"}}] = Artifacts.answered(ticket.id)
      assert view |> element("#question-#{version.id}-format") |> render() =~ "JSON, please"
    end

    # Off the wire, a payload of the wrong shape is ignored, not raised on: a crash here is the
    # page going away under the person holding it.
    test "a malformed event is ignored", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [blocking("backend", "Which backend?")])

      {:ok, view, _html} = live(conn, ~p"/")

      render_change(view, "form:change", %{"form" => version.id, "answers" => "abc"})
      render_change(view, "form:change", %{"form" => version.id, "answers" => ["x"]})
      render_change(view, "form:change", %{"answers" => %{}})
      render_click(view, "form:open", %{"form" => version.id})

      render_submit(view, "questions:send", %{
        "form" => version.id,
        "ticket" => ticket.id,
        "version" => version.id,
        "answers" => "abc"
      })

      render_submit(view, "chat:questions:send", %{"form" => "x", "chat" => "not-a-uuid"})
      assert render(view) =~ "That no longer exists."
      assert Artifacts.answered(ticket.id) == []
    end

    test "a stale form sends nothing", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      stale = ask(ticket, [blocking("backend", "Which backend?")])

      {:ok, view, _html} = live(conn, ~p"/")

      # The agent wrote the document again while the form was open, asking something else.
      ask(ticket, [blocking("format", "Which format?")])

      render_submit(view, "questions:send", %{
        "form" => stale.id,
        "ticket" => ticket.id,
        "version" => stale.id,
        "answers" => %{"backend" => %{"choice" => "a", "text" => ""}}
      })

      assert render(view) =~ "were answered or changed since the page showed them"
      assert Artifacts.answered(ticket.id) == []
    end
  end

  # What the form draws, and what its Send carries from what is drawn — the rendered inputs, not
  # parameters a test hands in. `docs/design/ui.md` § Answering questions is the standard.
  describe "what the form draws and carries" do
    defp rich(key, opts) do
      recommended = if opts[:recommended], do: ", recommended: true", else: ""

      tail =
        if opts[:blocking] == false,
          do: "blocking: false\nassumption: went with Postgres",
          else: "blocking: true"

      """
      ```question
      key: #{key}
      text: "Which #{key}?"
      options:
        - {label: Postgres, detail: "Where the data is."}
        - {label: SQLite, detail: "A file beside it."#{recommended}}
      #{tail}
      ```
      """
    end

    test "an option is its headline and its sentence, the recommendation tagged", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")

      question = "#question-#{version.id}-store"
      assert has_element?(view, question <> " label", "Where the data is.")
      assert has_element?(view, question <> " label", "A file beside it.")
      assert view |> element(question <> " label", "SQLite") |> render() =~ "recommended"
      refute view |> element(question <> " label", "Postgres") |> render() =~ "recommended"
    end

    test "Clear choice is offered with a choice, and only then", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true), rich("size", [])])
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#question-#{version.id}-store label", "Clear choice")
      refute has_element?(view, "#question-#{version.id}-size label", "Clear choice")
    end

    test "an optional question says so, and a blocking one does not", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", []), rich("naming", blocking: false)])
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#question-#{version.id}-naming") |> render() =~ "optional"
      refute view |> element("#question-#{version.id}-store") |> render() =~ "optional"
    end

    # The queue serves blocking questions first; the form draws them as the agent wrote them.
    test "questions are drawn in the order they were written", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("naming", blocking: false), rich("store", [])])
      {:ok, _view, html} = live(conn, ~p"/")

      assert index(html, "question-#{version.id}-naming") <
               index(html, "question-#{version.id}-store")
    end

    # `docs/design/ui.md` § The question card: the card sits in the split pane under the item, its
    # handle above it, with Later beside Send. The limit and the fold are the browser's (the
    # `.SplitPane` hook); what is pinned here is that the card is drawn inside it.
    test "the card sits in the split pane, Later beside Send", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")

      pane = ~s(#queue-pane[phx-hook="ForgeWeb.Operator.QuestionForm.SplitPane"])
      assert has_element?(view, pane <> " .qpane-handle")
      assert has_element?(view, pane <> " #form-#{version.id}")
      assert has_element?(view, "#form-#{version.id} .qcard-dock #queue-later")
      refute has_element?(view, "#queue-dock")
    end

    # `docs/design/ui.md` § The affordance rule: Enter never sends a question form. A one-line
    # input submitted it on Enter, before the questions after it were read. A key press is a
    # browser event ExUnit cannot drive, so what is pinned is the box: a textarea, which Enter
    # cannot submit, on the composer's hook with the query every pointer matches, and no hint.
    test "Enter in a question's own words is a new line", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", [])])
      {:ok, view, _html} = live(conn, ~p"/")

      box =
        view |> element("#form-#{version.id} textarea[name='answers[store][text]']") |> render()

      assert box =~ ~s(data-newline-on="all")
      assert box =~ ~s(aria-label="Your own words on: Which store?")
      refute has_element?(view, "#form-#{version.id} input[type=text]")
      refute has_element?(view, "#form-#{version.id} [data-hint]")

      # And Enter from the form's other inputs — a radio — is swallowed by the form's hook.
      assert has_element?(
               view,
               ~s(#form-#{version.id}[phx-hook="ForgeWeb.Operator.QuestionForm.EnterNeverSends"])
             )
    end

    # A question whose tab is not shown carries its answer in its own inputs, hidden: a note typed
    # on it is still there when the Send is taken from another tab.
    test "a note on a question not shown rides the Send", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", []), rich("size", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "store", "text"],
        "answers" => %{"store" => %{"text" => "and keep a copy"}}
      })

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "store", "choice"],
        "answers" => %{"store" => %{"choice" => "SQLite", "text" => "and keep a copy"}}
      })

      view |> element("#tab-#{version.id}-size") |> render_click()
      refute shown?(view, "#question-#{version.id}-store")
      view |> element("#form-#{version.id}") |> render_submit()

      answers = Map.new(Artifacts.answered(ticket.id), &{&1.question.key, &1.answer})
      assert %{choice: "SQLite", text: "and keep a copy"} = answers["store"]
    end

    test "a question opened by hand sends the choice it shows", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")

      view |> element("#form-#{version.id}") |> render_submit()

      assert [%{answer: %{choice: "SQLite", text: nil}}] = Artifacts.answered(ticket.id)
    end

    # Whitespace is no answer: an optional question left with some is skipped, not sent blank and
    # refused with the rest of the batch.
    test "whitespace on an optional question is not sent", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true), rich("naming", blocking: false)])
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#form-#{version.id}")
      |> render_submit(%{"answers" => %{"naming" => %{"text" => "   "}}})

      assert render(view) =~ "Sent 1 answer"
      assert [%{key: "naming"}] = Artifacts.open_questions(ticket.id)
    end

    # The refusals a page can be sent, said as the person reads them.
    test "a refused Send says why", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", []), rich("size", [])])
      {:ok, view, _html} = live(conn, ~p"/")

      send = fn answers ->
        render_submit(view, "questions:send", %{
          "form" => version.id,
          "ticket" => ticket.id,
          "version" => version.id,
          "answers" => answers
        })
      end

      assert send.(%{"store" => %{"choice" => "SQLite"}}) =~ "Not sent: answer size first"

      # Refused, the item stays on screen and is not counted decided.
      assert on_screen(view) == "questions-#{version.id}"
      refute has_element?(view, "#item-questions-#{version.id}[data-decided]")

      assert send.(%{"store" => %{"choice" => "MySQL"}, "size" => %{"choice" => "SQLite"}}) =~
               "Not sent: &quot;MySQL&quot; is not an option of store"

      assert Artifacts.answered(ticket.id) == []
    end
  end

  # A conversation asking several questions leads with how many, and the first of them: the
  # sentence is what the item is about, and "Which backend?" alone would hide the rest.
  test "a conversation asking several questions says how many", %{conn: conn, project: project} do
    {:ok, chat} = Forge.Conversations.open(project, "which?")

    :ok =
      Jobs.record_harness_event(chat.id, %{
        type: "job.harness.text",
        payload: %{
          text:
            "```question\nkey: store\ntext: Which backend?\n```\n\n" <>
              "```question\nkey: rows\ntext: How many rows?\n```\n"
        }
      })

    {:ok, _chat} =
      Forge.Conversations.record_turn(chat, %{
        "turn" => 1,
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "subtype" => "success"}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert view |> element("#item-chat-#{chat.id}") |> render() =~ "2 questions: Which backend?"
  end

  describe "not waiting on you" do
    # Beneath the last decision and above the end, whatever its age: an assumption sorted in
    # among the decisions by age would compete with a held job for the same glance.
    test "the digest follows the decisions, however old it is", %{conn: conn, project: project} do
      assuming = admit(project, "Carried on")
      asking = admit(project, "Stopped")
      assumption = ask(assuming, [non_blocking("naming", "What should the table be called?")])
      decision = ask(asking, [blocking("backend", "Which backend?")])
      aged(assumption, 7200)
      aged(decision, 60)

      {:ok, _view, html} = live(conn, ~p"/")

      [question] = Repo.preload(assumption, :questions).questions

      assert index(html, "item-questions-#{decision.id}") <
               index(html, "assumption-#{question.id}")
    end

    test "its lines are oldest first", %{conn: conn, project: project} do
      older = ask(admit(project, "First"), [non_blocking("naming", "Which name?")])
      newer = ask(admit(project, "Second"), [non_blocking("format", "Which format?")])
      aged(older, 3600)
      aged(newer, 60)

      {:ok, _view, html} = live(conn, ~p"/")

      [older_q] = Repo.preload(older, :questions).questions
      [newer_q] = Repo.preload(newer, :questions).questions
      assert index(html, "assumption-#{older_q.id}") < index(html, "assumption-#{newer_q.id}")

      # And the sentence above them counts them, in the plural.
      assert html =~ "2 assumptions were stated and work continued."
    end

    # Answering never navigates, and a navigation target never encloses a control that commits,
    # so a line leads to its ticket — where the question is answered — and answers nothing here.
    test "a line leads to its ticket, says what was assumed, and answers nothing", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [non_blocking("naming", "What should the table be called?")])
      [question] = Repo.preload(version, :questions).questions

      {:ok, view, _html} = live(conn, ~p"/")

      line = "#assumption-#{question.id}"
      assert has_element?(view, ~s(#{line} a[href="/tickets/#{project.name}/#{ticket.number}"]))
      assert view |> element(line) |> render() =~ "Assumed: went with a"
      refute has_element?(view, "#queue-digest [phx-click]")
      refute has_element?(view, "#queue-digest form")

      assert view |> element("#queue-digest") |> render() =~
               "1 assumption was stated and work continued."
    end

    # With nothing but assumptions, nothing is waiting: no count in the header, and the end of
    # the queue says so. The digest is still there above it.
    test "assumptions alone leave nothing waiting on you", %{conn: conn, project: project} do
      ask(admit(project, "Carried on"), [non_blocking("naming", "Which name?")])

      {:ok, view, _html} = live(conn, ~p"/")

      assert subline(view) == "nothing waiting"
      assert view |> element("#queue-end") |> render() =~ "Nothing needs you."
      assert has_element?(view, "#queue-digest")
    end
  end

  # `ForgeWeb.Operator.Actions.ticket/1` casts before it queries, which is CLAUDE.md's "a guard
  # must use the same model as the operation it guards" written as code: `Tickets.get!/1` on a
  # string that is not a UUID raises `Ecto.Query.CastError`, which the `rescue` in `handle/3` does
  # not catch, and the whole LiveView dies rather than flashing. Nothing on the page can send such
  # an id, which is exactly why nothing exercised it — but a stale tab, a crafted payload or a
  # renamed param all can.
  test "a malformed ticket id is refused rather than killing the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert render_click(view, "transition", %{"ticket" => "not-a-uuid", "to" => "planning"}) =~
             "That ticket no longer exists."

    # Still there, and still usable: the flash is only a friendly error if the page survives it.
    assert has_element?(view, "#queue-end")
  end

  # The queue never decides; it links (`docs/design/ui.md` § The decision row). What a merge
  # will commit is in the decision's panel on the ticket, beside the diff, and not here.
  test "an approval item links to its change, and decides nothing", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    changeset!(ticket, seeded_head(project))
    commit_message!(ticket, "Persist the scores\n")
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s(a#review-#{ticket.id}[href="/tickets/#{project.name}/#{ticket.number}?tab=changes"]),
             "Review the changeset"
           )

    refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]))
    refute has_element?(view, ~s(button[value="approved"]))
    refute has_element?(view, ~s(button[value="rejected"]))

    # 18a: enough to know what you are walking into — what the merge will write, and the change.
    message = view |> element("#queue-commit-message") |> render()
    assert message =~ "Persist the scores"
    # Drawn by the one component every merge message is (`WorkScreen.commit_message/1`).
    refute message =~ "view only"
    assert message =~ "commit-message-subject"
    assert message =~ "v1"
    assert has_element?(view, "#queue-changeset")
    assert view |> element("#queue-item .queue-eyebrow") |> render() =~ "review_ready → merged"

    # The row's kicker is the kind alone, its age apart at the right; the transition is said once,
    # on the latest line (UX pass, A24).
    row = "#item-approval-#{ticket.id}"
    assert view |> element("#{row} .ui-row-kicker-text") |> render() =~ ">approval<"
    assert has_element?(view, "#{row} .ui-row-age", "now")
    assert has_element?(view, "#{row} .ui-row-latest", "→ merged")
    assert view |> element(row) |> render() |> String.split("→") |> length() == 2
  end

  # The queue draws the message only where the panel would: an approval that does not merge says
  # nothing of a commit, whatever the ticket has written (`Decision.commit/1`, one rule for both).
  test "an approval that does not merge draws no commit message", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    commit_message!(ticket, "Persist the scores\n")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "# Refinement\n"
      })

    ticket
    |> Ecto.Changeset.change(
      state: "refining",
      status: :active,
      pending_transition: %{
        "from" => "refining",
        "to" => "planning",
        "outcome" => "done",
        "approve" => ["refinement.md"]
      }
    )
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#queue-item")
    refute has_element?(view, "#queue-commit-message")
  end

  # A merging approval with nothing written for it says so, as its panel does, where the panel
  # draws no Approve.
  test "a merging approval with no message says there is nothing to merge yet", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    changeset!(ticket, seeded_head(project))
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#queue-commit-message", "nothing to merge yet")
  end

  # **A merge decision is never a one-line summary**, and what makes it one is the state it enters
  # and not the names it pins: a merging transition that approves something else was offered with
  # no link to the diff, so the merge was taken without the operator seeing the change
  # (`Forge.Engine.approval_merges?/1`).
  test "a merging approval of something else still offers the diff first", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    changeset!(ticket, seeded_head(project))
    commit_message!(ticket, "Persist the scores\n")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    pending!(ticket, "merged", ["refinement.md"])

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s(#review-#{ticket.id}[href="/tickets/#{project.name}/#{ticket.number}?tab=changes"]),
             "Review the changeset"
           )
  end

  # The queue draws every ticket at once, so one whose pinned workflow no longer builds — the
  # grammar can drop a key, and a pin is not validated again — costs its own detail and not the page.
  test "a ticket whose pinned workflow no longer parses does not take the queue down", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    changeset!(ticket, seeded_head(project))
    ticket = ticket |> Ecto.Changeset.change(workflow: %{}) |> Repo.update!()
    pending!(ticket, "merged", ["changeset"])

    {:ok, view, _html} = live(conn, ~p"/")

    # Drawn, linked to its ticket, and nothing claimed about a merge it cannot be sure of.
    assert has_element?(view, "#review-#{ticket.id}", "Review the changeset")
    refute has_element?(view, ~s([id="#{commit_message_id(ticket)}"]))
  end

  defp pending!(ticket, to, approve) do
    ticket
    |> Ecto.Changeset.change(
      state: "review_ready",
      status: :active,
      pending_transition: %{
        "from" => "review_ready",
        "to" => to,
        "outcome" => nil,
        "approve" => approve
      }
    )
    |> Repo.update!()
  end

  defp seeded_head(project) do
    {:ok, sha} = Forge.Git.resolve(Projects.repo_path(project), "refs/heads/main")
    sha
  end

  # The pass (`docs/design/ui.md` § The queue, `ForgeWeb.QueuePass`): one item on screen, Later to
  # the end, deciding moves on in place, the end says what was decided and what was left.
  describe "the pass" do
    defp questions!(project, title, key, age) do
      ticket = admit(project, title)
      version = ask(ticket, [blocking(key, "Which #{key}?")])
      aged(version, age)
      {ticket, version}
    end

    test "Later sends the item to the end, and the pass ends after the last", %{
      conn: conn,
      project: project
    } do
      {first_ticket, first} = questions!(project, "First", "backend", 3600)
      {_second, second} = questions!(project, "Second", "format", 60)

      {:ok, view, _html} = live(conn, ~p"/")
      assert on_screen(view) == "questions-#{first.id}"
      assert subline(view) == "1 of 2 · 2 decisions"

      view |> element("#queue-later") |> render_click()

      assert on_screen(view) == "questions-#{second.id}"
      html = render(view)

      assert index(html, "item-questions-#{second.id}") <
               index(html, "item-questions-#{first.id}")

      view |> element("#queue-later") |> render_click()

      assert on_screen(view) == nil
      ending = view |> element("#queue-end") |> render()
      refute ending =~ "decided"
      assert ending =~ "2 left for later."
      # Over items left for later the end does not say done (UX pass, A9): green and *End of
      # queue* are for a pass with nothing left.
      assert has_element?(view, "#queue-end .ui-eyebrow", "End of the pass")
      refute has_element?(view, "#queue-end .ui-eyebrow--success")
      # What is left is drawn as the *All* sheet draws it: its kind and the item's title.
      assert has_element?(view, "#back-questions-#{first.id}.ui-row", "First")

      assert has_element?(
               view,
               "#back-questions-#{first.id} .ui-row-kicker",
               "1 blocking question"
             )

      assert subline(view) == "done · 2 decisions left"

      # And back to it: the end's way back shows the item again.
      view |> element("#back-questions-#{first.id}") |> render_click()
      assert on_screen(view) == "questions-#{first.id}"

      # Nothing was answered by any of it.
      assert Artifacts.latest(first_ticket.id, "answers.md") == nil
    end

    # Deciding moves the pass on in place: no navigation, the next item on screen, and the one
    # decided still in the list and the sheet, dimmed with a tick.
    test "answering sends once and shows the next item without a navigation", %{
      conn: conn,
      project: project
    } do
      {first_ticket, first} = questions!(project, "First", "backend", 3600)
      {_second_ticket, second} = questions!(project, "Second", "format", 60)

      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("#form-#{first.id}") |> render_submit() =~ "Sent 1 answer"
      refute_redirected(view)

      assert [%{question: %{key: "backend"}}] = Artifacts.answered(first_ticket.id)
      assert on_screen(view) == "questions-#{second.id}"
      assert has_element?(view, "#item-questions-#{first.id}[data-decided]", "✓")
      assert has_element?(view, "#all-item-questions-#{first.id}[data-decided]", "✓")
      refute has_element?(view, "#item-questions-#{second.id}[data-decided]")
      assert subline(view) == "2 of 2 · 1 decision"

      view |> element("#form-#{second.id}") |> render_submit()

      assert on_screen(view) == nil
      assert view |> element("#queue-end") |> render() =~ "2 decided"
      refute view |> element("#queue-end") |> render() =~ "left for later"
      assert has_element?(view, "#queue-end .ui-eyebrow--success", "End of queue")
      refute has_element?(view, "#queue-left")
    end

    # `?item=` — the list column's rows, *All*'s rows — shows that item; anything else is ignored.
    test "a row jumps the pass to its item", %{conn: conn, project: project} do
      {_first, first} = questions!(project, "First", "backend", 3600)
      {_second, second} = questions!(project, "Second", "format", 60)

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("#item-questions-#{second.id}") |> render_click()
      assert on_screen(view) == "questions-#{second.id}"

      {:ok, view, _html} = live(conn, ~p"/?item=nothing")
      assert on_screen(view) == "questions-#{first.id}"

      {:ok, view, _html} = live(conn, ~p"/?item=end")
      assert on_screen(view) == nil
      assert has_element?(view, "#queue-end")
    end

    # The queue does not rearrange itself under a thumb: what arrives joins the end, and an item
    # answered somewhere else while on screen stays there, saying so, until the person moves on.
    test "an arrival joins the end, and an item answered elsewhere stays on screen", %{
      conn: conn,
      project: project,
      user: user
    } do
      {first_ticket, first} = questions!(project, "First", "backend", 3600)
      {:ok, view, _html} = live(conn, ~p"/")

      {_late, late} = questions!(project, "Arrived late, waiting longest", "format", 7200)
      {:ok, _ticket} = Forge.Operator.answer(first_ticket, user, "backend", %{choice: "a"})
      # The page hears changes through the frame, which counts the first in a second at once and
      # the rest at the second's end: the arrival was the first, so this is that end.
      send(view.pid, :frame_recount)

      assert on_screen(view) == "questions-#{first.id}"
      assert has_element?(view, "#queue-gone")

      html = render(view)
      assert index(html, "item-questions-#{first.id}") < index(html, "item-questions-#{late.id}")

      view |> element("#queue-later") |> render_click()
      assert on_screen(view) == "questions-#{late.id}"
      refute has_element?(view, "#item-questions-#{first.id}")
    end

    # 13c: why, in words, and the ways forward as choice rows; the dock's button takes the one
    # picked, and the pass moves on.
    test "a stuck ticket's ways forward are choice rows, and the dock takes the one picked", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")
      [job | _] = Jobs.for_ticket(ticket.id)
      {:ok, _} = job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Repo.update()
      ticket = ticket |> Ecto.Changeset.change(state: "verifying") |> Repo.update!()
      {:ok, ticket} = Forge.Engine.stick(ticket, "the job failed")

      {:ok, view, _html} = live(conn, ~p"/")

      assert on_screen(view) == "stuck-#{ticket.id}"
      assert has_element?(view, "#queue-attempt")
      # Its row's line is amber, as a wait is, not a warning (UX re-check #4).
      assert has_element?(view, "#item-stuck-#{ticket.id} .ui-row-latest--accent")
      refute has_element?(view, "#item-stuck-#{ticket.id} .ui-row-latest--warning")
      ways = "#ways-#{ticket.id}"
      assert has_element?(view, ways <> " label", "Retry verifying")
      assert has_element?(view, ways <> " label", "Move to review_ready")
      # Nothing is preselected: the dock's button names no way and takes none until one is picked.
      refute has_element?(view, ways <> " input[checked]")
      assert has_element?(view, ~s(#queue-take[form="ways-#{ticket.id}"][disabled]), "Pick a way")
      refute has_element?(view, "#queue-item [phx-click]")

      # Picking changes what the dock says, and nothing else.
      view |> element(ways) |> render_change(%{"ticket" => ticket.id, "way" => "to:review_ready"})
      assert has_element?(view, "#queue-take", "Move to review_ready")
      refute has_element?(view, "#queue-take[disabled]")
      assert has_element?(view, ways <> ~s( input[value="to:review_ready"][checked]))
      assert Tickets.get!(ticket.id).status == :stuck

      view
      |> element(ways)
      |> render_submit(%{"ticket" => ticket.id, "way" => "to:review_ready"})

      refute_redirected(view)
      assert %{state: "review_ready", status: :active} = Tickets.get!(ticket.id)
      assert has_element?(view, "#item-stuck-#{ticket.id}[data-decided]", "✓")
      refute on_screen(view) == "stuck-#{ticket.id}"
    end
  end

  # A way the operation refuses, taken from the item on screen: said in the dock under it, since
  # a failure is never a toast. Here the edge the press names is not one the ticket has.
  test "a way refused from the item on screen is said in its dock", %{
    conn: conn,
    project: project
  } do
    ticket = admit(project, "Persist scores")
    [job | _] = Jobs.for_ticket(ticket.id)
    {:ok, _} = job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Repo.update()
    {:ok, ticket} = Forge.Engine.stick(ticket, "the job failed")

    {:ok, view, _html} = live(conn, ~p"/")
    assert on_screen(view) == "stuck-#{ticket.id}"

    view
    |> element("#ways-#{ticket.id}")
    |> render_submit(%{"ticket" => ticket.id, "way" => "to:nowhere"})

    assert on_screen(view) == "stuck-#{ticket.id}"
    assert has_element?(view, "#queue-refusal[role=alert]", "Failed")
    refute has_element?(view, "#toast")
  end

  # The browser's refusal to subscribe is said beside Notify me, on the queue as on You.
  test "a push subscription the browser refused is said beside Notify me", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "push:error", %{"reason" => "permission was not granted"})

    assert has_element?(view, "#queue-list #push-error", "permission was not granted")
  end

  # The context names what happened on the ticket since this person last opened it, and nothing
  # from before that (`docs/design/ui.md` § The end of the pass, and *All*).
  test "the context lists only what happened since you last looked", %{
    conn: conn,
    project: project,
    user: user
  } do
    ticket = admit(project, "Persist scores")
    ask(ticket, [blocking("backend", "Which backend?")])

    event! = fn type, payload, ago ->
      Repo.insert!(%Forge.Events.Event{
        ticket_id: ticket.id,
        project_id: project.id,
        actor: %{"kind" => "system", "id" => nil},
        type: type,
        payload: payload,
        inserted_at: DateTime.add(DateTime.utc_now(:second), -ago)
      })
    end

    event!.("transition.taken", %{"from" => "triage", "to" => "refining"}, 7200)
    event!.("ticket.stuck", %{"reason" => "nothing could hold it"}, 600)

    other = Forge.ForgeFixtures.member_fixture(project, :member)

    for {who, text} <- [{user, "Keep it to one screen."}, {other, "Two screens, surely."}] do
      Repo.insert!(%Forge.Events.Event{
        ticket_id: ticket.id,
        project_id: project.id,
        actor: %{"kind" => "user", "id" => who.id},
        type: "chat.message",
        payload: %{"text" => text},
        inserted_at: DateTime.add(DateTime.utc_now(:second), -300)
      })
    end

    Forge.Tickets.Views.touch(user, ticket)

    Repo.update_all(
      from(v in Forge.Tickets.View, where: v.user_id == ^user.id),
      set: [viewed_at: DateTime.add(DateTime.utc_now(), -3600)]
    )

    {:ok, view, _html} = live(conn, ~p"/")
    since = view |> element("#queue-since") |> render()

    assert since =~ "stuck: nothing could hold it"
    # The viewer's own words are theirs; another person's are not called theirs.
    assert since =~ "you: “Keep it to one screen.”"
    assert since =~ "someone: “Two screens, surely.”"
    refute since =~ "triage → refining"
    assert since =~ "1h"
  end

  # The group the ticket asks for: whether a ticket's work is on a machine or still waiting for
  # one, at a glance from the Queue (`docs/design/ui.md` § A job waiting for a machine). Quiet,
  # below everything, and in no count — so the assertions are on position, on the absence of the
  # marks, and on the counts not moving.
  describe "work under way" do
    defp on_worker(ticket) do
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
      [job | _] = Jobs.for_ticket(ticket.id)

      {:ok, _running} =
        Repo.update(
          Forge.Jobs.Job.progress_changeset(job, %{status: :running, worker_id: worker.id})
        )

      ticket
    end

    defp under_way(view), do: view |> element("#queue-under-way") |> render()

    test "a running ticket and a waiting one each get a line, and say which", %{
      conn: conn,
      project: project
    } do
      running = on_worker(admit(project, "Already on a machine"))
      on_worker(admit(project, "Also on a machine"))
      waiting = admit(project, "Still queued for one")

      {:ok, view, _html} = live(conn, ~p"/")

      # Each half says what it is once, over its titles, rather than on every line (UX pass, A9).
      assert has_element?(view, "#under-way-running #under-way-#{running.id}")
      assert has_element?(view, "#under-way-waiting #under-way-#{waiting.id}")
      refute has_element?(view, "#under-way-running #under-way-#{waiting.id}")
      refute under_way(view) =~ "Not yet on a worker."

      # Asymmetric on purpose: with one of each, a sentence that counted the two groups the wrong
      # way round would read the same and nothing here would notice.
      assert view |> element("#under-way-running .queue-quiet") |> render() =~
               "2 tickets running on a worker."

      assert view |> element("#under-way-waiting .queue-quiet") |> render() =~
               "1 ticket not yet on a worker."

      # Each line leads to its ticket, and offers nothing that commits — the digest's rule.
      assert has_element?(
               view,
               ~s(#under-way-#{running.id} a[href="/tickets/#{project.name}/#{running.number}"])
             )

      refute has_element?(view, "#queue-under-way [phx-click]")
      refute has_element?(view, "#queue-under-way form")
    end

    # Below the decisions per the answered question, and below the digest because it is the
    # quieter of the two things that wait on nobody. Every line is on the page in any order, so
    # only position tells the arrangement from its reverse.
    test "the group follows the decisions and the digest", %{conn: conn, project: project} do
      decision = ask(admit(project, "Stopped"), [blocking("backend", "Which backend?")])
      assumption = ask(admit(project, "Carried on"), [non_blocking("naming", "Which name?")])
      moving = on_worker(admit(project, "Already on a machine"))

      {:ok, _view, html} = live(conn, ~p"/")

      [question] = Repo.preload(assumption, :questions).questions

      assert index(html, "item-questions-#{decision.id}") <
               index(html, "assumption-#{question.id}")

      assert index(html, "assumption-#{question.id}") < index(html, "under-way-#{moving.id}")
    end

    # Criterion 3. Accent is the queue's mark for an item waiting on a human and is used for
    # nothing else; neither is `mark/1`'s outline for an approval or a review. A job that is
    # merely running, or merely held for capacity, is not a decision.
    test "no line carries a mark or an accent", %{conn: conn, project: project} do
      on_worker(admit(project, "Already on a machine"))
      admit(project, "Still queued for one")

      {:ok, view, _html} = live(conn, ~p"/")
      section = under_way(view)

      for class <- ["accent", "ui-row", "ui-eyebrow--", "ui-choice"] do
        refute section =~ class
      end
    end

    # Criterion 4. The header and the nav badge count `@items`, which these are not in: a number
    # that answering nothing ever lowers is not a count of what is waiting.
    test "neither counts in the header or the nav badge", %{conn: conn, project: project} do
      ask(admit(project, "Stopped"), [blocking("backend", "Which backend?")])

      {:ok, before_view, _html} = live(conn, ~p"/")
      before_header = subline(before_view)

      on_worker(admit(project, "Already on a machine"))
      admit(project, "Still queued for one")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#queue-under-way")
      assert subline(view) == before_header
      assert before_header == "1 of 1 · 1 decision"
      assert view |> element("#desktop-header .frame-queue .ui-count") |> render() =~ ">1<"
    end

    test "a ticket under way alone leaves the badge off entirely", %{
      conn: conn,
      project: project
    } do
      admit(project, "Still queued for one")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#queue-under-way")
      assert subline(view) == "nothing waiting"
      refute has_element?(view, "#desktop-header .frame-queue .ui-count--accent")
      assert view |> element("#queue-end") |> render() =~ "Nothing needs you."
    end

    # Criterion 6. A placement stick leaves the pending job on the row, so without the status
    # filter this ticket would be drawn twice: once in accent as a decision and once quietly as
    # though it were only waiting for a machine.
    test "a stuck ticket is drawn once, as stuck", %{conn: conn, project: project} do
      ticket = admit(project, "Nothing could hold it")
      {:ok, _stuck} = Forge.Engine.stick(ticket, "no template could hold it", :placement)

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#item-stuck-#{ticket.id}")
      refute has_element?(view, "#under-way-#{ticket.id}")
      refute has_element?(view, "#queue-under-way")
    end

    # `docs/design/capacity.md` keeps a paused ticket out of the queue entirely, and the cap is
    # node-wide: without the drop, every active ticket arrives here at once the moment it trips.
    test "a spend-paused ticket is not in the group at all", %{conn: conn, project: project} do
      admit(project, "Held by the cap")

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#queue-under-way")

      previous = Application.get_env(:forge, Forge.Spend, [])
      Application.put_env(:forge, Forge.Spend, daily_tokens: 0)
      on_exit(fn -> Application.put_env(:forge, Forge.Spend, previous) end)

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#queue-under-way")
      assert view |> element("#queue-end") |> render() =~ "Nothing needs you."
    end

    # The failure this read was found by: a command state creates no workflow job, so the page
    # said "Nothing needs you" while the ticket's build was on a machine.
    test "a ticket whose build is on a machine is listed", %{conn: conn, project: project} do
      ticket = admit(project, "Checking")
      [job | _] = Jobs.for_ticket(ticket.id)
      {:ok, _} = Repo.update(Forge.Jobs.Job.progress_changeset(job, %{status: :parked}))
      {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

      command =
        %Forge.Jobs.Job{}
        |> Forge.Jobs.Job.create_changeset(%{
          kind: :command,
          ticket_id: ticket.id,
          project_id: project.id,
          state: "check",
          attempt: 1,
          spec: %{},
          worker_id: worker.id,
          memory_max: Forge.Jobs.default_resources().memory,
          cores: Forge.Jobs.default_resources().cores
        })
        |> Repo.insert!()

      {:ok, _running} =
        Repo.update(Forge.Jobs.Job.progress_changeset(command, %{status: :running}))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#under-way-running #under-way-#{ticket.id}")
      # A half with nothing in it is not drawn as *0 tickets*.
      refute has_element?(view, "#under-way-waiting")
    end

    test "a ticket whose current job has finished has no line", %{conn: conn, project: project} do
      ticket = admit(project, "Done with that job")
      [job | _] = Jobs.for_ticket(ticket.id)

      {:ok, _hibernated} =
        Repo.update(Forge.Jobs.Job.progress_changeset(job, %{status: :hibernated}))

      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#under-way-#{ticket.id}")
      refute has_element?(view, "#queue-under-way")
    end
  end

  # The key of the item on screen, or nil at the end of the pass.
  defp on_screen(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#queue-item")
    |> LazyHTML.attribute("data-key")
    |> List.first()
  end

  # One count: a document's questions are one decision however many there are, and an account
  # waiting on a node admin is one too, so the subline says what the queue button says.
  test "the subline counts decisions as the queue button does", %{conn: conn, project: project} do
    ticket = admit(project, "Persist scores")
    ask(ticket, [blocking("backend", "Which backend?"), blocking("format", "Which format?")])
    admin = Forge.ForgeFixtures.member_fixture(project, :member)
    {:ok, admin} = admin |> Ecto.Changeset.change(node_admin: true) |> Repo.update()
    Forge.AccountsFixtures.pending_user_fixture()

    {:ok, view, _html} = build_conn() |> log_in_user(admin) |> live(~p"/")

    assert subline(view) == "1 of 2 · 2 decisions"
    assert Forge.Queue.count(admin) == 2

    {:ok, view, _html} = live(conn, ~p"/")
    assert subline(view) == "1 of 1 · 1 decision"
  end

  # Accounts waiting on a node admin are counted as decisions on the queue button, so the queue
  # lists them where the count says they are: one item, whose way on is Accounts (UX pass, A23).
  # Before, the count said 2 and the pass had nothing in it.
  test "accounts waiting on an admin are one item, leading to Accounts", %{project: project} do
    admin = Forge.ForgeFixtures.member_fixture(project, :member)
    {:ok, admin} = admin |> Ecto.Changeset.change(node_admin: true) |> Repo.update()
    Forge.AccountsFixtures.pending_user_fixture()
    Forge.AccountsFixtures.pending_user_fixture()

    {:ok, view, _html} = build_conn() |> log_in_user(admin) |> live(~p"/")

    assert subline(view) == "1 of 1 · 2 decisions"
    assert Forge.Queue.count(admin) == 2
    assert on_screen(view) == "accounts"

    assert view |> element("#queue-item .queue-sentence") |> render() =~
             "2 accounts wait to be approved."

    assert has_element?(
             view,
             ~s(#queue-dock a#queue-accounts[href="/accounts"]),
             "Review the accounts"
           )

    assert has_element?(view, "#item-accounts .ui-row-kicker", "accounts")
    # Nothing is decided here: the accounts are, on their page.
    refute has_element?(view, ~s(#queue-item [phx-click="approve"]))

    # Later leaves them for later, like any item, and the end does not say done.
    view |> element("#queue-later") |> render_click()
    refute view |> element("#queue-end") |> render() =~ "Nothing needs you"
    assert has_element?(view, "#back-accounts", "2 accounts wait to be approved.")

    # A member who is not a node admin has none.
    {:ok, member_view, _html} =
      build_conn()
      |> log_in_user(Forge.ForgeFixtures.member_fixture(project, :member))
      |> live(~p"/")

    refute has_element?(member_view, "#item-accounts")
  end

  # The item has waited as long as the oldest account in it, not the newest (review fixes 7, L5).
  test "the accounts item is as old as the oldest account waiting", %{project: project} do
    admin = Forge.ForgeFixtures.member_fixture(project, :member)
    {:ok, admin} = admin |> Ecto.Changeset.change(node_admin: true) |> Repo.update()
    oldest = Forge.AccountsFixtures.pending_user_fixture()
    Forge.AccountsFixtures.pending_user_fixture()

    oldest
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), -3, :day))
    |> Repo.update!()

    {:ok, view, _html} = build_conn() |> log_in_user(admin) |> live(~p"/")

    assert on_screen(view) == "accounts"
    assert view |> element("#queue-item .queue-age") |> render() =~ "waiting 3d"
  end

  test "one account waiting is said in the singular", %{project: project} do
    admin = Forge.ForgeFixtures.member_fixture(project, :member)
    {:ok, admin} = admin |> Ecto.Changeset.change(node_admin: true) |> Repo.update()
    Forge.AccountsFixtures.pending_user_fixture()

    {:ok, view, _html} = build_conn() |> log_in_user(admin) |> live(~p"/")

    assert view |> element("#queue-item .queue-sentence") |> render() =~
             "1 account waits to be approved."
  end

  # The queue button recounts on the frame's own signals — a change in one of the viewer's
  # projects, and the minute tick that reads a node admin's waiting accounts — and the page follows
  # them, so it moves when the button does. A sign-up announces nothing else.
  test "the page counts again when the queue button does", %{project: project} do
    admin = Forge.ForgeFixtures.member_fixture(project, :member)
    {:ok, admin} = admin |> Ecto.Changeset.change(node_admin: true) |> Repo.update()

    {:ok, view, _html} = build_conn() |> log_in_user(admin) |> live(~p"/")
    assert subline(view) == "nothing waiting"

    Forge.AccountsFixtures.pending_user_fixture()
    send(view.pid, :capacity_tick)
    assert subline(view) == "1 of 1 · 1 decision"

    Forge.AccountsFixtures.pending_user_fixture()
    send(view.pid, {:queue_changed, project.id})
    assert subline(view) == "1 of 1 · 2 decisions"
  end

  # One ticket change, one read of the queue (r3 L4): the frame's recount takes the page's own
  # count rather than reading the queue again, and the page hears the change only through the
  # frame — which a ticket change reaches as a `:queue_changed` (`Forge.Events.notify/1`). Counted
  # by the questions the view reads, which `Forge.Queue.items/1` reads once per call and nothing
  # else on the page reads at all.
  test "a ticket change reads the queue once", %{conn: conn, project: project} do
    ticket = admit(project, "Persist scores")
    ask(ticket, [blocking("backend", "Which backend?")])
    {:ok, view, _html} = live(conn, ~p"/")

    test = self()
    handler = "queue-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:forge, :repo, :query],
      fn _event, _measurements, meta, pid ->
        if self() == pid and meta.source == "questions", do: send(test, :questions)
      end,
      view.pid
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Forge.Events.notify(ticket.id)
    assert subline(view) =~ "1 decision"

    assert_received :questions
    refute_received :questions
  end

  # The queue's subline: the place in the pass and the decisions left, as the title row draws it.
  defp subline(view) do
    view
    |> element("#title-row .frame-subline")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.trim()
  end

  defp index(html, id) do
    [{position, _length}] = :binary.matches(html, ~s(id="#{id}"))
    position
  end
end
