defmodule ForgeWeb.ChatLiveTest do
  @moduledoc """
  The conversation page: what it shows, what the three controls do, and that a reply appears as
  it arrives rather than when it is finished.

  The streaming itself cannot be proved from ExUnit — whether text *looks* live in a browser is
  the one thing in this feature no test can reach. What is proved here is the mechanism under it:
  the view re-renders on each event, with only what had arrived by then.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects, Tickets}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "chat-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    {:ok, chat} = Conversations.open(project, "what is this repository?")
    %{project: project, chat: chat}
  end

  # The rail is the one surface that shows a job's resolved model, so it is the one that has to
  # show the resolved effort beside it (`refinement.md`). Both are the chain's answer, not the
  # row's: this chat named neither, so both read as the project's.
  test "the rail shows the resolved model and effort together", %{
    conn: conn,
    project: project,
    chat: chat
  } do
    {:ok, _project} = Projects.set_model(project, "opus")
    {:ok, _project} = Projects.set_effort(project, "xhigh")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "dt", "model")
    assert has_element?(view, "dt", "effort")
    assert has_element?(view, "dd", "opus")
    assert has_element?(view, "dd", "xhigh")
  end

  # Nothing anywhere in the chain means the harness's own default, which the page says in words
  # rather than drawing an empty row.
  test "an effort nothing resolved reads as the platform's", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "dt", "effort")
    assert has_element?(view, "dd", "the platform's")
  end

  defp text(chat, text),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

  defp turn(chat, index) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "subtype" => "success"}
      })
  end

  # `docs/design/conversations.md` § References in messages: a message has no version, so the
  # moment it stands in for does the pinning, and a project chat's names are its own documents.
  describe "references in a conversation's messages" do
    defp note!(chat, content) do
      {:ok, _} =
        Forge.Artifacts.record_version({:job, chat.id}, "notes.md", :document, {:job, chat.id}, %{
          content: content
        })
    end

    defp said(view),
      do: view |> element(~s([data-said="agent"])) |> render() |> Floki.parse_fragment!()

    test "a project chat's reply links to its own document as it was when the turn was recorded",
         %{conn: conn, chat: chat} do
      note!(chat, "# one\n")
      text(chat, "See [the notes](notes.md) and ![shot](shot.png) and [a](archive/9/x.md).")
      turn(chat, 1)
      note!(chat, "# two\n")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      html = said(view)

      assert Floki.attribute(Floki.find(html, "a"), "href") ==
               ["/chats/#{chat.id}/artifacts/notes.md/1"]

      assert Floki.find(html, "img") == []
      assert Floki.text(html) =~ "is not in this conversation"
      # A link that does not resolve is its words, with no target.
      assert Floki.text(html) =~ "and a."
    end

    test "a person's message sees what was recorded before it was sent, and no later", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "Please read [the notes](notes.md).")
      note!(chat, "# written after the message\n")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      html = view |> element(~s([data-said="you"])) |> render() |> Floki.parse_fragment!()

      assert Floki.find(html, "a") == []
      assert Floki.text(html) =~ "the notes"
    end

    test "a reply still streaming sees what exists as it is drawn", %{conn: conn, chat: chat} do
      note!(chat, "# one\n")
      note!(chat, "# two\n")
      text(chat, "See [the notes](notes.md).")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert Floki.attribute(Floki.find(said(view), "a"), "href") ==
               ["/chats/#{chat.id}/artifacts/notes.md/2"]
    end

    defp ticket_shot!(ticket, versions) do
      artifact =
        Forge.Repo.insert!(%Forge.Artifacts.Artifact{
          ticket_id: ticket.id,
          name: "q.png",
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

    test "a person's message in a ticket conversation draws the ticket's screenshots", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "t"}, {:user, user.id})
      ticket_shot!(ticket, [{1, -60}])
      {:ok, chat} = Conversations.open(project, "Is ![this](q.png) right?", ticket: ticket)

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      html = view |> element(~s([data-said="you"])) |> render() |> Floki.parse_fragment!()

      assert Floki.attribute(Floki.find(html, "img"), "src") ==
               ["/tickets/#{project.name}/#{ticket.number}/artifacts/q.png/1"]
    end

    # Nothing is recorded for a reply still being said, so it sees what exists as it is drawn —
    # a version stamped after its first words included.
    test "a reply still streaming sees every version that exists", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "t"}, {:user, user.id})
      ticket_shot!(ticket, [{1, -60}, {2, 3600}])
      {:ok, chat} = Conversations.open(project, "about it", ticket: ticket)
      text(chat, "Look: ![the queue](q.png)")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert [src] = Floki.attribute(Floki.find(said(view), "img"), "src")
      assert src == "/tickets/#{project.name}/#{ticket.number}/artifacts/q.png/2"
    end

    # A ticket conversation's documents are the ticket's, so what they refer to is the ticket's.
    test "a document a ticket conversation wrote is drawn against the ticket", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "t"}, {:user, user.id})
      ticket_shot!(ticket, [{1, -60}])
      {:ok, chat} = Conversations.open(project, "about it", ticket: ticket)

      {:ok, _} =
        Forge.Artifacts.record_version(ticket.id, "report.md", :document, {:job, chat.id}, %{
          content: "# Report\n\n![q](q.png)\n"
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

      html =
        view |> element(~s(section[id="doc-report.md"])) |> render() |> Floki.parse_fragment!()

      assert Floki.attribute(Floki.find(html, "img"), "src") ==
               ["/tickets/#{project.name}/#{ticket.number}/artifacts/q.png/1"]
    end

    test "a ticket conversation draws the ticket's screenshots", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, ticket} = Forge.Tickets.admit(project, %{title: "t"}, {:user, user.id})
      {:ok, chat} = Conversations.open(project, "about it", ticket: ticket)

      artifact =
        Forge.Repo.insert!(%Forge.Artifacts.Artifact{
          ticket_id: ticket.id,
          name: "q.png",
          kind: :blob
        })

      Forge.Repo.insert!(%Forge.Artifacts.Version{
        artifact_id: artifact.id,
        version: 1,
        author: %{"kind" => "system", "id" => nil},
        blob_uri: "store:job/x/out-a/1",
        content_hash: "h",
        inserted_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
      })

      text(chat, "Look: ![the queue](q.png)")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert [src] = Floki.attribute(Floki.find(said(view), "img"), "src")
      assert src == "/tickets/#{project.name}/#{ticket.number}/artifacts/q.png/1"
    end
  end

  # The one thing the page says about a turn that neither side said: its work is not on the
  # branch, because a merge is still open. Before this it was a line in the machine's log only,
  # which the person in the conversation never sees (ticket 11).
  test "a turn that could not commit says so in the conversation", %{conn: conn, chat: chat} do
    text(chat, "Merging main.")

    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "commit" => nil,
        "uncommitted" => %{"reason" => "merge_unresolved", "paths" => ["README.md"]},
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "subtype" => "success"}
      })

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, ".chat-uncommitted", "README.md")
    assert view |> element(".chat-uncommitted") |> render() =~ "Nothing from this turn reached"

    # Nobody's reply: it carries neither side's label, which is what `ui.md` § Talk says of a
    # notice. Asserted on the whole entry and not on the line, because the label is the entry's
    # sibling — scoped to the line, the assertion could not see a label however it was drawn.
    assert render(element(view, "#said-1")) =~ "agent"
    refute render(element(view, "#said-2")) =~ "agent"
    assert render(element(view, "#said-2")) =~ "Nothing from this turn reached"
  end

  test "it shows what was said, and where it is", %{conn: conn, chat: chat, project: project} do
    {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "what is this repository?"
    assert html =~ project.name
    assert html =~ "chat/#{chat.id}"
  end

  test "every view of a chat is drawn at one width, a project's and a ticket's", %{
    conn: conn,
    project: project,
    chat: chat
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, about} = Conversations.open(project, "why did it fail?", ticket: ticket)

    for chat <- [chat, about] do
      pages =
        for tab <- ~w(talk changes docs activity) do
          {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=#{tab}")
          {tab, render(view)}
        end

      ForgeWeb.FrameAssertions.assert_one_width(pages)
    end
  end

  test "a chat's side column can be resized", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#frame-aside-handle[role=separator][aria-controls=frame-aside]")
    assert has_element?(view, "aside#frame-aside")
  end

  test "a ticket chat says which ticket it is about", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "why did it fail?", ticket: ticket)

    {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "Persist scores"
    assert html =~ "About this ticket"
  end

  test "the conversation's strip says the harness and its model", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert view |> element("#chat-harness") |> render() =~ "Claude Code"

    Forge.Repo.update!(Ecto.Changeset.change(chat, harness: "codex", model: "gpt-look-5"))

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert view |> element("#chat-harness") |> render() =~ "Codex · gpt-look-5"
  end

  # A conversation nothing can place yet says why, where the reply will appear, and a page that
  # was already open hears it. A chat sticks nothing, so this is the one surface that says a
  # template is missing at all (`docs/design/provisioning.md` § The gate).
  test "a conversation waiting for a machine says why", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(view, "#chat-waiting")

    :ok = Jobs.record_wait(chat, "none_assigned", "Waiting for a template: none is assigned.")
    assert has_element?(view, "#chat-waiting", "Waiting for a template")
  end

  # The mechanism under streaming: the page is subscribed per job and appends what has arrived,
  # so a partial reply is on screen before the turn ends. A page that reloaded on completion
  # would show nothing until then and pass any test that only looked at the end.
  test "a reply appears while it is still arriving", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    text(chat, "Looking at ")
    assert render(view) =~ "Looking at"
    refute render(view) =~ "the README"

    text(chat, "the README now.")
    assert render(view) =~ "the README now."

    turn(chat, 1)
    assert render(view) =~ "turn 1"
  end

  test "a page open on one conversation is not redrawn by another's output", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    {:ok, other} = Conversations.open(project, "unrelated")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    text(other, "something else entirely")

    refute render(view) =~ "something else entirely"
  end

  describe "the three controls" do
    test "sending queues a message, which shows as queued until it is taken", %{
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      html = view |> form("#say", %{"text" => "try the other backend"}) |> render_submit()

      assert html =~ "try the other backend"
      assert html =~ "queued"

      # Delivery is the harness's echo, matched to the message the worker was given.
      [_opening, sent] = Conversations.messages(chat.id)

      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.delivered",
          payload: %{text: "try the other backend", message_id: sent.id}
        })

      # The opening message is still queued — it has not been delivered either — so this asks
      # about the one that was, rather than about the word appearing anywhere on the page.
      assert Enum.any?(
               Conversations.messages(chat.id),
               &(&1.text == "try the other backend" and &1.delivered)
             )

      refute render(view) =~ "try the other backend</div>\n                · queued"
    end

    # The conversation scrolls inside itself rather than growing the page, which would move the
    # box you type in further away with every reply. Whether it *scrolls* is a browser question,
    # so what is pinned here is that the pane and its hook are on the page — without them the
    # list grows the document again and nothing else would notice.
    test "the messages are in a pane that scrolls itself", %{conn: conn, chat: chat} do
      {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

      assert html =~ "StickToBottom"
      assert html =~ "overflow-y-auto"
      assert html =~ "data-scroll-items"
    end

    # Enter sends where the pointer is fine and is a newline where it is coarse, because a phone
    # keyboard has no shift-enter. Whether a key sends is a browser event ExUnit cannot drive, so
    # what is pinned is what the hook reads: the query that makes Enter a newline, the most lines
    # the box grows to, and a hint drawn only where it is true.
    test "the box takes a newline on a phone and sends on enter elsewhere", %{
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      box = view |> element("#draft") |> render()
      assert box =~ ~s(phx-hook="ForgeWeb.UI.Forms.Composer")
      assert box =~ ~s|data-newline-on="(pointer: coarse)"|
      assert box =~ ~s(data-max-lines="6")
      assert box =~ ~s(rows="1")

      hint = view |> element("#say [data-hint]") |> render()
      assert hint =~ "Enter sends"
      assert hint =~ "pointer-coarse:hidden"

      # Send is the round icon inside the field, never a filled button, named for a screen
      # reader because it has no word on it (`docs/design/ui.md` § Talk).
      send = view |> element(~s(#say button[type="submit"][aria-label="Send"])) |> render()
      assert send =~ "ui-composer-send"
    end

    test "an empty message is not sent", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      before = length(Conversations.messages(chat.id))
      view |> form("#say", %{"text" => "   "}) |> render_submit()

      assert length(Conversations.messages(chat.id)) == before
    end

    # Stop is the now line's, and the now line is drawn only while a turn is open: with no turn
    # open there is nothing to stop. While one is open, a typed message makes Send *Interrupt and
    # send* (`15a`) — named for what it costs, and only once there is something to send.
    test "stop and interrupt are there only while a turn is open", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#now-line")
      refute has_element?(view, "button", "Stop")
      view |> form("#say", %{"text" => "hello"}) |> render_change()
      refute has_element?(view, "#say button", "Interrupt and send")
      refute has_element?(view, ~s(#say input[name="interrupt"]))

      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#now-line button", "Stop")
      refute has_element?(view, "#say button", "Interrupt and send")

      view |> form("#say", %{"text" => "actually"}) |> render_change()
      assert has_element?(view, "#say button", "Interrupt and send")
      assert has_element?(view, ~s(#say input[name="interrupt"][value="true"]))
    end

    test "stop ends the turn without sending anything", %{conn: conn, chat: chat} do
      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      before = length(Conversations.messages(chat.id))
      view |> element("button", "Stop") |> render_click()

      assert length(Conversations.messages(chat.id)) == before
    end

    test "interrupt and send does send", %{conn: conn, chat: chat} do
      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> form("#say", %{"text" => "actually, stop"}) |> render_change()
      html = view |> form("#say", %{"text" => "actually, stop"}) |> render_submit()

      assert html =~ "actually, stop"
    end
  end

  defp running!(chat, attrs \\ %{}) do
    {:ok, running} =
      chat
      |> Forge.Jobs.Job.progress_changeset(Map.merge(%{status: :running}, attrs))
      |> Forge.Repo.update()

    running
  end

  # The machine a conversation holds, in its details (`15e`): its shape to every member, a link
  # to its page only for its owner, since the machines' pages are the owner's
  # (`docs/design/identity.md` § Workers).
  describe "the machine it holds" do
    setup %{chat: chat} do
      owner = Forge.AccountsFixtures.user_fixture()

      machine =
        Forge.MachinesFixtures.machine_fixture(owner, %{
          provider_id: "hz-fsn1-2",
          memory_budget: 8 * 1024 * 1024 * 1024,
          cores: 4
        })

      %{owner: owner, machine: machine, chat: running!(chat, %{worker_id: machine.id})}
    end

    test "a member sees its shape and no link to a page that is not theirs", %{
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#frame-details #chat-machine", "hz-fsn1-2 · 8 GiB · 4 cores")
      refute has_element?(view, "#chat-machine-link")
      refute has_element?(view, ~s(#frame-details a[href^="/workers/"]))
    end

    test "its owner is linked to its page", %{
      conn: conn,
      chat: chat,
      user: user,
      machine: machine
    } do
      {:ok, _machine} = Forge.Workers.update(machine, %{user_id: user.id})
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert view |> element("#chat-machine-link", "hz-fsn1-2") |> render() =~
               ~s(href="/workers/#{machine.id}")
    end

    # `worker_id` outlives the run, so a conversation whose machine was released still names its
    # last machine on its row; it holds none, and the details say so.
    test "a conversation whose machine was released holds none", %{conn: conn, chat: chat} do
      {:ok, _chat} = Conversations.ended(chat, nil, "idle")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#chat-machine", "none held")
      refute has_element?(view, "#chat-machine", "hz-fsn1-2")
    end

    # Send while the agent responds is *Interrupt and send*: the turn in flight is interrupted
    # before the message goes, which the machine is told first.
    test "interrupt and send interrupts before it sends", %{
      conn: conn,
      chat: chat,
      machine: machine
    } do
      :ok = Forge.Workers.connected(machine.id)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> form("#say", %{"text" => "wait"}) |> render_change()
      view |> form("#say", %{"text" => "wait"}) |> render_submit()

      assert_receive {"interrupt", _payload}
      assert_receive {"message", %{"text" => "wait"}}
    end

    test "send with nothing in flight does not interrupt", %{
      conn: conn,
      chat: chat,
      machine: machine
    } do
      :ok = Forge.Workers.connected(machine.id)
      text(chat, "done")
      turn(chat, 1)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> form("#say", %{"text" => "next"}) |> render_submit()

      assert_receive {"message", %{"text" => "next"}}
      refute_received {"interrupt", _payload}
    end
  end

  # A message *is* a body, so a fenced question block in a reply parses with the same parser a
  # document uses, and answering sends the choice as the next message — nothing is written to
  # `answers`, because the transcript is already the record.
  # Every question the reply asked is in one form, and Send posts one message holding every
  # answer, each under its question (`docs/design/conversations.md` § Asking a question).
  test "the last reply's questions are one form, answered in one message", %{
    conn: conn,
    chat: chat
  } do
    text(chat, """
    Two things.

    ```question
    key: backend
    text: Which backend should it use?
    options:
      - {label: postgres, detail: About postgres, recommended: true}
      - {label: sqlite, detail: About sqlite}
    ```

    ```question
    key: rows
    text: How many rows?
    ```
    """)

    turn(chat, 1)

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")
    assert html =~ "Which backend should it use?"
    assert html =~ "How many rows?"

    # In a chat every question is required, and only one is answered so far.
    assert has_element?(view, "#answer-rows button[type=submit][disabled]")
    assert view |> element("#answer-rows") |> render() =~ "1 question left"

    view
    |> element("#answer-rows form")
    |> render_change(%{
      "_target" => ["answers", "rows", "text"],
      "answers" => %{
        "backend" => %{"choice" => "postgres", "text" => ""},
        "rows" => %{"text" => "a thousand"}
      }
    })

    # Locking in sent nothing.
    refute Enum.any?(Conversations.messages(chat.id), &(&1.role == :user and &1.text =~ "rows"))

    view |> element("#answer-rows form") |> render_submit()

    assert %{role: :user, text: text} = List.last(Conversations.messages(chat.id))

    assert text ==
             "**Which backend should it use?**\npostgres\n\n**How many rows?**\na thousand"
  end

  # chat_live hands the form's events to the form itself, and a payload of the wrong shape — no
  # form, no chat, a chat id that is no id — used to take the page down with it.
  test "a malformed form event is ignored", %{conn: conn, chat: chat} do
    text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
    turn(chat, 1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    render_change(view, "form:change", %{"answers" => %{}})
    render_click(view, "form:open", %{})
    render_submit(view, "chat:questions:send", %{"form" => "x"})
    html = render_submit(view, "chat:questions:send", %{"form" => "x", "chat" => "not-a-uuid"})

    assert html =~ "That no longer exists."
    refute Enum.any?(Conversations.messages(chat.id), &(&1.role == :user and &1.text =~ "rows"))
  end

  # A later reply can ask under the same key; the form carries the reply it was drawn for, and a
  # Send for any other is refused rather than answering a question nobody saw.
  test "a form for an earlier reply sends nothing", %{conn: conn, chat: chat} do
    ask = fn index ->
      text(chat, "```question\nkey: backend\ntext: Which one, #{index}?\n```\n")
      turn(chat, index)
    end

    ask.(1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    [reply] =
      view
      |> element("#answer-rows form input[name=reply]")
      |> render()
      |> then(&Regex.run(~r/value="([^"]+)"/, &1, capture: :all_but_first))

    {:ok, _event} = Conversations.send(chat, "go on")
    ask.(2)

    html =
      render_click(view, "chat:questions:send", %{
        "form" => "chat-#{chat.id}-#{reply}",
        "chat" => chat.id,
        "reply" => reply,
        "answers" => %{"backend" => %{"text" => "the first"}}
      })

    assert html =~ "were answered or changed since the page showed them"
    refute Enum.any?(Conversations.messages(chat.id), &(&1.text =~ "the first"))

    # Said in the card that stands in its place, and gone once that card's own Send goes.
    assert has_element?(view, "#answer-rows .qcard-foot [role=alert]", "answered or changed")

    [current] =
      view
      |> element("#answer-rows form input[name=reply]")
      |> render()
      |> then(&Regex.run(~r/value="([^"]+)"/, &1, capture: :all_but_first))

    render_click(view, "chat:questions:send", %{
      "form" => "chat-#{chat.id}-#{current}",
      "chat" => chat.id,
      "reply" => current,
      "answers" => %{"backend" => %{"text" => "the second"}}
    })

    assert Enum.any?(Conversations.messages(chat.id), &(&1.text =~ "the second"))

    # The next card the agent asks with starts clean.
    ask.(3)
    assert has_element?(view, "#answer-rows form")
    refute render(view) =~ "answered or changed"
  end

  describe "while the agent has the ball" do
    setup %{chat: chat} do
      {:ok, running} =
        chat |> Forge.Jobs.Job.progress_changeset(%{status: :running}) |> Forge.Repo.update()

      %{chat: running}
    end

    test "it says so after you have sent something", %{conn: conn, chat: chat} do
      {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

      # The opening message is the last thing said, so the agent has the ball.
      assert html =~ "…"
    end

    test "it keeps saying so while the reply is still arriving", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      text(chat, "Looking at the")
      # Streaming, not finished: no `chat.turn` has closed this reply.
      assert render(view) =~ "…"
    end

    test "and stops once the turn has ended", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      text(chat, "Here it is.")
      turn(chat, 1)

      html = render(view)
      assert html =~ "Here it is."
      assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting on you")
      refute html =~ ~s(<span class="font-mono text-[17px] leading-none opacity-40">…</span>)
    end
  end

  # Criterion 11: when the idle timeout takes the machine back nothing on the page says it
  # stopped — no Reopen, no dimmed transcript, no "stopped" — and the composer stays, as on a
  # conversation holding a machine.
  test "a conversation whose machine was released is drawn as one holding a machine", %{
    conn: conn,
    chat: chat
  } do
    text(chat, "Here it is.")
    turn(chat, 1)
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, "#draft")
    assert has_element?(view, "#say")
    refute html =~ "Reopen"
    refute html =~ "stopped"
    refute html =~ "chat-messages--stopped"
    refute has_element?(view, "#reopen")
    refute has_element?(view, "#chat-ended")
    refute has_element?(view, "#chat-lost")
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting on you")
  end

  # Sending is how it is carried on: the message is recorded and the conversation goes back to
  # waiting for a machine, saying so, with nothing else for the person to do.
  test "sending from the page starts a released conversation again", %{conn: conn, chat: chat} do
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> form("#say", %{"text" => "and the lexer?"}) |> render_change()
    view |> form("#say", %{"text" => "and the lexer?"}) |> render_submit()

    assert Conversations.get!(chat.id).status == :pending
    assert List.last(Conversations.messages(chat.id)).text == "and the lexer?"
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting for a machine")
    assert has_element?(view, "#draft")
  end

  # The person's message was the last word and the machine went before a reply came: one quiet
  # line, the composer stays, and sending carries on. Not for one whose last word is the agent's.
  test "a reply lost with its machine says so once, and keeps the composer", %{
    conn: conn,
    chat: chat
  } do
    {:ok, _event} = Conversations.send(chat, "anyone there?")
    {:ok, _chat} = Conversations.ended(Conversations.get!(chat.id), nil, "worker_lost")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert view |> element("#chat-lost") |> render() =~
             "The reply was lost with its machine; send again to carry on."

    assert has_element?(view, "#draft")
    refute render(view) =~ "Reopen"
  end

  # The agent had said something and no turn ended it before the machine went.
  test "a reply cut off mid-turn by a lost machine says it was lost", %{conn: conn, chat: chat} do
    text(chat, "Let me look at the")
    {:ok, _chat} = Conversations.ended(chat, nil, "worker_lost")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert view |> element("#chat-lost") |> render() =~ "The reply was lost with its machine"
    refute has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting on you")
    assert has_element?(view, "#draft")
  end

  test "a reply that came is not lost when the machine goes", %{conn: conn, chat: chat} do
    text(chat, "Here it is.")
    turn(chat, 1)
    {:ok, _chat} = Conversations.ended(chat, nil, "worker_lost")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#chat-lost")
  end

  # Ending is final (criterion 10): the transcript stays, a line says it was ended and what became
  # of its branch, and there is no composer, no answer rows and no Reopen.
  test "an ended conversation is read-only, and says what became of its branch", %{
    conn: conn,
    chat: chat,
    user: user
  } do
    text(chat, "Here it is.")
    turn(chat, 1)

    :ok = Forge.Operator.close_chat(chat, user)

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "Here it is."
    assert has_element?(view, "#chat-ended", "Ended")
    assert view |> element("#chat-ended") |> render() =~ "by you"
    assert view |> element("#chat-ended") |> render() =~ "Its branch was deleted"
    refute has_element?(view, "#draft")
    refute has_element?(view, "#say")
    refute has_element?(view, "#answer-rows")
    refute html =~ "Reopen"
    refute has_element?(view, "#chat-ending")
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "ended")
  end

  # A send to one that was ended — a page drawn before, a crafted event — is refused in words and
  # records nothing.
  test "a send to an ended conversation is refused in words and records nothing", %{
    conn: conn,
    chat: chat
  } do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    :ok = Conversations.close(chat)
    before = length(Forge.Events.for_job(chat.id))

    html = render_hook(view, "send", %{"text" => "hello?"})

    assert html =~ "This conversation was ended"
    assert has_element?(view, ".chat-dock #chat-error[role=alert]")
    assert length(Forge.Events.for_job(chat.id)) == before
    refute Enum.any?(Conversations.messages(chat.id), &(&1.text == "hello?"))
  end

  test "an ended conversation whose branch was kept says so", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    head =
      commit_to(Projects.repo_path(project), "chat/" <> chat.id, %{"README.md" => "mine\n"}, "x")

    commit_to(Projects.repo_path(project), "main", %{"README.md" => "theirs\n"}, "y")
    assert head
    :ok = Conversations.close(chat)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert view |> element("#chat-ended") |> render() =~
             "was kept, because it would not merge cleanly"
  end

  # Ending deletes the branch, and ending is the one control on the page that does. The
  # confirm is where a person finds that out before rather than after, and the line beside the
  # control says it too — both from one definition, so neither can understate the other.
  test "ending it says the branch goes with it", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    rule = ForgeWeb.Conversations.ending_rule()

    assert rule =~ "its branch is deleted"
    assert view |> element("#chat-end-confirm .ui-confirm-sentence") |> render() =~ rule
    assert has_element?(view, ~s(#chat-end[phx-click="close"]), "End it")
    assert view |> element("#ending-copy") |> render() =~ "If you end it, #{rule}"
  end

  # A merge deletes the branch too, and a conversation merged and then ended was told its ending
  # deleted it — which it did not; it ended with nothing to delete.
  test "a merged conversation that was ended is not told its ending deleted the branch", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    wrote(chat, 1, %{"commit-message" => "Nothing to see here\n"})
    {:ok, _result} = Forge.Merge.perform_chat(chat)
    refute Forge.Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
    :ok = Conversations.close(chat)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    copy = view |> element("#chat-ended") |> render()

    assert copy =~ "already gone"
    refute copy =~ "was deleted"
  end

  # Every ticket change on the node reaches the page on the global topic, and a handler on one
  # filters before it does any work. The page's own ticket is what it reloads for; another
  # ticket's change is ignored. A status written without a notice is how the two are told apart:
  # a reload would draw it, and ignoring the message leaves the page as it was.
  test "another ticket's change does not reload the page; its own ticket's does", %{
    conn: conn,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, other} = Tickets.admit(project, %{title: "Something else"}, :system)
    {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting for a machine")

    stop_quietly(chat)

    send(view.pid, {:ticket_changed, other.id})
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting for a machine")

    send(view.pid, {:ticket_changed, ticket.id})
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "idle")
  end

  # A project chat has no ticket, and its changes are announced under `nil`.
  test "a project chat reloads for the changes announced without a ticket", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    stop_quietly(chat)

    send(view.pid, {:ticket_changed, ticket.id})
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "waiting for a machine")

    send(view.pid, {:ticket_changed, nil})
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "idle")
  end

  defp stop_quietly(chat) do
    {:ok, _stopped} =
      chat |> Jobs.Job.progress_changeset(%{status: :hibernated}) |> Forge.Repo.update()
  end

  test "a send from a stale page to a live conversation keeps its worker", %{
    conn: conn,
    chat: chat
  } do
    {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    {:ok, _running} =
      chat
      |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
      |> Forge.Repo.update()

    render_hook(view, "send", %{"text" => "go on"})

    assert %{status: :running, worker_id: worker_id} = Jobs.get!(chat.id)
    assert worker_id == worker.id
    refute Enum.any?(Forge.Events.for_job(chat.id), &(&1.type == "chat.reopened"))
  end

  # The usage lines written out in the details are facts on the facts' edge: with nothing
  # reported one row in the title menu's words, never `5h —` and `week —` (UX re-check #7); with
  # a figure, each window's own row.
  test "the details say the usage as facts, and no figures yet when none", %{
    conn: conn,
    user: user,
    project: project,
    chat: chat
  } do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    view |> element("#title-row h1 button") |> render_click()

    assert has_element?(view, "#chat-facts", "no figures yet")
    refute view |> element("#chat-facts") |> render() =~ "—"
    refute has_element?(view, "#chat-usage")

    credential = Forge.ForgeFixtures.pool!(project, Forge.ForgeFixtures.credential_fixture(user))
    reporting = Forge.ForgeFixtures.chat_fixture(%{project: project})

    reporting
    |> Ecto.Changeset.change(credential_id: credential.id)
    |> Forge.Repo.update!()

    :ok =
      Jobs.record_harness_event(reporting.id, %{
        type: "job.harness.rate_limit",
        payload: %{
          status: "allowed_warning",
          rate_limit_type: "five_hour",
          utilization: 0.42,
          resets_at: System.os_time(:second) + 3600
        }
      })

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    view |> element("#title-row h1 button") |> render_click()

    refute has_element?(view, "#chat-facts", "no figures yet")
    assert view |> element("#chat-facts") |> render() =~ "42%"
  end

  # End is drawn on an ordinary conversation that has not been ended, so a close arriving after it
  # was is a stale page or a crafted event. It was a match on `:ok` that took the view down.
  test "a close sent to an ended conversation is refused, and said", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    :ok = Conversations.close(chat)
    before = length(Forge.Events.for_job(chat.id))

    render_hook(view, "close", %{})
    # Said in the details, where End was pressed, and not in the dock.
    assert has_element?(view, "#chat-details #chat-ending-error[role=alert]", "already ended")
    refute has_element?(view, "#chat-error")
    assert length(Forge.Events.for_job(chat.id)) == before
  end

  # An idle conversation keeps its branch and offers End, as one holding a machine does.
  test "a released conversation can still be ended from its page", %{conn: conn, chat: chat} do
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, ~s(#chat-end[phx-click="close"]), "End it")

    render_hook(view, "close", %{})

    assert Conversations.ended?(chat)
    assert has_element?(view, "#chat-ended")
    refute has_element?(view, "#draft")
  end

  # Remaking the branch is a git write and can fail. The page says so rather than crashing, and
  # nothing was recorded.
  test "a send that cannot make its branch again says so", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")
    repo = Projects.repo_path(project)
    :ok = Forge.Git.delete_branch(repo, "chat/" <> chat.id)
    :ok = Forge.Git.delete_branch(repo, ticket.branch)
    before = length(Conversations.messages(chat.id))

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    view |> form("#say", %{"text" => "carry on"}) |> render_submit()
    assert has_element?(view, ".chat-dock #chat-error[role=alert]", "Could not send")
    assert Conversations.get!(chat.id).status == :finished
    assert length(Conversations.messages(chat.id)) == before
  end

  # The answer rows are a send button, so they follow the same rule as the box: drawn exactly when a
  # send would be taken. A released conversation takes one — it starts it again — and an ended
  # one does not, so its rows go and what it asked stays readable where it was said.
  test "a released conversation keeps its answer rows, and an ended one loses them", %{
    conn: conn,
    chat: chat
  } do
    text(chat, """
    Which backend?

    ```question
    key: backend
    text: Which backend should it use?
    options: [{label: postgres, detail: About postgres}, {label: sqlite, detail: About sqlite}]
    ```
    """)

    turn(chat, 1)
    {:ok, _chat} = Conversations.ended(chat, nil, "worker_lost")

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#answer-rows form")
    refute html =~ "Reopen"

    :ok = Conversations.close(Conversations.get!(chat.id))
    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    refute has_element?(view, "#answer-rows")
    refute has_element?(view, "button", "postgres")
    # What it asked is still readable — it is in the reply above, which is where it was said.
    assert html =~ "Which backend should it use?"
  end

  # Between the render and the tap: it is ended while the page is open. The page says so and stops
  # offering it, rather than accepting the tap into nothing.
  test "a conversation that is ended under the page refuses the tap", %{
    conn: conn,
    chat: chat
  } do
    text(chat, """
    ```question
    key: backend
    text: Which backend should it use?
    options: [{label: postgres, detail: About postgres}, {label: sqlite, detail: About sqlite}]
    ```
    """)

    turn(chat, 1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#answer-rows form")
    reply = Conversations.reply_ref(Conversations.messages(chat.id))

    # It is ended while the page is open. The view is subscribed, so the form goes on its own.
    :ok = Conversations.close(Conversations.get!(chat.id))
    refute has_element?(view, "#answer-rows form")

    # A client that did not get that far still sends the event — a phone asleep in a pocket,
    # a tap landing as the update arrives. Pushed directly, because by now no DOM node carries
    # it and the point is precisely a click the page no longer offers.
    html =
      render_click(view, "chat:questions:send", %{
        "form" => "chat-#{chat.id}-#{reply}",
        "chat" => chat.id,
        "reply" => reply,
        "answers" => %{"backend" => %{"choice" => "postgres"}}
      })

    assert html =~ "This conversation was ended, so it takes no answer."

    refute Enum.any?(
             Conversations.messages(chat.id),
             &(&1.role == :user and &1.text =~ "postgres")
           )
  end

  # A tap on an answer row of a conversation whose machine was released starts it again, with the
  # answer as what it replies to.
  test "an answer to a released conversation starts it again", %{conn: conn, chat: chat} do
    text(chat, """
    ```question
    key: backend
    text: Which backend should it use?
    options: [{label: postgres, detail: About postgres}, {label: sqlite, detail: About sqlite}]
    ```
    """)

    turn(chat, 1)
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    reply = Conversations.reply_ref(Conversations.messages(chat.id))

    render_click(view, "chat:questions:send", %{
      "form" => "chat-#{chat.id}-#{reply}",
      "chat" => chat.id,
      "reply" => reply,
      "answers" => %{"backend" => %{"choice" => "postgres"}}
    })

    assert Conversations.get!(chat.id).status == :pending
    assert List.last(Conversations.messages(chat.id)).text =~ "postgres"
  end

  # The card also goes when its questions are answered in another tab while the conversation is
  # live. The Send that arrives after is refused, and drawn where the card stood.
  test "a Send whose card was answered elsewhere is refused where the card stood", %{
    conn: conn,
    chat: chat,
    user: user
  } do
    text(chat, "```question\nkey: rows\ntext: How many rows?\n```\n")
    turn(chat, 1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "#answer-rows form")
    reply = Conversations.reply_ref(Conversations.messages(chat.id))

    {:ok, _event} =
      Forge.Operator.answer_chat(chat, user, reply, %{"rows" => %{choice: nil, text: "ten"}})

    refute has_element?(view, "#answer-rows form")

    render_click(view, "chat:questions:send", %{
      "form" => "chat-#{chat.id}-#{reply}",
      "chat" => chat.id,
      "reply" => reply,
      "answers" => %{"rows" => %{"text" => "a thousand"}}
    })

    assert has_element?(view, "#questions-refusal")

    refute Enum.any?(
             Conversations.messages(chat.id),
             &(&1.role == :user and &1.text =~ "a thousand")
           )
  end

  defp wrote(chat, index, documents) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{
          "turns" => 1,
          "usage" => 2_000 * index,
          "cost_usd" => 0.01 * index,
          "subtype" => "success"
        },
        "documents" => documents
      })
  end

  # Every artifact name in the product links to its exact version (ui.md § Addressable artifact
  # versions), and the rail listed a conversation's by bare name because it had no address.
  test "what it wrote links to each exact version, at the conversation's address", %{
    conn: conn,
    chat: chat
  } do
    wrote(chat, 1, %{"notes.md" => "# Notes\n"})
    wrote(chat, 2, %{"notes.md" => "# More notes\n"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

    assert has_element?(view, ~s(#docs a[href="/chats/#{chat.id}/artifacts/notes.md/1"]))
    assert has_element?(view, ~s(#docs a[href="/chats/#{chat.id}/artifacts/notes.md/2"]))
  end

  # A ticket chat writes against its ticket, so its documents are the ticket's and have the
  # ticket's address — the conversation's would be a miss for them.
  test "a ticket chat's documents link to the ticket's address", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "rewrite the plan", ticket: ticket)
    wrote(chat, 1, %{"plan.md" => "# Plan\n"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

    assert has_element?(
             view,
             ~s(#docs a[href="/tickets/#{project.name}/#{ticket.number}/artifacts/plan.md/1"])
           )

    refute has_element?(view, ~s(#docs a[href^="/chats/"]))
  end

  # A ticket chat's proposals are not the ticket's: a proposal is scoped to the job that wrote it
  # (`ticket-proposals.md` § Scope), so it has the conversation's address even when the
  # conversation is about a ticket — and that address has to serve it. Only a project chat's were
  # tested, and a page or a route that took "has a ticket" for "is the ticket's" passed.
  test "a ticket chat's proposal links to the conversation's address, which serves it", %{
    conn: conn,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "file a follow-up", ticket: ticket)

    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => 1,
        "harness" => %{"turns" => 1, "usage" => 2_000, "cost_usd" => 0.01, "subtype" => "success"},
        "proposals" => %{
          "later.md" => %{
            "title" => "Do it later",
            "body" => "b",
            "raw" => "# Do it later\n\nb\n"
          }
        }
      })

    href = "/chats/#{chat.id}/artifacts/proposal-later.md/1"

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")
    assert has_element?(view, ~s(#docs a[href="#{href}"]))

    assert get(conn, href) |> response(200) =~ "Do it later"
  end

  # A document that did not arrive would otherwise only be absent, which reads the same as one
  # that was never written.
  test "what the last turn left that was not recorded is listed, with why", %{
    conn: conn,
    chat: chat
  } do
    wrote(chat, 1, %{"ticket" => "# Not mine to write\n"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

    row = view |> element("#unrecorded li") |> render()
    assert row =~ "ticket"
    assert row =~ "reserved"
  end

  # `docs/design/conversations.md` § Commits: what the merge commit says is the conversation's own
  # `commit-message`, so the page draws it above the merge control read-only and draws no button
  # until one exists — pressing merge without it is refused, and a button that would fail is worse
  # than none.
  test "the merge waits for a commit message and shows the one it would use", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    commit_on_chat(project, chat, "NOTES.md", "from a conversation\n")

    # The merge is the decision row's — neutral, since nobody is waiting on it — on every view;
    # with nothing written to say, there is nothing to merge yet and no button to press.
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=talk")
    assert has_element?(view, "#decision-row.ui-decision--neutral", "nothing to merge yet")
    assert has_element?(view, "#decision-row button[disabled]", "Merge")
    refute has_element?(view, "#decision-row", "merges cleanly")

    wrote(chat, 1, %{"commit-message" => "Write the notes down\n"})

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=changes")
    view |> element("#decision-row button[phx-click='decision:open']") |> render_click()
    block = view |> element("#chat-commit-message") |> render()

    assert block =~ "Write the notes down"
    refute block =~ "view only"
    assert block =~ "commit-message-subject"
    assert has_element?(view, "#decision-form button[type=submit]", "Merge")

    view |> form("#decision-form") |> render_submit()
    assert has_element?(view, "#toast", "Merged chat/")
    assert has_element?(view, "#toast", "into main")
    refute has_element?(view, "#decision-row")
  end

  # Stands in for the worker, which pushes with a token scoped to exactly this ref: the hook
  # refuses an uncredentialed push, which is the point of it.
  defp commit_on_chat(project, chat, path, content) do
    repo = Projects.repo_path(project)
    branch = Jobs.chat_branch(chat)
    work = tmp_dir("chat-work")
    {_out, 0} = System.cmd("git", ["clone", "--quiet", "--branch", branch, repo, work])
    File.write!(Path.join(work, path), content)

    for args <- [
          ["config", "user.name", "chat"],
          ["config", "user.email", "chat@forge"],
          ["add", "."],
          ["commit", "--quiet", "-m", "from the conversation"],
          ["push", "--quiet", "origin", "HEAD:refs/heads/" <> branch]
        ] do
      {_out, 0} =
        System.cmd("git", ["-C", work] ++ args,
          stderr_to_stdout: true,
          env: [{"FORGE_INTERNAL", "1"}]
        )
    end

    :ok
  end

  test "it requires a logged-in operator", %{chat: chat} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/chats/#{chat.id}")
  end
end
