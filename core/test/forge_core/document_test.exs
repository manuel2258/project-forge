defmodule ForgeCore.DocumentTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Error

  @fixture Path.expand("../fixtures/document_example.md", __DIR__)

  describe "parse/1 on the example document" do
    setup do
      {:ok, document} = Document.parse(File.read!(@fixture))
      %{document: document}
    end

    test "reads front matter and outcome", %{document: document} do
      assert document.outcome == "done"

      assert document.front_matter == %{
               "outcome" => "done",
               "summary" => "Persist the high score table."
             }

      assert String.starts_with?(document.body, "# Plan\n")
      refute String.contains?(document.body, "outcome: done")
    end

    test "extracts questions outside code blocks only, in order, with line numbers", %{
      document: document
    } do
      assert [
               %Question{
                 key: "storage-backend",
                 anchor: "Persist the high score table",
                 text: "Local file or the existing SQLite database?",
                 options: ["local-file", "sqlite"],
                 default: "sqlite",
                 blocking: false,
                 assumption: "sqlite",
                 line: 9
               },
               %Question{
                 key: "score-format",
                 blocking: true,
                 assumption: nil,
                 options: [],
                 line: 32
               }
             ] = document.questions
    end

    test "reports blocking questions", %{document: document} do
      assert [%Question{key: "score-format"}] = Document.blocking_questions(document)
      assert Document.blocking?(document)
    end
  end

  describe "fence variants" do
    test "trailing whitespace, indentation and a BOM are tolerated" do
      text =
        "\uFEFF---\noutcome: done\n---\n- item\n  ```question  \n  key: a\n  text: t\n  blocking: true\n  ```\n"

      assert {:ok, %Document{outcome: "done", questions: [%Question{key: "a", blocking: true}]}} =
               Document.parse(text)
    end

    test "CRLF line endings parse" do
      assert {:ok, %Document{outcome: "done", questions: [%Question{key: "a"}]}} =
               Document.parse(
                 "---\r\noutcome: done\r\n---\r\n```question\r\nkey: a\r\ntext: t\r\nassumption: x\r\n```\r\n"
               )
    end
  end

  describe "documents without front matter or questions" do
    test "are plain bodies" do
      assert {:ok, %Document{front_matter: %{}, outcome: nil, questions: [], body: "just text\n"}} =
               Document.parse("just text\n")

      refute Document.blocking?(Document.parse!("plain"))
    end

    test "empty front matter is allowed" do
      assert {:ok, %Document{front_matter: %{}, body: "body"}} = Document.parse("---\n---\nbody")
    end
  end

  describe "front matter errors" do
    test "unclosed" do
      assert {:error, [%Error{path: "front_matter", message: "is not closed by a --- line"}]} =
               Document.parse("---\noutcome: done\n")
    end

    test "not a mapping" do
      assert {:error, [%Error{path: "front_matter", message: "must be a mapping"}]} =
               Document.parse("---\n- a\n---\n")
    end

    test "invalid YAML" do
      assert {:error, [%Error{path: "front_matter", message: "invalid YAML: " <> _}]} =
               Document.parse("---\na: [\n---\n")
    end

    test "outcome must be a non-empty string" do
      assert {:error, [%Error{path: "front_matter.outcome"}]} =
               Document.parse("---\noutcome: 3\n---\n")
    end
  end

  describe "question block errors" do
    test "unclosed block" do
      assert {:error,
              [%Error{path: "question[0]", message: "block starting at line 2 is not closed"}]} =
               Document.parse("text\n```question\nkey: a\n")
    end

    test "invalid YAML and non-mapping blocks" do
      assert {:error,
              [%Error{path: "question[0]", message: "block at line 1: invalid YAML: " <> _}]} =
               Document.parse("```question\nkey: [\n```\n")

      assert {:error,
              [%Error{path: "question[0]", message: "block at line 1 must be a YAML mapping"}]} =
               Document.parse("```question\n- a\n```\n")
    end

    test "every field is checked" do
      yaml = """
      ```question
      key: Bad Key
      options: [a, a]
      default: b
      blocking: maybe
      assumption: 3
      extra: 1
      ```
      """

      assert messages(yaml) == [
               {"question[0].assumption", "must be a non-empty string"},
               {"question[0].blocking", "must be true or false"},
               {"question[0].default", "\"b\" is not one of the options"},
               {"question[0].extra", "unknown key"},
               {"question[0].key", "must be lowercase letters, digits, - or _"},
               {"question[0].options", "must not repeat an option"},
               {"question[0].text", "is required"}
             ]
    end

    test "default requires options; assumption follows blocking" do
      assert messages("```question\nkey: a\ntext: t\ndefault: x\n```\n") == [
               {"question[0].assumption", "is required on a non-blocking question"},
               {"question[0].default", "requires options"}
             ]

      assert messages("```question\nkey: a\ntext: t\nblocking: true\nassumption: x\n```\n") == [
               {"question[0].assumption", "not allowed on a blocking question"}
             ]
    end

    test "keys are unique per document" do
      text =
        "```question\nkey: a\ntext: t\nassumption: x\n```\n\n```question\nkey: a\ntext: u\nassumption: y\n```\n"

      assert messages(text) == [
               {"question[0].key", "\"a\" is used by more than one question"},
               {"question[1].key", "\"a\" is used by more than one question"}
             ]
    end

    test "errors from several blocks are all reported" do
      text = "```question\nkey: a\n```\n\n```question\ntext: t\nassumption: x\n```\n"

      assert Enum.map(errors(text), & &1.path) == [
               "question[0].assumption",
               "question[0].text",
               "question[1].key"
             ]
    end
  end

  test "parse!/1 raises with the errors listed" do
    assert_raise ArgumentError, ~r/front_matter: is not closed/, fn ->
      Document.parse!("---\n")
    end
  end

  defp errors(text) do
    {:error, errors} = Document.parse(text)
    Enum.sort_by(errors, &{&1.path, &1.message})
  end

  defp messages(text), do: Enum.map(errors(text), &{&1.path, &1.message})
end
