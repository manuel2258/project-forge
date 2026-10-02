defmodule ForgeWeb.QueueLiveTest do
  @moduledoc """
  The home screen, on the two things its own doc says it is: "one ordered list of decisions,
  oldest first" and one interruption per stopped job rather than one per question.

  Both are properties of arrangement, and arrangement is what a page-wide `assert html =~` cannot
  see — every item is on the page in any order, and every question is on the page whether or not
  it was answered. So the assertions here are on position and on what is left open afterwards.

  `docs/design/ui.md` § The affordance rule and `ForgeWeb.QueueLive`'s moduledoc are the standard.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.GitFixtures
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

  # "One ordered list of decisions, oldest first" is the first line of the page's own doc, and it
  # is what makes the queue drainable: the operator works down it and the thing that has been
  # waiting longest is never at the bottom where a long list hides it. Reversing the order leaves
  # every item on the page, so only position can tell the two apart.
  test "items are oldest first", %{conn: conn, project: project} do
    older = admit(project, "Waiting since yesterday")
    newer = admit(project, "Only just arrived")

    older_version = ask(older, [blocking("backend", "Which backend?")])
    newer_version = ask(newer, [blocking("format", "Which format?")])

    aged(older_version, 3600)
    aged(newer_version, 60)

    {:ok, _view, html} = live(conn, ~p"/")

    assert index(html, "item-questions-#{older_version.id}") <
             index(html, "item-questions-#{newer_version.id}")
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

    item = view |> element("#item-questions-#{version.id}") |> render()
    assert item =~ "1 blocking question · 1 optional"
    assert item =~ "What should the table be called?"
    refute has_element?(view, "#queue-digest")
    assert view |> element("main header span.font-mono") |> render() =~ "1 decision · 1 item"
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

    # Folded is the form's state, drawn below `lg` only: the question's inputs are in the form
    # whether or not it is folded, so whether radios are drawn says nothing about it.
    defp folded?(view, question), do: has_element?(view, question <> "[data-folded]")

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

    # Folded, a question is one line, its answer in its own inputs hidden beside it; tapping the
    # line opens it; choosing folds it again; typing keeps it open.
    test "a locked question folds, and opens again", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [blocking("backend", "Which backend?")])
      question = "#question-#{version.id}-backend"

      {:ok, view, _html} = live(conn, ~p"/")

      # Recommended, so chosen, so folded: a line, and the line says what was chosen — the whole
      # text of it, since a one-letter label is in any class list.
      assert folded?(view, question)
      assert has_element?(view, question <> " button span.font-medium", ~r/^\s*a\s*$/)

      view |> element(question <> " button[phx-click='form:open']") |> render_click()
      refute folded?(view, question)
      refute has_element?(view, question <> " button[phx-click='form:open']")

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "backend", "text"],
        "answers" => %{"backend" => %{"choice" => "a", "text" => "and keep the old file"}}
      })

      refute folded?(view, question)

      choose(view, version, "backend", "b", "and keep the old file")
      assert folded?(view, question)
      assert view |> element(question) |> render() =~ "b — and keep the old file"
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

      refute folded?(view, naming)

      view |> element("#form-#{version.id}") |> render_submit()

      assert [%{key: "naming"}] = Artifacts.open_questions(ticket.id)
      assert folded?(view, naming)
      assert view |> element(naming) |> render() =~ "change"
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

    # Clearing a choice leaves the question to be answered in words, so it stays open even with a
    # note already typed — it does not fold under the thumb.
    test "clearing a choice keeps the question open", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [blocking("backend", "Which backend?")])
      question = "#question-#{version.id}-backend"

      {:ok, view, _html} = live(conn, ~p"/")
      view |> element(question <> " button[phx-click='form:open']") |> render_click()

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "backend", "choice"],
        "answers" => %{"backend" => %{"choice" => "", "text" => "neither"}}
      })

      refute folded?(view, question)
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
    defp classes(view, selector) do
      [{_tag, attrs, _children}] =
        view |> element(selector) |> render() |> Floki.parse_fragment!()

      attrs |> List.keyfind("class", 0, {"class", ""}) |> elem(1) |> String.split()
    end

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

    defp opened(view, version, key) do
      view
      |> element("#question-#{version.id}-#{key} button[phx-click='form:open']")
      |> render_click()
    end

    test "an option is its headline and its sentence, the recommendation tagged", %{
      conn: conn,
      project: project
    } do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")
      opened(view, version, "store")

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
      opened(view, version, "store")

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

    # `docs/design/ui.md` § Answering questions: the fold is the width's. Below `lg` a folded
    # question is its line and its fields are hidden; at `lg` and up the line is hidden and the
    # fields drawn, so choosing never shrinks a question under the pointer on a laptop. A media
    # query is CSS, which no ExUnit test evaluates, so what is pinned is the classes that say it.
    test "at lg and up nothing folds", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true), rich("size", [])])
      {:ok, view, _html} = live(conn, ~p"/")

      folded = "#question-#{version.id}-store"
      assert folded?(view, folded)
      assert "lg:hidden" in classes(view, folded <> " button[phx-click='form:open']")
      group = classes(view, folded <> " [role=group]")
      assert "hidden" in group
      assert "lg:flex" in group

      open = "#question-#{version.id}-size"
      refute folded?(view, open)
      group = classes(view, open <> " [role=group]")
      assert "flex" in group
      # Hidden at no width: an open question has no line to stand in for it.
      refute Enum.any?(group, &(&1 =~ ~r/(^|:)(hidden|invisible|sr-only)$/))
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

    # Folded, a question carries its answer in its own inputs, hidden: a note typed before
    # choosing is still there when the Send is taken from the page.
    test "a note on a folded question rides the Send", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", [])])
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

      assert folded?(view, "#question-#{version.id}-store")
      view |> element("#form-#{version.id}") |> render_submit()

      assert [%{answer: %{choice: "SQLite", text: "and keep a copy"}}] =
               Artifacts.answered(ticket.id)
    end

    test "a question opened by hand sends the choice it shows", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", recommended: true)])
      {:ok, view, _html} = live(conn, ~p"/")
      opened(view, version, "store")

      view |> element("#form-#{version.id}") |> render_submit()

      assert [%{answer: %{choice: "SQLite", text: nil}}] = Artifacts.answered(ticket.id)
    end

    # Open because nothing is chosen, not because it was opened by hand: typing locks it, and it
    # stays open all the same.
    test "typing keeps a question open", %{conn: conn, project: project} do
      ticket = admit(project, "Persist scores")
      version = ask(ticket, [rich("store", [])])
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("#form-#{version.id}")
      |> render_change(%{
        "_target" => ["answers", "store", "text"],
        "answers" => %{"store" => %{"text" => "neither"}}
      })

      refute folded?(view, "#question-#{version.id}-store")
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
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
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

      assert index(html, "assumption-#{question.id}") < index(html, "queue-end")
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

      refute has_element?(view, "main header span.font-mono")
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

  defp index(html, id) do
    [{position, _length}] = :binary.matches(html, ~s(id="#{id}"))
    position
  end
end
