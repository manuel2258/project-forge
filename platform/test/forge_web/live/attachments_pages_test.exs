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
