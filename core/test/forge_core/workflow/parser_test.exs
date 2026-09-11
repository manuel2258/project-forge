defmodule ForgeCore.Workflow.ParserTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Budget, Error, Parser, State, Transition}

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
      assert workflow.initial == "refined"
      assert workflow.limits.ticket_cost == 25.0
      assert map_size(workflow.states) == 6
      assert length(workflow.transitions) == 7

      assert %State{
               prompt: "agents/implement.md",
               env: "implement",
               inputs: ["plan.md"],
               produces: ["implementation.md", "changeset"],
               outcomes: ["done", "plan_invalid"],
               budget: %Budget{turns: 200, cost: 10.0}
             } = workflow.states["implemented"]

      assert %Transition{
               from: "verified",
               to: "implemented",
               when: "tests_failed",
               max: 3,
               approve: []
             } =
               Enum.at(workflow.transitions, 5)
    end

    test "defaults outcomes of a job state to [done] and leaves human states bare", %{yaml: yaml} do
      {:ok, workflow} = Parser.parse(yaml)
      assert workflow.states["refined"].outcomes == ["done"]

      assert %State{prompt: nil, outcomes: nil, budget: nil, inputs: [], produces: []} =
               workflow.states["merged"]

      assert State.human?(workflow.states["review_ready"])
      assert Workflow.terminal?(workflow, "merged")
      refute Workflow.terminal?(workflow, "review_ready")
    end

    test "answers questions about the definition", %{yaml: yaml} do
      {:ok, workflow} = Parser.parse(yaml)
      assert Workflow.producers(workflow, "plan.md") == ["planned"]
      assert Workflow.producers(workflow, "changeset") == ["implemented"]

      assert Workflow.outcomes(workflow, "verified") ==
               Workflow.engine_outcomes() ++ ["done", "tests_failed"]

      assert Workflow.outcomes(workflow, "merged") == Workflow.engine_outcomes()
      assert Transition.outcome(Enum.at(workflow.transitions, 1)) == "done"
      assert Transition.requires_approval?(Enum.at(workflow.transitions, 0))
      assert State.outcome_document(workflow.states["implemented"]) == "implementation.md"
    end

    test "checks prompt files when asked", %{yaml: yaml} do
      assert {:ok, _} = Parser.parse(yaml, prompt_exists: fn _ -> true end)
      assert {:error, errors} = Parser.parse(yaml, prompt_exists: &(&1 != "agents/plan.md"))
      assert [%Error{path: "states.planned.prompt"}] = errors
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
        |> put_in(["states", "refined", "can_spawn"], ["x"])
        |> update_in(["transitions"], fn [first | rest] ->
          [Map.put(first, "guard", "x") | rest]
        end)
        |> put_in(["limits", "spawn_depth"], 2)

      assert paths(map) == [
               "blocks",
               "limits.spawn_depth",
               "states.refined.can_spawn",
               "transitions[0].guard"
             ]

      assert Enum.all?(errors(map), &(&1.message == "unknown key"))
    end

    test "version must be 1", %{map: map} do
      assert messages(Map.put(map, "version", 2)) == [{"version", "must be 1"}]
      assert messages(Map.delete(map, "version")) == [{"version", "is required"}]
    end

    test "budget fields are typed", %{map: map} do
      map = put_in(map, ["states", "refined", "budget"], %{"turns" => 0, "cost" => "cheap"})

      assert messages(map) == [
               {"states.refined.budget.cost", "must be a non-negative number"},
               {"states.refined.budget.turns", "must be a positive integer"}
             ]
    end

    test "lists must hold non-empty strings", %{map: map} do
      map = put_in(map, ["states", "refined", "inputs"], ["ticket", 3])
      assert messages(map) == [{"states.refined.inputs", "must be a list of non-empty strings"}]
    end

    test "limits are required", %{map: map} do
      assert messages(Map.delete(map, "limits")) == [
               {"limits", "must be a mapping with ticket_cost"}
             ]

      assert messages(Map.put(map, "limits", %{})) == [{"limits.ticket_cost", "is required"}]
    end

    test "states must be a non-empty mapping and each state a mapping", %{map: map} do
      assert messages(Map.put(map, "states", %{})) |> Enum.map(&elem(&1, 0)) == ["states"]

      assert [{"states.refined", "must be a mapping" <> _}] =
               messages(put_in(map, ["states", "refined"], nil))
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
        |> update_in(["states", "refined"], &Map.delete(&1, "budget"))
        |> put_in(["states", "merged"], %{"env" => "x", "produces" => ["y"]})

      assert messages(map) == [
               {"states.merged.env", "not allowed on a human state (no prompt)"},
               {"states.merged.produces", "not allowed on a human state (no prompt)"},
               {"states.refined.budget", "is required on a job state"}
             ]
    end

    test "inputs must be ticket or produced somewhere", %{map: map} do
      map = put_in(map, ["states", "planned", "inputs"], ["ticket", "missing.md", "answers.md"])

      assert messages(map) == [
               {"states.planned.inputs[1]", "\"missing.md\" is not produced by any state"},
               {"states.planned.inputs[2]", "answers.md is platform-managed and never declared"}
             ]
    end

    test "documents are produced by exactly one state; reserved names are never produced", %{
      map: map
    } do
      map =
        map
        |> put_in(["states", "planned", "produces"], ["plan.md", "ticket"])
        |> put_in(["states", "verified", "produces"], ["report.md", "plan.md"])

      assert messages(map) == [
               {"states.planned.produces[0]",
                "\"plan.md\" is produced by more than one state: planned, verified"},
               {"states.planned.produces[1]", "\"ticket\" is reserved and cannot be produced"},
               {"states.verified.produces[1]",
                "\"plan.md\" is produced by more than one state: planned, verified"}
             ]
    end

    test "the prefix group form is reserved", %{map: map} do
      map = put_in(map, ["states", "verified", "produces"], ["report.md", "screenshots/*"])

      assert [{"states.verified.produces[1]", "prefix groups (name/*) are reserved" <> _}] =
               messages(map)
    end

    test "declared outcomes are non-empty, unique, not engine outcomes, and carried by a document",
         %{map: map} do
      map =
        map
        |> put_in(["states", "planned", "outcomes"], ["done", "error", "done"])
        |> put_in(["states", "implemented", "produces"], ["changeset"])
        |> put_in(["states", "verified", "inputs"], ["plan.md", "changeset"])

      assert messages(map) == [
               {"states.implemented.outcomes",
                "declaring outcomes other than done requires a document in produces"},
               {"states.planned.outcomes", "\"done\" is declared more than once"},
               {"states.planned.outcomes",
                "\"error\" is an engine outcome and cannot be declared"}
             ]
    end

    test "transitions reference known states and known outcomes", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          transitions ++
            [
              %{"from" => "ghost", "to" => "merged"},
              %{"from" => "planned", "to" => "ghost", "when" => "budget_exhausted"},
              %{"from" => "planned", "to" => "merged", "when" => "tests_failed"},
              %{"from" => "review_ready", "to" => "merged", "when" => "done"}
            ]
        end)

      assert messages(map) == [
               {"transitions[10].when", "not allowed on a transition from a human state"},
               {"transitions[7].from", "names an unknown state \"ghost\""},
               {"transitions[8].to", "names an unknown state \"ghost\""},
               {"transitions[9].when", "\"tests_failed\" is not an outcome of state \"planned\""}
             ]
    end

    test "one transition per outcome from a job state", %{map: map} do
      map = Map.update!(map, "transitions", &(&1 ++ [%{"from" => "planned", "to" => "merged"}]))

      assert messages(map) == [
               {"transitions[1]", "more than one transition from \"planned\" on \"done\""},
               {"transitions[7]", "more than one transition from \"planned\" on \"done\""}
             ]
    end

    test "approval names artifacts produced by from or a state before it", %{map: map} do
      map =
        update_in(map, ["transitions"], fn [first | rest] ->
          [Map.put(first, "approve", ["plan.md"]) | rest]
        end)

      assert [
               {"transitions[0].approve[0]",
                "\"plan.md\" is not produced by \"refined\" or a state before it"}
             ] = messages(map)
    end

    test "approval may name an artifact from an earlier state", %{map: map} do
      map =
        update_in(map, ["transitions"], fn ts ->
          List.update_at(ts, 4, &Map.put(&1, "approve", ["plan.md"]))
        end)

      assert {:ok, _} = Parser.from_map(map)
    end

    test "every state must be reachable from initial", %{map: map} do
      map = put_in(map, ["states", "orphan"], %{})
      assert messages(map) == [{"states.orphan", "is not reachable from initial"}]
    end
  end

  defp errors(map) do
    {:error, errors} = Parser.from_map(map)
    errors
  end

  defp paths(map), do: Enum.map(errors(map), & &1.path)
  defp messages(map), do: Enum.map(errors(map), &{&1.path, &1.message})
end
