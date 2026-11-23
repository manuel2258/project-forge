defmodule ForgeWeb.AttachmentsPagesTest do
  @moduledoc """
  What a person sees of the files they attach (`docs/design/ui.md` § Attaching files): the box on
  every place they write, the names under what was sent, the Docs row and its withdrawal. The
  bytes and the guards are `Forge.AttachmentsTest`'s; this is the pages.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Attachments, Conversations, Projects, Repo, Tickets}
  alias Forge.Attachments.Attachment

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "att-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    %{project: project}
  end

  defp staged!(project, user, original, bytes \\ "bytes") do
    path = Path.join(tmp_dir("src"), "#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    {:ok, upload} = Attachments.stage(project, user, {:file, path}, original)
    upload.id
  end

  defp files(ids_and_names) do
    %{
      "ids" => Enum.map(ids_and_names, &elem(&1, 0)),
      "names" => Enum.map(ids_and_names, &elem(&1, 1))
    }
  end

  describe "the box" do
    # The inventory of criterion 1's places that a page draws on load: a form that stops drawing
    # `[data-attach]` is a place a person can no longer attach, and nothing else would say so.
    test "is on a chat's message form and on the forms that start one", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "what is this?")

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      assert has_element?(view, "form#say [data-attach]")

      {:ok, view, _html} = live(conn, ~p"/chats/new?#{[project: project.name]}")
      assert has_element?(view, "form#chat-form [data-attach]")

      {:ok, view, _html} = live(conn, ~p"/chats")
      assert has_element?(view, "form#chat-start [data-attach]")

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")
      assert has_element?(view, "form#chat-start [data-attach]")
    end

    test "carries the pool's own limits, so a refusal can name them", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "what is this?")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      html = view |> element("[data-attach]") |> render()
      assert html =~ ~s(data-pool-files="#{Attachments.limits().pool_files}")
      assert html =~ ~s(data-pool-bytes="#{Attachments.limits().pool_bytes}")
    end

    test "carries the upload address and the limits the page knows", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "what is this?")
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      html = view |> element("[data-attach]") |> render()
      assert html =~ ~s(data-url="/projects/#{project.name}/uploads")
      assert html =~ ~s(data-max-files="10")
      assert html =~ ~s(data-max-bytes="#{Attachments.limits().file_bytes}")
      assert html =~ ~s(type="file")
      assert html =~ "multiple"
    end

    test "the document editor, the notes and the question card draw it when given a project" do
      html =
        render_component(&ForgeWeb.Operator.Components.document_editor/1,
          ticket: %{id: "t"},
          name: "feedback.md",
          latest: nil,
          drafts: %{},
          project: "p"
        )

      assert html =~ "data-attach"

      refute render_component(&ForgeWeb.Operator.Components.document_editor/1,
               ticket: %{id: "t"},
               name: "feedback.md",
               latest: nil,
               drafts: %{}
             ) =~ "data-attach"
    end
  end

  describe "the compact control" do
    # Ticket 71: *Attach files* was a full-width row under every form, and a chat's dock with a
    # question open drew two. It is a round paperclip inside the field's corner now, drawn once.
    test "is a paperclip inside a chat's reply field, never a row of its own", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "what is this?")
      {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(
               view,
               ~s(form#say .ui-composer-field > .ui-attach-clip input[type=file][aria-label="Attach files"])
             )

      refute html =~ "ui-attach-button"
      # Nothing attached adds no height: the list is empty, and the waiting words are hidden.
      assert has_element?(view, "form#say .ui-attach-list:empty")

      assert has_element?(
               view,
               "form#say [data-attach-waiting][hidden]",
               "Sending when uploads finish"
             )
    end

    test "is drawn once in a chat's dock: the question card has none", %{
      conn: conn,
      project: project
    } do
      {:ok, chat} = Conversations.open(project, "which?")
      Forge.ForgeFixtures.chat_started!(chat)

      :ok =
        Forge.Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{text: "```question\nkey: backend\ntext: Which one?\n```\n"}
        })

      {:ok, _chat} =
        Conversations.record_turn(chat, %{
          "turn" => 1,
          "harness" => %{"turns" => 1, "usage" => 1, "cost_usd" => 0.01, "subtype" => "success"}
        })

      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      assert has_element?(view, "#answer-rows form")
      refute has_element?(view, "#answer-rows [data-attach]")
      refute has_element?(view, "#answer-rows .ui-attach-clip")

      doc = view |> render() |> Floki.parse_document!()
      assert length(Floki.find(doc, "[data-attach]")) == 1
      assert length(Floki.find(doc, ".ui-attach-clip")) == 1
    end

    test "is inside the field of every form that starts a chat, and of a new ticket's body", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/new?#{[project: project.name]}")
      assert has_element?(view, "form#chat-form [data-attach] #chat_text ~ div .ui-attach-clip")

      {:ok, view, _html} = live(conn, ~p"/chats")

      assert has_element?(
               view,
               "form#chat-start [data-attach] .ui-composer-field .ui-attach-clip"
             )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")

      assert has_element?(
               view,
               "form#chat-start [data-attach] .ui-composer-field .ui-attach-clip"
             )

      {:ok, view, _html} = live(conn, ~p"/tickets/new?#{[project: project.name]}")
      assert has_element?(view, "form [data-attach] .ui-field-box .ui-attach-clip")
      refute has_element?(view, ".ui-attach-button")
    end

    # The queue's and a ticket's card have no reply box under them, so the clip sits beside Send.
    test "is beside Send on a question card that is given a project, and absent on one that is not" do
      questions = [
        %{
          key: "naming",
          text: "Which?",
          anchor: nil,
          assumption: nil,
          blocking: true,
          line: 1,
          options: []
        }
      ]

      card = fn project ->
        render_component(&ForgeWeb.Operator.QuestionForm.question_form/1,
          id: "card",
          questions: questions,
          forms: %{},
          submit: "questions:send",
          project: project
        )
        |> Floki.parse_fragment!()
      end

      with = card.("p")
      assert [_] = Floki.find(with, ".qcard-dock > .ui-attach-clip")
      assert [_] = Floki.find(with, "[data-attach] .qcard-foot")
      assert Floki.find(card.(nil), "[data-attach], .ui-attach-clip") == []
    end

    test "the document editor and the notes put it inside the textarea's corner" do
      html =
        render_component(&ForgeWeb.Operator.Components.document_editor/1,
          ticket: %{id: "t"},
          name: "feedback.md",
          latest: nil,
          drafts: %{},
          project: "p"
        )
        |> Floki.parse_fragment!()

      assert [_] = Floki.find(html, "[data-attach] textarea ~ div .ui-attach-clip")
    end
  end

  # Files alone (ticket 71): a chat message, and the opening of a chat, may carry nothing else.
  describe "files alone" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "what is this?")
      Forge.ForgeFixtures.chat_started!(chat)
      %{chat: chat}
    end

    defp said(chat), do: length(Forge.Events.for_job(chat.id))

    test "a reply of files with nothing typed is sent, as a bubble holding only its names", %{
      conn: conn,
      project: project,
      user: user,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      id = staged!(project, user, "shot.png")

      html =
        render_hook(view, "send", %{"text" => "", "attachments" => files([{id, "shot.png"}])})

      assert [%{text: "", role: :user} | _] =
               Enum.filter(
                 Conversations.transcript(chat.id),
                 &(&1.role == :user and &1.text == "")
               )

      assert has_element?(view, "[data-said=you] [data-attached]", "shot.png")
      # The bubble is the names alone: no empty paragraph of words above them.
      refute has_element?(view, "[data-said=you] [data-attached]:first-child ~ .msg")
      assert html =~ "queued"
    end

    test "a reply with no text whose every file failed sends nothing, and the box says so", %{
      conn: conn,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      before = said(chat)

      render_hook(view, "send", %{"text" => "", "attachments" => %{"failed" => ["big.mov"]}})

      assert said(chat) == before
      assert_push_event(view, "attach:sent", %{})
    end

    test "nothing typed and nothing attached still sends nothing", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      before = said(chat)

      render_hook(view, "send", %{"text" => "   "})

      assert said(chat) == before
    end

    # Every form that starts a chat: the same membership check, the same rule. A first file's name
    # is what it is called by.
    test "files alone start a chat from each of the three forms", %{
      conn: conn,
      project: project,
      user: user
    } do
      attach = fn name -> files([{staged!(project, user, name), name}]) end

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")
      render_hook(view, "chat:start", %{"text" => "", "attachments" => attach.("one.png")})
      assert {path, _flash} = assert_redirect(view)
      assert path =~ "/chats/"

      {:ok, view, _html} = live(conn, ~p"/chats")

      render_hook(view, "chat:start", %{
        "project" => project.name,
        "text" => "",
        "attachments" => attach.("two.png")
      })

      assert_redirect(view)

      {:ok, view, _html} = live(conn, ~p"/chats/new?#{[project: project.name]}")

      render_hook(view, "open", %{
        "chat" => %{"project" => project.name, "text" => ""},
        "attachments" => attach.("three.png")
      })

      assert_redirect(view)

      titles =
        project.id
        |> Forge.Jobs.chats_for_project()
        |> Enum.map(& &1.id)
        |> Conversations.opening_words()
        |> Map.values()

      assert "one.png" in titles and "two.png" in titles and "three.png" in titles
    end

    test "files that all failed start nothing, from any form", %{conn: conn, project: project} do
      before = length(Forge.Jobs.chats_for_project(project.id))
      failed = %{"failed" => ["big.mov"]}

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}?view=chats")
      render_hook(view, "chat:start", %{"text" => "", "attachments" => failed})
      assert_push_event(view, "attach:sent", %{})

      {:ok, view, _html} = live(conn, ~p"/chats")

      render_hook(view, "chat:start", %{
        "project" => project.name,
        "text" => "",
        "attachments" => failed
      })

      assert_push_event(view, "attach:sent", %{})

      {:ok, view, _html} = live(conn, ~p"/chats/new?#{[project: project.name]}")

      html =
        render_hook(view, "open", %{
          "chat" => %{"project" => project.name, "text" => ""},
          "attachments" => failed
        })

      assert html =~ "say something to start with"
      assert_push_event(view, "attach:sent", %{})
      assert length(Forge.Jobs.chats_for_project(project.id)) == before
    end

    # A file's name is text, as every name on these pages: markup in it is shown as written.
    test "a chat named after a file shows markup in the name as text", %{
      conn: conn,
      project: project,
      user: user
    } do
      batch = %Forge.Attachments.Batch{
        uploads: [%{id: staged!(project, user, "<b>x</b>.png"), name: "<b>x</b>.png"}]
      }

      {:ok, chat} = Conversations.open(project, "", actor: {:user, user.id}, attachments: batch)

      {:ok, view, html} = live(conn, ~p"/chats/#{chat.id}")
      refute html =~ "<b>x</b>"
      refute view |> element("#top-bar") |> render() =~ "<b>x</b>"

      {:ok, _view, html} = live(conn, ~p"/chats")
      refute html =~ "<b>x</b>"
    end
  end

  describe "a chat message with files" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "what is this?")
      %{chat: chat}
    end

    test "names them under the person's bubble, as links, and says which were not received", %{
      conn: conn,
      project: project,
      user: user,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      id = staged!(project, user, "Screen Shot.png")

      html =
        render_hook(view, "send", %{
          "text" => "see this",
          "attachments" => Map.put(files([{id, "Screen Shot.png"}]), "failed", ["big.mov"])
        })

      assert html =~ "Screen-Shot.png"
      assert html =~ ~s(href="/chats/#{chat.id}/artifacts/attachments%2FScreen-Shot.png/1")
      assert html =~ "big.mov"
      assert html =~ "not received"
    end

    test "a file whose upload was never sent is not attached", %{
      conn: conn,
      project: project,
      user: user,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")
      _unsent = staged!(project, user, "never.png")

      html = render_hook(view, "send", %{"text" => "no files here"})

      refute html =~ "never.png"
      assert Attachments.pool(Conversations.pool(chat)) == []
    end

    test "is in the chat's Docs with who attached it, and withdrawing it says so", %{
      conn: conn,
      project: project,
      user: user,
      chat: chat
    } do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")
      id = staged!(project, user, "shot.png")
      render_hook(view, "send", %{"text" => "x", "attachments" => files([{id, "shot.png"}])})

      html = view |> element("a[href*=attachments]") |> render()
      assert html =~ "shot.png" or has_element?(view, "#doc-attachments\\/shot\\.png")

      assert has_element?(view, "form[phx-submit='attachments:withdraw']")
      # Who attached it, as a ticket's Docs rows say who wrote them.
      assert has_element?(view, ~s(section[id="doc-attachments/shot.png"]), user.email)

      view
      |> form("form[phx-submit='attachments:withdraw']", %{"which" => "all", "reason" => "oops"})
      |> render_submit()

      assert [%Attachment{withdrawn_at: %DateTime{}, withdraw_reason: "oops"}] =
               Repo.all(Attachment)

      assert render(view) =~ "withdrawn"
      refute has_element?(view, "form[phx-submit='attachments:withdraw']")
    end

    test "a member who did not attach it is refused, in place, and nothing is withdrawn", %{
      conn: _conn,
      project: project,
      user: user,
      chat: chat
    } do
      id = staged!(project, user, "shot.png")

      {:ok, _} =
        Forge.Operator.send_chat(chat, user, "x",
          attachments: %Attachments.Batch{uploads: [%{id: id, name: "shot.png"}]}
        )

      other = Forge.AccountsFixtures.user_fixture()
      Forge.ForgeFixtures.join!(project, other, :member)
      conn = build_conn() |> log_in_user(other)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}?tab=docs")

      # The form is not drawn for them, so a press sent by hand is the context's to refuse.
      refute has_element?(view, "form[phx-submit='attachments:withdraw']")

      html =
        render_hook(view, "attachments:withdraw", %{
          "name" => "attachments/shot.png",
          "which" => "all"
        })

      assert html =~ "may withdraw it"
      assert [%Attachment{withdrawn_at: nil}] = Repo.all(Attachment)
    end
  end

  describe "the ticket's page" do
    setup %{project: project, user: user} do
      {:ok, ticket} =
        Forge.Operator.admit(project, user, %{
          title: "Bug",
          body: "See the picture.",
          on_hold: false,
          attachments: %Attachments.Batch{
            uploads: [%{id: staged!(project, user, "bug.png"), name: "bug.png"}]
          }
        })

      %{ticket: Tickets.get!(ticket.id)}
    end

    test "Docs lists the file under Built from, and Activity says it was attached", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")

      assert has_element?(view, "#docs-built_from")

      # A long name is cut short on screen and whole in the title (criterion 22); another artifact's
      # name breaks as it always has.
      assert has_element?(view, ~s(.work-doc-name-cut[title="attachments/bug.png"]))
      refute has_element?(view, ~s(#doc-ticket .work-doc-name-cut))
      # An ordinary artifact's name is on its row, broken rather than cut.
      assert has_element?(view, ~s(#doc-ticket span.break-all), "ticket")
      assert has_element?(view, ~s(section[id="doc-attachments/bug.png"]))
      assert has_element?(view, "form[phx-submit='attachments:withdraw']")

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")
      assert render(view) =~ "attachment.added"
      assert render(view) =~ "attachments/bug.png v1"
    end

    test "a file a project token attached is under Built from too", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, _secret, token} =
        Forge.Git.Tokens.issue(project, name: "ci", git: :reader, api: :write)

      path = Path.join(tmp_dir("src"), "ci")
      File.write!(path, "x")
      {:ok, upload} = Attachments.stage(project, token, {:file, path}, "ci.png")

      {:ok, _} =
        Attachments.claim(
          {:ticket, ticket.id},
          token,
          %Attachments.Batch{uploads: [%{id: upload.id, name: "ci.png"}]},
          :note,
          :added
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")

      assert has_element?(view, ~s(#docs-built_from section[id="doc-attachments/ci.png"]), "ci")
    end

    test "Steps names the files that came with the ticket's text", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=steps")

      assert has_element?(view, "#steps [data-attached]", "bug.png")
      assert has_element?(view, ~s(#steps a[href*="artifacts"]), "bug.png")
    end

    test "an answer that came with files is listed, with the names under it", %{
      conn: conn,
      project: project,
      user: user,
      ticket: ticket
    } do
      doc = """
      Which?

      ```question
      key: naming
      anchor: "Which?"
      text: "Which?"
      options:
        - label: "a"
          detail: "one"
        - label: "b"
          detail: "two"
      blocking: false
      assumption: "a"
      ```
      """

      {:ok, _} = Forge.Operator.edit(ticket, user, "notes.md", doc, "0")

      {:ok, _} =
        Forge.Operator.answer(Tickets.get!(ticket.id), user, "naming", %{choice: "b"},
          attachments: %Attachments.Batch{
            uploads: [%{id: staged!(project, user, "why.png"), name: "why.png"}]
          }
        )

      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=activity")

      assert has_element?(view, "#ticket-events [data-attached]", "why.png")
      assert has_element?(view, "#ticket-events", "question.answered")
      # In words, not the ids of the rows.
      assert has_element?(view, "#ticket-events", "answered naming")
      refute render(view) =~ "answer_id="
    end

    test "a ticket's text names the file that came with it", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")
      assert has_element?(view, "#doc-ticket [data-attached]", "bug.png")
    end

    test "withdrawing records who and why, and the row says withdrawn", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      {:ok, view, _html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=docs")

      view
      |> form("form[phx-submit='attachments:withdraw']", %{"which" => "1", "reason" => "wrong"})
      |> render_submit()

      assert [%Attachment{withdraw_reason: "wrong"}] = Repo.all(Attachment)
      assert has_element?(view, ~s(section[id="doc-attachments/bug.png"]), "withdrawn")
    end
  end
end
