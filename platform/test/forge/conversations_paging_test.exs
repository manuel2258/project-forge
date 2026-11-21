defmodule Forge.ConversationsPagingTest do
  @moduledoc """
  A conversation read by turns (`Forge.Conversations.talk/3`) and by its last word
  (`last_said/2`), and what is asked of the log to do it: no more of its events than the part a
  caller draws, and never a tool call for a caller that does not (`docs/design/conversations.md`
  § Messages are a projection; `docs/design/ui.md` § Talk).
  """

  use Forge.DataCase, async: false

  import Forge.ForgeFixtures

  alias Forge.{Conversations, EventReads, Events}

  setup do
    EventReads.watch()
    %{chat: chat_fixture(%{status: :running})}
  end

  defp record(chat, type, payload) do
    {:ok, event} =
      Events.append(type, {:job, chat.id}, %{job_id: chat.id, payload: payload})

    event
  end

  defp turn(chat, n, opts \\ []) do
    if Keyword.get(opts, :said, true) do
      record(chat, "chat.message", %{"text" => "question #{n}"})
      record(chat, "job.harness.text", %{"text" => "answer #{n}"})
    end

    for k <- 1..Keyword.get(opts, :calls, 0)//1 do
      record(chat, "job.harness.tool_use", %{
        "id" => "c#{n}-#{k}",
        "name" => "Bash",
        "input" => %{}
      })

      record(chat, "job.harness.tool_result", %{"tool_use_id" => "c#{n}-#{k}", "bytes" => 1})
    end

    record(chat, "chat.turn", %{"turn" => n})
  end

  defp turns(page),
    do: for(%{type: "chat.turn", payload: %{"turn" => n}} <- page.events, do: n)

  describe "talk/3" do
    test "the latest page is ten turns and the turn in progress, whole", %{chat: chat} do
      for n <- 1..25, do: turn(chat, n)
      record(chat, "chat.message", %{"text" => "and now?"})
      record(chat, "job.harness.text", %{"text" => "working on it"})

      page = Conversations.talk(chat.id, :latest)

      assert turns(page) == Enum.to_list(16..25)
      assert page.more
      assert List.last(page.events).payload["text"] == "working on it"
      assert page.from == Enum.find(Events.for_job(chat.id), &(&1.payload["turn"] == 15)).seq
    end

    test "older is the ten turns before, joined to the page by the turn they end at", %{
      chat: chat
    } do
      for n <- 1..25, do: turn(chat, n)

      latest = Conversations.talk(chat.id, :latest)
      older = Conversations.talk(chat.id, {:older, latest.from})

      assert turns(older) == Enum.to_list(6..15)
      assert older.more

      oldest = Conversations.talk(chat.id, {:older, older.from})
      assert turns(oldest) == Enum.to_list(1..5)
      assert oldest.from == 0
      refute oldest.more

      # Nothing of a page is in the next, nothing missed between.
      seqs = for page <- [oldest, older, latest], event <- page.events, do: event.seq
      assert seqs == Enum.sort(seqs) and seqs == Enum.uniq(seqs)
      assert length(seqs) == 25 * 3
    end

    test "exactly ten turns, and ten and one", %{chat: chat} do
      for n <- 1..10, do: turn(chat, n)
      refute Conversations.talk(chat.id, :latest).more
      turn(chat, 11)
      assert %{more: true} = Conversations.talk(chat.id, :latest)
    end

    test "a turn of over a hundred events is whole, on whichever page", %{chat: chat} do
      for n <- 1..12, do: turn(chat, n, calls: if(n == 2, do: 58, else: 0))

      latest = Conversations.talk(chat.id, :latest)
      older = Conversations.talk(chat.id, {:older, latest.from})

      five =
        Enum.filter(
          older.events,
          &(&1.type in ["job.harness.tool_use", "job.harness.tool_result"])
        )

      assert length(five) == 116
      assert turns(older) == [1, 2]
    end

    test "a position is snapped to the turn that holds it, and never past the conversation's own",
         %{
           chat: chat
         } do
      for n <- 1..4, do: turn(chat, n)
      events = Events.for_job(chat.id)
      inside_turn_three = Enum.at(events, 7).seq

      assert turns(Conversations.talk(chat.id, {:since, inside_turn_three})) == [3, 4]
      assert turns(Conversations.talk(chat.id, {:since, 1})) == [1, 2, 3, 4]
      # A number past everything snaps to the newest turn's end: nothing above it, and no error.
      assert %{events: []} = Conversations.talk(chat.id, {:since, 9_000_000_000})

      other = chat_fixture(%{})
      for n <- 1..3, do: turn(other, n)

      mine =
        for event <-
              Conversations.talk(chat.id, {:older, hd(Events.for_job(other.id)).seq}).events,
            do: event.job_id

      assert Enum.all?(mine, &(&1 == chat.id))
    end

    test "reads only the fold's types, a page of them", %{chat: chat} do
      for n <- 1..30, do: turn(chat, n, calls: 5)
      EventReads.rows()

      Conversations.talk(chat.id, :latest)

      # Ten turns of two messages, five calls and five results and a turn's end: 13 each, 130 in all.
      assert EventReads.most() <= 250
    end
  end

  describe "last_said/2" do
    test "is the newest said, found thirteen silent turns back", %{chat: chat} do
      turn(chat, 1)
      for n <- 2..14, do: turn(chat, n, said: false, calls: 2)
      EventReads.rows()

      assert %{role: :assistant, text: "answer 1"} = Conversations.last_said(chat.id)
      assert Conversations.last_said(chat.id, :user).text == "question 1"
      # It read ten turns at a time, and no tool call.
      assert EventReads.most() <= 30
    end

    test "is nil for a conversation that said nothing", %{chat: chat} do
      assert Conversations.last_said(chat.id) == nil
      assert Conversations.last_said(chat.id, :assistant) == nil
    end

    test "of a role is that side's", %{chat: chat} do
      turn(chat, 1)
      record(chat, "chat.message", %{"text" => "thanks"})

      assert Conversations.last_said(chat.id).text == "thanks"
      assert Conversations.last_said(chat.id, :assistant).text == "answer 1"
    end
  end

  describe "reply_ref/1" do
    test "is the same for the reply however many messages were read", %{chat: chat} do
      for n <- 1..15, do: turn(chat, n)

      whole = chat.id |> Conversations.messages() |> Conversations.reply_ref()
      last = chat.id |> Conversations.last_said() |> List.wrap() |> Conversations.reply_ref()

      page =
        Conversations.talk(chat.id, :latest).events
        |> Conversations.transcript()
        |> Conversations.said()
        |> Conversations.reply_ref()

      assert whole == last and last == page and whole != nil
    end

    test "does not move while the reply is still being spoken, and names the next reply apart", %{
      chat: chat
    } do
      first = record(chat, "job.harness.text", %{"text" => "The first"})
      ref = Conversations.reply_ref(Conversations.messages(chat.id))
      record(chat, "job.harness.text", %{"text" => "and then more"})
      assert Conversations.reply_ref(Conversations.messages(chat.id)) == ref
      assert ref == Integer.to_string(first.seq)

      record(chat, "chat.turn", %{"turn" => 1})
      record(chat, "chat.message", %{"text" => "go on"})
      record(chat, "job.harness.text", %{"text" => "Another"})
      assert Conversations.reply_ref(Conversations.messages(chat.id)) != ref
    end

    test "a reply that opened with a call is named by its first words", %{chat: chat} do
      record(chat, "job.harness.tool_use", %{"id" => "x", "name" => "Bash", "input" => %{}})
      said = record(chat, "job.harness.text", %{"text" => "Done."})

      assert chat.id |> Conversations.transcript() |> Conversations.reply_ref() ==
               Integer.to_string(said.seq)
    end
  end

  describe "messages/1" do
    test "reads the words and the turns' ends, and no tool call", %{chat: chat} do
      for n <- 1..20, do: turn(chat, n, calls: 5)
      EventReads.rows()

      assert length(Conversations.messages(chat.id)) == 40
      # 20 turns of two messages and a turn's end: 60, and none of the 200 calls and results.
      assert EventReads.most() <= 60
    end

    test "is the same words with the calls there or not", %{chat: chat} do
      with_calls = chat_fixture(%{})
      for n <- 1..3, do: turn(chat, n)
      for n <- 1..3, do: turn(with_calls, n, calls: 3)

      strip = fn messages -> Enum.map(messages, &Map.take(&1, [:role, :text, :turn])) end

      assert strip.(Conversations.messages(chat.id)) ==
               strip.(Conversations.messages(with_calls.id))
    end
  end

  describe "in_flight?/1" do
    test "is one look above the newest turn, and false for a conversation whose last turn ended",
         %{
           chat: chat
         } do
      for n <- 1..20, do: turn(chat, n, calls: 5)
      refute Conversations.in_flight?(chat)

      EventReads.rows()
      record(chat, "chat.message", %{"text" => "again"})
      assert Conversations.in_flight?(chat)
      assert EventReads.most() <= 2
    end

    test "is false for a turn that has only been reported on", %{chat: chat} do
      turn(chat, 1)
      record(chat, "job.harness.rate_limit", %{})
      refute Conversations.in_flight?(chat)
    end
  end

  describe "a position that is a turn's own end" do
    # A reconnect carries the oldest event it held; when that is a `chat.turn` (a turn that said
    # nothing has no other), the turn is the one that holds it and is read, not skipped.
    test "reads the turn that ends there, and the ones after it", %{chat: chat} do
      turn(chat, 1)
      silent = turn(chat, 2, said: false)
      turn(chat, 3)

      page = Conversations.talk(chat.id, {:since, silent.seq})

      assert turns(page) == [2, 3]
      assert page.from == Enum.at(Events.for_job(chat.id), 2).seq
    end
  end

  describe "a swept conversation" do
    test "is not something either side said", %{chat: chat} do
      turn(chat, 1)

      record(chat, "job.swept", %{"removed" => 4, "days" => 30, "ended" => "2026-10-01T00:00:00Z"})

      transcript = Conversations.transcript(chat.id)
      assert Enum.any?(transcript, &(&1.role == :swept))

      assert Enum.all?(Conversations.said(transcript), &(&1.role in [:user, :assistant]))
      assert Conversations.last_said(chat.id).text == "answer 1"
    end
  end

  describe "open_turn/1" do
    test "is what follows the newest turn's end, and the now line reads it", %{chat: chat} do
      for n <- 1..5, do: turn(chat, n, calls: 2)
      assert Conversations.open_turn(chat.id) == []

      record(chat, "job.harness.tool_use", %{
        "id" => "now",
        "name" => "Bash",
        "input" => %{"command" => "mix test"}
      })

      record(chat, "job.harness.retry", %{"attempt" => 2, "max_retries" => 5})

      open = Conversations.open_turn(chat.id)
      assert Enum.map(open, & &1.type) == ["job.harness.tool_use", "job.harness.retry"]
      assert {:retrying, 2, 5} = Conversations.now(open)
    end

    test "starts at the newest process, so a restarted turn is not read from the old one's events",
         %{chat: chat} do
      turn(chat, 1)
      record(chat, "job.harness.text", %{"text" => "said before the process went"})
      record(chat, "job.started", %{})
      record(chat, "job.harness.text", %{"text" => "said by the new process"})

      texts =
        for %{type: "job.harness.text", payload: %{"text" => t}} <-
              Conversations.open_turn(chat.id),
            do: t

      assert texts == ["said by the new process"]
    end
  end
end
