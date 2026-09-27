defmodule ForgeWeb.TranscriptTest do
  @moduledoc """
  How a conversation is drawn from its messages (`docs/design/ui.md` § Talk): when a turn's calls
  are folded, which text is a box, and where the plan is drawn. `Forge.Conversations.transcript/1`
  makes the messages; here they are written out, so each rule is aimed at directly.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeWeb.Transcript

  @at ~U[2026-09-26 12:00:00Z]

  defp agent(items, turn \\ nil),
    do: %{role: :assistant, items: items, text: "", at: @at, turn: turn}

  defp call(id, name, input),
    do:
      {:action,
       %{
         id: id,
         name: name,
         input: input,
         at: @at,
         result: %{is_error: false, excerpt: "", bytes: 0},
         children: []
       }}

  defp plan(id, items),
    do:
      call(id, "TodoWrite", %{
        "todos" =>
          for({content, status} <- items, do: %{"content" => content, "status" => status})
      })

  defp draw(messages, live \\ true),
    do:
      render_component(&Transcript.transcript/1, messages: messages, live: live, now: @at)
      |> Floki.parse_fragment!()

  describe "a turn's calls" do
    test "are every line while the turn is open in a live conversation" do
      doc = draw([agent([call("t1", "Bash", %{"command" => "mix test"})])])

      assert [_live] = Floki.find(doc, "[data-run=live]")
      assert Floki.find(doc, "[data-run=folded]") == []
    end

    test "fold once the turn has ended" do
      doc = draw([agent([call("t1", "Bash", %{"command" => "mix test"})], 1)])

      assert [_folded] = Floki.find(doc, "[data-run=folded]")
    end

    # A conversation that has stopped will not finish the reply it was cut off in, so its calls
    # are history like any ended turn's, not lines still being added to.
    test "fold in a conversation that has stopped, though the turn never ended" do
      doc = draw([agent([call("t1", "Bash", %{"command" => "mix test"})])], false)

      assert [_folded] = Floki.find(doc, "[data-run=folded]")
      assert Floki.find(doc, "[data-run=live]") == []
    end
  end

  # A model ends a block with a newline now and then, and a block of nothing but that is not
  # something it said.
  test "a block of only whitespace is not a box" do
    doc = draw([agent([{:text, "Hello."}, {:text, "  \n "}, {:text, "World."}], 1)])

    assert doc |> Floki.find("[data-said=agent]") |> length() == 2
  end

  describe "a turn's plan" do
    # Drawn once, where the agent first wrote it, as it stands now: the plan redrawn in place
    # rather than repeated each time the agent ticks an item.
    test "is drawn at the first TodoWrite, as the latest one says" do
      doc =
        draw([
          agent(
            [
              plan("p1", [{"parse", "in_progress"}, {"lex", "pending"}]),
              {:text, "Parsing done."},
              plan("p2", [{"parse", "completed"}, {"lex", "in_progress"}])
            ],
            1
          )
        ])

      assert [first_run, _second_run] = Floki.find(doc, "[data-run]")
      assert [todo] = Floki.find(first_run, "[data-action=todo]")

      assert todo |> Floki.find("li") |> Enum.map(&String.trim(Floki.text(&1))) ==
               ["☑parse", "▸lex"]

      assert Floki.find(doc, "[data-action=todo]") == [todo]
    end

    # The line above the now line: where the agent is in its own plan, whichever of its replies
    # last changed it.
    test "above the now line is the latest anywhere in the conversation" do
      messages = [
        agent([plan("p1", [{"parse", "in_progress"}])], 1),
        %{role: :user, id: "1", text: "go on", at: @at, delivered: true},
        agent([plan("p2", [{"parse", "completed"}, {"lex", "in_progress"}])], 2),
        agent([{:text, "Still going."}])
      ]

      assert [%{"content" => "parse", "status" => "completed"}, %{"content" => "lex"}] =
               Transcript.plan(messages)
    end
  end
end
