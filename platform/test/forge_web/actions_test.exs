defmodule ForgeWeb.ActionsTest do
  @moduledoc """
  What each tool call is drawn as (`docs/design/ui.md` § Talk): the line for each kind, the words
  the now line uses, the one line a finished run folds into, and a failure's excerpt shown
  without being asked. The page tests draw these in place; here each rule is aimed at directly.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeWeb.Actions

  @at ~U[2026-09-26 12:00:00Z]

  defp action(name, input, result \\ nil, children \\ []) do
    %{id: name, name: name, input: input, at: @at, result: result, children: children}
  end

  defp ok(excerpt \\ "ok"), do: %{is_error: false, excerpt: excerpt, bytes: 2}
  defp failed(excerpt), do: %{is_error: true, excerpt: excerpt, bytes: byte_size(excerpt)}

  defp draw(action), do: render_component(&Actions.line/1, line: {:one, action})

  describe "the now line's words" do
    test "say what each kind of call is doing" do
      assert Actions.now_words({:action, action("Bash", %{"command" => "mix test\nrest"})}) ==
               "running mix test"

      assert Actions.now_words({:action, action("Edit", %{"file_path" => "/w/lib/lexer.ex"})}) ==
               "editing lexer.ex"

      assert Actions.now_words({:action, action("Read", %{"file_path" => "/w/router.ex"})}) ==
               "reading router.ex"

      assert Actions.now_words({:action, action("Grep", %{"pattern" => "lex"})}) ==
               "searching lex"

      assert Actions.now_words({:action, action("Task", %{"description" => "find it"})}) ==
               "delegating: find it"

      assert Actions.now_words({:action, action("WebFetch", %{"url" => "https://x.io"})}) ==
               "fetching https://x.io"

      assert Actions.now_words({:action, action("WebSearch", %{"query" => "lexers"})}) ==
               "searching the web for lexers"

      assert Actions.now_words({:action, action("TodoWrite", %{})}) == "planning"
      assert Actions.now_words({:action, action("Frob", %{})}) == "running Frob"
    end

    test "say a retry and a limit, with the time it lifts" do
      assert Actions.now_words({:retrying, 2, 10}) == "retrying (2 of 10)"

      assert Actions.now_words({:rate_limited, ~U[2026-09-26 14:05:00Z]}) ==
               "rate limited, resumes 14:05 UTC"

      assert Actions.now_words({:rate_limited, nil}) == "rate limited"
      assert Actions.now_words(nil) == nil
    end

    # A command is a line on a phone: the first line of it, and no more than fits.
    test "cut a long command short" do
      words =
        Actions.now_words({:action, action("Bash", %{"command" => String.duplicate("x", 90)})})

      assert String.length(words) == String.length("running ") + 60
      assert String.ends_with?(words, "…")
    end
  end

  describe "a finished run's one line" do
    test "counts the calls, names the files edited and each command's outcomes in order" do
      run = [
        action("Bash", %{"command" => "mix test"}, failed("1 failure")),
        action("Edit", %{"file_path" => "/w/lib/parser.ex"}, ok()),
        action("Edit", %{"file_path" => "/w/lib/parser.ex"}, ok()),
        action("Write", %{"file_path" => "/w/lib/lexer.ex"}, ok()),
        action("Bash", %{"command" => "mix test"}, ok()),
        action("Bash", %{"command" => "mix format"}, ok())
      ]

      assert Actions.fold_summary(run) ==
               "6 actions · edited parser.ex, lexer.ex · mix test ✗→✓, mix format ✓"
    end

    test "says one action, and names at most three files and two commands" do
      assert Actions.fold_summary([action("Read", %{"file_path" => "/w/a.ex"}, ok())]) ==
               "1 action"

      edits = for f <- ~w(a b c d e), do: action("Edit", %{"file_path" => "/w/#{f}.ex"}, ok())
      assert Actions.fold_summary(edits) == "5 actions · edited a.ex, b.ex, c.ex +2"

      commands = for c <- ~w(one two three), do: action("Bash", %{"command" => c}, ok())
      assert Actions.fold_summary(commands) == "3 actions · one ✓, two ✓"
    end
  end

  describe "an edit" do
    test "counts its lines from its input, for each edit call" do
      assert Actions.edit_counts(action("Edit", %{"old_string" => "a", "new_string" => "b\nc"})) ==
               {2, 1}

      assert Actions.edit_counts(
               action("MultiEdit", %{
                 "edits" => [
                   %{"old_string" => "a\nb", "new_string" => "c"},
                   %{"old_string" => "d", "new_string" => "e\nf\ng"}
                 ]
               })
             ) == {4, 3}

      assert Actions.edit_counts(action("Write", %{"content" => "x\ny\n"})) == {2, 0}
      assert Actions.edit_counts(action("NotebookEdit", %{"new_source" => "z"})) == {1, 0}
    end

    test "expands to the change, and a failed one says why in error colour" do
      html =
        draw(
          action(
            "Edit",
            %{"file_path" => "/w/a.ex", "old_string" => "old", "new_string" => "new"},
            failed("String not found")
          )
        )

      doc = Floki.parse_fragment!(html)
      [edit] = Floki.find(doc, "details[data-action=edit]")

      assert Floki.text(edit) =~ "− old"
      assert Floki.text(edit) =~ "+ new"
      assert "text-error" in (edit |> Floki.attribute("class") |> hd() |> String.split())
      assert doc |> Floki.find("[data-failure]") |> Floki.text() =~ "String not found"

      [ok] =
        action("Edit", %{"file_path" => "/w/a.ex"}, ok())
        |> draw()
        |> Floki.parse_fragment!()
        |> Floki.find("details[data-action=edit]")

      refute "text-error" in (ok |> Floki.attribute("class") |> hd() |> String.split())
    end

    # A glance, not the change: the Changes tab has the rest.
    test "shows forty lines of a long change and says how many more" do
      content = Enum.map_join(1..45, "\n", &"line #{&1}")
      html = draw(action("Write", %{"file_path" => "/w/a.ex", "content" => content}, ok()))

      assert html =~ "+ line 40"
      refute html =~ "+ line 41"
      assert html =~ "… 5 more lines"
    end

    test "is every call that writes a file" do
      for name <- ~w(Edit MultiEdit Write NotebookEdit) do
        assert Actions.kind(action(name, %{})) == :edit, name
      end
    end
  end

  describe "a run of reads and searches" do
    test "reads a listing as a read and marks a failure" do
      html =
        render_component(&Actions.line/1,
          line:
            {:looks,
             [
               action("Read", %{"file_path" => "/w/a.ex"}, ok()),
               action("LS", %{"path" => "/w"}, ok()),
               action("Glob", %{"pattern" => "*.ex"}, failed("no match"))
             ]}
        )

      assert html =~ "read 2 files · searched 1×"
      assert html =~ "✗"
      assert html =~ "no match"
    end
  end

  describe "a task" do
    # Its subagent's calls fold under it, counted, each drawn with its own line.
    test "expands to its subagent's calls" do
      task =
        action("Task", %{"description" => "find the lexer"}, ok(), [
          action("Grep", %{"pattern" => "lex"}, ok()),
          action("Bash", %{"command" => "mix compile"}, ok())
        ])

      html = draw(task)

      assert html =~ "⤷"
      assert html =~ "2 calls"
      assert html =~ "searched 1×"
      assert html =~ "$ mix compile"
    end
  end

  test "a path is its last three segments" do
    assert Actions.short_path("/home/worker/job/checkout/lib/forge/parser.ex") ==
             "…/lib/forge/parser.ex"

    assert Actions.short_path("lib/parser.ex") == "lib/parser.ex"
  end

  # The plan above the now line is collapsed to what is being done, else what is next.
  test "a plan's current item is the one in progress, else the first not done" do
    todos = [
      %{"content" => "a", "status" => "completed"},
      %{"content" => "b", "status" => "pending"},
      %{"content" => "c", "status" => "in_progress"}
    ]

    assert %{"content" => "c"} = Actions.current_todo(todos)
    assert %{"content" => "b"} = Actions.current_todo(List.delete_at(todos, 2))
    assert Actions.current_todo([%{"content" => "a", "status" => "completed"}]) == nil
  end
end
