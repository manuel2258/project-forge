defmodule ForgeCore.Job.CorrectionTest do
  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.{Document, Error}
  alias ForgeCore.Job.{Correction, Result}

  @clean %{"subtype" => "success", "is_error" => false}

  defp failed(overrides) do
    struct!(
      %Result{status: :finished, outcome: :error, harness: @clean},
      overrides
    )
  end

  defp plan(outcome), do: Document.parse!("---\noutcome: #{outcome}\n---\n# Plan\n")

  describe "needed/2" do
    # The production case: a question block whose options YAML typed as integers.
    test "lists every error of every invalid document, one line each, named" do
      result =
        failed(
          invalid: %{
            "plan.md" => [
              Error.new("question[2].options", "must be a non-empty list of strings"),
              Error.new("question[2].default", "must be a string")
            ]
          }
        )

      assert Correction.needed(spec(), result) ==
               {:correct,
                [
                  "plan.md: question[2].options: must be a non-empty list of strings",
                  "plan.md: question[2].default: must be a string"
                ]}
    end

    test "names a missing output and an undeclared one" do
      assert {:correct, [missing, undeclared]} =
               Correction.needed(spec(), failed(missing: ["plan.md"], undeclared: ["notes.md"]))

      assert missing =~ "plan.md: was not written"
      assert undeclared =~ "notes.md: is not a declared output"
    end

    # `docs/design/workflow-grammar-v1.md` § Semantics: an optional document's absence is not a
    # failure, so it is not something to correct either. The run has to have failed on something
    # else for the list to be reached at all, which is exactly the case this guards: the session
    # would otherwise be told to write the document its own manifest told it it could skip
    # (`.forge/agents/present.md`).
    test "an optional output that was not written is not a problem to correct" do
      spec = %{spec() | produces: ["plan.md", "deck.md!"], optional: ["deck.md"]}

      assert {:correct, problems} =
               Correction.needed(spec, failed(missing: ["plan.md", "deck.md"]))

      assert problems == ["plan.md: was not written; write it to $FORGE_JOB/out/plan.md"]

      assert {:correct, [undeclared]} =
               Correction.needed(spec, failed(missing: ["deck.md"], undeclared: ["notes.md"]))

      assert undeclared =~ "notes.md: is not a declared output"
    end

    test "names an outcome the state does not accept, and the ones it does" do
      result = failed(documents: %{"plan.md" => plan("shipped")})

      assert {:correct, [problem]} = Correction.needed(spec(), result)
      assert problem =~ ~s(plan.md: declares the outcome "shipped")
      assert problem =~ "`done`, `plan_invalid`, `did_not_converge`"
    end

    test "names an outcome document with no outcome" do
      document = Document.parse!("# Plan\n")

      assert {:correct, [problem]} =
               Correction.needed(spec(), failed(documents: %{"plan.md" => document}))

      assert problem =~ "plan.md: has no `outcome`"
    end

    # Every mutation below leaves the outputs as broken as above; only the reason the run ended
    # differs. None of them is the agent's writing to put right.
    test "is not needed when the run did not end cleanly in error" do
      broken = %{missing: ["plan.md"]}

      assert Correction.needed(spec(), failed(Map.put(broken, :killed, :operator))) == :none
      assert Correction.needed(spec(), failed(Map.put(broken, :killed, :wall_clock))) == :none
      assert Correction.needed(spec(), failed(Map.put(broken, :outcome, :converged))) == :none

      assert Correction.needed(spec(), failed(Map.put(broken, :outcome, :budget_exhausted))) ==
               :none

      assert Correction.needed(spec(), %{failed(broken) | status: :waiting}) == :none
      assert Correction.needed(spec(), %{failed(broken) | status: :parked}) == :none
    end

    test "is not needed when the harness itself stopped or failed" do
      broken = %{missing: ["plan.md"]}

      stopped = %{"subtype" => "error_max_turns", "is_error" => true}
      not_logged_in = %{"subtype" => "success", "is_error" => true}

      assert Correction.needed(spec(), failed(Map.put(broken, :harness, stopped))) == :none
      assert Correction.needed(spec(), failed(Map.put(broken, :harness, not_logged_in))) == :none
      assert Correction.needed(spec(), failed(Map.put(broken, :harness, %{}))) == :none
    end

    # An error with valid outputs and an accepted outcome failed for some other reason, and
    # a correction would ask the agent to fix nothing.
    test "is not needed when nothing about the outputs is wrong" do
      assert Correction.needed(spec(), failed(documents: %{"plan.md" => plan("done")})) == :none

      assert Correction.needed(
               spec(),
               failed(documents: %{"plan.md" => plan("did_not_converge")})
             ) == :none

      assert Correction.needed(spec(), failed([])) == :none
    end
  end

  describe "prompt/3" do
    test "lists the problems and says which correction it is" do
      text = Correction.prompt(["plan.md: question[0]: invalid YAML"], 1, 2)

      assert text =~ "- plan.md: question[0]: invalid YAML"
      assert text =~ "correction 1 of 2"
    end
  end

  describe "remaining/2" do
    test "what is left of the budget after what was spent" do
      assert Correction.remaining(spec(), %{turns: 30, cost: 1.5}) ==
               {:ok, %{turns: 10, cost: 0.5}}
    end

    test "nothing worth starting on no turns, or no money" do
      assert Correction.remaining(spec(), %{turns: 40, cost: 0.1}) == :exhausted
      assert Correction.remaining(spec(), %{turns: 39, cost: 2.0}) == :exhausted
      assert Correction.remaining(%{spec() | budget: nil}, %{turns: 0, cost: 0}) == :exhausted
    end

    test "whole cents, rounded down, and at least one of them" do
      assert {:ok, %{cost: 0.99}} = Correction.remaining(spec(), %{turns: 0, cost: 1.004})
      assert {:ok, %{cost: 0.01}} = Correction.remaining(spec(), %{turns: 0, cost: 1.99})
      assert Correction.remaining(spec(), %{turns: 0, cost: 1.996}) == :exhausted
    end

    test "one turn and a little money is enough" do
      assert {:ok, %{turns: 1}} = Correction.remaining(spec(), %{turns: 39, cost: 1.99})
    end
  end
end
