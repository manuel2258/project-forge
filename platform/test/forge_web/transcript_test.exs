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

  describe "a question the agent asked" do
    @asked """
    Two ways to keep it.

    ```question
    key: store
    text: Where should scores live?
    options: [{label: disk, detail: A file}, {label: db, detail: Postgres}]
    ```

    Say which.
    """

    test "is drawn as what it asks, not as the block's YAML" do
      doc = draw([agent([{:text, @asked}], 1)])
      text = Floki.text(doc)

      assert text =~ "Where should scores live?"
      assert text =~ "disk · db"
      assert text =~ "Two ways to keep it."
      assert text =~ "Say which."
      refute text =~ "key: store"
      assert Floki.find(doc, "[data-said=agent] blockquote") != []
    end

    test "is left as written when a fence is not one of the document's questions" do
      nested = "````markdown\n```question\nkey: k\ntext: Not asked\n```\n````\n"
      assert Transcript.asked(nested) == nested
      assert Transcript.asked("Nothing asked.") == "Nothing asked."
    end

    # The review's case: an example fence inside another block, which the parser does not read,
    # and a real question its parser does read but a column-0 regex would not ("``` question",
    # indented). One miss each way gave equal counts, and the real question's words were written
    # into the example's code block while the real one stayed raw YAML.
    test "replaces the block the parser read, not the one a second reading finds" do
      example = "````markdown\n```question\nkey: k\ntext: EXAMPLE\n```\n````\n"
      real = "  ``` question\n  key: real\n  text: REAL\n  ```\n"
      text = example <> "\n" <> real

      asked = Transcript.asked(text)

      assert asked =~ example
      assert asked =~ "> **Asked:** REAL"
      refute asked =~ "key: real"
      refute asked =~ "> **Asked:** EXAMPLE"
    end

    test "reads a block written with CRLF line ends" do
      asked = Transcript.asked("Say.\r\n```question\r\nkey: k\r\ntext: Which?\r\n```\r\nDone.")
      assert asked == "Say.\n> **Asked:** Which?\nDone."
    end
  end

  describe "a turn's calls" do
    test "are every line while the turn is open in a live conversation" do
      doc = draw([agent([call("t1", "Bash", %{"command" => "mix test"})])])

      assert [_live] = Floki.find(doc, "[data-run=live]")
      assert Floki.find(doc, "[data-run=folded]") == []
    end

    test "fold once the turn has ended" do
      doc = draw([agent([call("t1", "Bash", %{"command" => "mix test"})], 1)])

      assert [folded] = Floki.find(doc, "[data-run=folded]")

      # Opened by the reader, it stays open while the conversation is patched.
      assert [mounted] = folded |> Floki.find("details") |> Floki.attribute("phx-mounted")
      assert mounted =~ "ignore_attrs"
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
