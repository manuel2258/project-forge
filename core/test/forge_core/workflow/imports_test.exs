defmodule ForgeCore.Workflow.ImportsTest do
  @moduledoc """
  `docs/design/ticket-types.md` § Imports: a ticket type may import libraries of commands,
  defaults and state templates, flattened before parsing into the plain v1 definition a ticket
  pins. Each rule here is one the note states, and each test is aimed at the clause that says it.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Imports, Parser, Resources}

  @common """
  commands:
    build: { run: .forge/commands/build.sh, timeout: 20m }
    lint: { run: .forge/commands/lint.sh, timeout: 5m }
  defaults:
    resources: { memory: 2GiB, cpu: 2 }
  states:
    implementing:
      prompt: agents/implement.md
      produces: [changeset]
      budget: { turns: 10, cost: 1.0 }
      may_invoke: { build: { max: 3 } }
  """

  @type_yaml """
  version: 1
  description: Something that worked and does not.
  import: [common.yml]
  initial: implementing
  states:
    implementing:
      extends: implementing
      inputs: [ticket]
    review_ready: {}
  transitions:
    - { from: implementing, to: review_ready }
  limits: { ticket_cost: 5 }
  """

  defp reader(files), do: fn path -> Map.fetch(files, path) end

  defp load(yaml, files \\ %{"common.yml" => @common}),
    do: Parser.load(yaml, read_library: reader(files))

  # The type above with `replace` applied to its text, so each test states only what it changes.
  defp type_with(pairs),
    do: Enum.reduce(pairs, @type_yaml, fn {a, b}, y -> String.replace(y, a, b) end)

  defp messages(errors), do: Enum.map(errors, &{&1.file, &1.path, &1.message})

  describe "flattening" do
    test "a template's keys arrive in the state that extends it, with the state's own beside them" do
      assert {:ok, %Workflow{} = workflow, flat} = load(@type_yaml)

      state = workflow.states["implementing"]
      assert state.prompt == "agents/implement.md"
      assert state.inputs == ["ticket"]
      assert state.budget.turns == 10
      assert state.may_invoke == %{"build" => %{max: 3, concurrent: nil}}
      assert workflow.description == "Something that worked and does not."

      # Commands are imported whole: `lint` is invoked by nothing and is still declared.
      assert Map.keys(workflow.commands) |> Enum.sort() == ["build", "lint"]
      assert %Resources{cpu: 2} = workflow.defaults.resources

      refute Map.has_key?(flat, "import")
      refute Map.has_key?(flat["states"]["implementing"], "extends")
    end

    # The reason resolution happens before parsing: a ticket's pinned map is read back everywhere
    # with no repository to read a library from.
    test "what comes out reads back without a reader, as the same workflow" do
      {:ok, workflow, flat} = load(@type_yaml)
      assert Parser.from_map(flat) == {:ok, workflow}
    end

    test "a key the state writes replaces the template's whole, never merges into it" do
      yaml = type_with([{"inputs: [ticket]", "inputs: [ticket]\n    budget: { turns: 50 }"}])

      # Merged, the template's `cost` would fill the gap and this would load.
      assert {:error, errors} = load(yaml)

      assert {nil, "states.implementing.budget.cost", "is required"} in messages(errors)
    end

    test "a state may extend a template under a name of its own" do
      yaml =
        type_with([
          {"initial: implementing", "initial: fixing"},
          {"  implementing:\n    extends", "  fixing:\n    extends"},
          {"from: implementing", "from: fixing"}
        ])

      assert {:ok, workflow, _flat} = load(yaml)
      assert workflow.states["fixing"].prompt == "agents/implement.md"
      refute Map.has_key?(workflow.states, "implementing")
    end

    test "a workflow that imports nothing is itself, and needs no reader" do
      yaml =
        type_with([
          {"import: [common.yml]\n", ""},
          {"extends: implementing", "prompt: a.md\n    budget: { turns: 1, cost: 1 }"}
        ])

      assert {:ok, _workflow, flat} = Parser.load(yaml)
      assert flat == YamlElixir.read_from_string!(yaml)
    end
  end

  describe "defaults" do
    test "are imported field by field, and the workflow's own win" do
      yaml = type_with([{"initial:", "defaults: { resources: { cpu: 4 } }\ninitial:"}])

      assert {:ok, workflow, _flat} = load(yaml)
      assert workflow.defaults.resources.cpu == 4
      assert workflow.defaults.resources.memory == 2 * 1024 * 1024 * 1024
    end

    test "two libraries setting one field is an error, because neither is nearer" do
      files = %{
        "common.yml" => @common,
        "big.yml" => "defaults:\n  resources: { memory: 8GiB }\n"
      }

      yaml = type_with([{"import: [common.yml]", "import: [common.yml, big.yml]"}])

      assert {:error, errors} = load(yaml, files)

      assert messages(errors) == [
               {"big.yml", "defaults.resources.memory", "is also set in common.yml"}
             ]
    end
  end

  describe "commands" do
    test "one the workflow declares too is an error, not an override" do
      yaml =
        type_with([
          {"initial:", "commands:\n  build: { run: .forge/b.sh, timeout: 1m }\ninitial:"}
        ])

      assert {:error, errors} = load(yaml)

      assert messages(errors) == [
               {"common.yml", "commands.build", "is also declared by the workflow importing this"}
             ]
    end

    test "one two libraries declare is an error naming the first" do
      files = %{
        "common.yml" => @common,
        "ci.yml" => "commands:\n  build: { run: .forge/ci.sh, timeout: 1m }\n"
      }

      yaml = type_with([{"import: [common.yml]", "import: [common.yml, ci.yml]"}])

      assert {:error, errors} = load(yaml, files)
      assert messages(errors) == [{"ci.yml", "commands.build", "is also declared in common.yml"}]
    end
  end

  describe "state templates" do
    test "extending a name no library declares lists the ones that are" do
      yaml = type_with([{"extends: implementing", "extends: implement"}])

      assert {:error, [%Error{path: "states.implementing.extends", message: message}]} =
               load(yaml)

      assert message =~ ~s(names "implement", which no imported library declares)
      assert message =~ "it has implementing"
    end

    test "extending with nothing imported says so" do
      yaml = type_with([{"import: [common.yml]\n", ""}])

      assert {:error, [%Error{path: "states.implementing.extends", message: message}]} =
               Parser.load(yaml)

      assert message =~ "no library this imports declares a state template"
    end

    test "one two libraries declare is an error" do
      files = %{
        "common.yml" => @common,
        "other.yml" => "states:\n  implementing: { prompt: x.md }\n"
      }

      yaml = type_with([{"import: [common.yml]", "import: [common.yml, other.yml]"}])

      assert {:error, errors} = load(yaml, files)

      assert messages(errors) == [
               {"other.yml", "states.implementing", "is also declared in common.yml"}
             ]
    end

    test "a template cannot extend another" do
      files = %{"common.yml" => @common <> "  deeper: { extends: implementing }\n"}

      assert {:error, errors} = load(@type_yaml, files)

      assert messages(errors) == [
               {"common.yml", "states.deeper.extends",
                "a state template cannot extend another: imports are one level deep"}
             ]
    end
  end

  describe "what a library may hold" do
    test "transitions and the rest of a workflow are refused, against the library" do
      files = %{"common.yml" => @common <> "transitions: []\ninitial: x\n"}

      assert {:error, errors} = load(@type_yaml, files)

      assert [
               {"common.yml", "initial", "not allowed in a library" <> _},
               {"common.yml", "transitions", "not allowed in a library" <> _}
             ] = messages(errors)
    end

    test "a library cannot import: imports are one level deep" do
      files = %{"common.yml" => @common <> "import: [more.yml]\n"}

      assert {:error, errors} = load(@type_yaml, files)

      assert messages(errors) == [
               {"common.yml", "import", "imports are one level deep: a library cannot import"}
             ]
    end

    test "a library that is not a mapping, or not YAML, is named" do
      assert {:error, [%Error{file: "common.yml", message: "a library must be a mapping"}]} =
               load(@type_yaml, %{"common.yml" => "- a list\n"})

      assert {:error, [%Error{file: "common.yml", message: "invalid YAML: " <> _}]} =
               load(@type_yaml, %{"common.yml" => "states: [unclosed\n"})
    end

    test "a section that is not a mapping is named" do
      assert {:error, errors} = load(@type_yaml, %{"common.yml" => "commands: [build]\n"})
      assert {"common.yml", "commands", "must be a mapping"} in messages(errors)
    end
  end

  describe "import" do
    test "a library that is not there is named at its entry" do
      assert {:error, errors} = load(@type_yaml, %{})

      assert messages(errors) == [
               {nil, "import[0]", ~s("common.yml" does not exist at this commit)}
             ]
    end

    test "naming a library twice is an error" do
      yaml = type_with([{"import: [common.yml]", "import: [common.yml, common.yml]"}])

      assert {:error, errors} = load(yaml)
      assert messages(errors) == [{nil, "import[1]", ~s("common.yml" is imported twice)}]
    end

    test "with no reader, a workflow that imports is refused rather than half-read" do
      assert {:error, [%Error{path: "import[0]", message: message}]} = Parser.load(@type_yaml)
      assert message =~ "no repository to read a library from"
    end

    test "is a list" do
      yaml = type_with([{"import: [common.yml]", "import: common.yml"}])
      assert {:error, [%Error{path: "import"}]} = load(yaml)
    end
  end

  describe "library_path?/1" do
    test "takes a path of names under .forge/" do
      assert Imports.library_path?("common.yml")
      assert Imports.library_path?("lib/common.yml")
    end

    # Every segment being a name is what keeps the read inside `.forge/`. A tree lookup resolves
    # no `..`, so this is the same model as the read rather than a guess about it.
    test "refuses anything that could leave .forge/ or is not a path" do
      for path <- [
            "../secret.yml",
            "lib/../../x.yml",
            "/etc/passwd",
            ".hidden.yml",
            "a//b.yml",
            "",
            3
          ] do
        refute Imports.library_path?(path), "accepted #{inspect(path)}"
      end
    end

    test "refuses a ticket type, which is a workflow and not a library" do
      refute Imports.library_path?("workflows/bug.yml")

      yaml = type_with([{"import: [common.yml]", "import: [workflows/bug.yml]"}])
      assert {:error, [%Error{path: "import[0]", message: message}]} = load(yaml)
      assert message =~ "is a ticket type, not a library"
    end
  end

  describe "errors name the library they are about" do
    test "a template's own mistake is reported against the library" do
      files = %{"common.yml" => String.replace(@common, "turns: 10", "turns: 0")}

      assert {:error, errors} = load(@type_yaml, files)

      assert {"common.yml", "states.implementing.budget.turns", "must be a positive integer"} in messages(
               errors
             )
    end

    test "an imported command's mistake is reported against the library" do
      files = %{"common.yml" => String.replace(@common, "timeout: 20m", "timeout: forever")}

      assert {:error, errors} = load(@type_yaml, files)
      assert [{"common.yml", "commands.build.timeout", _message}] = messages(errors)
    end

    test "an imported default's mistake is reported against the library" do
      files = %{"common.yml" => String.replace(@common, "memory: 2GiB", "memory: 2GB")}

      assert {:error, errors} = load(@type_yaml, files)
      assert [{"common.yml", "defaults.resources.memory", _message}] = messages(errors)
    end

    # A state may extend a template under a name of its own, and the path then has to be the
    # template's: the library has no `states.fixing`.
    test "the path is into the library, under the template's name" do
      files = %{"common.yml" => String.replace(@common, "turns: 10", "turns: 0")}

      yaml =
        type_with([
          {"initial: implementing", "initial: fixing"},
          {"  implementing:\n    extends", "  fixing:\n    extends"},
          {"from: implementing", "from: fixing"}
        ])

      assert {:error, errors} = load(yaml, files)

      assert {"common.yml", "states.implementing.budget.turns", "must be a positive integer"} in messages(
               errors
             )
    end

    test "a mistake in the workflow's own part of the state is the workflow's" do
      yaml =
        type_with([{"inputs: [ticket]", "inputs: [ticket]\n    budget: { turns: 0, cost: 1 }"}])

      assert {:error, errors} = load(yaml)

      assert {nil, "states.implementing.budget.turns", "must be a positive integer"} in messages(
               errors
             )
    end

    # A path into a list — `invoke[0]` — is under its key as much as a dotted one is.
    test "an indexed path into a template's list is the library's" do
      files = %{
        "common.yml" => @common <> "  checking:\n    invoke: [[3]]\n    exit: { 0: done }\n"
      }

      yaml =
        type_with([
          {"  review_ready: {}", "  checking: { extends: checking }\n  review_ready: {}"},
          {"    - { from: implementing, to: review_ready }",
           "    - { from: implementing, to: checking }\n    - { from: checking, to: review_ready }"}
        ])

      assert {:error, errors} = load(yaml, files)

      assert {"common.yml", "states.checking.invoke[0]",
              "must be a command name, or a list of the name and its arguments"} in messages(
               errors
             )
    end

    # Errors come back in one order — the workflow's own first, then each library's — however
    # they were found: a list that reordered between runs is one a person re-reads to compare.
    test "come back ordered by file, then path" do
      yaml =
        type_with([
          {"initial:", "commands:\n  build: { run: .forge/b.sh, timeout: 1m }\ninitial:"},
          {"extends: implementing", "extends: nothing"}
        ])

      assert {:error, errors} = load(yaml)

      assert [
               {nil, "states.implementing.extends", _},
               {"common.yml", "commands.build", _}
             ] = messages(errors)
    end

    test "attribute/2 leaves an error that already names its file alone" do
      error = %{Error.new("states.a.prompt", "m") | file: "own.yml"}

      assert [%Error{file: "own.yml"}] =
               Imports.attribute([error], [{"states.a", "x.yml", "states.a"}])
    end

    test "attribute/2 leaves an error with no matching origin alone, and takes the longest" do
      origins = [
        {"states.a", "x.yml", "states.a"},
        {"states.a.budget", "y.yml", "states.a.budget"}
      ]

      assert [%Error{file: "y.yml"}, %Error{file: "x.yml"}, %Error{file: nil}, %Error{file: nil}] =
               Imports.attribute(
                 [
                   Error.new("states.a.budget.turns", "m"),
                   Error.new("states.a.prompt", "m"),
                   Error.new("states.ab.prompt", "m"),
                   Error.new("states", "m")
                 ],
                 origins
               )
    end
  end

  describe "a workflow's own malformed section is the parser's to name" do
    # The resolver merges into what the workflow wrote only where it is a mapping; anything else is
    # left as written, so the parser's own message about it is the one the author reads.
    test "commands, defaults and states that are not mappings" do
      for {from, to, path} <- [
            {"initial:", "commands: [build]\ninitial:", "commands"},
            {"initial:", "defaults: [x]\ninitial:", "defaults"},
            {"initial:", "defaults: { resources: big }\ninitial:", "defaults.resources"}
          ] do
        assert {:error, errors} = load(type_with([{from, to}]))
        assert Enum.any?(errors, &(&1.path == path and &1.file == nil)), inspect(errors)
      end

      yaml =
        "version: 1\nimport: [common.yml]\ninitial: a\nstates: [a]\ntransitions: []\nlimits: { ticket_cost: 1 }\n"

      assert {:error, errors} = load(yaml)
      assert Enum.any?(errors, &(&1.path == "states" and &1.file == nil))
    end

    test "a library default that is not a mapping is imported whole, and named against it" do
      files = %{
        "common.yml" => String.replace(@common, "defaults:\n", "defaults:\n  priority: high\n")
      }

      assert {:error, errors} = load(@type_yaml, files)
      assert messages(errors) == [{"common.yml", "defaults.priority", "unknown key"}]
    end

    test "a state template that is not a mapping is named" do
      files = %{"common.yml" => "states:\n  implementing: just-a-string\n"}

      assert {:error, errors} = load(@type_yaml, files)

      assert messages(errors) == [
               {"common.yml", "states.implementing", "a state template must be a mapping"}
             ]
    end

    test "extends that is not a name" do
      yaml = type_with([{"extends: implementing", "extends: [implementing]"}])

      assert {:error, [%Error{path: "states.implementing.extends", message: message}]} =
               load(yaml)

      assert message == "must name a state template from an imported library"
    end
  end

  # `commands:` with everything under it commented out is YAML's null. It read as a section to
  # sort, raised, and on the platform failed every job of the project.
  describe "an empty section" do
    test "in a library is no entries" do
      # The library holds only the empty section: appended to one that already has the key, YAML
      # keeps the first and the null never arrives, which is how this test once passed against the
      # bug it is for.
      for section <- ["commands", "defaults", "states"] do
        files = %{"common.yml" => "#{section}:\n"}

        yaml =
          type_with([
            {"extends: implementing", "prompt: a.md\n    budget: { turns: 1, cost: 1 }"}
          ])

        assert {:ok, _workflow, _flat} = load(yaml, files), section
      end
    end

    test "in the workflow itself is none of its own" do
      yaml = type_with([{"initial:", "commands:\ndefaults:\ninitial:"}])
      assert {:ok, workflow, _flat} = load(yaml)
      assert Map.keys(workflow.commands) |> Enum.sort() == ["build", "lint"]
    end
  end

  # YAML allows a mapping as a key. Every key is turned into a string on the way through, and one
  # that cannot be raised rather than being reported.
  describe "a key that is not a name" do
    test "in the workflow is refused where it is" do
      yaml = type_with([{"  review_ready: {}", "  review_ready: {}\n  ? {a: 1}\n  : {}"}])

      assert {:error, [%Error{path: "states", message: "a key must be a name" <> _}]} = load(yaml)
    end

    test "in a library is refused against the library" do
      files = %{"common.yml" => @common <> "? [a]\n: 1\n"}

      assert {:error, [%Error{file: "common.yml", path: "", message: message}]} =
               load(@type_yaml, files)

      assert message == "a key must be a name, not a mapping or a sequence"
    end

    test "in a map read back from storage is refused too" do
      assert {:error, [%Error{path: "states"}]} =
               Parser.from_map(%{"version" => 1, "states" => %{%{"a" => 1} => %{}}})
    end
  end

  describe "import entries that are not paths" do
    test "say what a path must be" do
      yaml = type_with([{"import: [common.yml]", "import: [../common.yml, 3]"}])

      assert {:error, errors} = load(yaml)

      assert [
               {nil, "import[0]",
                ~s("../common.yml" must be a path under .forge/, like common.yml, of names: ) <> _},
               {nil, "import[1]", "3 must be a path under .forge/, like common.yml"}
             ] = messages(errors)
    end
  end

  describe "description" do
    test "is optional, and a string when present" do
      yaml = type_with([{"description: Something that worked and does not.\n", ""}])
      assert {:ok, %Workflow{description: nil}, _flat} = load(yaml)

      yaml = type_with([{"description: Something that worked and does not.", "description: [a]"}])

      assert {:error, [%Error{path: "description", message: "must be a non-empty string"}]} =
               load(yaml)
    end
  end
end
