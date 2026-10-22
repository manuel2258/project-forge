defmodule ForgeCore.Workflow.CommandsTest do
  @moduledoc """
  The command half of the grammar: `commands`, `invoke`, `exit` and `may_invoke`
  (`docs/design/workflow-grammar-v1.md` § Commands, § Validation), and what the workflow answers
  about them — outcomes, resources and the mapping of a batch's exit statuses.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Engine, Error, Workflow}
  alias ForgeCore.Workflow.{Command, Parser, Resources, State}

  # The example the grammar note opens with, read out of the note the validator is compiled with,
  # so the note cannot show a workflow the validator refuses.
  defp note_example do
    [_before, rest] = String.split(Workflow.grammar(), "## Shape", parts: 2)
    [_prose, rest] = String.split(rest, "```yaml\n", parts: 2)
    [yaml, _after] = String.split(rest, "```", parts: 2)
    yaml
  end

  @base """
  version: 1
  initial: implementing
  commands:
    build:
      run: .forge/commands/build.sh
      env: build
      produces: build.log
      timeout: 20m
      resources: { memory: 4GiB, cpu: 4 }
    test:
      run: .forge/commands/test.sh
      timeout: 90
  states:
    implementing:
      prompt: agents/implement.md
      produces: [implementation.md, changeset]
      may_invoke:
        build: { max: 40 }
        test: { max: 20, concurrent: 4 }
      budget: { turns: 10, cost: 1 }
    checking:
      invoke: [build, [test, --all, --jobs, 4]]
      exit: { 0: done, 2: flaky, "*": checks_failed }
      resources: { memory: 1GiB }
    done: {}
  transitions:
    - { from: implementing, to: checking }
    - { from: checking, to: done }
    - { from: checking, to: implementing, when: checks_failed, max: 3 }
    - { from: checking, to: checking, when: flaky, max: 1 }
  limits:
    ticket_cost: 5
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp messages(map, opts \\ []) do
    case Parser.from_map(map, opts) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  describe "the grammar note's example" do
    test "parses, commands and command state included" do
      assert {:ok, workflow} = Parser.parse(note_example())
      assert Map.keys(workflow.commands) == ["build", "test"]
      assert State.command?(workflow.states["checking"])

      assert workflow.states["checking"].invoke == [
               %{command: "build", args: []},
               %{command: "test", args: ["--all"]}
             ]
    end
  end

  describe "commands" do
    test "carry their script, environment, log, timeout and resources" do
      workflow = Parser.parse!(@base)

      assert %Command{
               name: "build",
               run: ".forge/commands/build.sh",
               env: "build",
               produces: "build.log",
               timeout_ms: 1_200_000,
               resources: %Resources{memory: 4_294_967_296, cpu: 4}
             } = workflow.commands["build"]

      # A bare number is seconds; absent `env`, `produces` and `resources` stay absent.
      assert %Command{timeout_ms: 90_000, env: nil, produces: nil, resources: nil} =
               workflow.commands["test"]
    end

    test "need a script and a timeout" do
      map = put_in(base_map(), ["commands", "test"], %{"env" => "x"})

      assert messages(map) == [
               {"commands.test.run", "is required"},
               {"commands.test.timeout", "is required"}
             ]
    end

    test "take no key the grammar does not name" do
      map = put_in(base_map(), ["commands", "test", "shell"], "bash")
      assert messages(map) == [{"commands.test.shell", "unknown key"}]
    end

    test "is a mapping of mappings" do
      assert messages(Map.put(base_map(), "commands", ["build"])) ==
               [{"commands", "must be a mapping of command names"}]

      assert [{"commands.build", "must be a mapping"} | _] =
               messages(put_in(base_map(), ["commands", "build"], "build.sh"))
    end

    # Lexical, against a commit: `docs/design/workflow-grammar-v1.md` § Validation puts the script
    # under `.forge/`, and the pinned commit is where it has to be.
    test "run a script under .forge/ that exists at the pinned commit" do
      for bad <- ["commands/build.sh", "/etc/passwd", ".forge/../x.sh", ".forge//x.sh", ".forge/"] do
        map = put_in(base_map(), ["commands", "test", "run"], bad)

        assert messages(map) ==
                 [
                   {"commands.test.run",
                    "must be a path under .forge/, like .forge/commands/build.sh"}
                 ],
               "accepted #{inspect(bad)}"
      end

      exists = &(&1 == ".forge/commands/build.sh")

      assert messages(base_map(), file_exists: exists) == [
               {"commands.test.run",
                "file \".forge/commands/test.sh\" does not exist at the pinned commit"}
             ]

      assert messages(base_map(), file_exists: fn _path -> true end) == []
    end

    test "produce a log no state and no other command produces" do
      by_state = put_in(base_map(), ["commands", "build", "produces"], "implementation.md")

      assert messages(by_state) == [
               {"commands.build.produces", "\"implementation.md\" is already produced by a state"}
             ]

      twice = put_in(base_map(), ["commands", "test", "produces"], "build.log")

      assert messages(twice) == [
               {"commands.build.produces", "\"build.log\" is also produced by test"},
               {"commands.test.produces", "\"build.log\" is also produced by build"}
             ]

      for reserved <- ["ticket", "answers.md", "changeset"] do
        map = put_in(base_map(), ["commands", "build", "produces"], reserved)

        assert messages(map) ==
                 [
                   {"commands.build.produces",
                    "#{inspect(reserved)} is reserved and cannot be produced"}
                 ]
      end

      map = put_in(base_map(), ["commands", "build", "produces"], "transcript-x")
      assert [{"commands.build.produces", "\"transcript-x\" is reserved" <> _}] = messages(map)

      map = put_in(base_map(), ["commands", "build", "produces"], "../log")
      assert [{"commands.build.produces", "artifact name must be" <> _}] = messages(map)
    end

    # `docs/design/workflow-grammar-v1.md` § Validation: a presentation is never under a name a
    # command produces as a group of files either. `command_outputs_errors/4` cannot see it from
    # its own side — it matches `deck.md` and `deck.md/*`, and the declaration is `deck.md!` — so
    # the clause is the presentation's, and one artifact would otherwise have two kinds.
    test "a presentation may not share its name with a command's group of files" do
      map =
        base_map()
        |> put_in(["commands", "build", "produces"], ["build.log", "deck.md/*"])
        |> put_in(["states", "implementing", "produces"], ["implementation.md", "deck.md!"])

      assert messages(map) == [
               {"states.implementing.produces[1]",
                "\"deck.md\" is also produced as a group of files by a command"}
             ]
    end

    # Which of the two command collisions is reported when both are true. The comment at
    # `presentation_error/4` says its branch order is asserted, and this is the pair that was not:
    # the group is reported, because a group is a name on disk and a log is a name the platform
    # gives the output of a script.
    test "a presentation colliding with both a command's group and a command's log names the group" do
      map =
        base_map()
        |> put_in(["commands", "build", "produces"], ["deck.md", "deck.md/*"])
        |> put_in(["states", "implementing", "produces"], ["implementation.md", "deck.md!"])

      assert {"states.implementing.produces[1]",
              "\"deck.md\" is also produced as a group of files by a command"} in messages(map)
    end

    # A presentation's artifact name has no marker in it, so a command's log can collide with one
    # under a name neither declaration shows. The collision is checked from the presentation's
    # side alone, which is why it is found whichever of the two is declared.
    test "a log may not share its name with a presentation" do
      map =
        base_map()
        |> put_in(["states", "implementing", "produces"], ["implementation.md", "build.log!"])

      assert messages(map) == [
               {"states.implementing.produces[1]",
                "\"build.log\" is also produced by command \"build\""}
             ]
    end
  end

  # `produces: [package.log, package/*]`: at most one log, any number of groups of files.
  describe "a command's groups of files" do
    # `workflow-grammar-v1.md` § Inputs: the log a command produces is something a later state can
    # read — the build that failed, for the review that has to judge the fix.
    test "produce a log a state may read, always as an optional input" do
      map = put_in(base_map(), ["states", "implementing", "inputs"], ["ticket", "build.log"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["implementing"].inputs == ["ticket", "build.log"]
      assert Workflow.log_producer(workflow, "build.log") == "build"
      assert Workflow.log_producer(workflow, "implementation.md") == nil
      refute Workflow.required_input?(workflow, "implementing", "build.log")
    end

    test "a log no command produces is still not an input" do
      map = put_in(base_map(), ["states", "implementing", "inputs"], ["test.log"])

      assert messages(map) == [
               {"states.implementing.inputs[0]",
                "\"test.log\" is not produced by any state or command"}
             ]
    end

    test "are read from a list beside its log, or on their own" do
      map =
        put_in(base_map(), ["commands", "build", "produces"], [
          "build.log",
          "package/*",
          "shots/*"
        ])

      workflow = Parser.from_map(map) |> elem(1)

      assert %Command{produces: "build.log", outputs: ["package/*", "shots/*"]} =
               workflow.commands["build"]

      map = put_in(base_map(), ["commands", "build", "produces"], "package/*")

      assert %Command{produces: nil, outputs: ["package/*"]} =
               Parser.from_map(map) |> elem(1) |> Map.fetch!(:commands) |> Map.fetch!("build")
    end

    test "take one log at most" do
      map = put_in(base_map(), ["commands", "build", "produces"], ["a.log", "b.log"])
      assert messages(map) == [{"commands.build.produces", "names at most one log"}]
    end

    test "are theirs alone" do
      by_state = put_in(base_map(), ["commands", "build", "produces"], ["implementation.md/*"])

      assert messages(by_state) == [
               {"commands.build.produces",
                "\"implementation.md/*\" is already produced by a state"}
             ]

      twice =
        base_map()
        |> put_in(["commands", "build", "produces"], ["pkg/*"])
        |> put_in(["commands", "test", "produces"], ["pkg/*"])

      assert messages(twice) == [
               {"commands.build.produces", "\"pkg/*\" is also produced by test"},
               {"commands.test.produces", "\"pkg/*\" is also produced by build"}
             ]

      state_too =
        base_map()
        |> put_in(["commands", "build", "produces"], ["pkg/*"])
        |> put_in(["states", "implementing", "produces"], [
          "implementation.md",
          "changeset",
          "pkg/*"
        ])

      assert {"states.implementing.produces[2]", "\"pkg/*\" is also produced by a command"} in messages(
               state_too
             )
    end

    test "are named as artifacts are, and not as the platform's" do
      map = put_in(base_map(), ["commands", "build", "produces"], ["../x/*", "proposals/*"])

      assert messages(map) == [
               {"commands.build.produces",
                "\"../x/*\" must name its files with a single path segment"},
               {"commands.build.produces", "\"proposals\" is reserved for ticket proposals"}
             ]
    end
  end

  describe "durations" do
    test "are a whole number and one unit, or bare seconds" do
      assert Command.parse_duration("90s") == {:ok, 90_000}
      assert Command.parse_duration("20m") == {:ok, 1_200_000}
      assert Command.parse_duration("2h") == {:ok, 7_200_000}
      assert Command.parse_duration(" 5m ") == {:ok, 300_000}
      assert Command.parse_duration(30) == {:ok, 30_000}
      assert Command.parse_duration("24h") == {:ok, 86_400_000}
      assert Command.parse_duration(86_400) == {:ok, 86_400_000}
    end

    # The worker arms a timer with it, and one past the runtime's largest crashes the command.
    test "refuse more than a day" do
      for bad <- ["25h", "1441m", "86401s", 86_401, "99999999999999h"] do
        assert Command.parse_duration(bad) == :error, "accepted #{inspect(bad)}"
      end
    end

    test "refuse zero, two units, spelled-out units and anything else" do
      for bad <- ["0m", "1h30m", "20 minutes", "20", "m", "-5m", 0, -3, 1.5, nil, %{}] do
        assert Command.parse_duration(bad) == :error, "accepted #{inspect(bad)}"
      end
    end

    test "a bad one names the form" do
      map = put_in(base_map(), ["commands", "test", "timeout"], "1h30m")

      assert messages(map) == [
               {"commands.test.timeout",
                "must be a duration of at most a day: a whole number and one of s, m or h, like 20m"}
             ]
    end
  end

  describe "invoke" do
    test "takes names, and lists of a name and its arguments, numbers as their digits" do
      workflow = Parser.parse!(@base)

      assert workflow.states["checking"].invoke == [
               %{command: "build", args: []},
               %{command: "test", args: ["--all", "--jobs", "4"]}
             ]
    end

    test "refuses what is not a name or a vector of strings" do
      map =
        put_in(base_map(), ["states", "checking", "invoke"], ["build", [], ["test", 1.5], %{}])

      assert messages(map) == [
               {"states.checking.invoke[1]",
                "must be a command name, or a list of the name and its arguments"},
               {"states.checking.invoke[2]", "arguments must be strings"},
               {"states.checking.invoke[3]",
                "must be a command name, or a list of the name and its arguments"}
             ]

      assert messages(put_in(base_map(), ["states", "checking", "invoke"], [])) ==
               [{"states.checking.invoke", "must be a non-empty list of commands"}]
    end

    test "names declared commands only" do
      map = put_in(base_map(), ["states", "checking", "invoke"], ["build", ["lint", "."]])

      assert messages(map) ==
               [{"states.checking.invoke[1]", "\"lint\" is not a declared command"}]
    end
  end

  describe "exit" do
    test "maps statuses and the default to outcomes" do
      assert Parser.parse!(@base).states["checking"].exit ==
               %{0 => "done", 2 => "flaky", "*" => "checks_failed"}
    end

    test "keys are statuses or \"*\", values are outcome names" do
      map =
        put_in(base_map(), ["states", "checking", "exit"], %{"x" => "done", -1 => "x", 3 => ""})

      assert messages(map) == [
               {"states.checking.exit", "\"x\" is not an exit status or \"*\""},
               {"states.checking.exit", "-1 is not an exit status or \"*\""},
               {"states.checking.exit.3", "must name an outcome"}
             ]
    end

    # `"0\n"` matched `^[0-9]+$`, whose `$` allows a final newline, and `String.to_integer/1` then
    # raised on it: a parse that raised rather than reported.
    test "a status with a trailing newline is not a status" do
      map = put_in(base_map(), ["states", "checking", "exit"], %{"0\n" => "done", "*" => "x"})
      assert {"states.checking.exit", ~s("0\\n" is not an exit status or "*")} in messages(map)
    end

    # The pinned definition is stored as JSON, where every key is a string: a command state has to
    # read back the way it was written, or its ticket stops parsing the first time it is read.
    test "a status written as its digits is that status, so the pinning survives JSON" do
      {:ok, pinned} = @base |> YamlElixir.read_from_string!() |> Jason.encode!() |> Jason.decode()

      assert %{"exit" => %{"0" => "done"}} = pinned["states"]["checking"]
      assert {:ok, workflow} = Parser.from_map(pinned)

      assert workflow.states["checking"].exit == %{
               0 => "done",
               2 => "flaky",
               "*" => "checks_failed"
             }
    end

    test "never names an engine outcome" do
      map = put_in(base_map(), ["states", "checking", "exit", "*"], "error")

      assert messages(map) == [
               {"states.checking.exit", "\"error\" is an engine outcome and cannot be mapped to"},
               {"transitions[2].when",
                "\"checks_failed\" is not an outcome of state \"checking\""}
             ]
    end

    test "is required on a command state and refused on a job state" do
      map =
        base_map()
        |> update_in(["states", "checking"], &Map.delete(&1, "exit"))
        |> put_in(["states", "implementing", "exit"], %{0 => "done"})

      assert {"states.checking.exit", "is required on a command state"} in messages(map)

      assert {"states.implementing.exit",
              "not allowed on a job state: its agent declares outcomes"} in messages(map)
    end
  end

  # Refusals with nothing else in the same map to catch them.
  describe "refused shapes" do
    test "a grant that is not a mapping, and may_invoke that is not one" do
      assert messages(put_in(base_map(), ["states", "implementing", "may_invoke", "build"], 3)) ==
               [{"states.implementing.may_invoke.build", "must be a mapping with max"}]

      assert messages(put_in(base_map(), ["states", "implementing", "may_invoke"], ["build"])) ==
               [{"states.implementing.may_invoke", "must be a mapping of command names"}]
    end

    # A `concurrent` of nothing would hold every invocation for ever.
    test "a concurrent of zero" do
      map =
        put_in(base_map(), ["states", "implementing", "may_invoke", "build"], %{
          "max" => 1,
          "concurrent" => 0
        })

      assert messages(map) ==
               [{"states.implementing.may_invoke.build.concurrent", "must be a positive integer"}]
    end

    test "exit on a human state" do
      assert messages(put_in(base_map(), ["states", "done", "exit"], %{0 => "x"})) ==
               [{"states.done.exit", "not allowed on a human state (no prompt)"}]
    end

    test "a command name that is not one segment" do
      map =
        put_in(base_map(), ["commands", "bad name"], %{
          "run" => ".forge/commands/build.sh",
          "timeout" => "1m"
        })

      assert messages(map) == [
               {"commands.bad name",
                "command name must be a single path segment: " <> Workflow.name_rule()}
             ]
    end

    test "a run path with a . segment" do
      assert messages(put_in(base_map(), ["commands", "build", "run"], ".forge/./build.sh")) == [
               {"commands.build.run",
                "must be a path under .forge/, like .forge/commands/build.sh"}
             ]
    end

    # Named, not raised: a key with digits in it is not a status.
    test "an exit key that is only partly digits, and an empty exit" do
      map = put_in(base_map(), ["states", "checking", "exit"], %{"2a" => "x", "*" => "done"})
      assert messages(map) == [{"states.checking.exit", "\"2a\" is not an exit status or \"*\""}]

      assert messages(put_in(base_map(), ["states", "checking", "exit"], %{})) ==
               [{"states.checking.exit", "must be a mapping of exit statuses to outcomes"}]
    end

    # A command state's outcomes are its exit values; two edges on one of them is as ambiguous as
    # it is from a job state.
    test "two transitions from a command state on one outcome" do
      extra = %{"from" => "checking", "to" => "done", "when" => "checks_failed"}
      map = Map.update!(base_map(), "transitions", &(&1 ++ [extra]))

      assert {"transitions[4]", "more than one transition from \"checking\" on \"checks_failed\""} in messages(
               map
             )
    end
  end

  describe "may_invoke" do
    test "grants a number of invocations and optionally a concurrency" do
      assert Parser.parse!(@base).states["implementing"].may_invoke == %{
               "build" => %{max: 40, concurrent: nil},
               "test" => %{max: 20, concurrent: 4}
             }
    end

    test "needs max, and nothing the grammar does not name" do
      map =
        put_in(base_map(), ["states", "implementing", "may_invoke"], %{
          "build" => %{"concurrent" => 2},
          "test" => %{"max" => 1, "priority" => 9}
        })

      assert messages(map) == [
               {"states.implementing.may_invoke.build.max", "is required"},
               {"states.implementing.may_invoke.test.priority", "unknown key"}
             ]
    end

    # A rule of the validator, which runs only once the structure is sound — so on its own.
    test "names declared commands only" do
      map = put_in(base_map(), ["states", "implementing", "may_invoke", "lint"], %{"max" => 1})

      assert messages(map) ==
               [{"states.implementing.may_invoke.lint", "is not a declared command"}]
    end

    test "is a job state's, not a command or a human state's" do
      map =
        base_map()
        |> put_in(["states", "checking", "may_invoke"], %{"build" => %{"max" => 1}})
        |> put_in(["states", "done", "may_invoke"], %{"build" => %{"max" => 1}})

      assert messages(map) == [
               {"states.checking.may_invoke", "not allowed on a command state"},
               {"states.done.may_invoke", "not allowed on a human state (no prompt)"}
             ]
    end
  end

  describe "a command state" do
    test "runs an agent or commands, not both" do
      map = put_in(base_map(), ["states", "implementing", "invoke"], ["build"])

      assert messages(map) ==
               [
                 {"states.implementing.invoke",
                  "a state runs an agent or commands, not both: it has a prompt"}
               ]
    end

    test "carries nothing an agent would, and no environment of its own" do
      map =
        update_in(base_map(), ["states", "checking"], fn state ->
          Map.merge(state, %{
            "env" => "build",
            "model" => "opus",
            "inputs" => ["ticket"],
            "produces" => ["x.md"],
            "outcomes" => ["done"],
            "budget" => %{"turns" => 1, "cost" => 1}
          })
        end)

      assert messages(map) == [
               {"states.checking.budget", "not allowed on a command state"},
               {"states.checking.env", "not allowed on a command state"},
               {"states.checking.inputs", "not allowed on a command state"},
               {"states.checking.model", "not allowed on a command state"},
               {"states.checking.outcomes", "not allowed on a command state"},
               {"states.checking.produces", "not allowed on a command state"}
             ]
    end

    test "is not where a ticket starts, and does not merge" do
      assert [{"initial", "must name a job state, not a command state"} | _] =
               messages(Map.put(base_map(), "initial", "checking"))

      map = put_in(base_map(), ["states", "checking", "on_enter"], "merge")

      assert {"states.checking.on_enter",
              "not allowed on a command state: entering it already runs its commands"} in messages(
               map
             )
    end

    test "selects its edges by the outcomes its exit map names" do
      map =
        update_in(base_map(), ["transitions"], fn transitions ->
          transitions ++ [%{"from" => "checking", "to" => "done", "when" => "tests_failed"}]
        end)

      assert messages(map) ==
               [
                 {"transitions[4].when",
                  "\"tests_failed\" is not an outcome of state \"checking\""}
               ]

      # `when` defaults to `done`, which is only an outcome when `exit` names it.
      map =
        put_in(base_map(), ["states", "checking", "exit"], %{0 => "ok", "*" => "checks_failed"})

      assert messages(map) == [
               {"transitions[1].when", "\"done\" is not an outcome of state \"checking\""},
               {"transitions[3].when", "\"flaky\" is not an outcome of state \"checking\""}
             ]
    end

    test "is not a human state, and the engine steps it" do
      workflow = Parser.parse!(@base)
      checking = workflow.states["checking"]

      assert State.command?(checking) and State.runs?(checking)
      refute State.human?(checking) or State.job?(checking)
      assert State.human?(workflow.states["done"])

      assert Workflow.outcomes(workflow, "checking") ==
               Workflow.engine_outcomes() ++ ["done", "flaky", "checks_failed"]

      assert {:transition, %{to: "implementing"}} =
               Engine.step(workflow, "checking", "checks_failed", %{})

      assert {:error, {:human_state, "done"}} = Engine.step(workflow, "done", "done", %{})
    end
  end

  describe "exit_outcome/2" do
    @exit %{0 => "done", 2 => "flaky", "*" => "failed"}

    test "every command exiting zero is status zero" do
      assert Workflow.exit_outcome(@exit, [0, 0]) == "done"
    end

    test "the first non-zero status in invoke order decides" do
      assert Workflow.exit_outcome(@exit, [0, 2, 1]) == "flaky"
      assert Workflow.exit_outcome(@exit, [1, 2]) == "failed"
    end

    # A command with no status — its timeout, a script that would not start — is not a zero.
    test "a command that ended without a status matches only the default" do
      assert Workflow.exit_outcome(@exit, [nil]) == "failed"
      assert Workflow.exit_outcome(@exit, [0, nil, 2]) == "failed"
      assert Workflow.exit_outcome(%{0 => "done"}, [nil]) == "error"
    end

    test "a status no key matches is the engine's error" do
      assert Workflow.exit_outcome(%{0 => "done"}, [3]) == "error"
      assert Workflow.exit_outcome(%{"*" => "failed"}, [0]) == "failed"
      assert Workflow.exit_outcome(%{1 => "failed"}, [0]) == "error"
    end
  end

  describe "command_resources/3" do
    test "the command's, then the invoking state's, then the defaults, each field on its own" do
      workflow = %{
        Parser.parse!(@base)
        | defaults: %ForgeCore.Workflow.Defaults{resources: %Resources{memory: 5, cpu: 7}}
      }

      assert Workflow.command_resources(workflow, "build", "checking") ==
               %Resources{memory: 4_294_967_296, cpu: 4}

      assert Workflow.command_resources(workflow, "test", "checking") ==
               %Resources{memory: 1_073_741_824, cpu: 7}

      assert Workflow.command_resources(workflow, "test", "implementing") ==
               %Resources{memory: 5, cpu: 7}

      assert Workflow.command_resources(workflow, "gone", "gone") == %Resources{memory: 5, cpu: 7}
    end
  end

  test "errors carry paths the operator can find" do
    assert %Error{path: "commands.test.run"} =
             Error.new(Error.join("commands", "test") |> Error.join("run"), "x")
  end
end
