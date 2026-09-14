defmodule ForgeCore.Job.OutcomeTest do
  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.Document
  alias ForgeCore.Document.Question
  alias ForgeCore.Job.Outcome

  @success %{subtype: "success", is_error: false}

  defp run(overrides) do
    Map.merge(
      %{
        killed: nil,
        exit_status: 0,
        result: @success,
        documents: %{},
        invalid: %{},
        missing: [],
        undeclared: []
      },
      overrides
    )
  end

  defp plan(outcome, extra \\ "") do
    Document.parse!("---\noutcome: #{outcome}\n---\n# Plan\n#{extra}")
  end

  test "a blocking question wins over the harness result, but not over a kill" do
    doc = plan("done", "```question\nkey: k\ntext: t\nblocking: true\n```\n")

    assert {:waiting, [%Question{key: "k"}]} =
             Outcome.decide(spec(), run(%{documents: %{"plan.md" => doc}, result: nil}))

    assert {:finished, :cancelled, nil, _} =
             Outcome.decide(spec(), run(%{documents: %{"plan.md" => doc}, killed: :operator}))

    assert {:finished, :budget_exhausted, nil, _} =
             Outcome.decide(spec(), run(%{documents: %{"plan.md" => doc}, killed: :wall_clock}))
  end

  test "a blocking question whose key was already answered no longer blocks" do
    doc = plan("done", "```question\nkey: k\ntext: t\nblocking: true\n```\n")
    spec = %{spec() | answered_keys: ["k"]}

    assert {:finished, :converged, "done", _} =
             Outcome.decide(spec, run(%{documents: %{"plan.md" => doc}}))
  end

  test "kills are decided before the harness result" do
    assert {:finished, :cancelled, nil, _} =
             Outcome.decide(spec(), run(%{killed: :operator}))

    assert {:finished, :budget_exhausted, nil, "wall-clock limit reached"} =
             Outcome.decide(spec(), run(%{killed: :wall_clock}))
  end

  test "no result message is an error" do
    assert {:finished, :error, nil, "harness produced no result message"} =
             Outcome.decide(spec(), run(%{result: nil, exit_status: 1}))
  end

  test "harness budget stops are budget_exhausted; other failures are errors" do
    assert {:finished, :budget_exhausted, nil, _} =
             Outcome.decide(
               spec(),
               run(%{result: %{subtype: "error_max_turns", is_error: true}})
             )

    assert {:finished, :budget_exhausted, nil, _} =
             Outcome.decide(
               spec(),
               run(%{result: %{subtype: "error_max_budget_usd", is_error: true}})
             )

    assert {:finished, :budget_exhausted, nil, _} =
             Outcome.decide(
               spec(),
               run(%{
                 exit_status: 2,
                 result: %{subtype: "error_during_execution", is_error: true}
               })
             )

    assert {:finished, :error, nil, "harness error: error_during_execution"} =
             Outcome.decide(
               spec(),
               run(%{result: %{subtype: "error_during_execution", is_error: true}})
             )
  end

  describe "naming the failure" do
    # The exact result a machine with no usable credential returns: `is_error` set, exit 1, one
    # turn, no tokens — and `subtype: "success"`. Reading the subtype alone reported a job that
    # never reached the model as "harness result: success", which is the opposite of what
    # happened. This is the shape that cost a session's debugging, so it is the shape tested.
    test "a result that calls itself a success but sets is_error is never reported as success" do
      unauthenticated = %{
        subtype: "success",
        is_error: true,
        text: "Not logged in · Please run /login"
      }

      assert {:finished, :error, nil, reason} =
               Outcome.decide(spec(), run(%{result: unauthenticated, exit_status: 1}))

      assert reason == "harness error: Not logged in · Please run /login"
      refute reason =~ "success"
    end

    test "an informative subtype is kept alongside the harness's own words" do
      assert {:finished, :error, nil, "harness error: error_during_execution: boom"} =
               Outcome.decide(
                 spec(),
                 run(%{
                   result: %{subtype: "error_during_execution", is_error: true, text: "boom"}
                 })
               )
    end

    test "a reason is one line and bounded, whatever the harness printed" do
      trace = "fatal: everything broke\n" <> String.duplicate("  at some/frame.ex:1\n", 50)

      assert {:finished, :error, nil, reason} =
               Outcome.decide(
                 spec(),
                 run(%{result: %{subtype: "success", is_error: true, text: trace}})
               )

      assert reason == "harness error: fatal: everything broke"
    end

    test "a long first line is truncated rather than allowed to fill the timeline" do
      assert {:finished, :error, nil, reason} =
               Outcome.decide(
                 spec(),
                 run(%{
                   result: %{
                     subtype: "success",
                     is_error: true,
                     text: String.duplicate("x", 500)
                   }
                 })
               )

      assert String.length(reason) == String.length("harness error: ") + 200
    end

    test "a harness with nothing to say falls back to its subtype, then to saying so" do
      assert {:finished, :error, nil, "harness error: error_during_execution"} =
               Outcome.decide(
                 spec(),
                 run(%{result: %{subtype: "error_during_execution", is_error: true, text: "  "}})
               )

      assert {:finished, :error, nil, "harness error: no message"} =
               Outcome.decide(
                 spec(),
                 run(%{result: %{subtype: nil, is_error: true, text: nil}})
               )
    end
  end

  test "outputs must be complete, declared and parseable" do
    assert {:finished, :error, nil, "missing outputs: plan.md"} =
             Outcome.decide(spec(), run(%{missing: ["plan.md"]}))

    assert {:finished, :error, nil, "undeclared outputs: notes.md"} =
             Outcome.decide(
               spec(),
               run(%{documents: %{"plan.md" => plan("done")}, undeclared: ["notes.md"]})
             )

    assert {:finished, :error, nil, "invalid documents: plan.md"} =
             Outcome.decide(spec(), run(%{invalid: %{"plan.md" => [:bad]}}))
  end

  test "the outcome document decides between converged, did_not_converge and error" do
    decide = fn doc -> Outcome.decide(spec(), run(%{documents: %{"plan.md" => doc}})) end

    assert {:finished, :converged, "done", _} = decide.(plan("done"))
    assert {:finished, :converged, "plan_invalid", _} = decide.(plan("plan_invalid"))
    assert {:finished, :did_not_converge, nil, _} = decide.(plan("did_not_converge"))

    assert {:finished, :error, nil, "plan.md declares unknown outcome \"tests_failed\""} =
             decide.(plan("tests_failed"))

    assert {:finished, :error, nil, "plan.md has no outcome in its front matter"} =
             decide.(Document.parse!("# Plan\n"))
  end

  test "a job producing no document converges as done" do
    spec = %{spec() | produces: ["changeset"], outcomes: ["done"]}
    assert {:finished, :converged, "done", _} = Outcome.decide(spec, run(%{}))
  end
end
