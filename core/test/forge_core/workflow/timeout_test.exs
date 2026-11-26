defmodule ForgeCore.Workflow.TimeoutTest do
  @moduledoc """
  `timeout` on an agent state and under `defaults` (`docs/design/workflow-grammar-v1.md` § Timeout):
  what the parser reads, where the validator refuses it by name, how it resolves, how a type's
  libraries supply it and what the manifest tells the agent.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Duration, Prompt, Workflow}
  alias ForgeCore.Job.Spec
  alias ForgeCore.Workflow.{Command, Parser}

  @base """
  version: 1
  initial: refining
  commands:
    build: { run: .forge/commands/build.sh, timeout: 10m }
  states:
    refining:
      prompt: agents/refine.md
      inputs: [ticket]
      produces: [refinement.md]
      budget: { turns: 5, tokens: 200k }
    chatting:
      chat: true
      prompt: agents/chat.md
      inputs: [ticket]
      produces: [notes.md]
    building:
      invoke: [build]
      exit: { "0": done, "*": failed }
    refresh:
      on_enter: update
    review_ready: {}
  transitions:
    - { from: refining, to: chatting }
    - { from: chatting, to: building }
    - { from: building, to: refresh }
    - { from: building, to: review_ready, when: failed }
    - { from: refresh, to: review_ready }
  limits: { ticket_tokens: 1M }
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp put_state(map, state, key, value), do: put_in(map, ["states", state, key], value)

  defp errors(map) do
    case Parser.from_map(map) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  defp refused(map, path),
    do: map |> errors() |> Enum.filter(fn {at, _} -> at == path end) |> Enum.map(&elem(&1, 1))

  defp parsed!(map) do
    assert {:ok, workflow} = Parser.from_map(map)
    workflow
  end

  describe "ForgeCore.Duration" do
    test "reads a whole number and one unit, or a bare number of seconds" do
      assert Duration.parse("90s", Duration.longest_ms()) == {:ok, 90_000}
      assert Duration.parse("20m", Duration.longest_ms()) == {:ok, 1_200_000}
      assert Duration.parse("3h", Duration.longest_ms()) == {:ok, 10_800_000}
      assert Duration.parse(7_200, Duration.longest_ms()) == {:ok, 7_200_000}
      # What a form box hands over with its stray spaces.
      assert Duration.parse(" 3h ", Duration.longest_ms()) == {:ok, 10_800_000}
    end

    test "refuses zero, a second unit, a decimal and a word" do
      for bad <- ["0h", 0, "1h30m", "1.5h", "abc", "", "-1h", "10", nil, true] do
        assert Duration.parse(bad, Duration.longest_ms()) == :error, inspect(bad)
      end
    end

    test "says a good duration that is past the maximum is too long, not malformed" do
      assert Duration.parse("25h", :timer.hours(24)) == :too_long
      assert Duration.parse("24h", :timer.hours(24)) == {:ok, 86_400_000}
    end

    test "writes the largest unit that divides exactly, and never days" do
      assert Duration.format(7_200_000) == "2h"
      assert Duration.format(5_400_000) == "90m"
      assert Duration.format(45_000) == "45s"
      assert Duration.format(3_600_000_000) == "1000h"
      # A multiple of a day is still hours: no `d` unit exists to write it in.
      assert Duration.format(86_400_000) == "24h"
      assert Duration.format(8_640_000_000) == "2400h"
      assert Duration.format(1_200_000) == "20m"
      # Not a whole second: said in seconds, rounded up, because nothing here is shorter.
      assert Duration.format(1_500) == "2s"
    end

    test "the technical bound is a thousand thousand hours" do
      assert Duration.longest_ms() == 1_000_000 * 3_600_000
    end

    test "a command's timeout still reads through it, at a day" do
      assert Command.parse_duration("24h") == {:ok, 86_400_000}
      assert Command.parse_duration("25h") == :error
    end
  end

  describe "parsing" do
    test "a state's timeout and the workflow's default are read" do
      map =
        base_map()
        |> put_state("refining", "timeout", "3h")
        |> Map.put("defaults", %{"timeout" => "90m"})

      workflow = parsed!(map)
      assert workflow.states["refining"].timeout_ms == 10_800_000
      assert workflow.defaults.timeout_ms == 5_400_000
    end

    test "1000h is accepted, on a state and under defaults" do
      map =
        base_map()
        |> put_state("refining", "timeout", "1000h")
        |> Map.put("defaults", %{"timeout" => "1000h"})

      workflow = parsed!(map)
      assert workflow.states["refining"].timeout_ms == 3_600_000_000
      assert workflow.defaults.timeout_ms == 3_600_000_000
    end

    test "a bare number is seconds" do
      workflow = parsed!(put_state(base_map(), "refining", "timeout", 7_200))
      assert workflow.states["refining"].timeout_ms == 7_200_000
    end

    test "malformed is refused by path on the state and on defaults" do
      for bad <- ["0", 0, "1h30m", "abc", "2d"] do
        message = "must be a duration: a whole number and one of s, m or h, like 3h"
        map = put_state(base_map(), "refining", "timeout", bad)
        assert refused(map, "states.refining.timeout") == [message], inspect(bad)

        map = Map.put(base_map(), "defaults", %{"timeout" => bad})
        assert refused(map, "defaults.timeout") == [message], inspect(bad)
      end
    end

    test "longer than forge can time is refused, saying so and not that it broke a rule" do
      message = "is longer than forge can time (at most 1000000h)"

      assert refused(
               put_state(base_map(), "refining", "timeout", "1000001h"),
               "states.refining.timeout"
             ) ==
               [message]

      assert refused(
               Map.put(base_map(), "defaults", %{"timeout" => "99999999999h"}),
               "defaults.timeout"
             ) ==
               [message]

      assert refused(
               put_state(base_map(), "refining", "timeout", "1000000h"),
               "states.refining.timeout"
             ) ==
               []
    end

    test "a command's own timeout still refuses a day and a quarter, in its own words" do
      map = put_in(base_map(), ["commands", "build", "timeout"], "25h")

      assert refused(map, "commands.build.timeout") == [
               "must be a duration of at most a day: a whole number and one of s, m or h, like 20m"
             ]
    end
  end

  describe "where it is refused" do
    test "a chat step names the state, and says a conversation's limit is the node's" do
      assert [message] =
               refused(
                 put_state(base_map(), "chatting", "timeout", "1h"),
                 "states.chatting.timeout"
               )

      assert message =~ "not allowed on a chat step"
    end

    test "a command state has none of its own: each command brings its own" do
      assert [message] =
               refused(
                 put_state(base_map(), "building", "timeout", "1h"),
                 "states.building.timeout"
               )

      assert message =~ "not allowed on a command state"
    end

    test "a human state runs nothing to time" do
      assert [message] =
               refused(
                 put_state(base_map(), "review_ready", "timeout", "1h"),
                 "states.review_ready.timeout"
               )

      assert message =~ "not allowed on a human state"
    end

    test "an update step is the platform's own work, with no job to time" do
      assert [message] =
               refused(
                 put_state(base_map(), "refresh", "timeout", "1h"),
                 "states.refresh.timeout"
               )

      assert message =~ "not allowed on a human state"
    end

    test "an agent state is the only one that may carry it" do
      assert errors(put_state(base_map(), "refining", "timeout", "1h")) == []
    end
  end

  describe "resolution" do
    test "nearest first: the state, then defaults, then two hours" do
      map =
        base_map()
        |> put_state("refining", "timeout", "3h")
        |> Map.put("defaults", %{"timeout" => "90m"})

      workflow = parsed!(map)
      assert Workflow.timeout_ms(workflow, "refining") == 10_800_000
      # No `timeout` of its own: the default.
      assert Workflow.timeout_ms(workflow, "building") == 5_400_000

      assert Workflow.timeout_ms(
               parsed!(put_state(base_map(), "refining", "timeout", "3h")),
               "building"
             ) ==
               Workflow.default_timeout_ms()

      assert Workflow.default_timeout_ms() == 7_200_000
      assert Workflow.timeout_ms(parsed!(base_map()), "refining") == 7_200_000
    end

    test "a state that does not exist resolves as one declaring nothing" do
      workflow = parsed!(Map.put(base_map(), "defaults", %{"timeout" => "5h"}))
      assert Workflow.timeout_ms(workflow, "vanished") == 18_000_000
    end

    test "a workflow with a resources default alone keeps the engine's two hours" do
      workflow = parsed!(Map.put(base_map(), "defaults", %{"resources" => %{"cpu" => 2}}))
      assert Workflow.timeout_ms(workflow, "refining") == 7_200_000
    end
  end

  describe "imports" do
    @library """
    defaults:
      timeout: 4h
    """

    @type_yaml """
    version: 1
    import: [common.yml]
    initial: refining
    states:
      refining:
        prompt: agents/refine.md
        inputs: [ticket]
        produces: [refinement.md]
        budget: { turns: 5, tokens: 200k }
      review_ready: {}
    transitions:
      - { from: refining, to: review_ready }
    limits: { ticket_tokens: 1M }
    """

    defp load(yaml, files),
      do:
        Parser.load(yaml,
          read_library: fn path ->
            case Map.fetch(files, path) do
              {:ok, text} -> {:ok, text}
              :error -> {:error, :enoent}
            end
          end
        )

    test "a library's default arrives, and the type's own wins" do
      assert {:ok, workflow, _flat} = load(@type_yaml, %{"common.yml" => @library})
      assert workflow.defaults.timeout_ms == 14_400_000

      own =
        String.replace(
          @type_yaml,
          "initial: refining",
          "defaults: { timeout: 1h }\ninitial: refining"
        )

      assert {:ok, workflow, _flat} = load(own, %{"common.yml" => @library})
      assert workflow.defaults.timeout_ms == 3_600_000
    end

    test "two libraries setting it is an error, because neither is nearer" do
      yaml = String.replace(@type_yaml, "import: [common.yml]", "import: [common.yml, other.yml]")

      assert {:error, errors} =
               load(yaml, %{"common.yml" => @library, "other.yml" => "defaults:\n  timeout: 5h\n"})

      assert Enum.map(errors, &{&1.file, &1.path, &1.message}) == [
               {"other.yml", "defaults.timeout", "is also set in common.yml"}
             ]
    end

    test "a library may set it beside resources without either losing" do
      library = "defaults:\n  timeout: 4h\n  resources: { cpu: 2 }\n"
      assert {:ok, workflow, _flat} = load(@type_yaml, %{"common.yml" => library})
      assert workflow.defaults.timeout_ms == 14_400_000
      assert workflow.defaults.resources.cpu == 2
    end
  end

  describe "the manifest" do
    defp spec(budget), do: %{ForgeCore.Fixtures.spec() | budget: budget}

    test "says the run's time and that the run is stopped when it passes it" do
      text = Prompt.manifest(spec(%{turns: 5, tokens: 200_000, timeout_ms: 10_800_000}), "/job")
      assert text =~ "- Time: 3h per run; the run is stopped when it passes it"
    end

    test "writes 1000h as 1000h" do
      text =
        Prompt.manifest(spec(%{turns: 5, tokens: 200_000, timeout_ms: 3_600_000_000}), "/job")

      assert text =~ "- Time: 1000h per run"
    end

    test "says nothing for a spec an older platform wrote" do
      text = Prompt.manifest(spec(%{turns: 5, tokens: 200_000}), "/job")
      refute text =~ "Time:"
    end

    test "the key survives the spec's round trip through JSON, which is how a worker reads it" do
      round_trip =
        %{turns: 5, tokens: 200_000, timeout_ms: 10_800_000}
        |> spec()
        |> Spec.to_json()
        |> Jason.decode!()
        |> Spec.from_map()

      assert round_trip.budget.timeout_ms == 10_800_000
    end

    test "a stored spec in dollars keeps its timeout out of the conversion" do
      spec =
        Spec.from_map(%{
          "job_id" => "j1",
          "budget" => %{"turns" => 5, "cost" => 2.0, "timeout_ms" => 10_800_000}
        })

      assert spec.budget.timeout_ms == 10_800_000
    end
  end
end
