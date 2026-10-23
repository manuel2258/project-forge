defmodule ForgeCore.Workflow.ParserTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Error
  alias ForgeCore.Workflow
  alias ForgeCore.Workflow.{Budget, Defaults, Parser, Resources, State, Transition}

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
               produces: ["implementation.md", "changeset", "commit-message"],
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

    test "job states need a budget; human states carry nothing a job would", %{map: map} do
      map =
        map
        |> update_in(["states", "refining"], &Map.delete(&1, "budget"))
        |> put_in(["states", "merged"], %{
          "env" => "x",
          "inputs" => ["ticket"],
          "model" => "opus",
          "resources" => %{"memory" => "1GiB"}
        })

      # A human state runs no job, so naming a model or resources for it is naming them for
      # nothing.
      assert messages(map) == [
               {"states.merged.env", "not allowed on a human state (no prompt)"},
               {"states.merged.inputs", "not allowed on a human state (no prompt)"},
               {"states.merged.model", "not allowed on a human state (no prompt)"},
               {"states.merged.resources", "not allowed on a human state (no prompt)"},
               {"states.refining.budget", "is required on a job state"}
             ]
    end

    # `docs/design/workflow-grammar-v1.md` § Semantics: a human state may declare the documents a
    # person writes while the ticket rests there, and a later state reads them like any other.
    test "a human state may produce documents a later state reads", %{map: map} do
      map =
        map
        |> put_in(["states", "review_ready", "produces"], ["test-report.md"])
        |> put_in(["states", "implementing", "inputs"], ["plan.md", "test-report.md"])
        |> update_in(
          ["transitions"],
          &(&1 ++ [%{"from" => "review_ready", "to" => "implementing"}])
        )

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["review_ready"].produces == ["test-report.md"]
      assert Workflow.producers(workflow, "test-report.md") == ["review_ready"]
    end

    test "a human state writes documents, never the changeset", %{map: map} do
      map = put_in(map, ["states", "review_ready", "produces"], ["changeset"])
      groups = put_in(map, ["states", "review_ready", "produces"], ["shots/*"])
      # A presentation is a document in every respect but its kind, so nothing else here refuses
      # it on a human state — and nothing would ever write it, since `Forge.Operator` records
      # what a person writes as a document whatever the state declared.
      deck = put_in(map, ["states", "review_ready", "produces"], ["deck.md!"])
      refusal = "a human state writes documents, not changeset, groups of files or presentations"

      for bad <- [map, groups, deck] do
        assert messages(bad) == [{"states.review_ready.produces", refusal}]
      end
    end

    test "inputs must be ticket or produced somewhere", %{map: map} do
      map = put_in(map, ["states", "planning", "inputs"], ["ticket", "missing.md", "answers.md"])

      assert messages(map) == [
               {"states.planning.inputs[1]",
                "\"missing.md\" is not produced by any state or command"},
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

    # `docs/design/workflow-grammar-v1.md` § Semantics: `name/*` is a group of files.
    test "a group of files is produced, and is not a document", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "screenshots/*"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert Workflow.producers(workflow, "screenshots/*") == ["verifying"]
      refute Workflow.document?("screenshots/*")
      assert State.outcome_document(workflow.states["verifying"]) == "report.md"
    end

    test "a group is one state's, under a name nothing else produces or keeps", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "shots/*", "plan.md/*"])
        |> put_in(["states", "planning", "produces"], ["plan.md", "shots/*", "proposals/*"])

      assert messages(map) == [
               {"states.planning.produces[1]",
                "\"shots/*\" is produced by more than one state: planning, verifying"},
               {"states.planning.produces[2]", "\"proposals\" is reserved for ticket proposals"},
               {"states.verifying.produces[1]",
                "\"shots/*\" is produced by more than one state: planning, verifying"},
               {"states.verifying.produces[2]", "\"plan.md\" is also produced as a document"}
             ]
    end

    test "a group is not yet an input, and is never approved", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "shots/*"])
        |> put_in(["states", "review_ready", "produces"], [])
        |> update_in(["transitions"], fn transitions ->
          List.update_at(transitions, 6, &Map.put(&1, "approve", ["changeset", "shots/*"]))
        end)
        |> put_in(["states", "implementing", "inputs"], ["plan.md", "shots/*"])

      assert messages(map) == [
               {"states.implementing.inputs[1]", "a group of files is not an input yet"},
               {"transitions[6].approve[1]", "a group of files cannot be approved"}
             ]
    end

    # `docs/design/workflow-grammar-v1.md` § Semantics: `name!` is a presentation.
    test "a presentation is produced under the name less its marker", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "deck.md!"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["verifying"].produces == ["report.md", "deck.md!"]
      assert Workflow.producers(workflow, "deck.md!") == ["verifying"]
      assert Workflow.presentation?("deck.md!")
      assert Workflow.presentation_name("deck.md!") == "deck.md"
    end

    # A presentation whose state produces nothing else carries the outcome, like any first
    # document — under the name on disk, which is what the worker writes and the engine reads.
    test "a presentation alone carries its job's outcome", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["deck.md!"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert State.outcome_document(workflow.states["verifying"]) == "deck.md"
    end

    test "a presentation is never an input and never approved", %{map: map} do
      map =
        map
        |> put_in(["states", "planning", "produces"], ["plan.md", "deck.md!"])
        |> put_in(["states", "review_ready", "produces"], [])
        |> update_in(["transitions"], fn transitions ->
          List.update_at(transitions, 6, &Map.put(&1, "approve", ["changeset", "deck.md"]))
        end)
        |> put_in(["states", "implementing", "inputs"], ["plan.md", "deck.md"])

      assert messages(map) == [
               {"states.implementing.inputs[1]",
                "\"deck.md\" is a presentation and cannot be an input"},
               {"transitions[6].approve[1]", "a presentation carries no approval"}
             ]
    end

    # Marker and all: an entry that keeps its `!` finds its producer by name, so without a branch
    # of its own it reads as an ordinary, perfectly valid input or approval.
    test "a presentation is refused as an input or approval under its declared name", %{map: map} do
      map =
        map
        |> put_in(["states", "planning", "produces"], ["plan.md", "deck.md!"])
        |> put_in(["states", "review_ready", "produces"], [])
        |> update_in(["transitions"], fn transitions ->
          List.update_at(transitions, 6, &Map.put(&1, "approve", ["changeset", "deck.md!"]))
        end)
        |> put_in(["states", "implementing", "inputs"], ["plan.md", "deck.md!"])

      assert messages(map) == [
               {"states.implementing.inputs[1]",
                "\"deck.md\" is a presentation and cannot be an input"},
               {"transitions[6].approve[1]", "a presentation carries no approval"}
             ]
    end

    # A group and a presentation under one name would be `out/deck.md` as a file and a directory
    # at once, which is refused for a document and must be refused here for the same reason.
    test "a presentation may not share its name with a group of files", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["deck.md!", "deck.md/*"])

      assert messages(map) == [
               {"states.verifying.produces[0]",
                "\"deck.md\" is also produced as a group of files"}
             ]
    end

    # A reserved name is refused for being reserved, whatever someone declared under it: the
    # presentation branch answering first made `answers.md` read as a presentation's problem.
    test "a reserved input name is refused for being reserved, not for a presentation", %{
      map: map
    } do
      map =
        map
        |> put_in(["states", "planning", "produces"], ["plan.md", "answers.md!"])
        |> put_in(["states", "implementing", "inputs"], ["plan.md", "answers.md"])

      assert messages(map) == [
               {"states.implementing.inputs[1]",
                "answers.md is platform-managed and never declared"},
               {"states.planning.produces[1]", "\"answers.md\" is reserved"}
             ]
    end

    test "a presentation is one state's, under a name nothing else produces or keeps", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(
          ["states", "planning", "produces"],
          ["plan.md", "deck.md!", "report.md!", "proposals!"]
        )

      assert messages(map) == [
               {"states.planning.produces[1]",
                "\"deck.md!\" is produced by more than one state: planning, verifying"},
               {"states.planning.produces[2]", "\"report.md\" is also produced as a document"},
               {"states.planning.produces[3]", "\"proposals\" is reserved for ticket proposals"},
               {"states.verifying.produces[1]",
                "\"deck.md!\" is produced by more than one state: planning, verifying"}
             ]
    end

    # `docs/design/workflow-grammar-v1.md` § Semantics: `optional` is how a workflow says an
    # artifact is not required. The names are the artifacts' own, so a presentation is excused by
    # the name it is recorded under and not by its declaration.
    test "optional names the state's own produced documents", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "verifying", "optional"], ["deck.md"])

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["verifying"].optional == ["deck.md"]
      assert State.optional?(workflow.states["verifying"], "deck.md")
      refute State.optional?(workflow.states["verifying"], "report.md")
    end

    test "optional refuses what the state does not produce as a document", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "shots/*", "changeset"])
        |> put_in(
          ["states", "verifying", "optional"],
          ["report.md", "report.md", "plan.md", "shots", "changeset", "../up"]
        )

      assert messages(map) == [
               {"states.verifying.optional[0]", "\"report.md\" is listed twice"},
               {"states.verifying.optional[1]", "\"report.md\" is listed twice"},
               {"states.verifying.optional[2]",
                "\"plan.md\" is not a document this state produces"},
               {"states.verifying.optional[3]",
                "\"shots\" is a group of files, which has no minimum and cannot be optional"},
               {"states.verifying.optional[4]",
                "changeset is the diff of the job's commits and cannot be optional"},
               {"states.verifying.optional[5]",
                "must be a single path segment: " <> Workflow.name_rule()},
               # `report.md` is also `verifying`'s outcome document, and `verifying` declares a
               # choice of outcomes: the rule below.
               {"states.verifying.outcomes",
                "declaring outcomes other than done requires the document that carries the " <>
                  "outcome: \"report.md\" is optional, and an outcome nobody wrote is done"}
             ]
    end

    # `docs/design/workflow-grammar-v1.md` § Validation. An absent outcome document is `done` and
    # can be nothing else — there is no front matter to choose in — so a state that declares a
    # choice and excuses that document has given itself a way to take the `done` edge by writing
    # nothing, and a state whose outcomes do not include `done` a way to converge on an outcome no
    # transition matches.
    test "a state declaring a choice of outcomes cannot make its outcome document optional", %{
      map: map
    } do
      choice =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "verifying", "optional"], ["report.md"])

      assert {"states.verifying.outcomes",
              "declaring outcomes other than done requires the document that carries the " <>
                "outcome: \"report.md\" is optional, and an outcome nobody wrote is done"} in messages(
               choice
             )

      # Not only where `done` is one of them: a state whose outcomes are all its own would
      # converge on `done` and stick behind a job that succeeded.
      none =
        map
        |> put_in(["states", "verifying", "outcomes"], ["tests_failed", "flaky"])
        |> put_in(["states", "verifying", "optional"], ["report.md"])

      assert {"states.verifying.outcomes",
              "declaring outcomes other than done requires the document that carries the " <>
                "outcome: \"report.md\" is optional, and an outcome nobody wrote is done"} in messages(
               none
             )

      # And the document it does not carry the outcome in may still be optional.
      fine =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "verifying", "optional"], ["deck.md"])

      assert {:ok, _workflow} = Parser.from_map(fine)
    end

    # Which collision is reported when more than one is true. The branches are ordered, the order
    # is what a person reads, and nothing asserted it: a name that is a document *and* a group is
    # reported as the document, which is the nearer mistake — the author wrote `deck.md` twice.
    test "a presentation's collisions are reported nearest first", %{map: map} do
      both =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "planning", "produces"], ["plan.md", "deck.md", "deck.md/*"])

      assert {"states.verifying.produces[1]", "\"deck.md\" is also produced as a document"} in messages(
               both
             )

      group =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "planning", "produces"], ["plan.md", "deck.md/*"])

      assert {"states.verifying.produces[1]", "\"deck.md\" is also produced as a group of files"} in messages(
               group
             )

      # And a reserved name is refused for being reserved, before any collision under it.
      reserved =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "proposals!"])
        |> put_in(["states", "planning", "produces"], ["plan.md", "proposals/*"])

      assert {"states.verifying.produces[1]", "\"proposals\" is reserved for ticket proposals"} in messages(
               reserved
             )
    end

    # The same ordering on the reading side: an input that names a reserved artifact somebody also
    # declared a presentation under is refused for the name, not for the presentation.
    test "a reserved input is refused for being reserved, not for a presentation", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "proposal-deck.md!"])
        |> put_in(["states", "planning", "inputs"], ["ticket", "proposal-deck.md"])

      assert {"states.planning.inputs[1]",
              "\"proposal-deck.md\" is reserved for ticket proposals"} in messages(map)

      refute {"states.planning.inputs[1]",
              "\"proposal-deck.md\" is a presentation and cannot be an input"} in messages(map)
    end

    # `changeset` in `optional` is refused by name only where the state produces it; elsewhere it
    # is simply not one of this state's documents, which is the message that tells the author what
    # to do about it.
    test "optional refuses changeset by name only where the state produces it", %{map: map} do
      assert messages(put_in(map, ["states", "planning", "optional"], ["changeset"])) == [
               {"states.planning.optional[0]",
                "\"changeset\" is not a document this state produces"}
             ]
    end

    # A presentation's declaration is not its artifact name, and `optional` takes the name.
    test "optional refuses a presentation under its declared spelling", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "deck.md!"])
        |> put_in(["states", "verifying", "optional"], ["deck.md!"])

      assert messages(map) == [
               {"states.verifying.optional[0]",
                "must be a single path segment: " <> Workflow.name_rule()}
             ]
    end

    test "optional is a job state's alone", %{map: map} do
      human =
        map
        |> put_in(["states", "review_ready", "produces"], ["test-report.md"])
        |> put_in(["states", "review_ready", "optional"], ["test-report.md"])
        |> update_in(
          ["transitions"],
          &(&1 ++ [%{"from" => "review_ready", "to" => "implementing"}])
        )

      assert {"states.review_ready.optional", "not allowed on a human state (no prompt)"} in messages(
               human
             )
    end

    # An input whose only producer may finish without writing it is not required, or the job that
    # reads it could not be created at all — which undoes the transition into it and sticks the
    # ticket (`ForgeCore.Workflow.required_input?/3`).
    # `notes.md` rather than `implementation.md`, which is `implementing`'s outcome document and
    # so may not be optional at all while that state declares a choice of outcomes (below).
    test "an optional output never makes an input required", %{map: map} do
      map =
        map
        |> put_in(
          ["states", "implementing", "produces"],
          ["implementation.md", "changeset", "commit-message", "notes.md"]
        )
        |> put_in(["states", "verifying", "inputs"], ["plan.md", "notes.md"])

      assert {:ok, required} = Parser.from_map(map)
      assert Workflow.required_input?(required, "verifying", "notes.md")

      optional = put_in(map, ["states", "implementing", "optional"], ["notes.md"])

      assert {:ok, workflow} = Parser.from_map(optional)
      refute Workflow.required_input?(workflow, "verifying", "notes.md")
      assert Workflow.required_input?(workflow, "verifying", "plan.md")
    end

    test "a presentation is named as an artifact is", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "../up!"])

      assert {"states.verifying",
              "artifact name \"../up\" must be a single path segment: " <> Workflow.name_rule()} in messages(
               map
             )
    end

    test "a group is named as an artifact is", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "../up/*"])

      assert {"states.verifying",
              "artifact name \"../up\" must be a single path segment: " <> Workflow.name_rule()} in messages(
               map
             )
    end

    test "the names ticket proposals use are reserved, produced or consumed", %{map: map} do
      map =
        map
        |> put_in(["states", "verifying", "produces"], ["report.md", "proposals"])
        |> put_in(["states", "planning", "inputs"], ["ticket", "proposal-score-table.md"])

      assert messages(map) == [
               {"states.planning.inputs[1]",
                "\"proposal-score-table.md\" is reserved for ticket proposals"},
               {"states.verifying.produces[1]", "\"proposals\" is reserved for ticket proposals"}
             ]
    end

    test "a transcript's name is not a workflow's to produce", %{map: map} do
      map = put_in(map, ["states", "verifying", "produces"], ["report.md", "transcript-x.jsonl"])

      assert messages(map) == [
               {"states.verifying.produces[1]",
                "\"transcript-x.jsonl\" is reserved for job transcripts"}
             ]
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
               # `implementing` is also where the fixture produces `commit-message`, so leaving it
               # `changeset` alone leaves the workflow's merge with nothing to say.
               {"states.merged.on_enter", "merge needs a state that produces commit-message"},
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
              "state name must be a single path segment: " <> Workflow.name_rule()} in messages(
               map
             )

      assert {"states.verifying",
              "artifact name \"../report.md\" must be a single path segment: " <>
                Workflow.name_rule()} in messages(map)
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
                "artifact name #{inspect(name)} must be a single path segment: " <>
                  Workflow.name_rule()} in messages(map),
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

    # `commit-message` is specified to carry no front matter, so a state that declares a choice of
    # outcomes and puts it first in `produces` has made that choice unmakeable: every job reads
    # `done`, and `plan_invalid` here could never be taken. It is the order that does it.
    test "the commit message cannot be the document a choice of outcomes is made in", %{map: map} do
      map =
        put_in(
          map,
          ["states", "implementing", "produces"],
          ["commit-message", "implementation.md", "changeset"]
        )

      assert {"states.implementing.outcomes",
              "declaring outcomes other than done requires a document that can carry one: " <>
                "commit-message is a plain git message with no front matter, and is first in " <>
                "produces"} in messages(map)
    end

    # The second half of the same rule: a merge that cannot say anything is as broken as one with
    # nothing to merge, and it is caught here rather than at the merge (§ Validation).
    test "merging needs a state that produces the commit message", %{map: map} do
      map =
        put_in(map, ["states", "implementing", "produces"], ["implementation.md", "changeset"])

      assert {"states.merged.on_enter", "merge needs a state that produces commit-message"} in messages(
               map
             )
    end

    # On the state that does produce it, which is the case the rule is for: "it is a document this
    # state produces" would otherwise excuse it like any other.
    test "the commit message may not be optional", %{map: map} do
      map = put_in(map, ["states", "implementing", "optional"], ["commit-message"])

      assert {"states.implementing.optional[0]",
              "commit-message is what the merge commit says and cannot be optional"} in messages(
               map
             )
    end

    # And on a state that does not produce it, the plain reason: excusing a document this state
    # never writes is a different mistake, and "cannot be optional" sent the author looking for
    # the wrong one.
    test "a state that does not produce the commit message is told that instead", %{map: map} do
      map = put_in(map, ["states", "verifying", "optional"], ["commit-message"])

      assert {"states.verifying.optional[0]",
              "\"commit-message\" is not a document this state produces"} in messages(map)
    end

    # The producer rule asks for the *artifact* name, so a state declaring it as a presentation
    # produces exactly the artifact the merge reads: `Workflow.produced_name/1` is what everything
    # that records one goes through, and comparing the raw declaration told this workflow its
    # merge had no message.
    test "a presentation declaration produces the commit message the merge reads", %{map: map} do
      map =
        put_in(
          map,
          ["states", "implementing", "produces"],
          ["implementation.md", "changeset", "commit-message!"]
        )

      assert {:ok, workflow} = Parser.from_map(map)

      assert workflow.states["implementing"].produces == [
               "implementation.md",
               "changeset",
               "commit-message!"
             ]
    end
  end

  describe "resources" do
    test "a state declares them and they reach the struct", %{map: map} do
      map = put_in(map, ["states", "refining", "resources"], %{"memory" => "6GiB", "cpu" => 4})

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["refining"].resources == %Resources{memory: 6_442_450_944, cpu: 4}
    end

    test "defaults carry them for the whole workflow", %{map: map} do
      map = Map.put(map, "defaults", %{"resources" => %{"memory" => "2200MiB", "cpu" => 1}})

      assert {:ok, workflow} = Parser.from_map(map)

      assert workflow.defaults == %Defaults{
               resources: %Resources{memory: 2_306_867_200, cpu: 1}
             }
    end

    # Each field falls back on its own, which is the whole point of `defaults:`. A state that
    # restated `cpu` to change `memory` would make the default worth half of what it claims.
    test "a state may declare one field and leave the other", %{map: map} do
      map = put_in(map, ["states", "refining", "resources"], %{"memory" => "6GiB"})

      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.states["refining"].resources == %Resources{memory: 6_442_450_944, cpu: nil}
    end

    # **A number written as a string is the same number.** It was not: `512` parsed and `"512"`
    # did not, because the unit was mandatory — so a form, where every field is a string, could
    # not carry a plain byte count, and the template page filled its own memory field with a
    # value it then refused. Found by an operator, not by this suite.
    test "a bare integer and the same digits as a string agree", %{map: map} do
      for written <- [536_870_912, "536870912", 8_589_934_592, "8589934592"] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})
        assert {:ok, workflow} = Parser.from_map(map)

        expected = if is_binary(written), do: String.to_integer(written), else: written
        assert workflow.states["refining"].resources.memory == expected
      end
    end

    # Every unit, at a size a ceiling may be. What they multiply to at one of each is
    # `Resources.parse_bytes/1`'s test, since the grammar refuses a ceiling that small.
    test "a bare integer is bytes, and every binary unit multiplies", %{map: map} do
      for {written, bytes} <- [
            {536_870_912, 536_870_912},
            {"536870912B", 536_870_912},
            {"524288KiB", 536_870_912},
            {"512MiB", 536_870_912},
            {"1GiB", 1_073_741_824},
            {"1TiB", 1_099_511_627_776}
          ] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})
        assert {:ok, workflow} = Parser.from_map(map)

        assert workflow.states["refining"].resources.memory == bytes,
               "#{inspect(written)} should be #{bytes} bytes"
      end
    end

    # **The ceiling of 2026-09-29**: `2` typed meaning 2 GiB, stored as two bytes, and a machine
    # whose PID 1 stopped answering. A size, and not one a job can run in — so refused by name,
    # with the minimum said, on both sides of it.
    test "a ceiling below the minimum is refused, and the minimum is named", %{map: map} do
      for written <- [2, "2", 536_870_911, "511MiB", "524287KiB"] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})

        assert messages(map) == [
                 {"states.refining.resources.memory",
                  "must be at least 512MiB, the least a job can run in"}
               ],
               "#{inspect(written)} should be refused"
      end

      map = Map.put(map, "defaults", %{"resources" => %{"memory" => "256MiB"}})

      assert messages(map) == [
               {"defaults.resources.memory",
                "must be at least 512MiB, the least a job can run in"}
             ]
    end

    test "the minimum itself is a ceiling a job may have", %{map: map} do
      for written <- [536_870_912, "512MiB", "512mib"] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})
        assert {:ok, workflow} = Parser.from_map(map)
        assert workflow.states["refining"].resources.memory == 536_870_912
      end
    end

    # `4GB` is 7% smaller than `4GiB`. Accepting it as an approximation would silently shrink a
    # ceiling whose job is to kill the job that crosses it, so it is refused by name.
    test "a decimal unit is refused and the binary one is named", %{map: map} do
      map = put_in(map, ["states", "refining", "resources"], %{"memory" => "4GB"})

      assert messages(map) == [
               {"states.refining.resources.memory", "must use a binary unit; did you mean GiB?"}
             ]
    end

    # Case is not part of the distinction: `mib` is still not `mb` after downcasing, so
    # refusing `4gib` would cost an operator a round trip and buy nothing.
    test "a unit is matched whatever its case", %{map: map} do
      for written <- ["4gib", "4GIB", "4GiB", "4Gib"] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})
        assert {:ok, workflow} = Parser.from_map(map)

        assert workflow.states["refining"].resources.memory == 4_294_967_296,
               "#{inspect(written)} should be four gibibytes"
      end
    end

    # `4XiB` is well-formed — digits then letters — so it reaches the unit lookup rather than
    # failing the shape check, which is the only way that branch is ever taken.
    test "a well-formed size with a unit that does not exist is refused", %{map: map} do
      map = put_in(map, ["states", "refining", "resources"], %{"memory" => "4XiB"})

      assert [{"states.refining.resources.memory", message}] = messages(map)
      assert message =~ "must be a positive number of bytes or a size in"
    end

    test "a size that is not a size says what one looks like", %{map: map} do
      for written <- ["", "GiB", "lots", "4 GiB please", 0, -1, 1.5, "0MiB", %{}] do
        map = put_in(map, ["states", "refining", "resources"], %{"memory" => written})

        assert [{"states.refining.resources.memory", message}] = messages(map),
               "#{inspect(written)} should be one error"

        assert message =~ "must be a positive number of bytes or a size in"
      end
    end

    # Reserved, not unknown: `disk` is the obvious third dimension and nothing enforces one yet.
    # "unknown key" would read as a typo and send somebody looking for the right spelling.
    test "disk is reserved rather than unknown, and says so once", %{map: map} do
      map =
        put_in(map, ["states", "refining", "resources"], %{"memory" => "1GiB", "disk" => "5G"})

      assert messages(map) == [{"states.refining.resources.disk", "is reserved"}]
    end

    test "any other key is unknown", %{map: map} do
      map = put_in(map, ["states", "refining", "resources"], %{"gpu" => 1})

      assert messages(map) == [{"states.refining.resources.gpu", "unknown key"}]
    end

    test "cpu must be a positive integer", %{map: map} do
      for written <- [0, -1, 1.5, "4"] do
        map = put_in(map, ["states", "refining", "resources"], %{"cpu" => written})

        assert messages(map) == [{"states.refining.resources.cpu", "must be a positive integer"}],
               "#{inspect(written)} should not be a core count"
      end
    end

    test "resources must be a mapping, and defaults must be one too", %{map: map} do
      assert messages(put_in(map, ["states", "refining", "resources"], "lots")) == [
               {"states.refining.resources", "must be a mapping of memory and cpu"}
             ]

      assert messages(Map.put(map, "defaults", "lots")) == [{"defaults", "must be a mapping"}]
    end

    test "defaults holds nothing but resources", %{map: map} do
      assert messages(Map.put(map, "defaults", %{"model" => "opus"})) == [
               {"defaults.model", "unknown key"}
             ]
    end

    # The grammar example declares none, and a workflow written before this key existed has to
    # keep parsing: absent is not the same as zero, and the platform supplies what is missing.
    test "declaring none leaves both levels nil", %{map: map} do
      assert {:ok, workflow} = Parser.from_map(map)
      assert workflow.defaults == nil
      assert workflow.states["refining"].resources == nil
    end
  end

  defp errors(map) do
    {:error, errors} = Parser.from_map(map)
    errors
  end

  defp paths(map), do: Enum.map(errors(map), & &1.path)
  defp messages(map), do: Enum.map(errors(map), &{&1.path, &1.message})
end
