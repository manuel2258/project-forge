defmodule ForgeCore.Workflow.ParserTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Budget, Parser, State, Transition}

  @fixture Path.expand("../../fixtures/workflow_example.yml", __DIR__)

  setup_all do
    yaml = File.read!(@fixture)
    {:ok, map} = YamlElixir.read_from_string(yaml)
    %{yaml: yaml, map: map}
  end

  describe "parse/2 on the grammar example" do
    test "returns a workflow with every state, transition and limit", %{yaml: yaml} do
      assert {:ok, %Workflow{} = workflow} = Parser.parse(yaml)

      assert workflow.version == 1
      assert workflow.initial == "refining"
      assert workflow.limits.ticket_cost == 25.0
      assert map_size(workflow.states) == 6
      assert length(workflow.transitions) == 7

      assert %State{
               prompt: "agents/implement.md",
               env: "implement",
               model: "opus",
               inputs: ["plan.md"],
               produces: ["implementation.md", "changeset"],
               outcomes: ["done", "plan_invalid"],
               budget: %Budget{turns: 200, cost: 10.0}
             } = workflow.states["implementing"]

      # A state that names none says nothing, rather than saying "the default": what fills the
      # gap is the project's, and then the machine's, and neither is core's to know.
      assert %State{model: nil} = workflow.states["refining"]

      assert %Transition{
               from: "verifying",
               to: "implementing",
               when: "tests_failed",
               max: 3,
               approve: []
             } =
               Enum.at(workflow.transitions, 5)
    end

    test "defaults outcomes of a job state to [done] and leaves human states bare", %{yaml: yaml} do
      {:ok, workflow} = Parser.parse(yaml)
      assert workflow.states["refining"].outcomes == ["done"]

      assert %State{prompt: nil, outcomes: nil, budget: nil, inputs: [], produces: []} =
               workflow.states["merged"]

      assert State.human?(workflow.states["review_ready"])
      assert Workflow.terminal?(workflow, "merged")
      refute Workflow.terminal?(workflow, "review_ready")
    end

    test "answers questions about the definition", %{yaml: yaml} do
      {:ok, workflow} = Parser.parse(yaml)
      assert Workflow.producers(workflow, "plan.md") == ["planning"]
      assert Workflow.producers(workflow, "changeset") == ["implementing"]

      assert Workflow.outcomes(workflow, "verifying") ==
               Workflow.engine_outcomes() ++ ["done", "tests_failed"]

      assert Workflow.outcomes(workflow, "merged") == Workflow.engine_outcomes()
      assert Transition.outcome(Enum.at(workflow.transitions, 1)) == "done"
      assert Transition.requires_approval?(Enum.at(workflow.transitions, 0))
      assert State.outcome_document(workflow.states["implementing"]) == "implementation.md"
    end

    test "checks prompt files when asked", %{yaml: yaml} do
      assert {:ok, _} = Parser.parse(yaml, prompt_exists: fn _ -> true end)
      assert {:error, errors} = Parser.parse(yaml, prompt_exists: &(&1 != "agents/plan.md"))
      assert [%Error{path: "states.planning.prompt"}] = errors
    end

    # A human state has no prompt, and the check must not be asked about `nil`. Both callbacks
    # above answer `true` for anything, `nil` included, so the `State.job?/1` filter that keeps
    # human states out was invisible to them. The platform supplies a real "does this path exist
    # at the pinned commit" function: handed `nil` it would either raise during admission or
    # report `states.merged.prompt: file nil does not exist` for a state that has no prompt file
    # by design.
    test "the prompt check is never asked about a state that has no prompt", %{yaml: yaml} do
      asked = :ets.new(:asked, [:public, :bag])

      assert {:ok, _workflow} =
               Parser.parse(yaml,
                 prompt_exists: fn path ->
                   :ets.insert(asked, {:path, path})
                   true
                 end
               )

      paths = Enum.map(:ets.lookup(asked, :path), &elem(&1, 1))

      refute Enum.empty?(paths)
      refute nil in paths
      assert Enum.all?(paths, &is_binary/1)

      # `merged` and `review_ready` are the example's human states; neither has a prompt file to
      # look for.
      assert paths == Enum.filter(paths, &String.starts_with?(&1, "agents/"))
    end

    test "parse!/2 raises with every error listed" do
      assert_raise ArgumentError, ~r/initial: is required.*version: is required/s, fn ->
        Parser.parse!("states: {a: {}}\ntransitions: []\nlimits: {ticket_cost: 1}\n")
      end
    end
  end

  describe "parse/2 on malformed input" do
    test "rejects invalid YAML" do
      assert {:error, [%Error{path: "", message: "invalid YAML: " <> _}]} =
               Parser.parse("states: [\n")
    end

    test "rejects a non-mapping document" do
      assert {:error, [%Error{message: "expected a mapping at the top level"}]} =
               Parser.parse("- a\n- b\n")
    end
  end

  describe "structural errors" do
    test "unknown keys anywhere, including the keys reserved for later versions", %{map: map} do
      map =
        map
        |> Map.put("blocks", %{})
        |> put_in(["states", "refining", "can_spawn"], ["x"])
        |> update_in(["transitions"], fn [first | rest] ->
          [Map.put(first, "guard", "x") | rest]
        end)
        |> put_in(["limits", "spawn_depth"], 2)

      assert paths(map) == [
               "blocks",
               "limits.spawn_depth",
               "states.refining.can_spawn",
               "transitions[0].guard"
             ]

      assert Enum.all?(errors(map), &(&1.message == "unknown key"))
    end

    test "version must be 1", %{map: map} do
      assert messages(Map.put(map, "version", 2)) == [{"version", "must be 1"}]
      assert messages(Map.delete(map, "version")) == [{"version", "is required"}]
    end

    test "budget fields are typed", %{map: map} do
      map = put_in(map, ["states", "refining", "budget"], %{"turns" => 0, "cost" => "cheap"})

      assert messages(map) == [
               {"states.refining.budget.cost", "must be a non-negative number"},
               {"states.refining.budget.turns", "must be a positive integer"}
             ]
    end

    # The test above feeds only a wrong *type*, so the sign half of "non-negative" and the sign
    # half of "positive" were never exercised. A negative cost budget reaches the harness as
    # `--max-budget-usd -5`, and a negative `ticket_cost` makes `Engine.within_ticket_budget?/2`
    # false for every ticket from its very first job — the ticket sticks before any work is done.
    test "budget numbers must have the right sign, not merely the right type", %{map: map} do
      map = put_in(map, ["states", "refining", "budget"], %{"turns" => -1, "cost" => -5})

      assert messages(map) == [
               {"states.refining.budget.cost", "must be a non-negative number"},
               {"states.refining.budget.turns", "must be a positive integer"}
             ]
    end

    test "a ticket allowance must not be negative", %{map: map} do
      assert messages(Map.put(map, "limits", %{"ticket_cost" => -1})) == [
               {"limits.ticket_cost", "must be a non-negative number"}
             ]
    end

    # Zero is a real allowance — "this state may spend nothing" — and must not be swept up with
    # the negatives it sits next to.
    test "zero is an allowance, not an error", %{map: map} do
      map = put_in(map, ["states", "refining", "budget", "cost"], 0)

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["refining"].budget.cost == 0
    end

    test "lists must hold non-empty strings", %{map: map} do
      map = put_in(map, ["states", "refining", "inputs"], ["ticket", 3])
      assert messages(map) == [{"states.refining.inputs", "must be a list of non-empty strings"}]
    end

    # Same shape as the budget case: the existing test feeds a number, so the emptiness check
    # never runs. An empty outcome name would make a transition matchable by a job that declared
    # nothing, and an empty input name resolves to the job directory itself.
    test "an empty string in a list is not a string", %{map: map} do
      map = put_in(map, ["states", "refining", "inputs"], ["ticket", ""])

      assert messages(map) == [{"states.refining.inputs", "must be a list of non-empty strings"}]
    end

    # `required_string` and `optional_string` both fold emptiness into their type check, and
    # neither half had a test. `prompt: ""` is the sharp one: it turns a human state into a job
    # state with no prompt file, which the validator then cannot check the existence of.
    test "a required string may not be empty", %{map: map} do
      assert messages(Map.put(map, "initial", ""))
             |> Enum.member?({"initial", "must be a non-empty string"})
    end

    test "an optional string, where present, may not be empty", %{map: map} do
      assert messages(put_in(map, ["states", "refining", "prompt"], "")) == [
               {"states.refining.prompt", "must be a non-empty string"}
             ]
    end

    # `docs/design/workflow-grammar-v1.md` § Model states the rule outright: "`model`, where
    # present, is a non-empty string". The grammar deliberately does not check the name against
    # any list, so emptiness is the only thing it does check — and it was unchecked.
    test "a model, where present, may not be empty", %{map: map} do
      assert messages(put_in(map, ["states", "refining", "model"], "")) == [
               {"states.refining.model", "must be a non-empty string"}
             ]
    end

    test "limits are required", %{map: map} do
      assert messages(Map.delete(map, "limits")) == [
               {"limits", "must be a mapping with ticket_cost"}
             ]

      assert messages(Map.put(map, "limits", %{})) == [{"limits.ticket_cost", "is required"}]
    end

    test "states must be a non-empty mapping and each state a mapping", %{map: map} do
      assert messages(Map.put(map, "states", %{})) |> Enum.map(&elem(&1, 0)) == ["states"]

      assert [{"states.refining", "must be a mapping" <> _}] =
               messages(put_in(map, ["states", "refining"], nil))
    end

    test "transitions must be mappings with from and to", %{map: map} do
      map = Map.put(map, "transitions", ["nope", %{"to" => "merged"}])

      assert messages(map) == [
               {"transitions[0]", "must be a mapping"},
               {"transitions[1].from", "is required"}
             ]
    end

    test "structural errors are reported together and before semantic ones", %{map: map} do
      map = map |> Map.put("version", 3) |> Map.put("initial", "nowhere")
      assert paths(map) == ["version"]
    end
  end

  describe "semantic errors" do
    test "initial must name a job state", %{map: map} do
      assert messages(Map.put(map, "initial", "nowhere")) == [
               {"initial", "names an unknown state \"nowhere\""}
             ]

      assert [{"initial", "must name a job state" <> _} | _] =
               messages(Map.put(map, "initial", "merged"))
    end

    test "job states need a budget; human states carry nothing else", %{map: map} do
      map =
        map
        |> update_in(["states", "refining"], &Map.delete(&1, "budget"))
        |> put_in(["states", "merged"], %{"env" => "x", "produces" => ["y"], "model" => "opus"})

      # A human state runs no job, so naming a model for it is naming one for nothing.
      assert messages(map) == [
               {"states.merged.env", "not allowed on a human state (no prompt)"},
               {"states.merged.model", "not allowed on a human state (no prompt)"},
               {"states.merged.produces", "not allowed on a human state (no prompt)"},
               {"states.refining.budget", "is required on a job state"}
             ]
    end

    test "inputs must be ticket or produced somewhere", %{map: map} do
      map = put_in(map, ["states", "planning", "inputs"], ["ticket", "missing.md", "answers.md"])

      assert messages(map) == [
               {"states.planning.inputs[1]", "\"missing.md\" is not produced by any state"},
               {"states.planning.inputs[2]", "answers.md is platform-managed and never declared"}
             ]
    end

    test "documents are produced by exactly one state; reserved names are never produced", %{
      map: map
    } do
      map =
        map
        |> put_in(["states", "planning", "produces"], ["plan.md", "ticket"])
        |> put_in(["states", "verifying", "produces"], ["report.md", "plan.md"])

      assert messages(map) == [
               {"states.planning.produces[0]",
                "\"plan.md\" is produced by more than one state: planning, verifying"},
               {"states.planning.produces[1]", "\"ticket\" is reserved and cannot be produced"},
               {"states.verifying.produces[1]",
                "\"plan.md\" is produced by more than one state: planning, verifying"}
             ]
    end

    test "the prefix group form is reserved", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "screenshots/*"])

      assert [{"states.verifying.produces[1]", "prefix groups (name/*) are reserved" <> _}] =
               messages(map)
    end

    test "declared outcomes are non-empty, unique, not engine outcomes, and carried by a document",
         %{map: map} do
      map =
        map
        |> put_in(["states", "planning", "outcomes"], ["done", "error", "done"])
        |> put_in(["states", "implementing", "produces"], ["changeset"])
        |> put_in(["states", "verifying", "inputs"], ["plan.md", "changeset"])

      assert messages(map) == [
               {"states.implementing.outcomes",
                "declaring outcomes other than done requires a document in produces"},
               {"states.planning.outcomes", "\"done\" is declared more than once"},
               {"states.planning.outcomes",
                "\"error\" is an engine outcome and cannot be declared"}
             ]
    end

    test "transitions reference known states and known outcomes", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          transitions ++
            [
              %{"from" => "ghost", "to" => "merged"},
              %{"from" => "planning", "to" => "ghost", "when" => "budget_exhausted"},
              %{"from" => "planning", "to" => "merged", "when" => "tests_failed"},
              %{"from" => "review_ready", "to" => "merged", "when" => "done"}
            ]
        end)

      assert messages(map) == [
               {"transitions[10].when", "not allowed on a transition from a human state"},
               {"transitions[7].from", "names an unknown state \"ghost\""},
               {"transitions[8].to", "names an unknown state \"ghost\""},
               {"transitions[9].when", "\"tests_failed\" is not an outcome of state \"planning\""}
             ]
    end

    test "one transition per outcome from a job state", %{map: map} do
      map = Map.update!(map, "transitions", &(&1 ++ [%{"from" => "planning", "to" => "merged"}]))

      assert messages(map) == [
               {"transitions[1]", "more than one transition from \"planning\" on \"done\""},
               {"transitions[7]", "more than one transition from \"planning\" on \"done\""}
             ]
    end

    test "approval names artifacts produced by from or a state before it", %{map: map} do
      map =
        update_in(map, ["transitions"], fn [first | rest] ->
          [Map.put(first, "approve", ["plan.md"]) | rest]
        end)

      assert [
               {"transitions[0].approve[0]",
                "\"plan.md\" is not produced by \"refining\" or a state before it"}
             ] = messages(map)
    end

    test "approval may name an artifact from an earlier state", %{map: map} do
      map =
        update_in(map, ["transitions"], fn ts ->
          List.update_at(ts, 4, &Map.put(&1, "approve", ["plan.md"]))
        end)

      assert {:ok, _} = Parser.from_map(map)
    end

    test "inputs must come from a state that runs before the consumer", %{map: map} do
      map = put_in(map, ["states", "refining", "inputs"], ["ticket", "plan.md"])

      assert [
               {"states.refining.inputs[1]",
                "\"plan.md\" is not produced by any state that runs before this one"}
             ] = messages(map)
    end

    test "state and artifact names are single path segments", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["../report.md"])
        |> put_in(["states", "review_ready"], %{})
        |> Map.update!("states", &Map.put(&1, "bad/name", %{}))
        |> Map.update!("transitions", &(&1 ++ [%{"from" => "review_ready", "to" => "bad/name"}]))

      assert {"states.bad/name",
              "state name must be a single path segment: letters, digits, . _ -"} in messages(map)

      assert {"states.verifying",
              "artifact name \"../report.md\" must be a single path segment: letters, digits, . _ -"} in messages(
               map
             )
    end

    # `.` and `..` are rejected because the format demands a leading alphanumeric, not because
    # they are listed anywhere — the `name not in [".", ".."]` conjunct beside the regex can
    # never fire. That makes this the only thing holding the traversal line: if the format is
    # ever widened to allow a leading dot (for a dotfile artifact, say), these names become legal
    # and an artifact called `..` is a write to the job directory's parent.
    test "a name that is only dots is refused, whatever the format is widened to", %{map: map} do
      for name <- [".", "..", "...", ".hidden"] do
        map = put_in(map, ["states", "verifying", "produces"], [name])

        assert {"states.verifying",
                "artifact name #{inspect(name)} must be a single path segment: letters, digits, . _ -"} in messages(
                 map
               ),
               "#{inspect(name)} was accepted as an artifact name"
      end
    end

    test "a name may hold a dot without being one", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.v2.md"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["verifying"].produces == ["report.v2.md"]
    end

    test "every state must be reachable from initial", %{map: map} do
      map = put_in(map, ["states", "orphan"], %{})
      assert messages(map) == [{"states.orphan", "is not reachable from initial"}]
    end
  end

  describe "on_enter" do
    test "the example's terminal state merges", %{yaml: yaml} do
      assert {:ok, workflow} = Parser.parse(yaml)
      assert workflow.states["merged"].on_enter == [:merge]
      assert State.merges?(workflow.states["merged"])
      assert Workflow.merges_on_enter?(workflow, "merged")
      refute Workflow.merges_on_enter?(workflow, "review_ready")
      assert workflow.states["review_ready"].on_enter == []
    end

    test "a list is accepted as well as a single action", %{map: map} do
      map = put_in(map, ["states", "merged", "on_enter"], ["merge"])
      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["merged"].on_enter == [:merge]
    end

    test "an unknown action is an error", %{map: map} do
      map = put_in(map, ["states", "merged", "on_enter"], ["deploy"])
      assert messages(map) == [{"states.merged.on_enter", ~s|unknown action "deploy"|}]
    end

    test "anything but an action or a list of them is an error", %{map: map} do
      map = put_in(map, ["states", "merged", "on_enter"], %{"do" => "merge"})

      assert {"states.merged.on_enter", "must be an action or a list of them"} in messages(map)
    end

    # Entering a job state already runs a job; two things on one entry would leave their order
    # undefined, so the grammar refuses rather than picking one.
    test "a job state may not carry one", %{map: map} do
      map = put_in(map, ["states", "verifying", "on_enter"], "merge")

      assert {"states.verifying.on_enter",
              "not allowed on a job state: entering it already runs a job"} in messages(map)
    end

    test "only one state may merge", %{map: map} do
      map = put_in(map, ["states", "review_ready"], %{"on_enter" => "merge"})

      assert {"states", "only one state may merge; merged, review_ready all do"} in messages(map)
    end

    test "the initial state may not merge", %{map: map} do
      map =
        map
        |> put_in(["states", "merged"], %{})
        |> put_in(["initial"], "review_ready")
        |> put_in(["states", "review_ready"], %{"on_enter" => "merge"})

      assert {"initial", "names a state that merges, so a ticket would merge at admission"} in messages(
               map
             )
    end

    test "merging needs a state that produces the changeset", %{map: map} do
      map =
        map
        |> put_in(["states", "implementing", "produces"], ["implementation.md"])
        |> put_in(["states", "verifying", "inputs"], ["plan.md", "implementation.md"])
        |> update_in(["transitions"], fn transitions ->
          Enum.reject(transitions, &(&1["to"] == "merged" and &1["approve"] == ["changeset"]))
        end)
        |> Map.update!("transitions", &(&1 ++ [%{"from" => "review_ready", "to" => "merged"}]))

      assert {"states.merged.on_enter", "merge needs a state that produces changeset"} in messages(
               map
             )
    end
  end

  defp errors(map) do
    {:error, errors} = Parser.from_map(map)
    errors
  end

  defp paths(map), do: Enum.map(errors(map), & &1.path)
  defp messages(map), do: Enum.map(errors(map), &{&1.path, &1.message})
end
