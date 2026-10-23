defmodule ForgeWeb.TicketWorkScreenTest do
  @moduledoc """
  A ticket as a work screen (`docs/design/ui.md` § The work screen, § Decide and Timeline):
  which tab it opens on, what Decide holds and counts, the ticket's conversations on its
  timeline, the change and its approval on Changes, *Ask about this* going to a conversation, and
  the running job's activity arriving while the page is open — here and on the job page.
  """

  use ForgeWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Forge.GitFixtures
  import Forge.MergeFixtures
  import ForgeWeb.Operator.Components, only: [commit_message_id: 1]

  alias Forge.{Artifacts, Conversations, Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "tw-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    %{project: project, ticket: ticket}
  end

  defp page(project, ticket, query \\ ""),
    do: "/tickets/#{project.name}/#{ticket.number}" <> query

  defp ask!(ticket, job, blocks) do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
        content: "---\noutcome: done\n---\n# Refinement\n\n" <> Enum.join(blocks, "\n")
      })
  end

  defp blocking(key),
    do:
      "```question\nkey: #{key}\ntext: Which #{key}?\noptions: [{label: a, detail: About a}, {label: b, detail: About b}]\nblocking: true\n```\n"

  # With an anchor, so "drawn without accent" is asked of a question that has one to draw.
  defp non_blocking(key),
    do:
      "```question\nkey: #{key}\nanchor: \"The #{key} passage\"\ntext: Which #{key}?\n" <>
        "options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]\n" <>
        "blocking: false\nassumption: went with a\n```\n"

  # A question is drawn in its document version's form, under that version and its key.
  defp question(ticket, key) do
    q = ticket.id |> Artifacts.open_questions() |> Enum.find(&(&1.key == key))
    "#question-#{q.artifact_version_id}-#{key}"
  end

  defp running!(job) do
    {:ok, job} = job |> Jobs.Job.progress_changeset(%{status: :running}) |> Forge.Repo.update()
    job
  end

  defp head_of(project),
    do: elem(Forge.Git.resolve(Projects.repo_path(project), "refs/heads/main"), 1)

  defp tool(job, id, command),
    do:
      :ok =
        Jobs.record_harness_event(job.id, %{
          type: "job.harness.tool_use",
          payload: %{id: id, name: "Bash", input: %{"command" => command}}
        })

  defp count(view, tab) do
    [_whole, n] = Regex.run(~r/>\s*(\d+)\s*</, view |> element("#tab-#{tab}") |> render())
    String.to_integer(n)
  end

  defp found(view, selector, within) do
    view |> element(within) |> render() |> Floki.parse_fragment!() |> Floki.find(selector)
  end

  describe "the tab it opens on" do
    test "is Decide while something waits on you", %{conn: conn, project: project, ticket: ticket} do
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-decide[aria-current="page"]))
      assert has_element?(view, "#approval-#{ticket.id}")
    end

    test "is the Timeline otherwise", %{conn: conn, project: project, ticket: ticket} do
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, ~s(#tab-timeline[aria-current="page"]))
      assert has_element?(view, "#timeline")
    end

    test "is the one the URL names", %{conn: conn, project: project, ticket: ticket} do
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      assert has_element?(view, ~s(#tab-docs[aria-current="page"]))
      refute has_element?(view, "#approval-#{ticket.id}")
    end
  end

  describe "Decide" do
    # What the queue would count for this ticket, from the queue's own reading of it.
    test "counts what the queue counts for the ticket", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert view |> element("#tab-decide") |> render() =~ ~r/opacity-40[^>]*>\s*0\s*</

      pend_merge(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert view |> element("#tab-decide") |> render() =~ ~r/>\s*1\s*</
    end

    # Decide is the third of the four surfaces an approval card is drawn on, and approving the
    # changeset here merges as it does anywhere else (`docs/design/ui.md` § Changes).
    test "shows the message the merge would commit, and no Approve without one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      changeset!(ticket, head_of(project))
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert view |> element("##{commit_message_id(ticket)}") |> render() =~
               "nothing to merge yet"

      refute has_element?(view, ~s(#decide button[value="approved"]))

      commit_message!(ticket, "Persist the scores\n")
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert view |> element("##{commit_message_id(ticket)}") |> render() =~ "Persist the scores"
      assert has_element?(view, ~s(#decide button[value="approved"]))
    end

    # An assumption is in the queue and waits on nobody, so it is in no count of what waits.
    test "does not count an assumption", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
          content: """
          ---
          outcome: done
          ---
          # Refinement

          ```question
          key: backend
          text: Which backend?
          options: [{label: a, detail: About a}, {label: b, detail: About b}]
          blocking: true
          ```

          ```question
          key: naming
          text: Which naming?
          options: [{label: a, detail: About a, recommended: true}, {label: b, detail: About b}]
          blocking: false
          assumption: went with a
          ```
          """
        })

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert view |> element("#tab-decide") |> render() =~ ~r/>\s*1\s*</
    end

    # An assumption is answered here — the queue's digest sends it here — but nothing waits on
    # the answer, so it is not under "Waiting on you" and it draws no accent. Asked beside a
    # blocking question, it is in that document's form instead, optional
    # (`docs/design/ui.md` § Answering questions).
    test "keeps an assumption apart from what waits", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      ask!(ticket, job, [non_blocking("naming")])

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-timeline[aria-current="page"]))

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=decide"))
      assert has_element?(view, "#nothing-to-decide")
      refute has_element?(view, "#hoisted-decision")
      assert has_element?(view, "#assumed " <> question(ticket, "naming"))

      # Opened, so its passage is drawn — and drawn without accent too.
      view |> element("#assumed button[phx-click='form:open']") |> render_click()
      assert view |> element("#assumed") |> render() =~ "The naming passage"
      refute view |> element("#assumed") |> render() =~ "accent"

      ask!(ticket, job, [blocking("backend"), non_blocking("naming")])
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#hoisted-decision " <> question(ticket, "backend"))
      assert has_element?(view, "#hoisted-decision " <> question(ticket, "naming"))
      refute has_element?(view, "#assumed")
    end

    # A form of assumptions only has nothing it must wait for — but nothing to send either, until
    # one is answered: an untouched one is not a Send of nothing.
    test "a form of assumptions waits for its first answer", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)

      ask!(ticket, job, [
        "```question\nkey: naming\ntext: Which naming?\n" <>
          "options: [{label: a, detail: About a}, {label: b, detail: About b}]\n" <>
          "blocking: false\nassumption: went with a\n```\n"
      ])

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=decide"))
      assert has_element?(view, "#assumed button[type=submit][disabled]")

      view
      |> element("#assumed form")
      |> render_change(%{
        "_target" => ["answers", "naming", "choice"],
        "answers" => %{"naming" => %{"choice" => "b", "text" => ""}}
      })

      refute has_element?(view, "#assumed button[type=submit][disabled]")
    end

    # Oldest version first, so the document a job stopped on longest ago is at the top.
    test "draws the forms of two documents oldest first", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, older} =
        Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
          content: "# Plan\n\n" <> blocking("backend")
        })

      {:ok, newer} =
        Artifacts.record_version(ticket.id, "notes.md", :document, {:job, job.id}, %{
          content: "# Notes\n\n" <> blocking("format")
        })

      Forge.Repo.update_all(
        from(q in Forge.Artifacts.Question, where: q.artifact_version_id == ^older.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]
      )

      {:ok, _view, html} = live(conn, page(project, ticket, "?tab=decide"))

      [{o, _}] = :binary.matches(html, "form-#{older.id}") |> Enum.take(1)
      [{n, _}] = :binary.matches(html, "form-#{newer.id}") |> Enum.take(1)
      assert o < n
    end

    test "with nothing waiting, says so and what would put something there", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=decide"))

      assert has_element?(view, "#nothing-to-decide", "Nothing here is waiting on you")
    end
  end

  describe "the Timeline" do
    # A conversation started from a ticket was findable from the project page and not from the
    # ticket it is about. Live first, because that is the one costing something.
    test "lists the ticket's conversations, live first", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, ended} = Conversations.open(project, "the old question", ticket: ticket)
      {:ok, _ended} = Conversations.ended(ended, nil, "idle")
      {:ok, live_one} = Conversations.open(project, "the new question", ticket: ticket)
      {:ok, _other} = Conversations.open(project, "about the project")

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=timeline"))
      chats = view |> element("#ticket-chats") |> render()

      assert chats =~ "/chats/#{live_one.id}"
      assert chats =~ "/chats/#{ended.id}"
      refute chats =~ "about the project"

      [first | _rest] = Regex.scan(~r"/chats/([0-9a-f-]{36})", chats, capture: :all_but_first)
      assert first == [live_one.id]
    end
  end

  describe "Changes" do
    setup %{project: project, ticket: ticket} do
      sha = commit_over_http(project, ticket.branch, "lib/score.ex", "def persist, do: :ok")
      %{sha: sha}
    end

    test "draws what the branch holds against its base, and its commits", %{
      conn: conn,
      project: project,
      ticket: ticket,
      sha: sha
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      assert has_element?(view, ~s(#changes-files li[data-path="lib/score.ex"]))
      assert has_element?(view, "#context-strip", ~r/\+1 −0 over 1 file\b/)
      assert view |> element("#commits") |> render() =~ String.slice(sha, 0, 7)
    end

    # Reading a change and approving it are adjacent — and only when the approval is what the
    # ticket waits on.
    test "carries the changeset approval at its foot, when that is what waits", %{
      conn: conn,
      project: project,
      ticket: ticket,
      sha: sha
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))
      refute has_element?(view, "#changes-approval")

      # An approval of something else is Decide's, not the diff's.
      {:ok, _ticket} =
        ticket
        |> Ecto.Changeset.change(
          pending_transition: %{
            "from" => "refining",
            "to" => "planning",
            "outcome" => nil,
            "approve" => ["refinement.md"]
          }
        )
        |> Forge.Repo.update()

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))
      refute has_element?(view, "#changes-approval")

      changeset!(ticket, sha)
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      # Nothing has written what the merge would say, so this surface offers no Approve either
      # (`docs/design/ui.md` § Changes).
      assert has_element?(view, "#changes-approval ##{commit_message_id(ticket)}")
      refute has_element?(view, ~s(#changes-approval button[value="approved"]))

      commit_message!(ticket, "Persist the scores\n")
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      assert has_element?(
               view,
               "#changes-approval #approval-#{ticket.id}",
               "Approve changeset v1"
             )

      # The operator reads what the merge will commit on this surface too, not only on the
      # review page.
      assert view |> element("#changes-approval ##{commit_message_id(ticket)}") |> render() =~
               "Persist the scores"

      # The card draws a pinned document, not a changeset: the diff above it is its rendering.
      # The commit message's own block is the other section in the card, so this asks for the
      # box a pin would be drawn in by its own id.
      refute has_element?(view, "#approving-#{ticket.id}-changeset")

      assert has_element?(view, ~s(#changes a[href="#{page(project, ticket, "/review")}"]))
    end

    # There is no composer on a ticket, so the reference goes to one: the ticket's live
    # conversation when there is one, a new conversation about the ticket when there is not.
    # Nothing is sent either way.
    test "asks about a hunk in a new conversation when none is live", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      {:error, {:live_redirect, %{to: to}}} =
        view |> element(~s(#changes-files [data-hunk="1"] button)) |> render_click()

      assert to =~ "/chats/new?"
      assert to =~ "ticket=#{ticket.number}"
      assert URI.decode_query(URI.parse(to).query)["text"] == "lib/score.ex:1"

      {:ok, new_chat, _html} = live(conn, to)
      assert new_chat |> element("#chat_text") |> render() =~ "lib/score.ex:1"
      assert Jobs.chats_for_ticket(ticket.id) == []
    end

    test "counts on its tab the files it lists", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      commit_over_http(project, ticket.branch, "lib/rank.ex", "def rank, do: 1")
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      assert length(found(view, "li[data-path]", "#changes-files")) == 2
      assert count(view, "changes") == 2
    end

    # A conversation that has ended has no composer to put the reference in.
    test "asks about a hunk in a new conversation when the only one has ended", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, chat} = Conversations.open(project, "the old question", ticket: ticket)
      {:ok, _ended} = Conversations.ended(chat, nil, "idle")
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      {:error, {:live_redirect, %{to: to}}} =
        view |> element(~s(#changes-files [data-hunk="1"] button)) |> render_click()

      assert URI.parse(to).path == "/chats/new"
    end

    test "asks about a hunk in the ticket's live conversation", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, chat} = Conversations.open(project, "about the score", ticket: ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))

      {:error, {:live_redirect, %{to: to}}} =
        view |> element(~s(#changes-files [data-hunk="1"] button)) |> render_click()

      assert URI.parse(to).path == "/chats/#{chat.id}"

      {:ok, talk, _html} = live(conn, to)
      assert talk |> element("#draft") |> render() =~ "lib/score.ex:1"
      assert length(Conversations.messages(chat.id)) == 1
    end
  end

  describe "Docs" do
    test "renders the ticket's documents", %{conn: conn, project: project, ticket: ticket} do
      {:ok, _v1} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# Plan\n"})

      {:ok, _v2} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
          content: "# Better plan\n"
        })

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      docs = view |> element("#docs") |> render()

      assert docs =~ "<h1>Better plan</h1>"
      assert has_element?(view, ~s(#docs a[href$="/artifacts/plan.md/1"]), "v1")
    end

    # The latest is the one drawn; the rest are linked, the newest of them first.
    test "links the earlier versions newest first, and not the latest", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      for n <- 1..3 do
        {:ok, _version} =
          Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
            content: "# Plan #{n}\n"
          })
      end

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      links = found(view, ~s(section[id="doc-plan.md"] a), "#docs")

      assert Enum.map(links, &String.trim(Floki.text(&1))) == ["v3 ›", "v2", "v1"]

      # Each to its own version's address: the latest's link is the latest's.
      assert links |> Enum.flat_map(&Floki.attribute(&1, "href")) |> Enum.map(&Path.basename/1) ==
               ["3", "2", "1"]
    end

    # `docs/design/ui.md` § Docs: collapsed until it is opened, so one long plan does not push
    # every row after it a screen down; left as the reader left it by a patch; and its version
    # linked beside the summary, never inside the control that opens it.
    test "draws a document collapsed, with its version beside the row", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _v1} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# Plan\n"})

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      assert [details] = found(view, ~s(section[id="doc-plan.md"] > details), "#docs")
      assert Floki.attribute(details, "open") == []
      assert [mounted] = Floki.attribute(details, "phx-mounted")
      assert mounted =~ "ignore_attrs"
      assert mounted =~ "open"

      assert details |> Floki.find("summary") |> Floki.text() =~ "plan.md"
      assert Floki.raw_html(details) =~ "<h1>Plan</h1>"

      assert Floki.find(details, "a") == []
      assert [link] = found(view, ~s(section[id="doc-plan.md"] > a), "#docs")

      assert Floki.attribute(link, "href") == [
               "/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md/1"
             ]

      # "v1" alone says nothing to a screen reader, out of the row it sits beside.
      assert Floki.attribute(link, "aria-label") == ["plan.md v1"]
    end

    # A presentation is not rendered and has no approval slot (`ui.md` § Semantics that must not
    # be lost): its row is its link, marked view only.
    test "draws a presentation as its link, view only", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _deck} =
        Artifacts.record_version(ticket.id, "deck", :presentation, :system, %{content: "# Deck\n"})

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      assert found(view, ~s(section[id="doc-deck"] details), "#docs") == []
      assert [link] = found(view, ~s(section[id="doc-deck"] > a), "#docs")
      assert Floki.text(link) =~ "view only"
      refute Floki.raw_html(link) =~ "<h1>"
    end

    # Markdown would join a log's lines into one paragraph and make a heading of a `#` comment.
    test "shows a document named as text as it was written", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _notes} =
        Artifacts.record_version(ticket.id, "notes.txt", :document, :system, %{
          content: "# not a heading\nsecond line\n"
        })

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      assert [pre] = found(view, ~s(section[id="doc-notes.txt"] details pre), "#docs")
      assert Floki.text(pre) == "# not a heading\nsecond line\n"
      refute view |> element(~s(section[id="doc-notes.txt"])) |> render() =~ "<h1>"
    end

    # `docs/design/ui.md` § Artifact types: each row says what kind of file it is. A file has no
    # body — drawing its row reads nothing from the store — so its whole row is the link to its
    # bytes; and an Android app says so in words as well as by its icon.
    test "marks each row with its type, and a file's row is its link", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _plan} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# P\n"})

      blobs = ~w(build.log package/app.apk shots/home.png package/manifest)

      for name <- blobs do
        key = "job/#{Ecto.UUID.generate()}/out-a/#{Path.basename(name)}"

        {:ok, _version} =
          Artifacts.record_version(ticket.id, name, :blob, :system, %{
            blob_uri: Forge.Storage.uri(key),
            content_hash: "sha256:" <> String.duplicate("0", 64)
          })
      end

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      types =
        for name <- ["plan.md" | blobs] do
          view
          |> found(~s(section[id="doc-#{name}"] [data-file-type]), "#docs")
          |> Floki.attribute("data-file-type")
        end

      assert types == [["markdown"], ["log"], ["apk"], ["image"], ["file"]]

      for name <- blobs do
        assert found(view, ~s(section[id="doc-#{name}"] details), "#docs") == []
      end

      assert [apk] = found(view, ~s(section[id="doc-package/app.apk"] > a), "#docs")

      assert Floki.attribute(apk, "href") == [
               "/tickets/#{project.name}/#{ticket.number}/artifacts/package%2Fapp.apk/1"
             ]

      assert Floki.find(apk, ~s([role="img"][aria-label="Android app"])) != []
      assert Floki.text(apk) =~ "Android app"
      # Said once to a screen reader, by the icon, rather than again by the caption.
      hidden =
        apk |> Floki.find(~s(span[aria-hidden="true"])) |> Enum.map(&String.trim(Floki.text(&1)))

      assert "Android app" in hidden

      refute view |> element(~s(section[id="doc-shots/home.png"])) |> render() =~ "Android app"
    end

    # The ticket's chips are its artifacts too, and carry the same mark.
    test "marks the rail's artifact chips with their type", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _plan} =
        Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{content: "# P\n"})

      # The changeset is a commit and not a file, and says so.
      sha = commit_over_http(project, ticket.branch, "lib/score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      # The chip's own size, smaller than a row's tile.
      assert has_element?(
               view,
               ~s(#details a[href$="/artifacts/plan.md/1"] [data-file-type="markdown"].size-5)
             )

      assert has_element?(
               view,
               ~s(#details a[href$="/artifacts/changeset/1"] [data-file-type="changeset"]),
               "±"
             )
    end

    # Approval is marked only where the workflow can ask for it, and says which way it stands.
    test "marks a document the workflow approves as unapproved, then approved", %{
      conn: conn,
      project: project,
      ticket: ticket,
      user: user
    } do
      {:ok, refinement} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "# Refinement\n"
        })

      {:ok, _notes} =
        Artifacts.record_version(ticket.id, "notes.md", :document, :system, %{content: "# N\n"})

      mark = fn view, name ->
        view |> found(~s(section[id="doc-#{name}"] span), "#docs") |> Enum.map(&Floki.text/1)
      end

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      assert "◇ unapproved" in mark.(view, "refinement.md")
      refute Enum.any?(mark.(view, "notes.md"), &(&1 =~ "approved"))

      {:ok, _} =
        Ecto.Multi.new()
        |> Artifacts.put_approval(
          :approval,
          refinement,
          user.id,
          :approved,
          %{"from" => "refining", "to" => "planning"},
          nil
        )
        |> Forge.Repo.transaction()

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      assert "✓ approved" in mark.(view, "refinement.md")
    end

    # The changeset is a commit, and it is what Changes draws. Docs is what was written.
    test "counts the documents, and the changeset is not one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      sha = commit_over_http(project, ticket.branch, "lib/score.ex", "def persist, do: :ok")
      changeset!(ticket, sha)

      for name <- ~w(plan.md notes.md) do
        {:ok, _version} =
          Artifacts.record_version(ticket.id, name, :document, :system, %{content: "# #{name}\n"})
      end

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      sections = found(view, "section", "#docs")

      assert "doc-plan.md" in Enum.flat_map(sections, &Floki.attribute(&1, "id"))
      refute "doc-changeset" in Enum.flat_map(sections, &Floki.attribute(&1, "id"))
      assert count(view, "docs") == length(sections)
    end
  end

  describe "Activity" do
    # A ticket's running job streams to its work screen: someone reading it is deciding whether
    # to wait, answer or steer (`ui.md` § Motion and structure).
    test "is live for the ticket's running job", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))
      refute render(view) =~ "mix test"

      tool(job, "b1", "mix test")
      assert view |> element("#job-events") |> render() =~ "$ mix test"
    end

    # The rail's latest events are the ticket's, and a running job's stream is some of them.
    test "keeps the rail's latest events current while the job runs", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

      tool(job, "b1", "mix test")

      assert view |> element("#details") |> render() =~ "job.harness.tool_use"
    end

    # The count on the tab is what the tab draws: a call and its result are one row.
    test "counts on its tab the rows it draws", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      tool(job, "b1", "mix test")

      :ok =
        Jobs.record_harness_event(job.id, %{
          type: "job.harness.tool_result",
          payload: %{tool_use_id: "b1", is_error: false, excerpt: "ok", bytes: 2}
        })

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

      rows = found(view, "li", "#job-events")
      assert rows != []
      assert count(view, "activity") == length(rows)
    end

    # Subscribed before the stream is read, an event can be both read and heard.
    test "draws an event it already has once", %{conn: conn, project: project, ticket: ticket} do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      tool(job, "b1", "mix compile")
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

      [event] =
        job.id |> Forge.Events.for_job() |> Enum.filter(&(&1.type == "job.harness.tool_use"))

      send(view.pid, {:job_event, job.id, event})

      assert [_once] = Regex.scan(~r/\$ mix compile/, view |> element("#job-events") |> render())

      assert [_once] =
               Regex.scan(~r/job\.harness\.tool_use/, view |> element("#details") |> render())
    end

    # A ticket moves on to a new job, and the page moves with it: what the new job does is what
    # the page streams, without being opened again.
    test "follows the ticket onto its next job", %{conn: conn, project: project, ticket: ticket} do
      [first] = Jobs.for_ticket(ticket.id)
      running!(first)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

      {:ok, %{next: next}} =
        Ecto.Multi.new()
        |> Jobs.put_create(:next, ticket, Tickets.workflow(ticket), ticket.state)
        |> Forge.Repo.transaction()

      Forge.Events.notify(ticket.id)
      # The page has taken the change in before the new job says anything.
      _html = render(view)

      running!(next)
      tool(next, "n1", "mix next")

      assert view |> element("#job-events") |> render() =~ "$ mix next"
    end

    test "is not woken by another ticket's job", %{conn: conn, project: project, ticket: ticket} do
      {:ok, other} = Tickets.admit(project, %{title: "Elsewhere"}, :system)
      [job] = Jobs.for_ticket(other.id)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))
      tool(job, "b1", "mix elsewhere")
      refute render(view) =~ "mix elsewhere"

      # Nor by one arriving from a topic it is not following — the job it followed before the
      # ticket moved on, whose last events can still be in flight.
      [event] = Forge.Events.for_job(job.id) |> Enum.filter(&(&1.type == "job.harness.tool_use"))
      send(view.pid, {:job_event, job.id, event})
      refute render(view) =~ "mix elsewhere"
    end
  end

  test "the job page draws an event it already has once", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    [job] = Jobs.for_ticket(ticket.id)
    running!(job)
    tool(job, "b1", "mix compile")
    {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{job.id}"))

    [event] =
      job.id |> Forge.Events.for_job() |> Enum.filter(&(&1.type == "job.harness.tool_use"))

    send(view.pid, {:job_event, job.id, event})

    assert [_once] = Regex.scan(~r/\$ mix compile/, view |> element("#job-events") |> render())
  end

  # A page at a time, on the ticket's Activity and on the job page alike: more is a tap away,
  # and the tap shows the next page.
  test "the ticket and the job page load the stream a page at a time", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    [job] = Jobs.for_ticket(ticket.id)
    running!(job)

    for n <- 1..(ForgeWeb.JobStream.page() + 5) do
      :ok =
        Jobs.record_harness_event(job.id, %{type: "job.harness.text", payload: %{text: "#{n}"}})
    end

    for path <- [page(project, ticket, "?tab=activity"), page(project, ticket, "/jobs/#{job.id}")] do
      {:ok, view, _html} = live(conn, path)
      assert length(found(view, "li", "#job-events")) == ForgeWeb.JobStream.page()

      view |> element(~s(button[phx-click="more"])) |> render_click()

      assert length(found(view, "li", "#job-events")) > ForgeWeb.JobStream.page()
      refute has_element?(view, ~s(button[phx-click="more"]))
    end
  end

  # `docs/design/capacity.md` § Memory, which a job holds rather than spends: under the outcome,
  # only when memory was the trouble, and its rows in the timeline with their type in `warning`.
  test "the job page says memory was the trouble, and only when it was", %{
    conn: conn,
    project: project,
    ticket: ticket
  } do
    [job] = Jobs.for_ticket(ticket.id)
    running!(job)
    tool(job, "b1", "gradle build")

    {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{job.id}"))
    refute has_element?(view, "#job-memory")

    :ok =
      Jobs.record_harness_event(job.id, %{
        type: "job.harness.memory",
        payload: %{
          what: "oom_kill",
          oom_kills: 2,
          new_kills: 2,
          peak: 2 * 1024 ** 3,
          ceiling: 2 * 1024 ** 3
        }
      })

    assert has_element?(view, "#job-memory", "⚠ 2 OOM kills · peak 2.0 GiB of 2 GiB")

    row = view |> element("#job-events li", "a process was killed for memory") |> render()
    assert row =~ ~s(text-warning)
    assert row =~ "(2 OOM kills · peak 2.0 GiB of 2 GiB)"

    # And the other rows are not in warning.
    refute view |> element("#job-events li", "gradle build") |> render() =~ "text-warning"

    # Read again from the log, as a page opened afterwards reads it.
    {:ok, reopened, _html} = live(conn, page(project, ticket, "/jobs/#{job.id}"))
    assert has_element?(reopened, "#job-memory", "2 OOM kills")
  end

  # The job page tails its job while it runs, for the reason the ticket's Activity does.
  test "the job page tails its running job", %{conn: conn, project: project, ticket: ticket} do
    [job] = Jobs.for_ticket(ticket.id)
    running!(job)

    {:ok, view, _html} = live(conn, page(project, ticket, "/jobs/#{job.id}"))
    refute render(view) =~ "mix test"

    tool(job, "b1", "mix test")
    assert view |> element("#job-events") |> render() =~ "$ mix test"
  end

  # `docs/design/ui.md` § Decide and Timeline: a human state's documents are written where the
  # person deciding where the ticket goes next already is.
  describe "a human state's documents" do
    setup %{user: user} do
      workflow =
        File.read!(Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__))
        |> String.replace(
          "  review_ready: {}",
          "  review_ready:\n    produces: [test-report.md]"
        )

      {:ok, project} =
        Projects.register(
          %{
            name: "hd-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
          },
          user
        )

      {:ok, ticket} = Tickets.admit(project, %{title: "Try it"}, {:user, user.id})
      %{project: project, ticket: ticket}
    end

    defp rest_in_review(ticket) do
      {:ok, ticket} =
        ticket |> Ecto.Changeset.change(state: "review_ready") |> Forge.Repo.update()

      ticket
    end

    test "are offered where the ticket rests, and saved as a person's version", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      ticket = rest_in_review(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=decide"))

      assert has_element?(view, "#write-test-report\\.md", "not written yet")

      view
      |> form("#write-test-report\\.md", %{content: "The save button does nothing.\n"})
      |> render_submit()

      assert %{
               version: 1,
               content: "The save button does nothing.\n",
               author: %{"kind" => "user"}
             } =
               Artifacts.latest(ticket.id, "test-report.md")

      assert has_element?(view, "#write-test-report\\.md", "v1")
    end

    # A job state's documents are its job's to write; offering them here would be a person
    # overwriting the contract between two states from a form that does not say so. Stuck, so
    # Decide is drawing — the state again, since `planning` approves a refinement that does not
    # exist yet — and would draw an editor beside it.
    test "are not offered while a job state holds the ticket", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      for job <- Forge.Jobs.for_ticket(ticket.id) do
        job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Forge.Repo.update!()
      end

      {:ok, ticket} = ticket |> Ecto.Changeset.change(status: :stuck) |> Forge.Repo.update()
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=decide"))

      assert has_element?(view, "#retry-#{ticket.id}")
      refute has_element?(view, ~s(form[phx-submit="write_document"]))
    end
  end
end
