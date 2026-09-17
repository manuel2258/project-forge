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

      html = view |> form("form", %{"text" => "try the other backend"}) |> render_submit()

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

    # Enter sends and shift-enter makes a newline, which a textarea does neither of on its own.
    # Whether the key actually sends cannot be driven from ExUnit — it is a browser event — so
    # what is pinned here is that the box carries the hook and says what the keys do.
    test "the box sends on enter", %{conn: conn, chat: chat} do
      {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")

      assert html =~ "phx-hook"
      assert html =~ "SendOnEnter"
      assert html =~ "Enter sends"
    end

    test "an empty message is not sent", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      before = length(Conversations.messages(chat.id))
      view |> form("form", %{"text" => "   "}) |> render_submit()

      assert length(Conversations.messages(chat.id)) == before
    end

    test "stop ends the turn without sending anything", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      before = length(Conversations.messages(chat.id))
      view |> element("button", "Stop") |> render_click()

      assert length(Conversations.messages(chat.id)) == before
    end

    test "interrupt and send does send", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> form("form", %{"text" => "actually, stop"}) |> render_change()
      html = view |> element("button", "Interrupt and send") |> render_click()

      assert html =~ "actually, stop"
    end
  end

  # A message *is* a body, so a fenced question block in a reply parses with the same parser a
  # document uses, and answering sends the choice as the next message — nothing is written to
  # `answers`, because the transcript is already the record.
  test "a question in the last reply gets one-tap answers", %{conn: conn, chat: chat} do
    text(chat, """
    Which backend?

    ```question
    key: backend
    text: Which backend should it use?
    options: [postgres, sqlite]
    ```
    """)

    turn(chat, 1)

    {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")
    assert html =~ "Which backend should it use?"

    html = view |> element("button", "postgres") |> render_click()
    assert html =~ "postgres"

    assert Enum.any?(Conversations.messages(chat.id), &(&1.text == "postgres"))
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

    view |> element("button", "Reopen") |> render_click()
    assert Conversations.get!(chat.id).status == :pending
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
    options: [postgres, sqlite]
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
    options: [postgres, sqlite]
    ```
    """)

    turn(chat, 1)
    {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
    assert has_element?(view, "button", "postgres")

    # It ends while the page is open. The view is subscribed, so the row goes on its own.
    {:ok, _chat} = Conversations.ended(chat, nil, "worker_lost")
    refute has_element?(view, "button", "postgres")

    # A client that did not get that far still sends the event — a phone asleep in a pocket,
    # a tap landing as the update arrives. Pushed directly, because by now no DOM node carries
    # it and the point is precisely a click the page no longer offers.
    html = render_click(view, "answer", %{"choice" => "postgres"})

    assert html =~ "This conversation has stopped"
    assert html =~ "Reopen"
    refute Enum.any?(Conversations.messages(chat.id), &(&1.text == "postgres"))
  end

  test "it requires a logged-in operator", %{chat: chat} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/chats/#{chat.id}")
  end
end
