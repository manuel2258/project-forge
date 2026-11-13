defmodule ForgeCore.Workflow.ReleaseKeysTest do
  @moduledoc """
  `release_files` and `release_notes` (`docs/design/workflow-grammar-v1.md` § Release keys): what
  the parser reads, what the validator refuses by file and key, and that a pin without them still
  reads. Each refusal is aimed at the clause that says it.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow.Parser

  @base """
  version: 1
  release: true
  initial: building
  commands:
    package:
      run: .forge/commands/package.sh
      timeout: 10m
      produces: [package.log, "dist/*"]
  states:
    building:
      prompt: agents/build.md
      produces: ["images/*", notes.md, deck.md!, changeset]
      budget: { turns: 5, tokens: 200k }
    discussing:
      chat: true
      prompt: agents/talk.md
      produces: [talk.md]
    done_state: {}
  transitions:
    - { from: building, to: discussing }
    - { from: discussing, to: done_state }
  limits: { ticket_tokens: 1M }
  """

  defp map(changes \\ %{}) do
    {:ok, map} = YamlElixir.read_from_string(@base)
    Map.merge(map, changes)
  end

  defp errors(map) do
    case Parser.from_map(map) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  test "a state's group, a command's group and a job document are accepted and kept" do
    map = map(%{"release_files" => ["images/*", "dist/*"], "release_notes" => "notes.md"})

    assert {:ok, workflow} = Parser.from_map(map)
    assert workflow.release_files == ["images/*", "dist/*"]
    assert workflow.release_notes == "notes.md"
  end

  test "absent keys read as no files and no notes, so a stored pin still reads" do
    assert {:ok, workflow} = Parser.from_pinned(map())
    assert workflow.release_files == []
    assert workflow.release_notes == nil
  end

  test "both keys are refused without release: true, naming the key" do
    map =
      map(%{"release" => false, "release_files" => ["images/*"], "release_notes" => "notes.md"})

    assert [{"release_files[0]", files}, {"release_notes", notes}] = errors(map)
    assert files =~ "release: true"
    assert notes =~ "release: true"
  end

  test "a file that is not a group some state or command produces is refused by index" do
    map = map(%{"release_files" => ["images/*", "dist", "nowhere/*", "package.log", "notes.md"]})

    assert [
             {"release_files[1]", _},
             {"release_files[2]", message},
             {"release_files[3]", _},
             {"release_files[4]", _}
           ] = errors(map)

    assert message =~ ~s("nowhere/*")
  end

  test "a group is not accepted for a name that merely looks like one" do
    assert [{"release_files[0]", _}] = errors(map(%{"release_files" => ["image/*"]}))
  end

  test "notes must be a plain document a job state produces" do
    for bad <- ["images/*", "deck.md", "deck.md!", "changeset", "talk.md", "missing.md"] do
      assert [{"release_notes", message}] = errors(map(%{"release_notes" => bad})),
             "#{bad} should be refused"

      assert message =~ inspect(bad)
    end
  end

  test "the shapes are checked before the meaning" do
    assert [{"release_files", _}] = errors(map(%{"release_files" => "images/*"}))
    assert [{"release_notes", _}] = errors(map(%{"release_notes" => ["notes.md"]}))
  end
end
