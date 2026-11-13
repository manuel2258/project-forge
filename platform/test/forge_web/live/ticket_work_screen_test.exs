defmodule ForgeWeb.TicketWorkScreenTest do
  @moduledoc """
  A ticket in the frame (`docs/design/ui.md` § The ticket): which view it opens on, what Steps
  holds where Decide used to, the ticket's conversations under Steps, the change and its approval
  on Changes, *Ask about this* going to a conversation, and
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

  # A message `ago` seconds old, inserted: events are append-only, so the time is chosen by
  # adding one later in the log, which is what a list reads as the last thing said.
  defp said_at(chat, text, ago) do
    Forge.Repo.insert!(%Forge.Events.Event{
      actor: %{"kind" => "system", "id" => nil},
      type: "chat.message",
      payload: %{"text" => text},
      job_id: chat.id,
      project_id: chat.project_id,
      inserted_at: DateTime.add(DateTime.utc_now(:second), -ago, :second)
    })
  end

  defp chat_order(view) do
    ~r/id="conversation-([0-9a-f-]{36})"/
    |> Regex.scan(render(view))
    |> Enum.map(&List.last/1)
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

  # The row's button drops the panel, which holds the decision's form.
  defp open!(view) do
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    assert has_element?(view, "#decision-panel")
    view
  end

  # A document's approval waiting into planning: Docs is where it is read.
  defp pend_document(ticket) do
    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    ticket
    |> Ecto.Changeset.change(
      status: :active,
      pending_transition: %{
        "from" => "refining",
        "to" => "planning",
        "outcome" => "done",
        "approve" => ["refinement.md"]
      }
    )
    |> Forge.Repo.update!()
  end

  describe "the view it opens on" do
    test "is Changes while a changeset approval waits", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-changes[aria-current="page"]))
      assert has_element?(view, "#changes")
    end

    # Not only a merge: an approval of the changeset into a state that does not merge is read on
    # Changes too.
    test "is Changes for a changeset approval that does not merge", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      changeset!(ticket, head_of(project))

      ticket
      |> Ecto.Changeset.change(
        state: "implementing",
        status: :active,
        pending_transition: %{
          "from" => "implementing",
          "to" => "verifying",
          "outcome" => nil,
          "approve" => ["changeset"]
        }
      )
      |> Forge.Repo.update!()

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-changes[aria-current="page"]))
    end

    test "is Docs while a document's approval waits", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      pend_document(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-docs[aria-current="page"]))
      assert has_element?(view, "#docs-waiting #doc-refinement\\.md")
    end

    test "is Steps while questions wait, and otherwise", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-steps[aria-current="page"]))
      assert has_element?(view, "#steps")

      [job] = Jobs.for_ticket(ticket.id)
      ask!(ticket, job, [blocking("backend")])

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-steps[aria-current="page"]))
    end

    test "is the one the URL names", %{conn: conn, project: project, ticket: ticket} do
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      assert has_element?(view, ~s(#tab-docs[aria-current="page"]))
      refute has_element?(view, "#changes")
    end

    # The Decide tab is gone, and a link to it — a push sent before it went, a bookmark — lands
    # where what waits is, as any view the ticket does not have does.
    test "is the default for a view the ticket no longer has", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      pend_merge(ticket)

      for gone <- ~w(decide timeline nonsense) do
        {:ok, view, _html} = live(conn, page(project, ticket, "?tab=#{gone}"))
        assert has_element?(view, ~s(#tab-changes[aria-current="page"]))
        refute has_element?(view, "#tab-#{gone}")
      end
    end
  end

  describe "the current step, where Decide was" do
    # The approval is the decision row, not a card: the current step says where it is, and the
    # panel shows the message the merge would commit (`docs/design/ui.md` § The decision row).
    test "points at the row, whose panel shows the message, and no Approve without one", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      changeset!(ticket, head_of(project))
      pend_merge(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))
      assert has_element?(view, "#steps #approval-pinned", "changeset v1")
      refute has_element?(view, "#steps #decision-form")
      open!(view)

      assert view |> element("##{commit_message_id(ticket)}") |> render() =~
               "nothing to merge yet"

      refute has_element?(view, ~s(#decision-form button[value="approved"]))

      commit_message!(ticket, "Persist the scores\n")
      {:ok, view, _html} = live(conn, page(project, ticket))
      open!(view)

      assert view |> element("##{commit_message_id(ticket)}") |> render() =~ "Persist the scores"
      assert has_element?(view, ~s(#decision-form button[value="approved"]), "Approve v1")
    end

    # Same rule on the ticket's own page: the change is what it opens on because the decision
    # enters a state that merges, not because of what it pins
    # (`Forge.Engine.merge_decision?/2`).
    test "a merging approval of something else still opens on the change", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      changeset!(ticket, head_of(project))

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
          content: "---\noutcome: done\n---\n# Refinement\n"
        })

      ticket
      |> Ecto.Changeset.change(
        state: "review_ready",
        status: :active,
        pending_transition: %{
          "from" => "review_ready",
          "to" => "merged",
          "outcome" => nil,
          "approve" => ["refinement.md"]
        }
      )
      |> Forge.Repo.update!()

      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#changes #changes-switch")
    end

    # The pane goes with its last card. A Send that arrives after the same questions were
    # answered in another tab is refused — and drawn where the pane stood, not nowhere.
    test "a Send whose card has gone since is refused where the pane stood", %{
      conn: conn,
      project: project,
      ticket: ticket,
      user: user
    } do
      [job] = Jobs.for_ticket(ticket.id)
      ask!(ticket, job, [blocking("backend")])
      version = Artifacts.latest(ticket.id, "refinement.md")

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      assert has_element?(view, "#question-pane")

      {:ok, _ticket} =
        Forge.Operator.answer_all(Tickets.get!(ticket.id), user, version.id, %{
          "backend" => %{choice: "a", text: nil}
        })

      render_hook(view, "questions:send", %{
        "form" => version.id,
        "ticket" => ticket.id,
        "version" => version.id,
        "answers" => %{"backend" => %{"choice" => "b", "text" => ""}}
      })

      refute has_element?(view, "#question-pane")
      assert has_element?(view, "#questions-gone-refusal", "Nothing was sent")
    end

    # An assumption is answered here — the queue's digest sends it here — but nothing waits on
    # the answer, so it is under Steps and not in the question pane, and it draws no accent. Asked
    # beside a blocking question, it is in that document's form in the pane instead, optional
    # (`docs/design/ui.md` § The question card).
    test "keeps an assumption apart from what waits", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      ask!(ticket, job, [non_blocking("naming")])

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-steps[aria-current="page"]))
      refute has_element?(view, "#question-pane")
      assert has_element?(view, "#steps #assumed " <> question(ticket, "naming"))

      # Its passage is drawn — and drawn without accent too.
      assert view |> element("#assumed") |> render() =~ "The naming passage"
      refute view |> element("#assumed") |> render() =~ "accent"

      ask!(ticket, job, [blocking("backend"), non_blocking("naming")])
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#question-pane " <> question(ticket, "backend"))
      assert has_element?(view, "#question-pane " <> question(ticket, "naming"))
      refute has_element?(view, "#assumed")

      # On every view: answered from where the person is reading.
      for tab <- ~w(changes docs activity) do
        {:ok, view, _html} = live(conn, page(project, ticket, "?tab=#{tab}"))
        assert has_element?(view, "#question-pane " <> question(ticket, "backend"))
      end
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

      {:ok, view, _html} = live(conn, page(project, ticket))
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

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      html = view |> element("#question-pane") |> render()

      [{o, _}] = :binary.matches(html, "form-#{older.id}") |> Enum.take(1)
      [{n, _}] = :binary.matches(html, "form-#{newer.id}") |> Enum.take(1)
      assert o < n
    end

    # A job is running: nothing waits, so the current step offers nothing and the dock holds
    # only the running job's chip, which opens its page (`5d`) — on Changes and Docs. Steps and
    # Activity lead with the job's own row, so the chip there said it twice (UX pass, B27).
    test "with nothing waiting, offers nothing, and the dock is the job's chip off Steps", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      {:ok, view, _html} = live(conn, page(project, ticket))

      refute has_element?(view, "#ways-forward")
      refute has_element?(view, "#question-pane")
      refute has_element?(view, "#approval-pinned")
      refute has_element?(view, "#job-chip")
      assert has_element?(view, "#job-row-#{job.id}")

      {:ok, activity, _html} = live(conn, page(project, ticket, "?tab=activity"))
      refute has_element?(activity, "#job-chip")

      for tab <- ~w(changes docs) do
        {:ok, view, _html} = live(conn, page(project, ticket, "?tab=#{tab}"))

        assert has_element?(
                 view,
                 ~s(#job-chip[href="#{page(project, ticket, "/jobs/#{job.id}")}"]),
                 "refining #1"
               )
      end

      # Something waiting takes the dock's place from the chip.
      pend_merge(Tickets.get!(ticket.id))
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      refute has_element?(view, "#job-chip")
    end

    # Amber is a person being waited on (`ui.md` § Colour): the current step's dot is info while
    # its job runs, and amber only once something waits — here, the merge decision's row.
    test "draws its dot amber only while the ticket waits on a person", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#steps .ticket-step--current.ticket-step--running")
      refute has_element?(view, "#steps .ticket-step--waiting")

      # A job that stopped to ask waits on a person too.
      {:ok, _job} = job |> Jobs.Job.progress_changeset(%{status: :waiting}) |> Forge.Repo.update()
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, "#steps .ticket-step--current.ticket-step--waiting")

      pend_merge(Tickets.get!(ticket.id))
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))
      assert has_element?(view, "#steps .ticket-step--current.ticket-step--waiting")
    end

    test "draws a ticket that has ended with a muted dot", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      ticket |> Ecto.Changeset.change(state: "merged", status: :done) |> Forge.Repo.update!()
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))
      assert has_element?(view, "#steps .ticket-step--current.ticket-step--ended")
    end
  end

  describe "Steps" do
    # A job that has spent nothing says nothing of it: `0 windows` beside every job that has not
    # started was the figure the row's end gave to nobody (UX pass, A11, B9).
    test "leaves a zero spend out of a job's row and its step", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)
      running!(job)
      {:ok, view, _html} = live(conn, page(project, ticket))

      refute view |> element("#job-row-#{job.id}") |> render() =~ "windows"
      refute view |> element("#step-0 .ticket-step-detail") |> render() =~ "windows"
      assert has_element?(view, "#step-0 .ticket-step-detail", "1 job")

      Forge.Repo.update_all(from(j in Jobs.Job, where: j.id == ^job.id), set: [usage: 300_000])
      {:ok, view, _html} = live(conn, page(project, ticket))
      spent = ForgeWeb.Format.windows(300_000)

      assert has_element?(view, "#job-row-#{job.id} .ticket-job-spent", spent)
      assert has_element?(view, "#step-0 .ticket-step-detail", "1 job · #{spent}")
    end

    # A conversation started from a ticket was findable from the project page and not from the
    # ticket it is about. The live one is a section of its own above, even when the ended one was
    # used more recently; the order within a section is the same one every list has.
    test "lists the ticket's conversations, the live ones in a section above", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, live_one} = Conversations.open(project, "the new question", ticket: ticket)
      {:ok, ended} = Conversations.open(project, "the old question", ticket: ticket)
      {:ok, _ended} = Conversations.ended(ended, nil, "idle")
      {:ok, _other} = Conversations.open(project, "about the project")
      said_at(live_one, "left alone", 3600)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))
      chats = view |> element("#ticket-chats") |> render()

      assert chats =~ "/chats/#{live_one.id}"
      assert chats =~ "/chats/#{ended.id}"
      refute chats =~ "about the project"

      assert has_element?(view, "#ticket-chats #conversations-live h3", "Live · 1")
      assert has_element?(view, "#ticket-chats #conversations-live #conversation-#{live_one.id}")
      assert has_element?(view, "#ticket-chats #conversations-earlier h3", "Earlier")
      assert has_element?(view, "#ticket-chats #conversations-earlier #conversation-#{ended.id}")
    end

    test "follows what is said in the ticket's conversations, and only those", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, older} = Conversations.open(project, "the older one", ticket: ticket)
      {:ok, newer} = Conversations.open(project, "the newer one", ticket: ticket)
      {:ok, elsewhere} = Conversations.open(project, "about the project")
      said_at(older, "old", 3600)
      said_at(newer, "new", 1800)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))
      assert chat_order(view) == [newer.id, older.id]

      # Another ticket's, or none: the list is not woken, so a change behind its back stays unseen.
      Forge.Repo.update_all(from(j in Jobs.Job, where: j.id == ^older.id), set: [turns: 7])
      assert render(view) =~ "0 turns"

      {:ok, _event} = Conversations.send(elsewhere, "not about the ticket")
      assert render(view) =~ "0 turns"
      refute render(view) =~ "7 turns"

      {:ok, _event} = Conversations.send(older, "this ticket again")
      assert chat_order(view) == [older.id, newer.id]
      assert render(view) =~ "7 turns"
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
      assert count(view, "changes") == 1

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes&sub=commits"))
      assert view |> element("#commits") |> render() =~ String.slice(sha, 0, 7)
    end

    # Reading a change and approving it are adjacent: the row is pinned above the diff, on this
    # view as on every other, and only while an approval is what the ticket waits on.
    test "has the changeset approval pinned above it, when that is what waits", %{
      conn: conn,
      project: project,
      ticket: ticket,
      sha: sha
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))
      refute has_element?(view, "#decision-row")

      changeset!(ticket, sha)
      pend_merge(ticket)
      commit_message!(ticket, "Persist the scores\n\nThey were lost on restart.\n")

      for tab <- ~w(changes docs activity steps) do
        {:ok, view, _html} = live(conn, page(project, ticket, "?tab=#{tab}"))
        assert has_element?(view, "#decision-row", "changeset v1")
      end

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=changes"))
      # The row names its size, from the diff below it.
      assert has_element?(view, "#decision-row .ui-diffstat", "+1")
      open!(view)
      assert has_element?(view, ~s(#decision-form button[value="approved"]), "Approve v1")

      # The operator reads what the merge will commit on this surface too.
      assert view |> element("#decision-panel ##{commit_message_id(ticket)}") |> render() =~
               "Persist the scores"

      # And above the files, before anything else on a phone (`18b`), drawn as the panel draws it:
      # the subject, then the body apart from it (UX pass, B11).
      assert has_element?(
               view,
               "#changes-will-commit .commit-message-subject",
               "Persist the scores"
             )

      assert has_element?(
               view,
               "#changes-will-commit .commit-message-body",
               "They were lost on restart."
             )
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

      assert [latest, "v2 · superseded" <> _, "v1 · superseded" <> _] =
               Enum.map(links, &(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

      assert latest == "v3 ›"

      # Each to its own version's address: the latest's link is the latest's.
      assert links |> Enum.flat_map(&Floki.attribute(&1, "href")) |> Enum.map(&Path.basename/1) ==
               ["3", "2", "1"]

      # The earlier ones are folded under a count (`ui.md` § Docs), the latest is not.
      assert has_element?(
               view,
               ~s(section[id="doc-plan.md"] details.work-doc-earlier-fold summary),
               "2 earlier versions"
             )

      assert has_element?(view, ~s(section[id="doc-plan.md"] details a[href$="/1"]))
      refute has_element?(view, ~s(section[id="doc-plan.md"] details a[href$="/3"]))
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
      # The version once, at the row's end where it is a link: not after the name as well, which
      # read `plan.md v1 … v1 ›` (UX pass, B29).
      refute details |> Floki.find("summary") |> Floki.text() =~ "v1"
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
               ~s(#frame-details a[href$="/artifacts/plan.md/1"] [data-file-type="markdown"].size-5)
             )

      assert has_element?(
               view,
               ~s(#frame-details a[href$="/artifacts/changeset/1"] [data-file-type="changeset"]),
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
      # It waits on you, so it is amber, not a warning (UX re-check #4).
      assert has_element?(
               view,
               ~s(section[id="doc-refinement.md"] span.text-accent-text),
               "◇ unapproved"
             )

      refute Enum.any?(mark.(view, "notes.md"), &(&1 =~ "approved"))

      # And on its chip under the step, in the same amber.
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ".ticket-chip span.text-accent-text", "◇ unapproved")

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

    # A version the job wrote is `wrote plan.md v1 ›`, linked where Docs links it — on a ticket as
    # on a conversation, which was the only screen that pinned it (review fixes 7, L5).
    test "links a version the job wrote to where Docs reads it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _version} =
        Artifacts.record_version(ticket.id, "plan.md", :document, {:job, job.id}, %{
          content: "# Plan\n"
        })

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=activity"))

      assert has_element?(
               view,
               ~s(#job-events [data-activity="wrote"] a[href="/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md/1"]),
               "plan.md v1"
             )
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

    assert has_element?(view, "#job-memory", "2 OOM kills · peak 2.0 GiB of 2 GiB")

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

  # A refinement written and its job over, then stuck: planning is offered, and so is the state
  # again (`docs/design/ui.md` § Steps).
  defp stuck_with_refinement(ticket) do
    for job <- Jobs.for_ticket(ticket.id) do
      job
      |> Ecto.Changeset.change(status: :finished, outcome: :converged)
      |> Forge.Repo.update!()
    end

    {:ok, _version} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n"
      })

    {:ok, stuck} = Forge.Engine.stick(Tickets.get!(ticket.id), "a reason")
    stuck
  end

  describe "ways forward" do
    test "are choice rows on the current step, nothing picked, the dock naming the one picked", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      stuck_with_refinement(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(
               view,
               ~s(#steps .ticket-step--current #ways-forward input[value="to:planning"])
             )

      assert has_element?(view, "#ways-forward #way-again")
      refute has_element?(view, "#ways-forward input[checked]")
      assert has_element?(view, "#forward-button[disabled]", "Pick a way forward")
      # The same button under the choices it commits, which the CSS shows from 768 in place of
      # the dock's (UX pass, B1): it submits the same form and names the same pick.
      assert has_element?(
               view,
               ~s(#steps .ticket-step--current #forward-inline #forward-button-inline[form="ways-forward"][disabled]),
               "Pick a way forward"
             )

      assert has_element?(view, ".ticket-dock--forward #forward-button")

      view |> form("#ways-forward", %{"way" => "to:planning"}) |> render_change()

      refute has_element?(view, "#forward-button[disabled]")
      assert has_element?(view, "#forward-button", "Move to planning")
      refute has_element?(view, "#forward-button-inline[disabled]")
      assert has_element?(view, "#forward-button-inline", "Move to planning")
      assert has_element?(view, ~s(#ways-forward input[value="to:planning"][checked]))

      # The dock's button is Steps': on another view there is nothing on screen it would take.
      {:ok, docs, _html} = live(conn, page(project, ticket, "?tab=docs"))
      refute has_element?(docs, "#forward-button")
      refute has_element?(docs, "#forward-button-inline")
    end

    test "take the one picked through the operation that takes it anywhere", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      stuck_with_refinement(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      view |> form("#ways-forward", %{"way" => "to:planning"}) |> render_submit()

      # A person taking it approves what it approves; the ticket is in planning, with nothing
      # left to pick.
      assert %{state: "planning", status: :active} = Tickets.get!(ticket.id)
      refute has_element?(view, "#ways-forward")
    end

    test "run the state again when that is the one picked", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      stuck_with_refinement(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert view |> form("#ways-forward", %{"way" => "again"}) |> render_submit() =~
               "Running refining again"

      assert Tickets.get!(ticket.id).status == :active
      assert [_first, %{attempt: 2}] = Jobs.for_ticket(ticket.id)
    end

    # The stuck reason heads the step it happened in: why, before the ways on.
    test "follow why the ticket stuck", %{conn: conn, project: project, ticket: ticket} do
      stuck_with_refinement(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, ".ticket-step--current #stuck-reason", "Stuck: a reason.")
      # A stuck ticket waits on a person: its step is the amber one.
      assert has_element?(view, ".ticket-step--waiting #stuck-reason")
      # In amber, with no △: stuck is a wait, not a warning (UX re-check #4).
      assert has_element?(view, "#stuck-reason.text-accent-text")
      refute has_element?(view, "#stuck-reason.text-warning")
    end
  end

  describe "the details" do
    test "say what it is, what it has spent, its facts and its lifecycle", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))
      details = view |> element("#frame-details") |> render()

      assert details =~ "#{project.name}##{ticket.number}"
      assert has_element?(view, "#ticket-facts", ticket.branch)
      assert has_element?(view, "#ticket-facts", "refining · visit 1")
      # No usage figure reported: the row is left out rather than drawn `5h — · week —`.
      refute has_element?(view, "#ticket-facts", "week")

      # Nothing spent yet: said in words, with the allowance and no meter at zero (UX re-check #7).
      assert has_element?(view, "#ticket-usage", "nothing spent yet")
      allowance = Forge.Tickets.workflow(ticket).limits.ticket_tokens

      assert has_element?(
               view,
               "#ticket-usage",
               "allowance #{ForgeWeb.Format.windows(allowance)}"
             )

      refute has_element?(view, "#ticket-usage .ticket-usage-track")

      # Once it has spent, the figure of the allowance and the meter.
      {:ok, spent} =
        ticket |> Ecto.Changeset.change(usage: 300_000) |> Forge.Repo.update()

      {:ok, spent_view, _html} = live(conn, page(project, spent))
      assert has_element?(spent_view, "#ticket-usage", ForgeWeb.Format.windows(300_000))
      assert has_element?(spent_view, "#ticket-usage", "of #{ForgeWeb.Format.windows(allowance)}")
      assert has_element?(spent_view, "#ticket-usage .ticket-usage-track")

      assert has_element?(view, "#frame-details #cancel-ticket")

      view |> element("#frame-details #cancel-ticket") |> render_click()
      assert Tickets.get!(ticket.id).status == :cancelled
      assert has_element?(view, "#frame-details #restore-ticket")
    end

    # Ways forward live on Steps; the details lead there rather than offering them twice.
    test "lead to the ways forward when there are some", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      refute has_element?(view, "#details-ways")

      stuck_with_refinement(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      assert has_element?(
               view,
               ~s(#details-ways[href="#{page(project, ticket, "?tab=steps")}"]),
               "Ways forward"
             )
    end
  end

  # The daily cap is the clock's to lift, so the ticket says when (`capacity.md` § Four
  # exhaustions, three treatments): `paused · spend 6h 12m`, neutral, in its subline.
  describe "paused on the daily cap" do
    test "says so, with the time until it lifts", %{conn: conn, project: project, ticket: ticket} do
      previous = Application.get_env(:forge, Forge.Spend, [])
      Application.put_env(:forge, Forge.Spend, daily_tokens: 0)
      on_exit(fn -> Application.put_env(:forge, Forge.Spend, previous) end)

      {:ok, view, _html} = live(conn, page(project, ticket))
      subline = view |> element("#title-row .frame-subline") |> render()

      assert subline =~ ~r/paused · spend (\d+h )?\d+m/
      refute subline =~ "waiting on you"
    end

    # The cap holds back a job not yet started; a ticket whose job is running is not paused by it.
    test "is said only while a job waits to start", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      previous = Application.get_env(:forge, Forge.Spend, [])
      Application.put_env(:forge, Forge.Spend, daily_tokens: 0)
      on_exit(fn -> Application.put_env(:forge, Forge.Spend, previous) end)

      [job] = Jobs.for_ticket(ticket.id)
      running!(job)

      {:ok, view, _html} = live(conn, page(project, ticket))
      refute view |> element("#title-row .frame-subline") |> render() =~ "paused"
    end

    # The countdown is drawn again on the minute, and whether the cap still holds with it: it
    # can lift before midnight.
    test "moves on with the clock, and goes when the cap lifts", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      previous = Application.get_env(:forge, Forge.Spend, [])
      Application.put_env(:forge, Forge.Spend, daily_tokens: 0)
      on_exit(fn -> Application.put_env(:forge, Forge.Spend, previous) end)

      {:ok, view, _html} = live(conn, page(project, ticket))
      assert view |> element("#title-row .frame-subline") |> render() =~ "paused · spend"
      drawn = :sys.get_state(view.pid).socket.assigns.now

      Application.put_env(:forge, Forge.Spend, previous)
      send(view.pid, :spend_tick)

      refute view |> element("#title-row .frame-subline") |> render() =~ "paused"
      assert DateTime.after?(:sys.get_state(view.pid).socket.assigns.now, drawn)
    end

    test "counts down to midnight UTC" do
      paused = &ForgeWeb.TicketLive.spend_paused/1
      assert paused.(~U[2026-11-10 17:48:00Z]) == "paused · spend 6h 12m"
      assert paused.(~U[2026-11-10 23:30:30Z]) == "paused · spend 29m"
      # The countdown `Format.until/2` draws, and under a minute none at all: never "spend now".
      assert paused.(~U[2026-11-10 23:59:30Z]) == "paused · spend"
    end
  end

  describe "Talk" do
    test "is a view while the ticket has a live conversation, and leads to it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))
      refute has_element?(view, "#tab-talk")

      {:ok, chat} = Conversations.open(project, "about the score", ticket: ticket)
      {:ok, view, _html} = live(conn, page(project, ticket))
      assert has_element?(view, ~s(#tab-talk[href="/chats/#{chat.id}"]))

      {:ok, _ended} = Conversations.ended(chat, nil, "idle")
      {:ok, view, _html} = live(conn, page(project, ticket))
      refute has_element?(view, "#tab-talk")
    end
  end

  describe "Docs, grouped by what each asks of you" do
    test "puts what the decision waits on first, then what it was built from, then the rest", %{
      conn: conn,
      project: project,
      ticket: ticket,
      user: user
    } do
      [job] = Jobs.for_ticket(ticket.id)

      {:ok, _} =
        Artifacts.record_version(ticket.id, "notes.md", :document, {:user, user.id}, %{
          content: "# Notes\n"
        })

      {:ok, _} =
        Artifacts.record_version(ticket.id, "log.txt", :document, {:job, job.id}, %{
          content: "ran\n"
        })

      pend_document(ticket)

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))

      assert has_element?(view, "#docs-waiting #doc-refinement\\.md")
      assert has_element?(view, "#docs-built_from #doc-notes\\.md", "a person")
      assert has_element?(view, "#docs-produced #doc-log\\.txt", "agent · refining #1")

      html = view |> element("#docs") |> render()

      at =
        for group <- ~w(docs-waiting docs-built_from docs-produced),
            do: elem(:binary.match(html, group), 0)

      assert at == Enum.sort(at)

      # Nothing waits once the approval is decided: no group of that name at all.
      Tickets.get!(ticket.id)
      |> Ecto.Changeset.change(pending_transition: nil)
      |> Forge.Repo.update!()

      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=docs"))
      refute has_element?(view, "#docs-waiting")
      assert has_element?(view, "#docs-produced #doc-refinement\\.md")
    end

    # With width, the document a decision waits on is read beside the view (`16i`).
    test "the document waited on is drawn for the wide screen's column", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, page(project, ticket))
      refute has_element?(view, "#aside-document")

      pend_document(ticket)
      {:ok, view, _html} = live(conn, page(project, ticket, "?tab=steps"))

      assert has_element?(view, ".frame-aside #aside-document", "refinement.md v1")
      assert view |> element("#aside-document") |> render() =~ "<h1>Refinement</h1>"
    end
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
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#steps #writable #write-test-report\\.md", "not written yet")

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
    # the current step offers its ways forward — the state again, since `planning` approves a
    # refinement that does not exist yet — and would draw an editor beside them.
    test "are not offered while a job state holds the ticket", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      for job <- Forge.Jobs.for_ticket(ticket.id) do
        job |> Ecto.Changeset.change(status: :finished, outcome: :error) |> Forge.Repo.update!()
      end

      {:ok, ticket} = ticket |> Ecto.Changeset.change(status: :stuck) |> Forge.Repo.update()
      {:ok, view, _html} = live(conn, page(project, ticket))

      assert has_element?(view, "#ways-forward #way-again")
      refute has_element?(view, ~s(form[phx-submit="write_document"]))
    end
  end
end
