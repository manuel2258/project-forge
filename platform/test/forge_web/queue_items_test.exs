defmodule ForgeWeb.QueueItemsTest do
  @moduledoc """
  The words a queue item is named by (`ForgeWeb.QueueItems`): shared by the queue page's rows and by
  the rows of **On hold** and the project's Tickets list, which name what waits on a held ticket.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.QueueItems

  defp at(seconds), do: DateTime.add(~U[2026-01-01 00:00:00Z], seconds)

  defp question(version, key, since, blocking \\ true) do
    %{
      kind: if(blocking, do: :question, else: :assumption),
      ticket: %{id: "t"},
      project: %{name: "p"},
      since: at(since),
      question: %{
        key: key,
        blocking: blocking,
        artifact_version_id: version,
        artifact_version: %{id: version}
      }
    }
  end

  defp item(kind, since), do: %{kind: kind, ticket: %{id: "t"}, since: at(since), detail: %{}}

  test "one document's questions are one item, counted as blocking" do
    items = [question("v1", "a", 10), question("v1", "b", 20), question("v1", "c", 30, false)]

    assert [%{kind: :questions, questions: [_, _, _]} = group] = QueueItems.group(items)
    assert QueueItems.kind(group) == "2 blocking questions"
    assert QueueItems.waits(items) == "2 blocking questions"
  end

  test "two documents' questions are two items, each named" do
    items = [question("v1", "a", 10), question("v2", "b", 20)]

    assert QueueItems.waits(items) == "1 blocking question · 1 blocking question"
  end

  test "every kind has its word, joined oldest first" do
    items = [
      item(:review, 50),
      item(:stuck, 40),
      item(:approval, 10),
      item(:chat, 30),
      question("v1", "a", 20)
    ]

    assert QueueItems.waits(items) ==
             "approval · 1 blocking question · conversation · stuck · review ready"
  end

  test "nothing waiting is no words, and nouns agree with their count" do
    assert QueueItems.waits([]) == ""
    assert QueueItems.noun(1, "question") == "question"
    assert QueueItems.noun(2, "question") == "questions"
    assert QueueItems.noun(0, "question") == "questions"
  end
end
