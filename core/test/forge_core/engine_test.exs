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
      assert {:approval,
              %Transition{from: "refining", to: "planning", approve: ["refinement.md"]}} =
               Engine.step(workflow, "refining", "done", %{})
    end

    test "a plain transition on the default outcome is taken", %{workflow: workflow} do
      assert {:transition, %Transition{from: "planning", to: "implementing"}} =
               Engine.step(workflow, "planning", "done", %{})
    end

    test "a declared outcome selects its transition, including backward edges", %{
      workflow: workflow
    } do
      assert {:transition, %Transition{from: "implementing", to: "planning"}} =
               Engine.step(workflow, "implementing", "plan_invalid", %{})

      assert {:transition, %Transition{from: "implementing", to: "verifying"}} =
               Engine.step(workflow, "implementing", "done", %{})
    end

    test "max caps how often a transition fires", %{workflow: workflow} do
      retry = {"verifying", "implementing", "tests_failed"}

      for count <- 0..2 do
        assert {:transition, %Transition{to: "implementing"}} =
                 Engine.step(workflow, "verifying", "tests_failed", %{retry => count})
      end

      assert {:stuck, {:max_exceeded, %Transition{to: "implementing", max: 3}}} =
               Engine.step(workflow, "verifying", "tests_failed", %{retry => 3})
    end

    test "an outcome with no transition sticks the ticket", %{workflow: workflow} do
      assert {:stuck, {:no_transition, "budget_exhausted"}} =
               Engine.step(workflow, "verifying", "budget_exhausted", %{})

      assert {:stuck, {:no_transition, "did_not_converge"}} =
               Engine.step(workflow, "refining", "did_not_converge", %{})
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

      assert {:ok, %Transition{from: "verifying", to: "implementing", max: 3}} =
               Engine.choose(workflow, "verifying", "implementing")

      assert {:error, :no_such_transition} = Engine.choose(workflow, "refining", "merged")
    end

    test "disambiguates parallel edges by outcome" do
      workflow = parallel_edges("- {from: a, to: b}")

      assert {:ok, %Transition{when: "again"}} = Engine.choose(workflow, "a", "b", "again")
      assert {:ok, %Transition{when: nil}} = Engine.choose(workflow, "a", "b", "done")
    end

    # The regression `reviewing → review_ready` was: a target with a bare edge and an outcome edge
    # could not be moved to at all, because the operator surface offers the target and sends no
    # outcome. The bare edge is what a person's move means.
    test "takes the default edge when no outcome is given and several lead to the target" do
      workflow = parallel_edges("- {from: a, to: b}")

      assert {:ok, %Transition{when: nil}} = Engine.choose(workflow, "a", "b")
    end

    test "stays ambiguous when several lead to the target and none is the default" do
      workflow = parallel_edges("- {from: a, to: b, when: done}")

      assert {:error, {:ambiguous, outcomes}} = Engine.choose(workflow, "a", "b")
      assert Enum.sort(outcomes) == ["again", "done"]
    end

    # Two edges from `a` to `b`: the second is always `when: again`, and the first is what the
    # test varies — bare, or naming `done` outright, which is the same outcome written out and so
    # not the default edge.
    defp parallel_edges(first_edge) do
      Parser.parse!("""
      version: 1
      initial: a
      states:
        a: {prompt: p.md, produces: [a.md], outcomes: [done, again], budget: {turns: 1, cost: 1}}
        b: {}
      transitions:
        #{first_edge}
        - {from: a, to: b, when: again}
      limits: {ticket_cost: 1}
      """)
    end
  end

  test "record/2 counts firings by transition id", %{workflow: workflow} do
    {:transition, retry} = Engine.step(workflow, "verifying", "tests_failed", %{})

    counts = %{} |> Engine.record(retry) |> Engine.record(retry)
    assert counts == %{{"verifying", "implementing", "tests_failed"} => 2}
    assert {:transition, _} = Engine.step(workflow, "verifying", "tests_failed", counts)

    assert {:stuck, _} =
             Engine.step(workflow, "verifying", "tests_failed", Engine.record(counts, retry))
  end

  test "within_ticket_budget?/2 compares against limits.ticket_cost", %{workflow: workflow} do
    assert Engine.within_ticket_budget?(workflow, 24.99)
    refute Engine.within_ticket_budget?(workflow, 25.0)
  end
end
