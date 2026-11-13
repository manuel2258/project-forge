defmodule ForgeWeb.ChatsLiveTest do
  @moduledoc """
  `/chats` — the conversations of the projects you are in.

  It had no test file at all, which for a page whose whole job is "show me the ones I have" means
  the difference between working and rendering permanently empty was invisible: a list that
  fetched nothing still returns 200, still draws its heading, and still says the empty-state
  sentence that a genuinely new node would say. So the assertions here are on the rows, by the
  link each one carries, rather than on the page existing.

  `docs/design/conversations.md` § Finding one again is what the page is for, and
  `ForgeWeb.ChatsLive`'s own doc says why it is not a queue.
  """

  use ForgeWeb.ConnCase, async: false

  import Forge.GitFixtures
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Forge.{Conversations, Jobs, Projects}

  setup :register_and_log_in_user

  # Owner is required: a project with no members is invisible to everyone, so a test that forgot
  # it would assert an empty page and pass for the wrong reason.
  defp project(label, owner) do
    {:ok, project} =
      Projects.register(
        %{
          name: "#{label}-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        owner
      )

    project
  end

  defp agent_said(chat, text),
    do:
      :ok =
        Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

  # A message at a chosen time: events are append-only, so one is inserted with it, later in the
  # log than any before, which is what the list reads as the last thing said.
  defp said_at(chat, text, at) do
    Forge.Repo.insert!(%Forge.Events.Event{
      actor: %{"kind" => "system", "id" => nil},
      type: "chat.message",
      payload: %{"text" => text},
      job_id: chat.id,
      project_id: chat.project_id,
      inserted_at: at
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(:second), -seconds, :second)

  # The chats' ids in the order the page draws them.
  defp order(html) do
    ~r/id="conversation-([0-9a-f-]{36})"/ |> Regex.scan(html) |> Enum.map(&List.last/1)
  end

  defp row(chat), do: ~s(ol li a[href="/chats/#{chat.id}"])

  # Across the reader's projects, not one of them — and not the node's. A page that narrowed to
  # a single project, or fetched nothing at all, draws the same heading and the same
  # "No conversations yet" sentence, so the assertions are on the rows.
  #
  # This test used to be called "every conversation on the node is listed, whichever project it
  # belongs to" and asserted exactly that, which is what a leak looks like when the suite is
  # written before the boundary exists.
  test "conversations across the reader's projects are listed", %{conn: conn, user: user} do
    {:ok, here} = Conversations.open(project("parser", user), "about the parser")
    {:ok, elsewhere} = Conversations.open(project("engine", user), "about the engine")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, row(here))
    assert has_element?(view, row(elsewhere))
    refute render(view) =~ "No conversations yet"
  end

  test "a conversation in a project the reader is not in is not listed", %{conn: conn, user: user} do
    mine = project("mine", user)
    {:ok, ours} = Conversations.open(mine, "about my parser")

    theirs = project("theirs", Forge.AccountsFixtures.user_fixture())
    {:ok, secret} = Conversations.open(theirs, "the acquisition price is 40m")

    {:ok, view, html} = live(conn, ~p"/chats")

    # The row carries the project name, the chat link and the last thing the agent said, so an
    # unscoped list hands a stranger the transcript's first line as well as the project's name.
    assert has_element?(view, row(ours))
    refute has_element?(view, row(secret))
    refute html =~ theirs.name
  end

  # Each row is a link to *its own* conversation. A row that navigates to `/chats` looks right in
  # a screenshot and takes you back to the list you tapped from, and there is no second gesture
  # in the row to recover with — the whole row is the target, on purpose.
  test "a row goes to the conversation it names", %{conn: conn, user: user} do
    {:ok, chat} = Conversations.open(project("parser", user), "about the parser")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert view |> element(row(chat)) |> render() =~ "about the parser"
    refute has_element?(view, ~s(ol li a[href="/chats"]))
  end

  # The row attributes the last line to whoever said it, and that is the only thing telling you
  # whether the conversation is waiting on you or on the machine. Swap the two labels and every
  # row reads as the opposite of what happened, which no page-wide `=~` would notice because both
  # words are on the page either way. Scoped to the row for exactly that reason.
  test "a row says who spoke last", %{conn: conn, user: user} do
    {:ok, mine} = Conversations.open(project("parser", user), "what is this repository?")
    {:ok, theirs} = Conversations.open(project("engine", user), "and this one?")
    agent_said(theirs, "It is a workflow engine.")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert view |> element(row(mine)) |> render() =~ "you:"
    refute view |> element(row(mine)) |> render() =~ "agent:"

    assert view |> element(row(theirs)) |> render() =~ "agent:"
    refute view |> element(row(theirs)) |> render() =~ "you:"
  end

  # The accent is the product's one colour and `docs/design/ui.md` says it means exactly one
  # thing: a human is being waited on. A live conversation whose last line is your own is waiting
  # on the machine, so the accent must not be on it.
  test "only a conversation the agent has left the ball with is accented", %{
    conn: conn,
    user: user
  } do
    {:ok, mine} = Conversations.open(project("parser", user), "what is this repository?")
    {:ok, theirs} = Conversations.open(project("engine", user), "and this one?")
    agent_said(theirs, "It is a workflow engine.")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert view |> element(row(theirs)) |> render() =~ "waiting on you"
    refute view |> element(row(mine)) |> render() =~ "waiting on you"
  end

  # A conversation has no title, so the last line is what tells one row from another. Cut it
  # short and the rows stop being distinguishable, which is the one thing this page is for.
  test "a row shows the last line, up to a bounded length", %{conn: conn, user: user} do
    {:ok, short} =
      Conversations.open(project("parser", user), "why does the lexer keep the comments?")

    {:ok, long} = Conversations.open(project("engine", user), String.duplicate("ab", 120))

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert view |> element(row(short)) |> render() =~ "why does the lexer keep the comments?"

    rendered = view |> element(row(long)) |> render()
    assert rendered =~ String.duplicate("ab", 70)
    refute rendered =~ String.duplicate("ab", 71)
  end

  # The live ones are a section of their own above, headed with their count — the count that used
  # to stand in the header. Live is holding a machine, so it is the same set that is offered End.
  test "live conversations are a section above the rest, headed with their count", %{
    conn: conn,
    user: user
  } do
    {:ok, running} = Conversations.open(project("parser", user), "still going")
    {:ok, finished} = Conversations.open(project("engine", user), "all done")
    {:ok, _closed} = Conversations.ended(finished, nil, "closed")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, "#conversations-live h2", "Live · 1")
    assert has_element?(view, "#conversations-live #conversation-#{running.id}")
    refute has_element?(view, "#conversations-live #conversation-#{finished.id}")

    assert has_element?(view, "#conversations-earlier h2", "Earlier")
    assert has_element?(view, "#conversations-earlier #conversation-#{finished.id}")
    refute has_element?(view, "#conversations-earlier #conversation-#{running.id}")

    refute has_element?(view, "header span", "live")
    assert render(view) =~ ~r/id="conversations-live".*id="conversations-earlier"/s
  end

  # A section with nothing in it is absent, and with nothing live the list is just the list.
  test "with nothing live there is no Live section and no Earlier heading", %{
    conn: conn,
    user: user
  } do
    {:ok, chat} = Conversations.open(project("parser", user), "all done")
    {:ok, _closed} = Conversations.ended(chat, nil, "closed")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, row(chat))
    refute has_element?(view, "#conversations-live")
    refute has_element?(view, "#conversations-earlier")
    refute render(view) =~ "Earlier"
  end

  test "with only live ones there is no Earlier heading", %{conn: conn, user: user} do
    {:ok, chat} = Conversations.open(project("parser", user), "still going")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, "#conversations-live #conversation-#{chat.id}")
    refute has_element?(view, "#conversations-earlier")
    refute render(view) =~ "Earlier"
  end

  # Criterion 6 and 12: the row follows what is said, and its time with it.
  test "a conversation moves to the top when it is spoken in, and its time with it", %{
    conn: conn,
    user: user
  } do
    {:ok, older} = Conversations.open(project("parser", user), "the older one")
    {:ok, newer} = Conversations.open(project("engine", user), "the newer one")
    said_at(older, "old", ago(3600))
    said_at(newer, "new", ago(1800))

    {:ok, view, html} = live(conn, ~p"/chats")
    assert order(html) == [newer.id, older.id]
    assert view |> element(row(older)) |> render() =~ "1h"

    agent_said(older, "back again")

    html = render(view)
    assert order(html) == [older.id, newer.id]
    assert view |> element(row(older)) |> render() =~ "back again"
    assert view |> element(row(older)) |> render() =~ "now"
    refute view |> element(row(older)) |> render() =~ "1h"
  end

  test "the person saying something moves it too", %{conn: conn, user: user} do
    {:ok, older} = Conversations.open(project("parser", user), "the older one")
    {:ok, newer} = Conversations.open(project("engine", user), "the newer one")
    said_at(older, "old", ago(3600))
    said_at(newer, "new", ago(1800))

    {:ok, view, _html} = live(conn, ~p"/chats")
    {:ok, _event} = Conversations.send(older, "one more thing")

    assert order(render(view)) == [older.id, newer.id]
  end

  # Criterion 7. The page is not woken by a chat it cannot show. "Not woken" is observed as the
  # page keeping what it drew: the `turns` of a visible row are changed behind its back, and only
  # a reload would show it.
  test "something said in a project the reader is not in does not reload the page", %{
    conn: conn,
    user: user
  } do
    {:ok, mine} = Conversations.open(project("mine", user), "about my parser")
    theirs = project("theirs", Forge.AccountsFixtures.user_fixture())
    {:ok, stranger} = Conversations.open(theirs, "not yours")

    {:ok, view, _html} = live(conn, ~p"/chats")
    assert view |> element(row(mine)) |> render() =~ "0 turns"

    Forge.Repo.update_all(from(j in Jobs.Job, where: j.id == ^mine.id), set: [turns: 7])

    agent_said(stranger, "a secret")
    assert view |> element(row(mine)) |> render() =~ "0 turns"

    agent_said(mine, "mine")
    assert view |> element(row(mine)) |> render() =~ "7 turns"
  end

  test "a change to a ticket of a project the reader is not in does not reload the page", %{
    conn: conn,
    user: user
  } do
    {:ok, mine} = Conversations.open(project("mine", user), "about my parser")
    ticket = Forge.ForgeFixtures.ticket_fixture()
    own = Forge.ForgeFixtures.ticket_fixture(%{project: project("own", user)})

    {:ok, view, _html} = live(conn, ~p"/chats")
    Forge.Repo.update_all(from(j in Jobs.Job, where: j.id == ^mine.id), set: [turns: 7])

    Forge.Events.notify(ticket.id)
    assert view |> element(row(mine)) |> render() =~ "0 turns"

    Forge.Events.notify(own.id)
    assert view |> element(row(mine)) |> render() =~ "7 turns"
  end

  # Criterion 13: the confirm names the chat it will end, because a row can move under a finger,
  # and confirming ends the row that was tapped.
  test "End names the conversation it will end", %{conn: conn, user: user} do
    parser = project("parser", user)
    {:ok, first} = Conversations.open(parser, "about the lexer")
    {:ok, second} = Conversations.open(project("engine", user), "about the scheduler")

    {:ok, view, html} = live(conn, ~p"/chats")
    # No paragraph of design rationale above the list (UX pass, B17).
    refute html =~ "This is for finding one again"

    # The sentence is in the row's own confirm, which carries the act: in place, and naming it.
    confirm = fn chat ->
      view
      |> element("#chat-end-#{chat.id}-confirm .ui-confirm-sentence")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
    end

    assert confirm.(first) =~ ~s(End #{parser.name} "about the lexer"?)
    assert confirm.(first) =~ ForgeWeb.Conversations.ending_rule()
    assert confirm.(second) =~ ~s("about the scheduler")
    refute confirm.(second) =~ "lexer"

    # The trigger is a quiet word in the row's first line, not a button on a line of its own
    # (UX pass, B17).
    assert has_element?(
             view,
             ~s(#conversation-#{first.id} > .chat-row-end #chat-end-#{first.id}-ask.ui-confirm-quiet),
             "End"
           )

    assert has_element?(view, ~s(#chat-end-#{first.id}[phx-value-id="#{first.id}"]), "End it")
    view |> element("#chat-end-#{first.id}") |> render_click()
    assert Jobs.get(first.id).status == :finished
    assert Jobs.get(second.id).status == :pending
  end

  test "a ticket's number is in the confirm when the chat has one", %{conn: conn, user: user} do
    project = project("parser", user)
    {:ok, ticket} = Forge.Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, _chat} = Conversations.open(project, "about the ticket", ticket: ticket)

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert view |> element("ol li .ui-confirm-sentence") |> render() =~
             "#{project.name} ##{ticket.number}"
  end

  # Criterion 16: a message is text, in the row and in the confirm, cut to its first line.
  test "a message holding markup is shown as text, cut to its first line", %{
    conn: conn,
    user: user
  } do
    {:ok, chat} =
      Conversations.open(
        project("parser", user),
        "<b>x</b> " <> String.duplicate("a", 200) <> "\nsecond line"
      )

    {:ok, view, _html} = live(conn, ~p"/chats")

    row = view |> element(row(chat)) |> render()
    assert row =~ "&lt;b&gt;x&lt;/b&gt;"
    refute row =~ "<b>"
    refute row =~ "second line"
    refute has_element?(view, "ol li b")

    confirm = view |> element("ol li .ui-confirm-sentence") |> render()
    assert confirm =~ "&lt;b&gt;x&lt;/b&gt;"
    refute confirm =~ "<b>x"
    refute confirm =~ "second line"
    refute confirm =~ String.duplicate("a", 141)
  end

  test "a node with no conversations says so instead of drawing an empty list", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/chats")

    refute has_element?(view, "ol li")
    assert render(view) =~ "No conversations yet"
  end

  # The page every other create affordance is reached from cannot reach this one: a conversation
  # is always about a project and this page is all of them, so the link goes to the bare route
  # that asks which (`docs/design/ui.md` § Creating things).
  test "a conversation can be started from here", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/chats")

    # The frame's context: `+ New` at the top bar's right end, and in the title row on a desktop.
    assert has_element?(view, ~s(#top-bar a.ui-top-context[href="/chats/new"]))
    assert has_element?(view, ~s(#title-row a.frame-context[href="/chats/new"]))
  end

  # The dock's composer starts one in place (`12c`), with a picker of the viewer's projects
  # beside it: this is the one surface with no project to carry.
  describe "the composer" do
    test "starts a chat in the picked project and opens it", %{conn: conn, user: user} do
      _first = project("first", user)
      second = project("second", user)
      {:ok, view, _html} = live(conn, ~p"/chats")

      assert has_element?(view, ~s(form#chat-start[phx-change="start:change"]))
      assert has_element?(view, ~s(#chat-start-project option[value="#{second.name}"]))

      assert {:error, {:live_redirect, %{to: "/chats/" <> id}}} =
               view
               |> form("#chat-start", %{"project" => second.name, "text" => "why is CI slow?"})
               |> render_submit()

      chat = Jobs.get(id)
      assert chat.project_id == second.id
      assert [%{text: "why is CI slow?"}] = Conversations.messages(id)
    end

    # The picker offers the viewer's projects only, and the event takes a name off the wire: one
    # of a project they are not in is refused by the lookup, as a missing one is, and nothing is
    # started there.
    test "refuses a project the viewer is not in", %{conn: conn, user: user} do
      _mine = project("mine", user)
      theirs = project("theirs", Forge.AccountsFixtures.user_fixture())
      {:ok, view, _html} = live(conn, ~p"/chats")

      refute has_element?(view, ~s(#chat-start-project option[value="#{theirs.name}"]))

      html = render_submit(view, "chat:start", %{"project" => theirs.name, "text" => "let me in"})

      assert html =~ "Choose one of your projects."
      assert Conversations.summaries(project_id: theirs.id) == []
    end

    test "says so instead of starting a chat with nothing said", %{conn: conn, user: user} do
      mine = project("mine", user)
      {:ok, view, _html} = live(conn, ~p"/chats")

      html =
        view |> form("#chat-start", %{"project" => mine.name, "text" => "   "}) |> render_submit()

      assert html =~ "Say what the chat is about first."
      assert Conversations.summaries(project_id: mine.id) == []
    end

    # What was typed is the page's, so a rejoin's replay of the form gives it back.
    test "keeps what was typed", %{conn: conn, user: user} do
      mine = project("mine", user)
      {:ok, view, _html} = live(conn, ~p"/chats")

      view
      |> form("#chat-start", %{"project" => mine.name, "text" => "half a thought"})
      |> render_change()

      assert view |> element("#chat-start-text") |> render() =~ "half a thought"
    end

    test "is not drawn for someone in no project", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chats")
      refute has_element?(view, "#chat-start")
    end
  end

  # A row is called what the person opened it with, or its ticket for a step's conversation
  # (`Forge.Conversations.title/3`), and says how many are live in the subline.
  test "a row is titled by the first thing said, and the subline counts the live", %{
    conn: conn,
    user: user
  } do
    p = project("titled", user)
    {:ok, chat} = Conversations.open(p, "Why is the build slow?\nIt went from 4 to 11 minutes.")
    agent_said(chat, "The asset step.")
    {:ok, done} = Conversations.open(p, "An older one")
    {:ok, _done} = Conversations.ended(done, nil, "idle")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(
             view,
             "#conversation-#{chat.id} .chat-row-title",
             "Why is the build slow?"
           )

    refute has_element?(view, "#conversation-#{chat.id} .chat-row-title", "4 to 11")
    assert has_element?(view, "#conversation-#{chat.id} .chat-row-said", "The asset step.")
    assert has_element?(view, "#top-bar .ui-top-title > .ui-top-sub", "1 live · 2 in all")
  end

  # A live row is a machine running, and until this existed the only way to stop one was to open
  # it first. The control is beside the row rather than inside it, because the row navigates
  # (`docs/design/ui.md` § The affordance rule).
  test "a live conversation is ended from its row", %{conn: conn, user: user} do
    {:ok, chat} = Conversations.open(project("parser", user), "about the parser")

    {:ok, view, _html} = live(conn, ~p"/chats")

    refute has_element?(view, ~s(ol li a[href="/chats/#{chat.id}"] button))

    # Ending deletes the branch unless it would not merge cleanly, and the confirm says so —
    # the conversation's own page's sentence, not a quieter one of the list's.
    assert view |> element("#chat-end-#{chat.id}-confirm") |> render() =~ "its branch is deleted"
    view |> element("#chat-end-#{chat.id}") |> render_click()

    assert Jobs.get(chat.id).status == :finished
  end

  # An ended one is not a machine and has nothing to stop.
  test "a conversation that has already ended offers no way to end it", %{conn: conn, user: user} do
    {:ok, chat} = Conversations.open(project("parser", user), "about the parser")
    {:ok, _chat} = Conversations.ended(chat, nil, "closed")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, row(chat))
    refute has_element?(view, ~s(ol li button[phx-value-id="#{chat.id}"]))
  end

  # The id arrives from the client, so seeing your own list is not what decides this: the chat
  # the id names has to be one you may act on (`docs/design/identity.md` § Sequencing).
  test "ending a conversation in a project the reader is not in is refused", %{
    conn: conn,
    user: user
  } do
    {:ok, mine} = Conversations.open(project("mine", user), "about my parser")
    theirs = project("theirs", Forge.AccountsFixtures.user_fixture())
    {:ok, secret} = Conversations.open(theirs, "not yours")

    {:ok, view, _html} = live(conn, ~p"/chats")

    view
    |> element(~s(ol li button[phx-value-id="#{mine.id}"]))
    |> render_click(%{"id" => secret.id})

    assert Jobs.get(secret.id).status == :pending
  end

  test "it requires a logged-in operator" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/chats")
  end
end
