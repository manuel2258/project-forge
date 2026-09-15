defmodule Forge.QueueChatTest do
  @moduledoc """
  A conversation in the queue, and the notification its reply sends.

  The queue's promise is that you can reach the end of it and be done. A conversation is in it
  only while it is actually waiting on you — a chat mid-reply is working, not waiting — and that
  distinction is the whole of what is tested here.
  """

  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects, Push, Queue, Tickets}
  alias Forge.Push.TestSender

  setup do
    TestSender.watch()

    {:ok, project} =
      Projects.register(%{
        name: "queue-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    {:ok, chat} = Conversations.open(project, "what is this?")
    %{project: project, chat: chat, user: user_fixture()}
  end

  defp reply(chat, text) do
    :ok =
      Jobs.record_harness_event(chat.id, %{type: "job.harness.text", payload: %{text: text}})

    {:ok, chat} =
      Conversations.record_turn(chat, %{
        "turn" => System.unique_integer([:positive]),
        "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
      })

    chat
  end

  defp kinds, do: Queue.items() |> Enum.map(& &1.kind)

  test "a conversation that has not replied yet is not waiting on you", %{chat: chat} do
    refute :chat in kinds()
    assert chat.status == :pending
  end

  test "a conversation that replied is waiting on you", %{chat: chat} do
    reply(chat, "It is a game.")

    assert :chat in kinds()
    item = Enum.find(Queue.items(), &(&1.kind == :chat))
    assert item.detail.chat_id == chat.id
    assert item.ticket == nil
    assert item.project.id == chat.project_id
  end

  # Said something back, so the ball is yours again — it is working, not waiting.
  test "a conversation you have answered is not waiting on you", %{chat: chat} do
    chat = reply(chat, "Which backend?")
    assert :chat in kinds()

    {:ok, _event} = Conversations.send(chat, "postgres")

    refute :chat in kinds()
  end

  test "a finished conversation leaves the queue", %{chat: chat} do
    chat = reply(chat, "Done.")
    assert :chat in kinds()

    {:ok, _chat} = Conversations.ended(chat, nil, "closed")

    refute :chat in kinds()
  end

  # Every queue item carries a project of its own now, because a project chat cannot reach one
  # through a ticket it does not have. A ticket item must still carry the right one.
  test "every item names its project, ticket or not", %{project: project} do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    {:ok, chat} = Conversations.open(project, "about that", ticket: ticket)
    reply(chat, "Looking.")

    for item <- Queue.items() do
      assert item.project.id == project.id
    end
  end

  test "a question in the reply is on the item, so it can be answered from the queue", %{
    chat: chat
  } do
    reply(chat, """
    I need to know.

    ```question
    key: backend
    text: Which backend?
    options: [postgres, sqlite]
    ```
    """)

    item = Enum.find(Queue.items(), &(&1.kind == :chat))
    assert item.detail.question.text == "Which backend?"
    assert item.detail.question.options == ["postgres", "sqlite"]
  end

  describe "the notification" do
    setup %{user: user} do
      {:ok, _subscription} =
        Push.subscribe(user, %{
          "endpoint" => "https://push.example/a",
          "keys" => %{
            "p256dh" => Base.url_encode64(:crypto.strong_rand_bytes(65), padding: false),
            "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
          }
        })

      :ok
    end

    # A deliberate widening of "blocking questions push, everything else is digested": a reply to
    # a question you asked is an answer you are owed, and you asked it from a train platform.
    test "a completed reply pushes", %{chat: chat} do
      reply(chat, "It is a game about scores.")

      assert_receive {:push, "https://push.example/a", payload, _opts}, 2_000
      assert payload["body"] == "It is a game about scores."
      assert payload["url"] == "/chats/#{chat.id}"
    end

    # The person who interrupted the turn is the person who would be notified about it.
    test "an interrupted turn does not", %{chat: chat} do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{text: "I was say"}
        })

      {:ok, _chat} =
        Conversations.record_turn(chat, %{
          "turn" => 1,
          "interrupted" => true,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "error_during_execution"}
        })

      refute_receive {:push, _endpoint, _payload, _opts}, 300
    end

    # One notification per conversation, replaced: a chat you are having must not stack a
    # notification per exchange.
    test "it is tagged per conversation, not per turn", %{chat: chat} do
      chat = reply(chat, "First.")
      assert_receive {:push, _endpoint, _first, opts_one}, 2_000

      reply(chat, "Second.")
      assert_receive {:push, _endpoint, _second, opts_two}, 2_000

      assert opts_one[:topic] == opts_two[:topic]
    end
  end
end
