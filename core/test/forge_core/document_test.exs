defmodule ForgeCore.DocumentTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Document.Question.Option
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
                 options: [
                   %Option{
                     label: "Local file",
                     detail: "Simple, but another thing to back up.",
                     recommended: false
                   },
                   %Option{
                     label: "SQLite database",
                     detail: "The scores already live there.",
                     recommended: true
                   }
                 ],
                 blocking: false,
                 assumption: "sqlite",
                 line: 9
               },
               %Question{
                 key: "score-format",
                 blocking: true,
                 assumption: nil,
                 options: [],
                 line: 36
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

    # CommonMark's rule is that a closing fence is *at least as long* as the opening one. The
    # cases above vary whitespace, indentation, a BOM and line endings but never the tick count,
    # so `>= width` and `== width` were indistinguishable. An agent that opens with three ticks
    # and closes with four is writing valid Markdown; under `==` the block reads as unclosed and
    # the whole document fails to parse, which fails the whole job.
    test "a closing fence may be longer than the one that opened the block" do
      assert {:ok, %Document{questions: [%Question{key: "a"}]}} =
               Document.parse("```question\nkey: a\ntext: t\nblocking: true\n````\n")
    end

    test "a closing fence may not be shorter" do
      assert {:error, [%Error{message: "block starting at line 1 is not closed"}]} =
               Document.parse("````question\nkey: a\ntext: t\nblocking: true\n```\n")
    end
  end

  # `docs/design/conversations.md` § Questions makes this a standard: "The flag is ignored for
  # chats — `Document.parse(text, blocking: :always)`". In a conversation the turn has ended and
  # the agent is waiting whichever way the flag was written, so there is no "instead" for an
  # assumption to describe. The option existed and no test passed it, which meant the rule that
  # a chat's questions are all blocking rested on nothing.
  describe "a conversation's questions" do
    test "are blocking whatever the flag said, and need no assumption" do
      text = "```question\nkey: a\ntext: t\nblocking: false\n```\n"

      # Without the option this is an error: a non-blocking question must say what it proceeded
      # with. Failing the parse would take the question down with the message it arrived in.
      assert messages(text) == [
               {"question[0].assumption", "is required on a non-blocking question"}
             ]

      assert {:ok, %Document{questions: [question]}} = Document.parse(text, blocking: :always)
      assert question.blocking
      assert question.assumption == nil
    end

    # Ignored rather than refused, and for the stated reason: refusing it fails the whole message
    # and the question vanishes rather than being shown without its form.
    test "an assumption written anyway is ignored, not refused" do
      text = "```question\nkey: a\ntext: t\nblocking: false\nassumption: I guessed\n```\n"

      assert {:ok, %Document{questions: [question]}} = Document.parse(text, blocking: :always)
      assert question.blocking
      assert question.assumption == nil
    end
  end

  # Not a parse rule — the parser reads bytes — but what JSON and a text column can carry. A
  # document that is not text fails the whole message or transaction it rides in, so it is
  # refused where it is read instead.
  describe "text?/1" do
    test "UTF-8 is text" do
      assert Document.text?("# Plan\n\nDo the thing — carefully.\n")
      assert Document.text?("")
    end

    test "bytes that are not UTF-8 are not" do
      refute Document.text?(<<0xFF, 0xFE, ?a>>)
    end

    test "a NUL is not, although it is valid UTF-8" do
      refute Document.text?("before" <> <<0>> <> "after")
    end

    test "anything but a binary is not" do
      refute Document.text?(nil)
    end
  end

  describe "text_error/1" do
    test "says nothing of text that can be a document" do
      assert Document.text_error("# Plan\n") == nil
      assert Document.text_error(String.duplicate("a", Document.max_bytes())) == nil
    end

    test "names what is wrong with what cannot" do
      assert Document.text_error(<<0xFF>>) == "must be UTF-8 text with no NUL byte"

      assert Document.text_error(String.duplicate("a", Document.max_bytes() + 1)) ==
               "must be no larger than 1024 KiB"
    end
  end

  # The raw text has no NUL, so `text?/1` passes it — the escape makes one — and front matter is
  # stored as `jsonb`, which refuses it inside the transaction that writes the document.
  describe "a NUL made by a YAML escape" do
    test "is refused in a value, a key, or anything nested" do
      for yaml <- [~s(title: "a\\0b"), ~s("k\\0": v), ~s(tags: ["x", "y\\0"]), ~s(a: {b: "c\\0"})] do
        raw = "---\n#{yaml}\n---\n# Doc\n"
        assert Document.text?(raw), yaml

        assert {:error, [%Error{path: "front_matter", message: message}]} = Document.parse(raw),
               yaml

        assert message =~ "NUL"
      end
    end

    test "and front matter without one is kept as it was" do
      assert {:ok, %Document{front_matter: %{"title" => "a b"}}} =
               Document.parse("---\ntitle: \"a b\"\n---\n# Doc\n")
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
      options:
        - {label: a, detail: d}
        - {label: a, detail: e}
      blocking: maybe
      assumption: [3]
      extra: 1
      ```
      """

      assert messages(yaml) == [
               {"question[0].assumption", "must be a non-empty string"},
               {"question[0].blocking", "must be true or false"},
               {"question[0].extra", "unknown key"},
               {"question[0].key", "must be lowercase letters, digits, - or _"},
               {"question[0].options", "must not repeat a label"},
               {"question[0].text", "is required"}
             ]
    end

    test "assumption follows blocking" do
      assert messages("```question\nkey: a\ntext: t\n```\n") == [
               {"question[0].assumption", "is required on a non-blocking question"}
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

    # The "every field is checked" case above feeds `key: Bad Key`, where the *space* is what
    # fails the regex — so the lowercase half of the rule was never exercised. Question keys are
    # the identity `Outcome.blocking_questions/2` matches `answered_keys` against: if `Storage`
    # and `storage` were both legal, an answered question would stop resolving and the job would
    # park for ever on a question a person had already answered.
    test "a key is lowercase, and that is a rule of its own" do
      assert messages("```question\nkey: Storage\ntext: t\nblocking: true\n```\n") == [
               {"question[0].key", "must be lowercase letters, digits, - or _"}
             ]
    end

    test "a key may hold digits, dashes and underscores" do
      assert {:ok, document} =
               Document.parse("```question\nkey: a_b-9\ntext: t\nblocking: true\n```\n")

      assert [%{key: "a_b-9"}] = document.questions
    end

    # Emptiness is folded into each field's type check, and no test fed an empty string to any of
    # them. A question with `text: ""` is drawn as a form with no question in it, and `options: []`
    # as a question with no options to choose — both things the operator cannot act on.
    test "a field that is present may not be empty" do
      yaml = """
      ```question
      key: a
      text: ""
      anchor: ""
      options: []
      blocking: true
      ```
      """

      assert messages(yaml) == [
               {"question[0].anchor", "must be a non-empty string"},
               {"question[0].options", "must be a non-empty list of options"},
               {"question[0].text", "must be a non-empty string"}
             ]
    end

    # An agent that wrote `label: 10` meant the label. YAML types it as an integer, and refusing
    # that kind of thing dropped a whole refinement, questions and all, in production.
    test "numbers and booleans where text is meant are read as the text they were written as" do
      yaml = """
      ```question
      key: 10
      text: 42
      anchor: 1.5
      options:
        - {label: 5, detail: 1.5}
        - {label: true, detail: false, recommended: true}
      blocking: false
      assumption: 5
      ```
      """

      assert {:ok, %{questions: [question]}} = Document.parse(yaml)
      assert question.key == "10"
      assert question.text == "42"
      assert question.anchor == "1.5"

      assert question.options == [
               %Option{label: "5", detail: "1.5", recommended: false},
               %Option{label: "true", detail: "false", recommended: true}
             ]

      assert question.assumption == "5"
    end

    # Only scalars are text: a list or a mapping where text is meant is still refused, and
    # `blocking` and `recommended` are flags, not text.
    test "a value that is not a scalar is still refused" do
      yaml = """
      ```question
      key: a
      text: [t]
      options:
        - {label: [a], detail: {b: c}, recommended: "true"}
        - [a]
      blocking: "true"
      ```
      """

      assert messages(yaml) == [
               {"question[0].assumption", "is required on a non-blocking question"},
               {"question[0].blocking", "must be true or false"},
               {"question[0].options[0].detail", "must be a non-empty string"},
               {"question[0].options[0].label", "must be a non-empty string"},
               {"question[0].options[0].recommended", "must be true or false"},
               {"question[0].options[1]", "must be a mapping with a `label` and a `detail`"},
               {"question[0].text", "must be a non-empty string"}
             ]
    end

    test "an option's label and detail are required and may not be empty" do
      yaml = """
      ```question
      key: a
      text: t
      options:
        - {label: "", detail: d}
        - {label: b}
        - {detail: d}
      blocking: true
      ```
      """

      assert messages(yaml) == [
               {"question[0].options[0].label", "must be a non-empty string"},
               {"question[0].options[1].detail", "is required"},
               {"question[0].options[2].label", "is required"}
             ]
    end

    # The non-blocking branch has its own emptiness check, reached only when `blocking` is false.
    test "an assumption may not be empty" do
      yaml = "```question\nkey: a\ntext: t\nassumption: \"\"\n```\n"

      assert messages(yaml) == [{"question[0].assumption", "must be a non-empty string"}]
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

  describe "options" do
    # The format this replaced, and the one an agent reaches for from habit: a bare label asks a
    # person on a phone to reconstruct the sentence the agent had in mind.
    test "a bare value is refused, with what to write instead" do
      yaml = "```question\nkey: a\ntext: t\noptions: [local-file, 5, true]\nblocking: true\n```\n"
      bare = "must be a mapping with a `label` and a `detail`, not a bare value"

      assert messages(yaml) == [
               {"question[0].options[0]", bare},
               {"question[0].options[1]", bare},
               {"question[0].options[2]", bare}
             ]
    end

    # A conversation reads every question as blocking, and nothing else about it is lenient.
    test "a bare value is refused in a conversation too" do
      yaml = "```question\nkey: a\ntext: t\noptions: [local-file]\n```\n"

      assert {:error, [%Error{path: "question[0].options[0]"}]} =
               Document.parse(yaml, blocking: :always)
    end

    test "default is gone, and the refusal says where the recommendation went" do
      yaml = """
      ```question
      key: a
      text: t
      options: [{label: A, detail: d}]
      default: A
      blocking: true
      ```
      """

      assert messages(yaml) == [
               {"question[0].default",
                "is not a key: mark the recommended option with `recommended: true`"}
             ]
    end

    test "an option has no keys but its own" do
      yaml =
        "```question\nkey: a\ntext: t\noptions: [{label: A, detail: d, id: x}]\nblocking: true\n```\n"

      assert messages(yaml) == [{"question[0].options[0].id", "unknown key"}]
    end

    test "at most one option is recommended" do
      two = """
      ```question
      key: a
      text: t
      options:
        - {label: A, detail: d, recommended: true}
        - {label: B, detail: d, recommended: true}
        - {label: C, detail: d}
      blocking: true
      ```
      """

      assert messages(two) == [
               {"question[0].options", "may mark one option recommended, not 2"}
             ]

      one =
        String.replace(two, "{label: B, detail: d, recommended: true}", "{label: B, detail: d}")

      assert {:ok, %{questions: [question]}} = Document.parse(one)
      assert %Option{label: "A"} = Question.recommended(question)
    end

    test "a question need not recommend anything" do
      yaml =
        "```question\nkey: a\ntext: t\noptions: [{label: A, detail: d}]\nblocking: true\n```\n"

      assert {:ok, %{questions: [question]}} = Document.parse(yaml)
      assert Question.recommended(question) == nil
    end
  end

  # The parser never raises on what an agent wrote, and never hands on a value the write after it
  # cannot store. Each of these was a raise — in the parser, or inside the transaction recording
  # the document — before it was a refusal.
  describe "what cannot be stored is refused, not raised on" do
    test "a key that is not text, on a question or an option" do
      option =
        "```question\nkey: a\ntext: t\noptions:\n  - {label: A, detail: d, ? {z: 1} : q}\nblocking: true\n```\n"

      question = "```question\nkey: a\ntext: t\n? {z: 1}\n: y\nblocking: true\n```\n"

      assert messages(option) == [
               {"question[0].options[0].(a key that is not text)", "unknown key"}
             ]

      assert messages(question) == [{"question[0].(a key that is not text)", "unknown key"}]
    end

    test "a key that is not text in the front matter" do
      assert messages("---\n? {a: 1}\n: b\n---\nbody\n") == [
               {"front_matter", "keys must be text"}
             ]

      # At any depth, a list's items included.
      assert messages("---\nitems:\n  - ? {a: 1}\n    : b\n---\nbody\n") == [
               {"front_matter", "keys must be text"}
             ]

      # Numbers and flags are keys JSON can name.
      assert {:ok, _document} = Document.parse("---\n1: a\ntrue: b\n---\nbody\n")
    end

    test "a NUL written as an escape, in any text field" do
      nul = ~S("a\0b")

      for {field, yaml} <- [
            {"text", "text: #{nul}\nblocking: true"},
            {"anchor", "text: t\nanchor: #{nul}\nblocking: true"},
            {"assumption", "text: t\nassumption: #{nul}"},
            {"options[0].label",
             "text: t\noptions: [{label: #{nul}, detail: d}]\nblocking: true"},
            {"options[0].detail",
             "text: t\noptions: [{label: A, detail: #{nul}}]\nblocking: true"}
          ] do
        assert messages("```question\nkey: a\n#{yaml}\n```\n") == [
                 {"question[0].#{field}", "must not contain a NUL character"}
               ]
      end
    end

    # A label of spaces is an option nobody can choose: the form reads a blank choice as none.
    test "text that is only whitespace, in any text field" do
      for {field, yaml} <- [
            {"text", "text: \"  \"\nblocking: true"},
            {"assumption", "text: t\nassumption: \" \""},
            {"options[0].label", "text: t\noptions: [{label: \" \", detail: d}]\nblocking: true"},
            {"options[0].detail",
             "text: t\noptions: [{label: A, detail: \"\t\"}]\nblocking: true"}
          ] do
        assert messages("```question\nkey: a\n#{yaml}\n```\n") == [
                 {"question[0].#{field}", "must be a non-empty string"}
               ]
      end
    end
  end

  describe "limits" do
    # Each limit at its ceiling and one past it, in characters: `é` is two bytes, so a limit
    # counted in bytes refuses the ceiling.
    for {field, max} <- [text: 200, label: 40, detail: 140] do
      test "#{field} is at most #{max} characters" do
        field = unquote(field)
        max = unquote(max)

        assert {:ok, _document} = Document.parse(sized(field, String.duplicate("é", max)))

        path =
          Map.fetch!(
            %{
              text: "question[0].text",
              label: "question[0].options[0].label",
              detail: "question[0].options[0].detail"
            },
            field
          )

        assert messages(sized(field, String.duplicate("é", max + 1))) == [
                 {path, "must be at most #{max} characters, not #{max + 1}"}
               ]
      end
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

  defp sized(field, value) do
    fields = Map.merge(%{text: "t", label: "A", detail: "d"}, %{field => value})

    """
    ```question
    key: a
    text: "#{fields.text}"
    options: [{label: "#{fields.label}", detail: "#{fields.detail}"}]
    blocking: true
    ```
    """
  end
end
