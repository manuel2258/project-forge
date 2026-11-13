defmodule Forge.Look.StepsTest do
  use ExUnit.Case, async: true

  alias Forge.Look.Steps

  defp parse!(text) do
    {:ok, [step]} = Steps.parse(text)
    step.op
  end

  test "every step form parses to its operation" do
    assert parse!("width phone") == {:width, :phone}
    assert parse!("width portrait") == {:width, :portrait}
    assert parse!("width wide") == {:width, :wide}
    assert parse!("width desktop") == {:width, :desktop}
    assert parse!("visit /tickets/game/1") == {:visit, {:path, "/tickets/game/1"}}
    assert parse!("visit :ticket") == {:visit, {:named, "ticket"}}
    assert parse!("click button.save") == {:click, {:css, "button.save"}}
    assert parse!(~s|click text "Save it"|) == {:click, {:text, "Save it"}}

    assert parse!(~s|fill "input[name=title]" "Hi there"|) ==
             {:fill, "input[name=title]", "Hi there"}

    assert parse!("wait .flash") == {:wait, {:css, ".flash"}}
    assert parse!(~s|wait text "Saved"|) == {:wait, {:text, "Saved"}}
    assert parse!("text .count") == {:text, ".count"}
    assert parse!("shot page queue-empty-phone.png") == {:shot, :page, "queue-empty-phone.png"}
    assert parse!(~s|shot ".card h2" card.png|) == {:shot, {:css, ".card h2"}, "card.png"}
  end

  test "steps keep their line numbers, skipping blanks and comments" do
    {:ok, steps} = Steps.parse("# a comment\n\nwidth phone\n  # another\nvisit /\n")
    assert [%{n: 3, text: "width phone"}, %{n: 5, text: "visit /"}] = steps
  end

  test "a visit must be a path on the app" do
    for bad <- [
          "http://evil.test/",
          "https://evil.test/x",
          "//evil.test/x",
          "file:///etc/passwd",
          "data:text/html,x",
          "javascript:alert(1)",
          "evil.test",
          "/\\evil.test"
        ] do
      assert {:error, %{n: 1, text: text, reason: reason}} = Steps.parse("visit " <> bad)
      assert text == "visit " <> bad
      assert reason =~ "path on the app"
    end

    assert {:error, %{reason: reason}} = Steps.parse(~s|visit "/a b"|)
    assert reason =~ "spaces"
    assert {:error, %{reason: "visit takes one path"}} = Steps.parse("visit")
    assert {:error, %{reason: "visit takes one path"}} = Steps.parse("visit /a /b")
  end

  test "a path with a character a URL parser strips or reads as a slash is refused" do
    for char <- ["\t", "\r", "\n", <<0>>, <<127>>, " ", "\\"] do
      assert {:error, reason} = Steps.check_path("/a" <> char <> "b")
      assert reason =~ "spaces, control characters or backslashes"
    end

    assert :ok == Steps.check_path("/tickets/game/1?tab=docs#top")
  end

  test "a bad line names its number, its text and why" do
    assert {:error, %{n: 2, text: "wiggle", reason: ~s|unknown step "wiggle"|}} =
             Steps.parse("width phone\nwiggle")

    assert {:error, %{reason: "width is phone, portrait, wide or desktop"}} =
             Steps.parse("width tablet")

    assert {:error, %{reason: "wrong arguments for fill"}} = Steps.parse("fill input")
    assert {:error, %{reason: "unbalanced quote"}} = Steps.parse(~s|click text "Save|)
    assert {:error, %{reason: reason}} = Steps.parse(~s|click text "it's \\"x\\""|)
    assert reason =~ "not both"
  end

  test "the widths are the sizes the handoff drew each layout at, and the prompts' desktop" do
    assert Steps.size(:phone) == {412, 915}
    assert Steps.size(:portrait) == {1080, 1500}
    assert Steps.size(:wide) == {1600, 1000}
    assert Steps.size(:desktop) == {1280, 800}
  end
end
