defmodule ForgeWeb.ChatNewLiveTest do
  @moduledoc """
  Starting a conversation from the thing it is about.

  A chat was only reachable once it existed: the page was built and nothing created one. These
  are the two ways in, and each carries its context rather than asking for it.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects, Tickets, Workers}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{
          name: "new-chat-#{System.unique_integer([:positive])}",
          repo_path: seeded_repo()
        },
        user
      )

    %{project: project}
  end

  test "the project page offers one, for the project", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

    assert has_element?(view, ~s(a[href="/chats/new?project=#{project.name}"]), "New chat")
  end

  test "the ticket page offers one, for the ticket", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}")

    assert has_element?(
             view,
             ~s(a[href="/chats/new?project=#{project.name}&ticket=#{ticket.number}"]),
             "New chat"
           )
  end

  # Reached from the project, so it says which project rather than asking: nothing here picks
  # one, because unlike a ticket a conversation is never started from nowhere. Named rather than
  # asserted as "no select at all" — the model field is one whenever a worker is connected.
  test "starting one for a project opens it and goes there", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/chats/new?project=#{project.name}")

    assert html =~ project.name
    assert html =~ "About the repository as a whole"
    refute has_element?(view, ~s([name*="project"]))

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#chat-form", %{"chat" => %{"text" => "what is this?"}})
             |> render_submit()

    assert "/chats/" <> id = to
    chat = Conversations.get!(id)
    assert chat.project_id == project.id
    assert is_nil(chat.ticket_id)

    # What you typed is the first thing said, not a title: a conversation has no title, and the
    # message is already the record of it.
    assert [%{role: :user, text: "what is this?"}] = Conversations.messages(chat.id)
  end

  test "starting one for a ticket carries the ticket", %{conn: conn, project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)

    {:ok, view, html} =
      live(conn, ~p"/chats/new?project=#{project.name}&ticket=#{ticket.number}")

    assert html =~ "Persist scores"

    assert {:error, {:live_redirect, %{to: "/chats/" <> id}}} =
             view
             |> form("#chat-form", %{"chat" => %{"text" => "why did it fail?"}})
             |> render_submit()

    chat = Conversations.get!(id)
    assert chat.ticket_id == ticket.id
    # Its own branch, never the ticket's: a chat writing the ticket's ref would race its jobs.
    assert Jobs.chat_branch(chat) == "chat/" <> chat.id
  end

  test "the first message box sends on enter too", %{conn: conn, project: project} do
    {:ok, _view, html} = live(conn, ~p"/chats/new?project=#{project.name}")

    assert html =~ "SendOnEnter"
    assert html =~ "Enter sends"
  end

  test "it will not start one with nothing said", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

    html = view |> form("#chat-form", %{"chat" => %{"text" => "   "}}) |> render_submit()

    assert html =~ "say something to start with"
    assert Jobs.chats_for_project(project.id) == []
  end

  # The names are never written down in the product: each worker reports what its harness
  # resolves and what its credential may use (docs/design/worker-channel.md § What a worker
  # offers), and the form shows the union.
  describe "picking a model" do
    defp connected_worker(offer) do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, 8_000, offer)
      worker
    end

    test "is a dropdown of what the connected workers report", %{conn: conn, project: project} do
      connected_worker(%{
        "aliases" => ["opus"],
        "models" => [%{"id" => "claude-opus-5", "name" => "Claude Opus 5"}]
      })

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert has_element?(view, ~s(select#chat_model))

      assert has_element?(
               view,
               ~s(select#chat_model optgroup[label="Models"] option),
               "Claude Opus 5"
             )

      # An alias floats and an id pins, so they are offered as two groups rather than one list.
      assert has_element?(view, ~s(select#chat_model optgroup[label="Aliases"] option), "opus")
    end

    test "the empty choice is offered in words, and means the project's", %{
      conn: conn,
      project: project
    } do
      connected_worker(%{"aliases" => ["opus"]})
      {:ok, project} = Projects.set_model(project, "sonnet")

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert has_element?(view, ~s(select#chat_model option[value=""]), "sonnet")

      view
      |> form("#chat-form", %{"chat" => %{"text" => "hello", "model" => ""}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert is_nil(chat.model)
      assert Jobs.model_for(chat) == "sonnet"
    end

    # A select with one empty option would make configuring a project before starting a machine
    # impossible, and that is the order a new operator does it in.
    test "with nothing connected it is free text and still takes a name", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert render(view) =~ "No worker is connected"
      refute has_element?(view, ~s(select#chat_model))

      view
      |> form("#chat-form", %{"chat" => %{"text" => "hello", "model" => "not-offered-by-anyone"}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.model == "not-offered-by-anyone"
    end
  end

  test "a project that is not there is not found", %{conn: conn} do
    assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/chats/new?project=nope") end
  end

  test "it requires a logged-in operator", %{project: project} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/chats/new?project=#{project.name}")
  end
end
