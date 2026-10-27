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

  defp project_of(owner) do
    {:ok, project} =
      Projects.register(
        %{name: "theirs-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        owner
      )

    project
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

    assert html =~ ~s(phx-hook="ForgeWeb.Conversations.Composer")
    assert html =~ ~s|data-newline-on="(pointer: coarse)"|
    assert html =~ "Enter sends"
  end

  # The first message can arrive in the address; only text is taken from it.
  test "takes the first message from the address, and only text", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}&text=lib/a.ex:3")
    assert view |> element("#chat_text") |> render() =~ "lib/a.ex:3"

    {:ok, view, _html} = live(conn, "/chats/new?project=#{project.name}&text[a]=b")
    refute view |> element("#chat_text") |> render() =~ "%{"
  end

  test "it will not start one with nothing said", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

    html = view |> form("#chat-form", %{"chat" => %{"text" => "   "}}) |> render_submit()

    assert html =~ "say something to start with"
    assert Jobs.chats_for_project(project.id) == []
  end

  # The names are never written down in the product: each worker reports what its harness
  # resolves, the credentials in the project's pool say which models they may use
  # (docs/design/credentials.md § Checked on save), and the form shows both.
  describe "picking a model" do
    defp connected_worker(offer) do
      {:ok, worker, _token} = Workers.create(%{provider: "fake"})
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000, "harness" => offer})
      worker
    end

    # The aliases are the machines' — names the harness binary resolves — and the models are the
    # project's pool's, because a machine holds no credential and which models may be called is an
    # account's (`docs/design/credentials.md` § Checked on save).
    test "is a dropdown of the workers' aliases and the project's credentials' models", %{
      conn: conn,
      project: project
    } do
      connected_worker(%{"aliases" => ["opus"]})

      Forge.ForgeFixtures.pool!(
        project,
        Forge.ForgeFixtures.credential_fixture(Forge.AccountsFixtures.user_fixture(),
          models: [%{"id" => "claude-opus-5", "name" => "Claude Opus 5"}]
        )
      )

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

    # The effort is chosen on the same form and resolves through the same chain. A box here,
    # because no worker is connected to offer a level.
    test "an effort typed on the form is the conversation's", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      view
      |> form("#chat-form", %{"chat" => %{"text" => "hello", "effort" => "high"}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.effort == "high"
      assert Jobs.effort_for(chat) == "high"
    end

    test "an empty effort is the project's, and the model stays its own choice", %{
      conn: conn,
      project: project
    } do
      connected_worker(%{"aliases" => ["opus"]})
      {:ok, project} = Projects.set_effort(project, "low")

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      view
      |> form("#chat-form", %{
        "chat" => %{"text" => "hello", "model" => "opus", "effort" => ""}
      })
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert is_nil(chat.effort)
      assert chat.model == "opus"
      assert Jobs.effort_for(chat) == "low"
    end

    test "the effort is a dropdown of the levels the workers offer, and the empty choice names the project's",
         %{conn: conn, project: project} do
      connected_worker(%{"efforts" => ~w(low high)})
      {:ok, project} = Projects.set_effort(project, "low")

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert has_element?(view, ~s(select#chat_effort option[value=""]), "low")
      assert has_element?(view, ~s(select#chat_effort option[value="high"]))
      refute has_element?(view, ~s(input#chat_effort))

      view
      |> form("#chat-form", %{"chat" => %{"text" => "hello", "effort" => "high"}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.effort == "high"
    end

    # A worker that reports aliases and no levels is a build older than this field: a box, with
    # the hint saying why. Decided on the levels, so a model alias being offered changes nothing.
    test "a worker that offers no levels leaves the effort a box", %{conn: conn, project: project} do
      connected_worker(%{"aliases" => ["opus"]})

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      assert has_element?(view, ~s(input#chat_effort[type=text]))
      refute has_element?(view, ~s(select#chat_effort))
      assert render(view) =~ "No connected worker offers a level"
    end

    # The list is an offer. A harness newer than the workers may take a level they never
    # reported, and the form's select is the browser's protection and not the platform's.
    test "a level nobody offers is still stored", %{conn: conn, project: project} do
      connected_worker(%{"efforts" => ~w(low high)})

      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      render_submit(view, "open", %{"chat" => %{"text" => "hello", "effort" => "ultra"}})

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.effort == "ultra"
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

  describe "the bare route" do
    # The chats page is every project at once and so has no project to carry. This is the one
    # create view that has to ask, the same exception `/tickets/new` already is.
    test "asks which project", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/chats/new")

      assert has_element?(view, ~s(select#chat_project))
      assert has_element?(view, ~s(select#chat_project option[value="#{project.name}"]))
    end

    test "starts the conversation in the project that was chosen", %{conn: conn, user: user} do
      {:ok, elsewhere} =
        Projects.register(
          %{name: "other-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, view, _html} = live(conn, ~p"/chats/new")

      view
      |> form("#chat-form", %{"chat" => %{"project" => elsewhere.name}})
      |> render_change()

      assert {:error, {:live_redirect, _to}} =
               view
               |> form("#chat-form", %{
                 "chat" => %{"project" => elsewhere.name, "text" => "about this one"}
               })
               |> render_submit()

      assert [_chat] = Jobs.chats_for_project(elsewhere.id)
    end

    # The models are the chosen project's pool's, so choosing another project on this route changes
    # them: a model offered for the wrong project is one its jobs would have no credential for.
    test "choosing another project offers that project's models", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, elsewhere} =
        Projects.register(
          %{name: "zz-other-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      owner = Forge.AccountsFixtures.user_fixture()

      Forge.ForgeFixtures.pool!(
        project,
        Forge.ForgeFixtures.credential_fixture(owner, models: [%{"id" => "first-projects"}])
      )

      Forge.ForgeFixtures.pool!(
        elsewhere,
        Forge.ForgeFixtures.credential_fixture(owner, models: [%{"id" => "second-projects"}])
      )

      {:ok, view, _html} = live(conn, ~p"/chats/new")
      assert has_element?(view, ~s(select#chat_model option[value="first-projects"]))

      view
      |> form("#chat-form", %{"chat" => %{"project" => elsewhere.name}})
      |> render_change()

      assert has_element?(view, ~s(select#chat_model option[value="second-projects"]))
      refute has_element?(view, ~s(select#chat_model option[value="first-projects"]))
    end

    # What was typed and chosen is the form's, not the project's: changing the project re-reads
    # both lists and must leave the message, the model and the level where they were put.
    test "choosing another project keeps the text, the model and the effort", %{
      conn: conn,
      user: user,
      project: project
    } do
      connected_worker(%{"aliases" => ["opus"], "efforts" => ~w(low high)})

      {:ok, elsewhere} =
        Projects.register(
          %{name: "zz-keep-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
          user
        )

      {:ok, view, _html} = live(conn, ~p"/chats/new")

      view
      |> form("#chat-form", %{
        "chat" => %{
          "project" => project.name,
          "text" => "half a thought",
          "model" => "opus",
          "effort" => "high"
        }
      })
      |> render_change()

      view
      |> form("#chat-form", %{"chat" => %{"project" => elsewhere.name}})
      |> render_change()

      assert has_element?(view, ~s(select#chat_effort option[value="high"][selected]))
      assert has_element?(view, ~s(select#chat_model option[value="opus"][selected]))
      assert view |> element("#chat_text") |> render() =~ "half a thought"
    end

    # The select offers only the projects you are in, so a name that is not in it is a project
    # you cannot see — and the guard is `Operator.open_chat/4`, not the options.
    test "a project the reader is not in cannot be chosen", %{conn: conn} do
      theirs =
        project_of(Forge.AccountsFixtures.user_fixture())

      {:ok, view, _html} = live(conn, ~p"/chats/new")

      refute has_element?(view, ~s(select#chat_project option[value="#{theirs.name}"]))

      # Pushed rather than submitted through the form, because the form refuses an option it
      # was never offered — which is the browser's protection and not the platform's. What has
      # to hold is that a name off the wire does not become a conversation.
      render_submit(view, "open", %{"chat" => %{"project" => theirs.name, "text" => "let me in"}})

      assert Jobs.chats_for_project(theirs.id) == []
    end
  end

  describe "what it asks for" do
    # A chat had no way to say, so it took the platform's number whatever it was about — which
    # is what put a conversation that compiles nothing on a build's slice
    # (`docs/design/conversations.md` § What it asks for).
    test "the figures typed are what the conversation is admitted with", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      view
      |> form("#chat-form", %{
        "chat" => %{"text" => "build the release", "memory" => "4GiB", "cores" => "2"}
      })
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.memory_max == 4 * 1024 * 1024 * 1024
      assert chat.cores == 2
    end

    test "saying nothing is the platform's own figures", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      view
      |> form("#chat-form", %{"chat" => %{"text" => "just talking"}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.memory_max == Jobs.default_resources().memory
      assert chat.cores == Jobs.default_resources().cores
    end

    # Refused where it was typed, and not quietly turned into the default: a person who wrote
    # `2 gigs` asked for something, and a conversation started on the default instead is the
    # silent substitution the templates page was already fixed not to make.
    test "a memory that is not a size is refused rather than replaced", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      html =
        view
        |> form("#chat-form", %{"chat" => %{"text" => "hello", "memory" => "2 gigs"}})
        |> render_submit()

      assert html =~ "memory has to be a size"
      assert Jobs.chats_for_project(project.id) == []
    end

    # `2` is a size — two bytes — and the one that took a machine down: typed meaning 2 GiB, it
    # was admitted, and the harness could never start in it. Refused by name, with the minimum.
    test "a memory below the minimum is refused and the minimum is named", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      html =
        view
        |> form("#chat-form", %{"chat" => %{"text" => "hello", "memory" => "2"}})
        |> render_submit()

      assert html =~ "memory must be at least 512MiB, the least a job can run in"
      assert Jobs.chats_for_project(project.id) == []

      view
      |> form("#chat-form", %{"chat" => %{"text" => "hello", "memory" => "512MiB"}})
      |> render_submit()

      assert [chat] = Jobs.chats_for_project(project.id)
      assert chat.memory_max == 536_870_912
    end

    test "cores that are not a whole number above zero are refused", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?project=#{project.name}")

      html =
        view
        |> form("#chat-form", %{"chat" => %{"text" => "hello", "cores" => "0"}})
        |> render_submit()

      assert html =~ "cores has to be a whole number"
      assert Jobs.chats_for_project(project.id) == []
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
