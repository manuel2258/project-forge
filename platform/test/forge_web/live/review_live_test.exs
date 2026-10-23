defmodule ForgeWeb.ReviewLiveTest do
  @moduledoc """
  The merge decision page: the diff beside what the platform knows about the change, and the
  approval that pins an exact commit.
  """

  use ForgeWeb.ConnCase, async: false

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

  test "draws the diff, the documents, the answers and the usage", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "report.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Report\n\nAll tests pass.\n"
      })

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "score.ex"
    assert html =~ "def persist"
    assert html =~ "report.md"
    assert html =~ "Questions answered"
    assert html =~ "allowance"
    # Dollars appear on no operator surface.
    refute html =~ "$"
  end

  test "the approval pins the changeset version and merges", context do
    %{conn: conn, project: project, ticket: ticket, bare: bare} = context
    {:ok, before} = Git.resolve(bare, "refs/heads/main")
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    commit_message!(ticket, "Persist the scores\n")
    pend_merge(ticket)

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    assert html =~ "Approve changeset v1"

    view
    |> form("#merge-decision form", %{"comment" => "ship it"})
    |> render_submit(%{"decision" => "approved"})

    assert Tickets.get!(ticket.id).state == "merged"
    {:ok, head} = Git.resolve(bare, "refs/heads/main")
    assert {:ok, ^before} = Git.resolve(bare, head <> "^1")
    assert {:ok, "def persist, do: :ok\n"} = Git.show(bare, head, "score.ex")
  end

  # The operator reads what the merge will commit and then confirms; the text is the agent's and
  # this page never offers to change it (`docs/design/ui.md` § Changes). Inside the approval card,
  # which is the one place all four approval surfaces share.
  test "draws the commit message above the approval, read only", context do
    %{conn: conn, project: project, ticket: ticket} = context
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

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    block = view |> element("##{commit_message_id(ticket)}") |> render()

    assert block =~ "Persist the scores"
    assert block =~ "They were lost on restart."
    refute block =~ "outcome: done"
    refute block =~ "---"
    assert block =~ "view only"
    refute block =~ "<textarea"
    refute block =~ "<input"
    assert has_element?(view, ~s(button[value="approved"]))
  end

  # Approving with nothing written for the commit to say parks the ticket in its merging state,
  # so the card draws no Approve — a button that cannot work is worse than none
  # (`docs/design/ui.md` § Changes).
  test "says there is nothing to merge yet, and offers no approval", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    block = view |> element("##{commit_message_id(ticket)}") |> render()

    assert block =~ "nothing to merge yet"
    refute block =~ "view only"
    refute has_element?(view, ~s(button[value="approved"]))
    # Reject still is: a ticket nobody wrote a message for is one to send back.
    assert has_element?(view, ~s(button[value="rejected"]))
  end

  test "says so plainly when no job has produced a changeset", context do
    %{conn: conn, project: project, ticket: ticket} = context

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "No job has produced a changeset"
  end

  # The page marks each document with whether it was approved, and that mark is the operator's
  # only record on this page that a person signed the chain off rather than an agent writing it.
  # Nothing asserted it: the existing test checks that `report.md` is listed, which it is whether
  # the mark is there, missing or on the wrong document. Placement matters as much as presence —
  # `docs/design/ui.md` § Semantics that must not be lost — so the mark is looked for inside the
  # row of the document it belongs to, with the other document beside it left unmarked.
  # The page hands what it does not match to `Operator.Actions`, which hands the question form's
  # events to the form. The page draws no form, but the event can still be sent to it, and a result
  # it had no clause for took the page down.
  test "a question form's event, sent to a page that draws none, is ignored", context do
    %{conn: conn, project: project, ticket: ticket} = context
    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    render_change(view, "form:change", %{"form" => "x", "answers" => %{}})
    render_click(view, "form:open", %{"form" => "x", "key" => "k"})

    assert render(view) =~ ticket.title
  end

  test "a document is marked approved only once somebody has approved it", context do
    %{conn: conn, project: project, ticket: ticket, scope: scope} = context
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

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    refute has_element?(view, ~s([id="review-doc-refinement.md"] .text-success))

    approve!(refinement, scope.user)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    assert has_element?(view, ~s([id="review-doc-refinement.md"] .text-success), "approved")
    refute has_element?(view, ~s([id="review-doc-report.md"] .text-success))
  end

  # `docs/design/ui.md` § Documents and § Artifact types: a document is drawn as what its name
  # says it is — Markdown rendered, a log as it was written — and its row carries its type.
  test "draws each document as its type, a log as it was written", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    for {name, content} <- [{"report.md", "# Report\n"}, {"check.log", "# step 1\nok\n"}] do
      {:ok, _version} =
        Artifacts.record_version(ticket.id, name, :document, :system, %{content: content})
    end

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert has_element?(view, ~s([id="review-doc-report.md"] summary [data-file-type="markdown"]))
    assert has_element?(view, ~s([id="review-doc-report.md"] h1), "Report")

    assert has_element?(view, ~s([id="review-doc-check.log"] summary [data-file-type="log"]))
    assert view |> element(~s([id="review-doc-check.log"] pre)) |> render() =~ "# step 1\nok\n"
    refute has_element?(view, ~s([id="review-doc-check.log"] h1))

    # The page reloads on every change to its ticket; a document the reader opened stays open.
    mounted = view |> element(~s([id="review-doc-report.md"])) |> render()
    assert mounted =~ ~s(phx-mounted="[[&quot;ignore_attrs&quot;)
  end

  # `docs/design/ui.md` § Changes: a presentation is the reasoning the patch cannot carry, so it is
  # drawn before the diff, open, dashed and `view only`, and never with an approval slot.
  test "a presentation is shown before the diff, view only", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, "---\noutcome: done\n---\nI moved the table into the database.\n")

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "Presented"
    assert has_element?(view, ~s([id="review-presentation-presentation.md"] .doc))
    assert render(view) =~ "I moved the table into the database."

    row = view |> element(~s([id="review-presentation-presentation.md"])) |> render()
    assert row =~ "view only"
    assert row =~ "border-dashed"
    refute row =~ "approved"

    # It is not one of the documents the change was built from: those are a contract between
    # states, and this is consumed by nobody.
    refute has_element?(view, ~s([id="review-doc-presentation.md"]))
  end

  test "a ticket with no presentation reviews as it did before", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    refute html =~ "Presented"
    refute has_element?(view, ~s([id="review-presentations"]))
  end

  # The whole of what the quoting convention buys: the lines the prose is about, from the
  # changeset's own commit, beneath the paragraph that named them — not a link into the diff.
  test "a quoted line range draws those exact lines from the changeset", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\nfour\nfive\n")
    changeset!(ticket, sha)
    present!(ticket, "The interesting part is `score.ex:2-3`, which is new.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    quoted = view |> element(~s([id="review-presentation-presentation.md"] pre)) |> render()
    assert quoted =~ "two\nthree"
    refute quoted =~ "one"
    refute quoted =~ "four"
    assert render(view) =~ "score.ex:2-3"
  end

  test "a single quoted line draws that line alone", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\n")
    changeset!(ticket, sha)
    present!(ticket, "Look at `score.ex:3`.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    quoted = view |> element(~s([id="review-presentation-presentation.md"] pre)) |> render()
    assert quoted =~ "three"
    refute quoted =~ "two"
  end

  # The prose is an agent's and unbounded, so every way a quote can fail to resolve is a note on
  # the page. A raise here would take down the surface merges are approved on.
  test "a quote that does not resolve degrades to a note", context do
    %{conn: conn, project: project, ticket: ticket} = context
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

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
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
    refute has_element?(view, ~s([id="review-presentation-presentation.md"] pre))
  end

  # The last line of a file is drawn, and the cap is drawn right up to its boundary: a test that
  # only ever asks for the middle of a file, or for a range far past the cap, says nothing about
  # either edge.
  test "the last line and a range of exactly the cap are drawn", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..61, "\n", &"line #{&1}"))
    changeset!(ticket, sha)

    present!(ticket, """
    The last line is `score.ex:61`.

    Exactly the cap: `score.ex:1-60`.

    One more than the cap: `score.ex:1-61`.
    """)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    drawn = view |> element(~s([id="review-presentation-presentation.md"])) |> render()

    assert drawn =~ "line 61"
    assert drawn =~ "score.ex:1-60"
    refute drawn =~ "score.ex:1-60 is too much"
    assert drawn =~ "score.ex:1-61 is too much to draw here"
  end

  # The slice is taken after the cache returns, so what the cache holds is the whole file: keyed by
  # anything but the path — a constant, say — it would serve one file's lines under another's
  # label, which is what the two-file case below holds. (Keying it by the quote instead would be
  # correct and merely wasteful, so that is not what this guards.) That the file is read once
  # rather than three times is not observable from here, and the comment at the code says so.
  test "two ranges of one file each draw their own lines", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo\nthree\nfour")
    changeset!(ticket, sha)
    present!(ticket, "First `score.ex:1`, then `score.ex:3-4`.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert pres(view) == ["one", "three\nfour"]
  end

  # Two files in one presentation, which nothing else here does: every other case quotes ranges of
  # `score.ex`, and a cache that returned any file's content for any path would pass all of them.
  test "two different files each draw their own content", context do
    %{conn: conn, project: project, ticket: ticket} = context
    commit_on_branch(context, "a.ex", "alpha")
    sha = commit_on_branch(context, "b.ex", "beta")
    changeset!(ticket, sha)
    present!(ticket, "First `a.ex:1`, then `b.ex:1`.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

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
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "logo.png", <<137, 80, 78, 71, 0, 255, 254>>)
    changeset!(ticket, sha)
    present!(ticket, "The icon is `logo.png:1`.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    html = render(view)

    assert html =~ "logo.png:1 is not text; read it in the diff"
    assert pres(view) == []
    # What the socket's serializer does with the rendered tree, which `Phoenix.LiveViewTest`
    # never does: the page is only as safe as its bytes are encodable.
    assert {:ok, _json} = Jason.encode(html)
  end

  # Both caps on size, each at a boundary no line count catches: one minified line is a megabyte,
  # and a file quoted at its first line can still be any size at all. The second is refused
  # before the blob is read rather than after — the cap the `git show` used to be inside of.
  test "a quote is refused for its bytes as well as its lines", context do
    %{conn: conn, project: project, ticket: ticket} = context
    commit_on_branch(context, "min.js", String.duplicate("x", 17_000), "minified")
    sha = commit_on_branch(context, "big.txt", String.duplicate("line\n", 300_000), "big")
    changeset!(ticket, sha)

    present!(ticket, """
    One long line: `min.js:1`.

    A big file, quoted small: `big.txt:1-2`.
    """)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    html = render(view)

    assert html =~ "min.js:1 is too much to draw here"
    assert html =~ "big.txt:1-2 is too much to draw here"
    assert pres(view) == []
  end

  # The prose is an agent's, and `@max_prose_bytes` of it holds some thirteen thousand quotes.
  # Every one of them would be a `pre` of up to 16 KiB built inside `mount/3`, per viewer, and
  # again on every patch of the page; the reads are fewer than that, because a path quoted twice
  # is read once, which is what the cache above is for.
  test "only a bounded number of quotes is drawn, and the rest are counted", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..40, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..20, " ", &"`score.ex:#{&1}`") <> "\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    drawn = view |> element(~s([id="review-presentation-presentation.md"])) |> render()

    assert length(pres(view)) == 12
    assert drawn =~ "8 further quotes are not drawn: a presentation draws at most 12."
  end

  # **The cap counts what is drawn, not what is distinct.** One quote named in forty paragraphs is
  # forty `pre` blocks against one path read, and a cap on distinct quotes bounds the reads and
  # nothing else — which is the half that does not make the page expensive.
  test "the same quote in many paragraphs is capped too", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..10, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..40, "\n\n", fn n -> "Point #{n}: `score.ex:1-5`." end))

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    drawn = view |> element(~s([id="review-presentation-presentation.md"])) |> render()

    assert length(pres(view)) == 12
    assert drawn =~ "28 further quotes are not drawn"
  end

  # One over the cap, which is the only case the singular sentence is written for.
  test "one quote over the cap is counted in the singular", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", Enum.map_join(1..20, "\n", &"line #{&1}"))
    changeset!(ticket, sha)
    present!(ticket, Enum.map_join(1..13, " ", &"`score.ex:#{&1}`") <> "\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    drawn = view |> element(~s([id="review-presentation-presentation.md"])) |> render()

    assert drawn =~ "1 further quote is not drawn: a presentation draws at most 12."
    refute drawn =~ "1 further quotes"
  end

  # A megabyte of `x\n\n` is 300,000 paragraphs, each parsed as Markdown on its own so that what
  # it quotes can be drawn beneath it: ten seconds inside `mount/3`, per viewer. The page draws
  # the beginning and says where the rest is.
  test "a presentation longer than the page draws is cut short, and says so", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)

    present!(
      ticket,
      "The start of it.\n\n" <> String.duplicate("filler\n\n", 12_000) <> "The end of it.\n"
    )

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
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
    %{conn: conn, project: project, ticket: ticket} = context
    commit_on_branch(context, "score.ex", "one\ntwo", "small")
    commit_on_branch(context, "over.txt", at_budget(1), "over")
    sha = commit_on_branch(context, "at.txt", at_budget(0), "at")
    changeset!(ticket, sha)

    present!(ticket, """
    One byte over: `over.txt:1-2`.

    Exactly the budget: `at.txt:1-2`.

    Nothing left for this: `score.ex:1`.
    """)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    html = render(view)

    assert html =~ "over.txt:1-2 is too much to draw here"
    assert pres(view) == ["x\nx"]
    assert html =~ "score.ex:1 is too much to draw here"
  end

  # The prose cap at its boundary in both directions: a test that overshoots it by 90 KB says
  # nothing about where it is.
  test "a presentation of exactly the prose cap is drawn whole", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, String.duplicate("a", 64 * 1024))

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    refute html =~ "longer than the page draws"

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "presentation.md", :presentation, :system, %{
        content: String.duplicate("a", 64 * 1024 + 1)
      })

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    assert html =~ "longer than the page draws"
  end

  # **The cut lands on a whole character.** Every other truncation here cuts at an ASCII boundary,
  # where the function that exists for this does nothing: the first prefix is already valid. Here
  # the cap falls inside a two-byte `é`, so the prefix has to lose that byte and keep the `Z`
  # before it — one byte further back and the marker goes with it, and a page of invalid UTF-8 is
  # what the socket's serializer raises on.
  test "a presentation cut short mid-character keeps the character before it", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    present!(ticket, String.duplicate("a", 64 * 1024 - 2) <> "Zé and the rest of it")

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

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

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "aQ"
    refute html =~ "the rest of it"
  end

  # Seven digits is every line of every file anyone has; the eighth stops it being a quote at all,
  # so there is no note either — the prose keeps the words it wrote and the page does no work.
  test "a line number past the pattern's bound is not a quote", context do
    %{conn: conn, project: project, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "one\ntwo")
    changeset!(ticket, sha)
    present!(ticket, "Eight digits: `score.ex:12345678`. Seven: `score.ex:1234567`.\n")

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")
    html = render(view)

    assert pres(view) == []
    # The seven-digit one is a quote and says it does not resolve; the eight-digit one is prose.
    assert html =~ "score.ex:1234567 is not in this changeset"
    refute html =~ "score.ex:12345678 is not in this changeset"
  end

  # "Newest material last" is the comment's claim and every other test records one presentation,
  # which says nothing about the order of two.
  test "presentations are drawn oldest first", context do
    %{conn: conn, project: project, ticket: ticket} = context
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

    {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert [%{name: "zebra.md"}, %{name: "alpha.md"}] =
             html
             |> Floki.parse_document!()
             |> Floki.find(~s([id^="review-presentation-"]))
             |> Enum.map(
               &%{
                 name:
                   &1
                   |> Floki.attribute("id")
                   |> hd()
                   |> String.trim_leading("review-presentation-")
               }
             )
  end

  # The section sits above the diff, so it is drawn on a ticket that has no changeset at all —
  # there is then no commit to resolve a quote against, and that is a note like any other.
  test "a presentation is shown, and its quotes noted, with no changeset yet", context do
    %{conn: conn, project: project, ticket: ticket} = context
    present!(ticket, "Before any of it: `score.ex:1`.\n")

    {:ok, view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}/review")

    assert html =~ "No job has produced a changeset"
    assert render(view) =~ "Before any of it"
    assert render(view) =~ "score.ex:1 is not in this changeset&#39;s commit"
  end

  test "the queue links to it only for an approval that pins the changeset", context do
    %{conn: conn, ticket: ticket} = context
    sha = commit_on_branch(context, "score.ex", "def persist, do: :ok")
    changeset!(ticket, sha)
    pend_merge(ticket)

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Read the change first"
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

  # The text of every quote the presentation drew, in the order it drew them.
  defp pres(view) do
    view
    |> element(~s([id="review-presentation-presentation.md"]))
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("pre")
    |> Enum.map(&Floki.text/1)
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
