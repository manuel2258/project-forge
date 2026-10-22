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

  defp text(chat, text),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

  defp turn(chat, index) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })
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
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert has_element?(view, ".chat-uncommitted", "README.md")
    assert view |> element(".chat-uncommitted") |> render() =~ "Nothing from this turn reached"

    # Nobody's reply: it carries neither side's label, which is what `ui.md` § Talk says of a
    # notice. Drawn as an assistant message it wore "agent · turn 1" over the platform's words.
    refute view |> element(".chat-uncommitted") |> render() =~ "agent"
  end

  test "it shows what was said, and where it is", %{conn: conn, chat: chat, project: project} do
    {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "what is this repository?"
    assert html =~ project.name
    assert html =~ "chat/#{chat.id}"
  end

  test "a ticket chat says which ticket it is about", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "why did it fail?", ticket: ticket)

    {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "Persist scores"
    assert html =~ "About this ticket"
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
      assert box =~ ~s(phx-hook="ForgeWeb.Conversations.Composer")
      assert box =~ ~s|data-newline-on="(pointer: coarse)"|
      assert box =~ ~s(data-max-lines="6")
      assert box =~ ~s(rows="1")

      hint = view |> element("#say [data-hint]") |> render()
      assert hint =~ "Enter sends"
      assert hint =~ "pointer-coarse:hidden"

      # Send is a 46px square, named for a screen reader because it has no word on it.
      send = view |> element(~s(#say button[type="submit"][aria-label="Send"])) |> render()
      assert send =~ "size-[46px]"
    end

    test "an empty message is not sent", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      before = length(Conversations.messages(chat.id))
      view |> form("#say", %{"text" => "   "}) |> render_submit()

      assert length(Conversations.messages(chat.id)) == before
    end

    # Stop and Interrupt are the now line's, and the now line is drawn only while a turn is
    # open: with no turn open there is nothing to stop, and the composer is the box and Send.
    test "stop and interrupt are there only while a turn is open", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      refute has_element?(view, "#now-line")
      refute has_element?(view, "button", "Stop")

      running!(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "#now-line button", "Stop")
      assert has_element?(view, "#now-line button", "Interrupt and send")
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
      html = view |> element("button", "Interrupt and send") |> render_click()

      assert html =~ "actually, stop"
    end
  end

  defp running!(chat) do
    {:ok, running} =
      chat |> Forge.Jobs.Job.progress_changeset(%{status: :running}) |> Forge.Repo.update()

    running
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
      assert html =~ "It is waiting on you."
      refute html =~ ~s(<span class="font-mono text-[17px] leading-none opacity-40">…</span>)
    end
  end

  test "a stopped conversation offers to reopen instead of a box to type in", %{
    conn: conn,
    chat: chat
  } do
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

    assert html =~ "Reopen"
    refute has_element?(view, "#draft")

    # What reopening does, said where the button is. It said the rest of the conversation was
    # not replayed, which stopped being true when the replay was built.
    copy = view |> element("#reopen-copy") |> render()
    assert copy =~ "given everything said here to read"
    refute copy =~ "not replayed"

    view |> element("button", "Reopen") |> render_click()
    assert Conversations.get!(chat.id).status == :pending
  end

  # Ending deletes the branch, and ending is the one control on the page that does. The
  # confirm is where a person finds that out before rather than after, and the line beside the
  # control says it too — both from one definition, so neither can understate the other.
  test "ending it says the branch goes with it", %{conn: conn, chat: chat} do
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    rule = ForgeWeb.Conversations.ending_rule()

    assert rule =~ "its branch is deleted"
    assert view |> element(~s(button[phx-click="close"])) |> render() =~ rule
    assert view |> element("#ending-copy") |> render() =~ "If you end it, #{rule}"
  end

  # Closing is not terminal: the branch it deleted is made again on reopen, from where opening
  # made it — and the page says which, beside the button, rather than the new process finding a
  # checkout without the work its replies describe.
  test "a stopped conversation says where a deleted branch starts again", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    :ok = Conversations.close(chat)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    copy = view |> element("#reopen-copy") |> render()

    assert copy =~ "Its branch is gone"
    assert copy =~ project.default_branch
    refute copy =~ "on its branch as it stands"
  end

  # Where the page says a deleted branch comes back from is where the reopen makes it — one
  # definition, `Conversations.base_branch/2` — and for a ticket chat that is the ticket's branch.
  test "a stopped ticket chat says its branch starts again from the ticket's", %{
    conn: conn,
    project: project
  } do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
    :ok = Conversations.close(chat)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    copy = view |> element("#reopen-copy") |> render()

    assert copy =~ ticket.branch
    refute copy =~ ">#{project.default_branch}<"
  end

  # A merge deletes the branch too, and a conversation merged and then left idle was told its
  # branch "was deleted when it ended" — which it was not; it ended with nothing to delete.
  test "a merged conversation that stopped is not told its ending deleted the branch", %{
    conn: conn,
    chat: chat,
    project: project
  } do
    {:ok, _result} = Forge.Merge.perform_chat(chat)
    refute Forge.Git.branch_exists?(Projects.repo_path(project), "chat/" <> chat.id)
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    copy = view |> element("#reopen-copy") |> render()

    assert copy =~ "a merge deletes it"
    refute copy =~ "deleted when it ended"
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
    assert has_element?(view, "#draft")

    stop_quietly(chat)

    send(view.pid, {:ticket_changed, other.id})
    assert has_element?(view, "#draft")

    send(view.pid, {:ticket_changed, ticket.id})
    refute has_element?(view, "#draft")
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
    assert has_element?(view, "#draft")

    send(view.pid, {:ticket_changed, nil})
    refute has_element?(view, "#draft")
  end

  defp stop_quietly(chat) do
    {:ok, _stopped} =
      chat |> Jobs.Job.progress_changeset(%{status: :hibernated}) |> Forge.Repo.update()
  end

  # The page draws Reopen only when the conversation is not live, but an event is anything the
  # socket sends. Reopened while running, a conversation lost the `worker_id` its worker reports
  # under; the context refuses, and the page says so rather than crashing or pretending.
  test "a reopen sent to a live conversation is refused, and said", %{conn: conn, chat: chat} do
    {:ok, worker, _token} = Forge.Workers.create(%{provider: "fake"})

    {:ok, _running} =
      chat
      |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
      |> Forge.Repo.update()

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(view, ~s(button[phx-click="reopen"]))

    assert render_hook(view, "reopen", %{}) =~ "still live"
    assert %{status: :running, worker_id: worker_id} = Jobs.get!(chat.id)
    assert worker_id == worker.id
  end

  # And the other way: End is drawn only while it is live, so a close arriving after it stopped
  # is a stale page or a crafted event. It was a match on `:ok` that took the view down.
  test "a close sent to a stopped conversation is refused, and said", %{conn: conn, chat: chat} do
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    refute has_element?(view, ~s(button[phx-click="close"]))

    assert render_hook(view, "close", %{}) =~ "already stopped"
    assert Jobs.get!(chat.id).status == :finished
  end

  # Remaking the branch is a git write and can fail. The page says so rather than crashing.
  test "a reopen that cannot make its branch again says so", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "about this", ticket: ticket)
    :ok = Conversations.close(chat)
    :ok = Forge.Git.delete_branch(Projects.repo_path(project), ticket.branch)

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

    assert view |> element("button", "Reopen") |> render_click() =~ "Could not reopen"
    assert Conversations.get!(chat.id).status == :finished
  end

  test "a stopped conversation whose branch is kept says it carries on from it", %{
    conn: conn,
    chat: chat
  } do
    {:ok, _chat} = Conversations.ended(chat, nil, "idle")

    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    copy = view |> element("#reopen-copy") |> render()

    assert copy =~ "on its branch as it stands"
    refute copy =~ "was deleted"
  end

  # The box was already swapped for Reopen; the answer rows were not, and an answer row *is* a
  # send button. A real chat on the dev node was tapped this way after it had stopped, and the
  # tap was recorded and never delivered.
  test "a stopped conversation takes its answer rows away with the box", %{
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

    refute has_element?(view, "button", "postgres")
    assert html =~ "Reopen"

    # What it asked is still readable — it is in the reply above, which is where it was said.
    assert html =~ "Which backend should it use?"
  end

  # Between the render and the tap. The page says so and stops offering it, rather than
  # accepting the tap into nothing.
  test "a conversation that stops under the page refuses the tap and swaps to reopen", %{
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

    # It ends while the page is open. The view is subscribed, so the form goes on its own.
    {:ok, _chat} = Conversations.ended(chat, nil, "worker_lost")
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

    # The refusal's own sentence: the stopped page says "This conversation has stopped" anyway.
    assert html =~ "Reopen it to answer."
    assert html =~ "Reopen"

    refute Enum.any?(
             Conversations.messages(chat.id),
             &(&1.role == :user and &1.text =~ "postgres")
           )
  end

  defp wrote(chat, index, documents) do
    {:ok, _chat} =
      Conversations.record_turn(chat, %{
        "turn" => index,
        "harness" => %{"turns" => 1, "cost_usd" => 0.01 * index, "subtype" => "success"},
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
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"},
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

  test "it requires a logged-in operator", %{chat: chat} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/chats/#{chat.id}")
  end
end
