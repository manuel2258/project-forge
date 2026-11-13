defmodule ForgeWeb.TicketChangesTest do
  @moduledoc """
  A ticket's Changes view, which the review page was folded into (`docs/design/ui.md` § Changes):
  the presentation with the source it quotes, the whole file an excerpt links to, the diff beside
  what the platform knows about the change, and the approval that pins an exact commit.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Forge.GitFixtures
  import Forge.MergeFixtures
  import ForgeWeb.Operator.Components, only: [commit_message_id: 1]
  import Phoenix.LiveViewTest

  alias Forge.{Artifacts, Git, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{scope: scope, user: user} do
    data_dir = tmp_dir("review-data")
    config = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(config, :data_dir, data_dir))
    on_exit(fn -> Application.put_env(:forge, Forge.Jobs, config) end)

    bare = seeded_repo()
    name = "review#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.register(%{name: name, repo_path: bare, default_branch: "main"}, user)

    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist scores", body: "do it"}, {:user, scope.user.id})

    %{project: project, bare: bare, ticket: ticket}
  end

  # The row's button drops the panel, which holds the decision's form.
  defp open!(view) do
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    assert has_element?(view, "#decision-panel")
    view
  end

  test "Files draws the diff, the documents, the answers and the usage", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Report\n\nAll tests pass.\n"
      })

    {:ok, view, _html} = live(conn, files(context))

    assert has_element?(view, ~s(#changes-files li[data-path="score.ex"]))
    assert has_element?(view, "#changes-files .diff-line--add", "def persist")
    assert has_element?(view, "#changes-built-from", "report.md")
    assert has_element?(view, "#changes-answers", "No question stopped a job")
    assert has_element?(view, "#changes-usage", "allowance")
    # Nothing spent: words, not a meter at `0 windows` (UX re-check #7).
    assert has_element?(view, "#changes-usage", "nothing spent yet")
    refute has_element?(view, "#changes-usage .changes-usage-bar")
    # Dollars appear on no operator surface.
    refute view |> element("#changes") |> render() =~ "$"

    # The wide index beside the patches: each row says which patch it is, which is what the
    # view's hook marks as the file in view and opens first (UX pass, B21). Nothing is drawn open:
    # below 1440 the list is the map, and only the hook, from 1440, opens the first.
    assert has_element?(view, ~s(#changes-files-view[phx-hook$="FilesIndex"]))
    assert has_element?(view, ~s(#changes-index .changes-index-row[data-index="0"]), "score.ex")
    refute has_element?(view, "#changes-files details[open]")
  end

  test "the approval pins the changeset version and merges", context do
    %{conn: conn, ticket: ticket, bare: bare} = context
    {:ok, before} = Git.resolve(bare, "refs/heads/main")
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    commit_message!(ticket, "Persist the scores\n")
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, changes(context))
    assert has_element?(view, "#decision-row", "changeset v1")
    # The row says it waits; the subline says where the ticket is, and is not cut on a phone by
    # saying it again (UX pass, B13).
    assert has_element?(view, "#title-row .frame-subline", "review_ready")
    refute has_element?(view, "#title-row .frame-subline", "waiting on you")
    open!(view)
    assert has_element?(view, "#decision-panel", "Approve changeset v1")

    view
    |> form("#decision-form", %{"note" => "ship it"})
    |> render_submit(%{"decision" => "approved"})

    assert Tickets.get!(ticket.id).state == "merged"
    {:ok, head} = Git.resolve(bare, "refs/heads/main")
    assert {:ok, ^before} = Git.resolve(bare, head <> "^1")
    assert {:ok, "def persist, do: :ok\n"} = Git.show(bare, head, "score.ex")
  end

  # What the merge is built from is the fact a reviewer reads closely: every version on a line of
  # its own, linked to it, never joined into one string an ellipsis cuts (UX pass, B12); and a
  # ticket that spent nothing says nothing of it.
  test "names what the merge is built from, each version linked", context do
    %{conn: conn, ticket: ticket, project: project} = context
    changeset!(ticket, commit_on_branch(context, "score.ex", "def persist, do: :ok"))
    commit_message!(ticket, "Persist the scores\n")

    for name <- ~w(refinement.md plan.md) do
      {:ok, _v} =
        Artifacts.record_version(ticket.id, name, :document, :system, %{content: "# #{name}\n"})
    end

    pend_merge(ticket)
    {:ok, view, _html} = live(conn, changes(context))
    open!(view)

    for name <- ~w(refinement.md plan.md) do
      assert has_element?(
               view,
               ~s(#decision-built-from a.decision-built-from-doc[href="/tickets/#{project.name}/#{ticket.number}/artifacts/#{name}/1"]),
               "#{name} v1"
             )
    end

    refute has_element?(view, "#decision-built-from a", "commit-message")
    refute has_element?(view, "#decision-built-from", "spent")

    Forge.Repo.update_all(
      from(t in Forge.Tickets.Ticket, where: t.id == ^ticket.id),
      set: [usage: 300_000]
    )

    {:ok, view, _html} = live(conn, changes(context))
    open!(view)
    assert has_element?(view, "#decision-built-from", ForgeWeb.Format.windows(300_000))
  end

  # The operator reads what the merge will commit and then confirms; the text is the agent's and
  # this page never offers to change it (`docs/design/ui.md` § Changes). Inside the approval card,
  # which is the one place all four approval surfaces share.
  test "draws the commit message above the approval, read only", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    # Front matter in the version, because what is drawn is the string the commit will
    # carry — `ForgeCore.Document.body/1`, the one the merge writes — and not the raw text: an
    # operator who approved one text and found git recording another is the defect
    # (`docs/design/ui.md` § Changes).
    commit_message!(
      ticket,
      "---\noutcome: done\n---\n\nPersist the scores\n\nThey were lost on restart.\n"
    )

    pend_merge(ticket)

    {:ok, view, _html} = live(conn, changes(context))
    open!(view)
    block = view |> element("##{commit_message_id(ticket)}") |> render()

    # As git keeps it: the subject on its own line, the body after it, never run together
    # (UX pass, A15, B11); and no "view only" where nothing beside it is editable.
    assert view |> element("##{commit_message_id(ticket)} .commit-message-subject") |> render() =~
             "Persist the scores"

    assert view |> element("##{commit_message_id(ticket)} .commit-message-body") |> render() =~
             "They were lost on restart."

    refute block =~ "outcome: done"
    refute block =~ "---"
    refute block =~ "view only"
    refute block =~ "<textarea"
    refute block =~ "<input"
    assert has_element?(view, ~s(button[value="approved"]))
  end

  # Approving with nothing written for the commit to say parks the ticket in its merging state,
  # so the card draws no Approve — a button that cannot work is worse than none
  # (`docs/design/ui.md` § Changes).
  test "says there is nothing to merge yet, and offers no approval", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, changes(context))
    open!(view)
    block = view |> element("##{commit_message_id(ticket)}") |> render()

    assert block =~ "nothing to merge yet"
    refute block =~ "view only"
    refute has_element?(view, ~s(button[value="approved"]))
    # Reject still is: a ticket nobody wrote a message for is one to send back.
    assert has_element?(view, ~s(button[value="rejected"]))
  end

  # Files marks each document with whether it was approved, and that mark is the operator's
  # only record here that a person signed the chain off rather than an agent writing it.
  # Placement matters as much as presence — `docs/design/ui.md` § Semantics that must not be
  # lost — so the mark is looked for inside the row of the document it belongs to, with the other
  # document beside it left unmarked.
  test "a document is marked approved only once somebody has approved it", context do
    %{conn: conn, ticket: ticket, scope: scope} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, refinement} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    {:ok, _report} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Report\n"
      })

    {:ok, view, _html} = live(conn, files(context))
    refute has_element?(view, ~s([id="changes-doc-refinement.md"] .changes-doc-approved))

    approve!(refinement, scope.user)

    {:ok, view, _html} = live(conn, files(context))

    assert has_element?(
             view,
             ~s([id="changes-doc-refinement.md"] .changes-doc-approved),
             "approved"
           )

    refute has_element?(view, ~s([id="changes-doc-report.md"] .changes-doc-approved))
  end

  # `docs/design/ui.md` § Documents and § Artifact types: a document is drawn as what its name
  # says it is — Markdown rendered, a log as it was written — and its row carries its type.
  test "draws each document as its type, a log as it was written", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    for {name, content} <- [{"report.md", "# Report\n"}, {"check.log", "# step 1\nok\n"}] do
      {:ok, _version} =
        Artifacts.record_version(ticket.id, name, :document, :system, %{content: content})
    end

    {:ok, view, _html} = live(conn, files(context))

    assert has_element?(
             view,
             ~s([id="changes-doc-report.md"] summary [data-file-type="markdown"])
           )

    assert has_element?(view, ~s([id="changes-doc-report.md"] h1), "Report")

    assert has_element?(view, ~s([id="changes-doc-check.log"] summary [data-file-type="log"]))
    assert view |> element(~s([id="changes-doc-check.log"] pre)) |> render() =~ "# step 1\nok\n"
    refute has_element?(view, ~s([id="changes-doc-check.log"] h1))

    # The page reloads on every change to its ticket; a document the reader opened stays open.
    mounted = view |> element(~s([id="changes-doc-report.md"])) |> render()
    assert mounted =~ ~s(phx-mounted="[[&quot;ignore_attrs&quot;)
  end

  # `docs/design/ui.md` § Changes: a presentation is the reasoning the patch cannot carry, so it is
  # what Changes opens on in review, `view only`, and never with an approval slot.
  test "a presentation is shown, view only", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, "---\noutcome: done\n---\nI moved the table into the database.\n")

    {:ok, view, _html} = live(conn, changes(context))

    assert has_element?(view, ~s(#changes-presentation [id="presentation-presentation.md"] .doc))
    assert render(view) =~ "I moved the table into the database."

    row = view |> element(~s([id="presentation-presentation.md"])) |> render()
    assert row =~ "view only"
    refute row =~ "approved"

    # It is not one of the documents the change was built from: those are a contract between
    # states, and this is consumed by nobody.
    {:ok, view, _html} = live(conn, files(context))
    assert has_element?(view, "#changes-built-from")
    refute has_element?(view, ~s([id="changes-doc-presentation.md"]))
  end

  # A new version written while the reader has it open is drawn, not the build of the old one.
  test "a presentation written again is drawn again on a page left open", context do
    %{conn: conn, ticket: ticket} = context
    changeset!(ticket, commit_on_branch(context, "score.ex", "def persist, do: :ok"))
    present!(ticket, "The first account.\n")

    {:ok, view, _html} = live(conn, changes(context))
    assert render(view) =~ "The first account."

    present!(ticket, "The second account.\n")
    send(view.pid, {:ticket_changed, ticket.id})

    assert render(view) =~ "The second account."
    refute render(view) =~ "The first account."
  end

  # `docs/design/ui.md` § Documents → References. A screenshot is a blob the ticket keeps; a
  # presentation draws the version that was current when it was written, and a version of the same
  # name that arrives later changes nothing it shows. Versions are inserted as rows, because a
  # version is immutable and its clock is the one thing the cut depends on.
  describe "a presentation that refers to a screenshot" do
    defp shot!(ticket, name, versions) do
      artifact =
        Forge.Repo.insert!(%Forge.Artifacts.Artifact{
          ticket_id: ticket.id,
          name: name,
          kind: :blob
        })

      for {number, offset} <- versions do
        Forge.Repo.insert!(%Forge.Artifacts.Version{
          artifact_id: artifact.id,
          version: number,
          author: %{"kind" => "system", "id" => nil},
          blob_uri: "store:job/x/out-a/#{number}",
          content_hash: "h#{number}",
          inserted_at: DateTime.add(DateTime.utc_now(:second), offset, :second)
        })
      end
    end

    defp section(context, content) do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)
      present!(ticket, content)
      {:ok, view, _html} = live(conn, changes(context))

      view
      |> element(~s([id="presentation-presentation.md"]))
      |> render()
      |> Floki.parse_fragment!()
    end

    defp srcs(html), do: html |> Floki.find("img") |> Floki.attribute("src")

    test "draws the version current when it was written, linked, and a later one changes nothing",
         context do
      %{project: project, ticket: ticket} = context
      shot!(ticket, "screenshots/queue.png", [{1, -60}, {2, 3600}])
      base = "/tickets/#{project.name}/#{ticket.number}/artifacts/screenshots%2Fqueue.png"

      html = section(context, "Here is the queue.\n\n![the queue](screenshots/queue.png)\n")

      assert srcs(html) == ["#{base}/1"]
      assert [img] = Floki.find(html, "a > img")
      assert Floki.attribute(img, "loading") == ["lazy"]
      assert Floki.attribute(img, "alt") == ["the queue"]
      assert Floki.attribute(Floki.find(html, "a:has(img)"), "href") == ["#{base}/1"]
    end

    # The common case: the screenshot's later version is in the *past* too, just after the
    # presentation. A cut at "now" would draw it; the cut is at the presentation's own clock.
    test "a version uploaded after the presentation changes nothing, however soon", context do
      %{conn: conn, project: project, ticket: ticket} = context
      shot!(ticket, "q.png", [{1, -7200}, {2, -60}])
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)

      # One presentation written by nobody in particular and one by a job (which is not a
      # conversation): the job's own versions are always seen, but the screenshot's are the
      # system's, so a clock that read "now" would draw version 2 in both.
      for {name, author} <- [
            {"presentation.md", %{"kind" => "system", "id" => nil}},
            {"by-a-job.md", %{"kind" => "job", "id" => Ecto.UUID.generate()}}
          ] do
        artifact =
          Forge.Repo.insert!(%Forge.Artifacts.Artifact{
            ticket_id: ticket.id,
            name: name,
            kind: :presentation
          })

        Forge.Repo.insert!(%Forge.Artifacts.Version{
          artifact_id: artifact.id,
          version: 1,
          author: author,
          content: "![a](q.png)\n\n![b](q.png@latest)\n",
          content_hash: "p",
          inserted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
        })
      end

      {:ok, view, _html} = live(conn, changes(context))
      base = "/tickets/#{project.name}/#{ticket.number}/artifacts/q.png"

      for name <- ["presentation.md", "by-a-job.md"] do
        html =
          view
          |> element(~s([id="presentation-#{name}"]))
          |> render()
          |> Floki.parse_fragment!()

        assert srcs(html) == ["#{base}/1", "#{base}/2"], name
      end
    end

    test "@N and @latest reach the later version, a bare name does not", context do
      %{project: project, ticket: ticket} = context
      shot!(ticket, "q.png", [{1, -60}, {2, 3600}])
      base = "/tickets/#{project.name}/#{ticket.number}/artifacts/q.png"

      html = section(context, "![a](q.png)\n\n![b](q.png@2)\n\n![c](q.png@latest)\n")

      assert srcs(html) == ["#{base}/1", "#{base}/2", "#{base}/2"]
    end

    test "anything else is a note, never an image", context do
      %{ticket: ticket} = context
      shot!(ticket, "diagram.svg", [{1, -60}])
      shot!(ticket, "q.png", [{1, -60}])

      md =
        for target <- [
              "missing.png",
              "diagram.svg",
              "q.png@5",
              "archive/9/q.png",
              "https://evil.test/p.png",
              "data:image/png;base64,AAAA",
              "//evil.test/p.png",
              "/tickets/x/1/artifacts/y/1"
            ],
            do: "![why](#{target})"

      html = section(context, Enum.join(md, "\n\n"))

      assert srcs(html) == []
      assert length(Floki.find(html, "span.ref-note")) == 8
      text = Floki.text(html)
      assert text =~ "is not on this ticket"
      assert text =~ "is not drawn as an image"
      assert text =~ "has no such version"
      assert text =~ "this project has no ticket 9"
      assert text =~ "images from outside the project are not shown"
    end

    test "has no cap on images, while quotes keep theirs", context do
      %{ticket: ticket} = context
      shot!(ticket, "q.png", [{1, -60}])
      html = section(context, Enum.map_join(1..30, "\n\n", fn _ -> "![x](q.png)" end))
      assert length(srcs(html)) == 30
    end

    test "an image past the prose bound is not drawn, because its prose is not", context do
      %{ticket: ticket} = context
      shot!(ticket, "q.png", [{1, -60}])
      filler = String.duplicate("word ", 70_000)
      html = section(context, "![early](q.png)\n\n#{filler}\n\n![late](q.png)\n")
      assert length(srcs(html)) == 1
    end

    test "a document draws the same picture on Changes and on the Docs tab", context do
      %{conn: conn, project: project, ticket: ticket} = context
      shot!(ticket, "q.png", [{1, -60}, {2, 3600}])
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
          content: "# Report\n\n![q](q.png)\n"
        })

      want = ["/tickets/#{project.name}/#{ticket.number}/artifacts/q.png/1"]

      {:ok, view, _html} = live(conn, files(context))
      review = view |> element(~s([id="changes-doc-report.md"])) |> render()
      assert srcs(Floki.parse_fragment!(review)) == want

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
      docs = view |> element(~s(section[id="doc-report.md"])) |> render()
      assert srcs(Floki.parse_fragment!(docs)) == want
      # Inside the row's `<details>`, which a browser does not fetch from while it is closed.
      assert [details] = docs |> Floki.parse_fragment!() |> Floki.find("details:has(img)")
      # ...and the row is closed and the image lazy: a browser fetches a lazy image in a closed
      # `<details>` only once it is opened (asserted here as markup; not observable in a test).
      assert Floki.attribute(details, "open") == []
      assert Floki.attribute(Floki.find(details, "img"), "loading") == ["lazy"]
    end
  end

  # The whole of what the quoting convention buys: the lines the prose is about, from the
  # changeset's own commit, beneath the paragraph that named them — not a link into the diff.
  test "a quoted line range draws those exact lines from the changeset", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\nfour\nfive\n")
    changeset!(ticket, sha)
    present!(ticket, "The interesting part is `score.ex:2-3`, which is new.\n")

    {:ok, view, _html} = live(conn, changes(context))

    quoted = pres(view) |> Enum.join("\n")
    assert quoted =~ "two\nthree"
    refute quoted =~ "one"
    refute quoted =~ "four"
    assert render(view) =~ "score.ex:2-3"
  end

  test "a single quoted line draws that line alone", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\n")
    changeset!(ticket, sha)
    present!(ticket, "Look at `score.ex:3`.\n")

    {:ok, view, _html} = live(conn, changes(context))

    quoted = pres(view) |> Enum.join("\n")
    assert quoted =~ "three"
    refute quoted =~ "two"
  end

  # The prose is an agent's and unbounded, so every way a quote can fail to resolve is a note on
  # the page. A raise here would take down the surface merges are approved on.
  test "a quote that does not resolve degrades to a note", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo")
    changeset!(ticket, sha)

    present!(ticket, """
    Gone: `missing.ex:1`.

    Past the end: `score.ex:9`.

    One past the last line: `score.ex:3`.

    Before the first: `score.ex:0`.

    Backwards: `score.ex:3-1`.

    Far too much: `score.ex:1-400`.
    """)

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert html =~ "missing.ex:1 is not in this changeset&#39;s commit"
    assert html =~ "score.ex:9 is not in this changeset&#39;s commit"
    # `score.ex` has two lines and ends in a newline. Splitting on newlines leaves a trailing
    # empty string, so line 3 used to resolve to it: a label over an empty `pre`, which reads as
    # a blank line in the source rather than as a range that is not there.
    assert html =~ "score.ex:3 is not in this changeset&#39;s commit"
    # `@quoted` matches a zero, and `Enum.slice(lines, 0 - 1, 1)` is the *last* line of the file.
    assert html =~ "score.ex:0 is not in this changeset&#39;s commit"
    assert html =~ "score.ex:3-1 is not in this changeset&#39;s commit"
    assert html =~ "score.ex:1-400 is too much to draw here"
    assert pres(view) == []
  end

  # The last line of a file is drawn, and the cap is drawn right up to its boundary: a test that
  # only ever asks for the middle of a file, or for a range far past the cap, says nothing about
  # either edge.
  test "the last line and a range of exactly the cap are drawn", context do
    %{conn: conn, ticket: ticket} = context
    # Text, which is drawn plain: a highlighted line is spans, and the space between two of
    # them is a text node `Phoenix.LiveViewTest` leaves out.
    sha = commit_on_branch(context, "score.txt", Enum.map_join(1..61, "\n", &"line #{&1}"))
    changeset!(ticket, sha)

    present!(ticket, """
    The last line is `score.txt:61`.

    Exactly the cap: `score.txt:1-60`.

    One more than the cap: `score.txt:1-61`.
    """)

    {:ok, view, _html} = live(conn, changes(context))
    drawn = view |> element(~s([id="presentation-presentation.md"])) |> render()

    assert drawn =~ "line 61"
    assert drawn =~ "score.txt:1-60"
    refute drawn =~ "score.txt:1-60 is too much"
    assert drawn =~ "score.txt:1-61 is too much to draw here"
  end

  # The slice is taken after the cache returns, so what the cache holds is the whole file: keyed by
  # anything but the path — a constant, say — it would serve one file's lines under another's
  # label, which is what the two-file case below holds. (Keying it by the quote instead would be
  # correct and merely wasteful, so that is not what this guards.) That the file is read once
  # rather than three times is not observable from here, and the comment at the code says so.
  test "two ranges of one file each draw their own lines", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\nfour")
    changeset!(ticket, sha)
    present!(ticket, "First `score.ex:1`, then `score.ex:3-4`.\n")

    {:ok, view, _html} = live(conn, changes(context))

    assert pres(view) == ["one", "three\nfour"]
  end

  # Two files in one presentation, which nothing else here does: every other case quotes ranges of
  # `score.ex`, and a cache that returned any file's content for any path would pass all of them.
  test "two different files each draw their own content", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "a.ex", "alpha")
    sha = commit_on_branch(context, "b.ex", "beta")
    changeset!(ticket, sha)
    present!(ticket, "First `a.ex:1`, then `b.ex:1`.\n")

    {:ok, view, _html} = live(conn, changes(context))

    assert [first, second] = pres(view)
    assert first == "alpha"
    assert second == "beta"
  end

  # **The page is rendered into JSON for every connected viewer.** `Jason` raises on invalid
  # UTF-8, so a `pre` of a binary file's bytes would not merely look wrong: it would take the
  # surface merges are approved on down for everyone reading it, which is what
  # `ForgeWeb.Markdown`'s own rescue clause exists to prevent. The diff does not print those bytes
  # either — git says `Binary files … differ` — and a quote reaches any path in the tree at head,
  # not only the ones the change touched.
  test "a quoted file that is not text is a note, and the page survives it", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "logo.png", <<137, 80, 78, 71, 0, 255, 254>>)
    changeset!(ticket, sha)
    present!(ticket, "The icon is `logo.png:1`.\n")

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert html =~ "logo.png:1 is not text; read it in Files"
    assert pres(view) == []
    # What the socket's serializer does with the rendered tree, which `Phoenix.LiveViewTest`
    # never does: the page is only as safe as its bytes are encodable.
    assert {:ok, _json} = Jason.encode(html)
  end

  # Both caps on size, each at a boundary no line count catches: one minified line is a megabyte,
  # and a file quoted at its first line can still be any size at all. The second is refused
  # before the blob is read rather than after — the cap the `git show` used to be inside of.
  test "a quote is refused for its bytes as well as its lines", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "min.js", String.duplicate("x", 17_000), "minified")
    sha = commit_on_branch(context, "big.txt", String.duplicate("line\n", 300_000), "big")
    changeset!(ticket, sha)

    present!(ticket, """
    One long line: `min.js:1`.

    A big file, quoted small: `big.txt:1-2`.
    """)

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert html =~ "min.js:1 is too much to draw here"
    assert html =~ "big.txt:1-2 is too much to draw here"
    assert pres(view) == []
  end

  # The byte cap at its edge, which the case above overshoots by six hundred bytes: a quote of
  # exactly 16 KiB is drawn and one byte more is not.
  test "a quote of exactly the byte cap is drawn, one byte more is not", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "at.txt", String.duplicate("x", 16 * 1024), "at")
    sha = commit_on_branch(context, "over.txt", String.duplicate("y", 16 * 1024 + 1), "over")
    changeset!(ticket, sha)
    present!(ticket, "At: `at.txt:1`.\n\nOver: `over.txt:1`.\n")

    {:ok, view, _html} = live(conn, changes(context))

    assert pres(view) == [String.duplicate("x", 16 * 1024)]
    assert render(view) =~ "over.txt:1 is too much to draw here"
  end

  # The prose is an agent's, and `@max_prose_bytes` of it holds some thirteen thousand quotes.
  # Every one of them would be a `pre` of up to 16 KiB built inside `mount/3`, per viewer, and
  # again on every patch of the page; the reads are fewer than that, because a path quoted twice
  # is read once, which is what the cache above is for.
  test "only a bounded number of quotes is drawn, and the rest are counted", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..40, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..20, " ", &"`score.ex:#{&1}`") <> "\n")

    {:ok, view, _html} = live(conn, changes(context))
    drawn = view |> element(~s([id="presentation-presentation.md"])) |> render()

    assert length(pres(view)) == 12
    assert drawn =~ "8 further quotes are not drawn: a presentation draws at most 12."
  end

  # **The cap counts what is drawn, not what is distinct.** One quote named in forty paragraphs is
  # forty `pre` blocks against one path read, and a cap on distinct quotes bounds the reads and
  # nothing else — which is the half that does not make the page expensive.
  test "the same quote in many paragraphs is capped too", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..10, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..40, "\n\n", fn n -> "Point #{n}: `score.ex:1-5`." end))

    {:ok, view, _html} = live(conn, changes(context))
    drawn = view |> element(~s([id="presentation-presentation.md"])) |> render()

    assert length(pres(view)) == 12
    assert drawn =~ "28 further quotes are not drawn"
  end

  # One over the cap, which is the only case the singular sentence is written for.
  test "one quote over the cap is counted in the singular", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..20, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..13, " ", &"`score.ex:#{&1}`") <> "\n")

    {:ok, view, _html} = live(conn, changes(context))
    drawn = view |> element(~s([id="presentation-presentation.md"])) |> render()

    assert drawn =~ "1 further quote is not drawn: a presentation draws at most 12."
    refute drawn =~ "1 further quotes"
  end

  # A megabyte of `x\n\n` is 300,000 paragraphs, each parsed as Markdown on its own so that what
  # it quotes can be drawn beneath it: ten seconds inside `mount/3`, per viewer. The page draws
  # the beginning and says where the rest is.
  test "a presentation longer than the page draws is cut short, and says so", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    present!(
      ticket,
      "The start of it.\n\n" <> String.duplicate("filler\n\n", 12_000) <> "The end of it.\n"
    )

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert html =~ "The start of it."
    refute html =~ "The end of it."
    assert html =~ "longer than the page draws"
  end

  # **Both edges of the read budget, and that it is one budget for the presentation.** Quoted in
  # this order on purpose: the file one byte over the budget is refused with the whole budget
  # free, then the file of exactly the budget is read, and then there is nothing left for a third
  # file that would otherwise be trivial to draw.
  test "a file of exactly the read budget is read, one byte more is not", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "score.ex", "one\ntwo", "small")
    commit_on_branch(context, "over.txt", at_budget(1), "over")
    sha = commit_on_branch(context, "at.txt", at_budget(0), "at")
    changeset!(ticket, sha)

    present!(ticket, """
    One byte over: `over.txt:1-2`.

    Exactly the budget: `at.txt:1-2`.

    Nothing left for this: `score.ex:1`.
    """)

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert html =~ "over.txt:1-2 is too much to draw here"
    assert pres(view) == ["x\nx"]
    assert html =~ "score.ex:1 is too much to draw here"
  end

  # The prose cap at its boundary in both directions: a test that overshoots it by 90 KB says
  # nothing about where it is.
  test "a presentation of exactly the prose cap is drawn whole", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, String.duplicate("a", 64 * 1024))

    {:ok, _view, html} = live(conn, changes(context))
    refute html =~ "longer than the page draws"

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "presentation.md", :presentation, :system, %{
        content: String.duplicate("a", 64 * 1024 + 1)
      })

    {:ok, _view, html} = live(conn, changes(context))
    assert html =~ "longer than the page draws"
  end

  # **The cut lands on a whole character.** Every other truncation here cuts at an ASCII boundary,
  # where the function that exists for this does nothing: the first prefix is already valid. Here
  # the cap falls inside a two-byte `é`, so the prefix has to lose that byte and keep the `Z`
  # before it — one byte further back and the marker goes with it, and a page of invalid UTF-8 is
  # what the socket's serializer raises on.
  test "a presentation cut short mid-character keeps the character before it", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, String.duplicate("a", 64 * 1024 - 2) <> "Zé and the rest of it")

    {:ok, _view, html} = live(conn, changes(context))

    assert html =~ "aZ"
    refute html =~ "the rest of it"
    assert html =~ "longer than the page draws"
    assert {:ok, _json} = Jason.encode(html)

    # And where the cap already falls between characters, nothing is dropped: the character at the
    # cap is the last one drawn. Both halves are needed — the case above passes whether the walk
    # back starts at nought or at one, and only this one says it starts at nought.
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "presentation.md", :presentation, :system, %{
        content: String.duplicate("a", 64 * 1024 - 1) <> "Q and the rest of it"
      })

    {:ok, _view, html} = live(conn, changes(context))

    assert html =~ "aQ"
    refute html =~ "the rest of it"
  end

  # Seven digits is every line of every file anyone has; the eighth stops it being a quote at all,
  # so there is no note either — the prose keeps the words it wrote and the page does no work.
  test "a line number past the pattern's bound is not a quote", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo")
    changeset!(ticket, sha)
    present!(ticket, "Eight digits: `score.ex:12345678`. Seven: `score.ex:1234567`.\n")

    {:ok, view, _html} = live(conn, changes(context))
    html = render(view)

    assert pres(view) == []
    # The seven-digit one is a quote and says it does not resolve; the eight-digit one is prose.
    assert html =~ "score.ex:1234567 is not in this changeset"
    refute html =~ "score.ex:12345678 is not in this changeset"
  end

  # "Newest material last" is the comment's claim and every other test records one presentation,
  # which says nothing about the order of two.
  test "presentations are drawn oldest first", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    # Named against the order they are written in, because `Artifacts.list/1` returns them by
    # name: alphabetical order would otherwise pass whichever way the page sorted. `inserted_at`
    # is to the second and `artifact_versions` is append-only, so the second has to really be
    # later — there is no way to backdate one.
    {:ok, _first} =
      Artifacts.record_version(ticket.id, "zebra.md", :presentation, :system, %{
        content: "The earlier one.\n"
      })

    Process.sleep(1_100)

    {:ok, _second} =
      Artifacts.record_version(ticket.id, "alpha.md", :presentation, :system, %{
        content: "The later one.\n"
      })

    {:ok, _view, html} = live(conn, changes(context))

    assert [%{name: "zebra.md"}, %{name: "alpha.md"}] =
             html
             |> Floki.parse_document!()
             |> Floki.find(~s([id^="presentation-"]))
             |> Enum.map(
               &%{
                 name:
                   &1
                   |> Floki.attribute("id")
                   |> hd()
                   |> String.trim_leading("presentation-")
               }
             )
  end

  # The section sits above the diff, so it is drawn on a ticket that has no changeset at all —
  # there is then no commit to resolve a quote against, and that is a note like any other.
  test "a presentation is shown, and its quotes noted, with no changeset yet", context do
    %{conn: conn, ticket: ticket} = context
    present!(ticket, "Before any of it: `score.ex:1`.\n")

    {:ok, view, html} = live(conn, changes(context))

    assert html =~ "No job has produced a changeset"
    assert render(view) =~ "Before any of it"
    assert render(view) =~ "score.ex:1 is not in this changeset&#39;s commit"
  end

  test "the queue links an approval of the changeset to the change", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s(#review-#{ticket.id}[href="/tickets/#{project.name}/#{ticket.number}?tab=changes"]),
             "Review the changeset"
           )
  end

  test "the API serves the same material", context do
    %{project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert body["changeset"]["commit"] == sha
    assert body["changeset"]["version"] == 1
    assert body["merged"] == false
    assert [%{"path" => "score.ex"}] = body["diff"]["files"]
    assert body["diff"]["patch"] =~ "def persist"
    assert body["diff"]["text"] == true
  end

  # `Jason` raises on a binary that is not valid UTF-8, so a latin-1 commit made this endpoint
  # 500 — the same root cause the pages answer with `ForgeWeb.Diff`, one layer earlier. The map
  # of the change still arrives; only the patch is withheld, and `text` says why.
  test "the API withholds a patch it cannot encode rather than failing whole", context do
    %{project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "latin1.ex", "def caf" <> <<0xE9>> <> ", do: :ok")
    changeset!(ticket, sha)

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert [%{"path" => "latin1.ex"}] = body["diff"]["files"]
    assert body["diff"]["text"] == false
    assert body["diff"]["patch"] == nil
  end

  # And a *name* that is not text, which reaches the same response through `--numstat`.
  test "the API names a file whose name is not text in a form JSON can carry", context do
    %{project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "caf" <> <<0xE9>> <> ".ex", "def ok, do: :ok")
    changeset!(ticket, sha)

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert [%{"path" => ~s("caf\\351.ex")}] = body["diff"]["files"]
  end

  # A changeset version whose uri is not a commit. Interpolated into `base..head` a nil head makes
  # `base..`, which git reads as `base..HEAD`: the API would answer with the default branch's diff
  # as this ticket's change, and say nothing was wrong. The page and the merge both refuse it, and
  # this is the third site of the three.
  test "the API refuses a changeset that is not a commit rather than diffing the branch",
       context do
    %{project: project, ticket: ticket} = context
    commit_on_branch(context, "score.ex", "def persist, do: :ok")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{blob_uri: "blob:nope"})

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert body["diff"]["error"] =~ "not_a_commit"
    refute body["diff"]["patch"]
  end

  # Separately from the documents, because the kind is the whole difference: a client handed one
  # in `documents` could not tell that nothing consumes it and nothing approves it.
  test "the API serves presentations apart from the documents", context do
    %{project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, "What I did.\n")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "# Report\n"
      })

    token = Forge.Accounts.create_api_token(context.scope.user, "test")

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/v1/tickets/#{project.name}/#{ticket.number}/review")
      |> json_response(200)

    assert [%{"name" => "presentation.md", "version" => 1, "content" => "What I did.\n"}] =
             body["presentations"]

    names = Enum.map(body["documents"], & &1["name"])
    assert "report.md" in names
    refute "presentation.md" in names
  end

  # -- the view: which sub-view, the whole file, the pinned change ------------------------------

  describe "which sub-view Changes opens on" do
    # `19d`: in review, with a presentation, the presentation is what is read first.
    test "the presentation, while an approval of the change waits and there is one", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)
      present!(ticket, "What I did.\n")
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, ticket_page(context))

      assert has_element?(view, "#changes #changes-presentation")
      assert has_element?(view, ~s(#changes-sub-presentation[aria-current="page"]))
      refute has_element?(view, "#changes-files-view")
    end

    # `19f`: before review there is a presentation to read, but what is open is the work.
    test "Files before review, with the presentation a tap away", context do
      %{conn: conn, ticket: ticket} = context
      commit_on_branch(context, "score.ex", "def persist, do: :ok")
      present!(ticket, "What I did.\n")

      {:ok, view, _html} = live(conn, ticket_page(context) <> "?tab=changes")

      assert has_element?(view, "#changes-files-view")
      assert has_element?(view, "a#changes-sub-presentation")
      refute has_element?(view, "#changes-no-presentation")
    end

    # Chosen as the page is opened, not as the ticket changes (`ui.md` § The ticket): someone
    # reading Files is not moved to Presentation when the approval arrives under them.
    test "an approval arriving while Files is read leaves the reader on Files", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)
      present!(ticket, "What I did.\n")

      {:ok, view, _html} = live(conn, ticket_page(context) <> "?tab=changes")
      assert has_element?(view, "#changes-files-view")

      pend_merge(ticket)
      Forge.Events.notify(ticket.id)

      assert has_element?(view, "#decision-row")
      assert has_element?(view, "#changes-files-view")
      refute has_element?(view, "#changes #changes-presentation")

      # The next visit opens where the ticket is now.
      {:ok, view, _html} = live(conn, ticket_page(context) <> "?tab=changes")
      assert has_element?(view, "#changes #changes-presentation")
    end

    # `19f`: with no presentation the option is dimmed and says why, and asking for it by its
    # address is Files rather than an empty view.
    test "Files with Presentation dimmed, when there is none", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)
      pend_merge(ticket)

      for path <- [ticket_page(context), changes(context)] do
        {:ok, view, _html} = live(conn, path)

        assert has_element?(view, "#changes-files-view"), path
        assert has_element?(view, ~s(span#changes-sub-presentation[aria-disabled="true"]))
        assert has_element?(view, "#changes-no-presentation", ticket.branch)

        # It leads: it says what the list under it is, and after the list it explained nothing
        # (UX pass, B28).
        html = view |> element("#changes-files-view .changes-files-main") |> render()
        {note, _} = :binary.match(html, "changes-no-presentation")
        {list, _} = :binary.match(html, ~s(id="changes-files"))
        assert note < list, path
      end
    end

    test "Commits lists the branch's commits since its base", context do
      %{conn: conn} = context
      sha = commit_on_branch(context, "score.ex", "def persist, do: :ok", "Persist it")

      {:ok, view, _html} = live(conn, ticket_page(context) <> "?tab=changes&sub=commits")

      assert has_element?(view, "#changes-commits #commits", String.slice(sha, 0, 7))
      assert has_element?(view, "#changes-commits #commits", "Persist it")
    end
  end

  # The review page was folded into Changes; its address is gone, not redirected
  # (`docs/design/ui.md` § Not found).
  test "the review page's address is not found", context do
    %{conn: conn, project: project, ticket: ticket} = context

    assert get(conn, "/tickets/#{project.name}/#{ticket.number}/review").status == 404
  end

  # **What Approve is pressed on is what the approval pins.** The branch can move on after the
  # changeset was recorded; Files shows the pinned commit's change while that approval waits,
  # and the branch's own once nothing does.
  test "while an approval of the changeset waits, Files is the pinned commit's change", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    commit_on_branch(context, "later.ex", "def later, do: :ok")

    {:ok, view, _html} = live(conn, files(context))
    assert has_element?(view, ~s(#changes-files li[data-path="later.ex"]))

    pend_merge(ticket)

    {:ok, view, _html} = live(conn, files(context))
    assert has_element?(view, ~s(#changes-files li[data-path="score.ex"]))
    refute has_element?(view, ~s(#changes-files li[data-path="later.ex"]))
  end

  # A pinned changeset that names no commit has no change to show, and the branch's is not it.
  test "a pinned changeset that is not a commit is said, not replaced by the branch", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "score.ex", "def persist, do: :ok")

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "changeset", :blob, :system, %{blob_uri: "blob:nope"})

    pend_merge(ticket)

    {:ok, view, _html} = live(conn, files(context))

    assert has_element?(view, "#changes", "not_a_commit")
    refute has_element?(view, ~s(#changes-files li[data-path="score.ex"]))
  end

  # `18f`: on a wide screen the row carries the message's first line inline; CSS shows it there
  # and nowhere narrower, so what is asserted is that the row holds it.
  test "the approval row carries the commit message's subject", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    commit_message!(ticket, "---\noutcome: done\n---\n\nPersist the scores\n\nWhy.\n")
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, ticket_page(context))

    assert view |> element("#decision-row #decision-will-commit") |> render() =~
             ~r/will commit<\/span>\s*Persist the scores\s*</
  end

  describe "an excerpt" do
    # Highlighted as the file it was cut from, and the lines the change added tinted — not the
    # ones it was already there with.
    test "is highlighted, with the lines the change added tinted", context do
      %{conn: conn, ticket: ticket, bare: bare} = context
      commit_on_branch(context, "score.ex", "defmodule Score do\nend")
      {:ok, base} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      set_base!(ticket, base)

      sha =
        commit_on_branch(
          context,
          "score.ex",
          "defmodule Score do\n  def persist, do: :ok\nend"
        )

      changeset!(ticket, sha)
      present!(ticket, "It persists: `score.ex:1-3`.\n")

      {:ok, view, _html} = live(conn, changes(context))

      assert has_element?(view, ".excerpt .code-highlighted")
      assert has_element?(view, ~s(.excerpt [data-line="2"].code-line--add))
      refute has_element?(view, ~s(.excerpt [data-line="1"].code-line--add))
      refute has_element?(view, ~s(.excerpt [data-line="3"].code-line--add))
      # Numbered from where it was cut.
      assert has_element?(view, ~s(.excerpt [data-line="1"] .code-number), "1")
    end

    # Tinted from the branch's diff only while the branch is at the changeset's commit: past it,
    # the diff's line numbers are not the excerpt's. The presentation is built again when either
    # head moves, on a page left open.
    test "is tinted only while the branch is at the changeset, and follows both", context do
      %{conn: conn, ticket: ticket, bare: bare} = context
      commit_on_branch(context, "score.ex", "defmodule Score do\nend")
      {:ok, base} = Git.resolve(bare, "refs/heads/" <> ticket.branch)
      set_base!(ticket, base)

      one = "defmodule Score do\n  def persist, do: :ok\nend"
      changeset!(ticket, commit_on_branch(context, "score.ex", one))
      present!(ticket, "It persists: `score.ex:1-3`.\n")

      {:ok, view, _html} = live(conn, changes(context))
      assert has_element?(view, ~s(.excerpt [data-line="2"].code-line--add))

      two = "defmodule Score do\n  def persist, do: :ok\n  def load, do: :ok\nend"
      sha = commit_on_branch(context, "score.ex", two)
      send(view.pid, {:ticket_changed, ticket.id})

      refute has_element?(view, ".excerpt .code-line--add")
      refute render(view) =~ "def load"

      changeset!(ticket, sha)
      send(view.pid, {:ticket_changed, ticket.id})

      assert has_element?(view, ~s(.excerpt [data-line="3"].code-line--add), "def load")
    end

    test "links to its whole file, and the file back to its paragraph", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.txt", "one\ntwo\nthree\nfour\nfive")
      changeset!(ticket, sha)
      present!(ticket, "First.\n\nThe middle: `score.txt:2-3`.\n")

      {:ok, view, _html} = live(conn, changes(context))

      assert has_element?(view, "#para-0-1 .excerpt")
      whole = view |> element("#para-0-1 .excerpt-whole") |> render_click()
      assert whole =~ "changes-file"

      path = assert_patch(view)
      assert path =~ "sub=files"
      assert path =~ "file=score.txt"
      assert path =~ "lines=2-3"
      assert path =~ "para=para-0-1"

      assert has_element?(view, ~s(#changes-file[data-path="score.txt"]))
      assert has_element?(view, ~s(#changes-sub-files[aria-current="page"]))

      for line <- [2, 3],
          do:
            assert(
              has_element?(view, ~s(#changes-file-code [data-line="#{line}"].code-line--marked))
            )

      for line <- [1, 4, 5],
          do:
            refute(
              has_element?(view, ~s(#changes-file-code [data-line="#{line}"].code-line--marked))
            )

      assert has_element?(view, "#changes-file", "The lines the presentation showed are marked.")

      assert view |> element("#changes-back") |> render() =~
               "?tab=changes&amp;sub=presentation#para-0-1"
    end
  end

  describe "the whole file" do
    # Read out of the changeset's commit and nowhere else: a file the branch gained after it, a
    # path out of the tree and a path that never existed are all one miss.
    test "is the changeset's commit's, and a path outside it is a miss", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "score.txt", "one")
      changeset!(ticket, sha)
      commit_on_branch(context, "later.txt", "after the changeset")

      {:ok, view, _html} = live(conn, whole(context, "score.txt"))
      assert has_element?(view, "#changes-file-code", "one")

      for path <- ["later.txt", "../score.txt", "../../etc/passwd", "nope.txt"] do
        {:ok, view, _html} = live(conn, whole(context, path))

        refute has_element?(view, "#changes-file-code"), path
        assert has_element?(view, "#changes-file", "is not in this changeset's commit"), path
      end
    end

    # The repository page's bound, at both edges: `commit_over_http/5` adds the final newline.
    test "draws a file under 512 KB and says so at 512 KB", context do
      %{conn: conn, ticket: ticket} = context
      commit_on_branch(context, "under.txt", String.duplicate("x", 512 * 1024 - 2), "under")
      sha = commit_on_branch(context, "at.txt", String.duplicate("x", 512 * 1024 - 1), "at")
      changeset!(ticket, sha)

      {:ok, view, _html} = live(conn, whole(context, "under.txt"))
      assert has_element?(view, "#changes-file-code")

      {:ok, view, _html} = live(conn, whole(context, "at.txt"))
      refute has_element?(view, "#changes-file-code")

      assert has_element?(
               view,
               "#changes-file",
               "at.txt is 512 KB; this page draws a file under 512 KB. Read it with git."
             )
    end

    test "says a file that is not text is not drawn", context do
      %{conn: conn, ticket: ticket} = context
      sha = commit_on_branch(context, "logo.png", <<137, 80, 78, 71, 0, 255, 254>>)
      changeset!(ticket, sha)

      {:ok, view, _html} = live(conn, whole(context, "logo.png"))

      assert has_element?(view, "#changes-file", "logo.png is not text this page can draw")
      assert {:ok, _json} = Jason.encode(render(view))
    end

    # Neighbouring files are one tap away at the foot (`19e`), in the file list's order.
    test "names its place among the change's files and links its neighbours", context do
      %{conn: conn, ticket: ticket} = context
      commit_on_branch(context, "a.txt", "a")
      commit_on_branch(context, "b.txt", "b")
      sha = commit_on_branch(context, "c.txt", "c")
      changeset!(ticket, sha)

      {:ok, view, _html} = live(conn, whole(context, "b.txt"))

      assert has_element?(view, ".changes-file-at", "2 of 3")
      assert has_element?(view, ~s(.changes-file-prev[href*="file=a.txt"]), "a.txt")
      assert has_element?(view, ~s(.changes-file-next[href*="file=c.txt"]), "c.txt")

      {:ok, view, _html} = live(conn, whole(context, "a.txt"))
      refute has_element?(view, ".changes-file-prev")
      assert has_element?(view, ".changes-file-at", "1 of 3")
    end
  end

  # A range off the address is a number a person can edit: seven digits at most, either way
  # round refused, and nothing that is not one.
  test "a range of lines off the address is read as one or not at all" do
    assert ForgeWeb.Presentation.range("14-19") == 14..19
    assert ForgeWeb.Presentation.range("7") == 7..7
    assert ForgeWeb.Presentation.range("3-1") == nil
    assert ForgeWeb.Presentation.range("0-2") == nil
    assert ForgeWeb.Presentation.range("12345678") == nil
    assert ForgeWeb.Presentation.range("1-2; x") == nil
    assert ForgeWeb.Presentation.range(nil) == nil
  end

  # The paragraph to come back to is an anchor this page wrote, and only that goes back into the
  # link: anything else in the address is no paragraph, and the way back is to Files.
  test "the way back from a whole file names only a paragraph anchor", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.txt", "one")
    changeset!(ticket, sha)
    base = ~p"/tickets/#{project.name}/#{ticket.number}"

    {:ok, view, _html} =
      live(conn, base <> "?tab=changes&sub=files&file=score.txt&para=para-0-3")

    assert view |> element("#changes-back") |> render() =~ "sub=presentation#para-0-3"

    {:ok, view, _html} =
      live(conn, base <> "?tab=changes&sub=files&file=score.txt&para=x%22%3E%3Cb%3E")

    assert has_element?(view, "#changes-back", "‹ Files")
    refute view |> element("#changes-back") |> render() =~ "x&quot;"
  end

  # `19g`: the wide pane beside the presentation shows the file the paragraph in view points
  # at, which the page's hook reports, and a file tab switches it by hand.
  test "the wide pane shows the file it is told to follow", context do
    %{conn: conn, ticket: ticket} = context
    commit_on_branch(context, "a.txt", "alpha\nmore")
    sha = commit_on_branch(context, "b.txt", "beta")
    changeset!(ticket, sha)
    present!(ticket, "First `a.txt:2`.\n\nThen `b.txt:1`.\n")

    {:ok, view, _html} = live(conn, changes(context))
    refute has_element?(view, "#changes-follow #changes-file-code")
    assert has_element?(view, "#para-0-0[data-follow='a.txt'][data-follow-lines='2-2']")

    render_hook(view, "changes:follow", %{"path" => "a.txt", "lines" => "2-2"})
    assert has_element?(view, "#changes-follow #changes-file-code", "alpha")
    assert has_element?(view, ~s(#changes-follow [data-line="2"].code-line--marked))
    refute has_element?(view, ~s(#changes-follow [data-line="1"].code-line--marked))

    view |> element("#changes-follow .changes-follow-tab", "b.txt") |> render_click()
    assert has_element?(view, "#changes-follow #changes-file-code", "beta")

    assert has_element?(
             view,
             ~s(#changes-follow .changes-follow-tab[aria-current="true"]),
             "b.txt"
           )
  end

  # -- helpers ---------------------------------------------------------------------------------

  defp commit_on_branch(%{project: project, ticket: ticket}, path, content, message \\ nil) do
    commit_over_http(project, ticket.branch, path, content, message)
  end

  # A file of exactly `@max_read_bytes` bytes, plus `over`, in lines small enough that what is
  # quoted out of it is nowhere near the per-quote caps. `commit_over_http/5` appends a newline,
  # which is the byte this leaves out.
  defp at_budget(over) do
    String.duplicate("x\n", 524_287) <> "x" <> String.duplicate("y", over)
  end

  # The text of every quote the presentation drew, in the order it drew them: each excerpt's
  # lines, joined as the file had them.
  defp pres(view) do
    view
    |> element(~s([id="presentation-presentation.md"]))
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(".excerpt")
    |> Enum.flat_map(fn excerpt ->
      case Floki.find(excerpt, ".code-text") do
        [] -> []
        lines -> [Enum.map_join(lines, "\n", &Floki.text/1)]
      end
    end)
  end

  defp changes(%{project: project, ticket: ticket}),
    do: ~p"/tickets/#{project.name}/#{ticket.number}?tab=changes&sub=presentation"

  defp files(%{project: project, ticket: ticket}),
    do: ~p"/tickets/#{project.name}/#{ticket.number}?tab=changes&sub=files"

  defp ticket_page(%{project: project, ticket: ticket}),
    do: ~p"/tickets/#{project.name}/#{ticket.number}"

  defp whole(%{project: project, ticket: ticket}, path, lines \\ nil) do
    query = [tab: "changes", sub: "files", file: path] ++ if(lines, do: [lines: lines], else: [])
    ~p"/tickets/#{project.name}/#{ticket.number}?#{query}"
  end

  # The ticket's base moved to `sha`, so that what the branch held before it is not the change.
  defp set_base!(ticket, sha) do
    ticket |> Ecto.Changeset.change(base_commit: sha) |> Forge.Repo.update!()
  end

  defp present!(ticket, content) do
    {:ok, version} =
      Artifacts.record_version(ticket.id, "presentation.md", :presentation, :system, %{
        content: content
      })

    version
  end

  # An operator's decision on one document version, as `Forge.Engine` records one.
  defp approve!(version, user) do
    {:ok, _changes} =
      Ecto.Multi.new()
      |> Artifacts.put_approval(
        :approval,
        version,
        user.id,
        :approved,
        %{"from" => "refining", "to" => "planning"},
        "reads right"
      )
      |> Forge.Repo.transaction()

    :ok
  end
end
