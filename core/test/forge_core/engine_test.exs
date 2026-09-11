defmodule ForgeCore.EngineTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Engine
  alias ForgeCore.Workflow.{Parser, Transition}

  @fixture Path.expand("../fixtures/workflow_example.yml", __DIR__)

  setup_all do
    %{workflow: Parser.parse!(File.read!(@fixture))}
  end

  describe "step/4 along the grammar example" do
    test "a transition with approve is queued, not taken", %{workflow: workflow} do
      assert {:approval, %Transition{from: "refined", to: "planned", approve: ["refinement.md"]}} =
               Engine.step(workflow, "refined", "done", %{})
    end

    test "a plain transition on the default outcome is taken", %{workflow: workflow} do
      assert {:transition, %Transition{from: "planned", to: "implemented"}} =
               Engine.step(workflow, "planned", "done", %{})
    end

    test "a declared outcome selects its transition, including backward edges", %{
      workflow: workflow
    } do
      assert {:transition, %Transition{from: "implemented", to: "planned"}} =
               Engine.step(workflow, "implemented", "plan_invalid", %{})

      assert {:transition, %Transition{from: "implemented", to: "verified"}} =
               Engine.step(workflow, "implemented", "done", %{})
    end

    test "max caps how often a transition fires", %{workflow: workflow} do
      retry = {"verified", "implemented", "tests_failed"}

      for count <- 0..2 do
        assert {:transition, %Transition{to: "implemented"}} =
                 Engine.step(workflow, "verified", "tests_failed", %{retry => count})
      end

      assert {:stuck, {:max_exceeded, %Transition{to: "implemented", max: 3}}} =
               Engine.step(workflow, "verified", "tests_failed", %{retry => 3})
    end

    test "an outcome with no transition sticks the ticket", %{workflow: workflow} do
      assert {:stuck, {:no_transition, "budget_exhausted"}} =
               Engine.step(workflow, "verified", "budget_exhausted", %{})

      assert {:stuck, {:no_transition, "did_not_converge"}} =
               Engine.step(workflow, "refined", "did_not_converge", %{})
    end

    test "rejects unknown and human states", %{workflow: workflow} do
      assert {:error, {:unknown_state, "ghost"}} = Engine.step(workflow, "ghost", "done", %{})

      assert {:error, {:human_state, "review_ready"}} =
               Engine.step(workflow, "review_ready", "done", %{})
    end
  end

  describe "choose/3" do
    test "lets a person take any declared transition, ignoring max", %{workflow: workflow} do
      assert {:ok, %Transition{from: "review_ready", to: "merged"}} =
               Engine.choose(workflow, "review_ready", "merged")

      assert {:ok, %Transition{from: "verified", to: "implemented", max: 3}} =
               Engine.choose(workflow, "verified", "implemented")

      assert {:error, :no_such_transition} = Engine.choose(workflow, "refined", "merged")
    end
  end

  test "record/2 counts firings by transition id", %{workflow: workflow} do
    {:transition, retry} = Engine.step(workflow, "verified", "tests_failed", %{})

    counts = %{} |> Engine.record(retry) |> Engine.record(retry)
    assert counts == %{{"verified", "implemented", "tests_failed"} => 2}
    assert {:transition, _} = Engine.step(workflow, "verified", "tests_failed", counts)

    assert {:stuck, _} =
             Engine.step(workflow, "verified", "tests_failed", Engine.record(counts, retry))
  end

  test "within_ticket_budget?/2 compares against limits.ticket_cost", %{workflow: workflow} do
    assert Engine.within_ticket_budget?(workflow, 24.99)
    refute Engine.within_ticket_budget?(workflow, 25.0)
  end
end
