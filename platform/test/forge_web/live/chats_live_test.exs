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

  # The figure in the header is the count of conversations holding a machine. It is the only
  # number on the page and the reason to look at it at all, so it has to be that count and not,
  # say, the length of the list.
  test "the live count is the number of conversations still holding a machine", %{
    conn: conn,
    user: user
  } do
    {:ok, running} = Conversations.open(project("parser", user), "still going")
    {:ok, finished} = Conversations.open(project("engine", user), "all done")
    {:ok, _closed} = Conversations.ended(finished, nil, "closed")

    {:ok, view, _html} = live(conn, ~p"/chats")

    assert has_element?(view, row(running))
    assert has_element?(view, row(finished))
    assert view |> element("header span.font-mono") |> render() =~ "1 live"
  end

  test "a node with no conversations says so instead of drawing an empty list", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/chats")

    refute has_element?(view, "ol li")
    assert render(view) =~ "No conversations yet"
  end

  test "it requires a logged-in operator" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/chats")
  end
end
