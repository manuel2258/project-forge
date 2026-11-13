defmodule ForgeWeb.ProjectRowsTest do
  @moduledoc """
  What a projects row says waits, item kind by item kind (`docs/design/ui.md` § The projects page).
  The page test stages a stuck ticket; the other kinds take a worker, a document or a chat to
  stage, so their words are checked here, on the queue item's shape.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.ProjectRows

  @ticket %{number: 40, state: "review"}

  test "each kind of waiting item is said by its ticket" do
    assert ProjectRows.waits(%{kind: :stuck, ticket: @ticket}) == "#40 is stuck in review"
    assert ProjectRows.waits(%{kind: :question, ticket: @ticket}) == "#40 asks you a question"
    assert ProjectRows.waits(%{kind: :approval, ticket: @ticket}) == "#40 waits for your approval"
    assert ProjectRows.waits(%{kind: :review, ticket: @ticket}) == "#40 waits in review for you"
    assert ProjectRows.waits(%{kind: :other, ticket: @ticket}) == "#40 waits on you"
  end

  test "a chat is said by its ticket when it has one, and as a chat when it has none" do
    assert ProjectRows.waits(%{kind: :chat, ticket: @ticket}) == "#40's chat waits for your reply"
    assert ProjectRows.waits(%{kind: :chat, ticket: nil}) == "a chat waits for your reply"
    assert ProjectRows.waits(%{kind: :other, ticket: nil}) == "something waits on you"
  end
end
