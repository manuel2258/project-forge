defmodule Forge.Look.Setups.Attachments do
  @moduledoc """
  Files people attached (`docs/design/ui.md` § Attaching files): a project chat whose first message
  came with a picture, a file whose name is long and full of markup, one that was not received and
  one withdrawn since; and a ticket whose text came with a picture, with the same files in its Docs.
  The member attached them all and is an admin, so *Withdraw* is drawn. Made-up data: the bytes
  are a few words each, never a secret. Users: `member`. Paths: `chat`, `chat_docs`, `ticket`, `ticket_activity`,
  `ticket_docs`, `new_chat`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [funded!: 1]
  import Forge.MergeFixtures, only: [jump_files: 0]
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Attachments, Conversations, Operator, Tickets}
  alias Forge.Attachments.Batch

  @hostile "<img src=x onerror=alert(1)> a very long name for a screenshot of the checkout page " <>
             "taken on a narrow phone on the train.png"

  @impl true
  def build do
    member = user_fixture()

    name = "look-attach"
    File.rm_rf!(Path.join(Forge.Projects.repos_dir(), name <> ".git"))
    {:ok, project} = Forge.Projects.register_named(name, "main", member)

    commit_files!(
      Forge.Projects.repo_path(project),
      "main",
      Map.put(jump_files(), "README.md", "# Game\n")
    )

    funded!(project)

    {:ok, ticket} =
      Operator.admit(project, member, %{
        title: "The checkout button is cut off",
        body: "See the screenshot: the button is cut off on a narrow phone.",
        on_hold: true,
        attachments: batch(project, member, [{"checkout.png", "pixels of the checkout"}])
      })

    # An answer that came with a picture: listed in the ticket's Activity, with the name under it.
    {:ok, _} =
      Operator.edit(
        Tickets.get!(ticket.id),
        member,
        "notes.md",
        """
        Which button?

        ```question
        key: which
        anchor: "Which button?"
        text: "Which button is cut off?"
        options:
          - label: "Start"
            detail: "The first one."
          - label: "Pay"
            detail: "The last one."
        blocking: false
        assumption: "Pay"
        ```
        """,
        "0"
      )

    {:ok, _} =
      Operator.answer(Tickets.get!(ticket.id), member, "which", %{choice: "Start"},
        attachments: batch(project, member, [{"which-button.png", "the button I mean"}])
      )

    {:ok, chat} = Conversations.open(project, "Why does the button look like this?")

    {:ok, _event} =
      Operator.send_chat(chat, member, "Here is what I see.",
        attachments:
          batch(
            project,
            member,
            [
              {"button.png", "pixels of the button"},
              {@hostile, "more pixels"},
              {"old.png", "an older picture"}
            ],
            ["recording.mov"]
          )
      )

    {:ok, _rows} =
      Attachments.withdraw({:job, chat.id}, member, "attachments/old.png", :all, "wrong one")

    %{
      users: %{"member" => member},
      paths: %{
        "chat" => "/chats/#{chat.id}",
        "chat_docs" => "/chats/#{chat.id}?tab=docs",
        "new_chat" => "/chats/new?project=#{project.name}",
        "ticket" => "/tickets/#{project.name}/#{Tickets.get!(ticket.id).number}",
        "ticket_activity" => "/tickets/#{project.name}/#{ticket.number}?tab=activity",
        "ticket_docs" => "/tickets/#{project.name}/#{ticket.number}?tab=docs"
      }
    }
  end

  defp batch(project, user, files, failed \\ []) do
    uploads =
      for {name, bytes} <- files do
        path = Path.join(System.tmp_dir!(), "look-attach-#{System.unique_integer([:positive])}")
        File.write!(path, bytes)
        {:ok, upload} = Attachments.stage(project, user, {:file, path}, name)
        File.rm(path)
        %{id: upload.id, name: name}
      end

    %Batch{uploads: uploads, not_received: failed}
  end
end
