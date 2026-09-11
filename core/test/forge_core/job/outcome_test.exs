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

  test "a blocking question wins over everything else" do
    doc = plan("done", "```question\nkey: k\ntext: t\nblocking: true\n```\n")

    assert {:waiting, [%Question{key: "k"}]} =
             Outcome.decide(
               spec(),
               run(%{documents: %{"plan.md" => doc}, result: nil, killed: :wall_clock})
             )
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

    assert {:finished, :error, nil, "harness result: error_during_execution"} =
             Outcome.decide(
               spec(),
               run(%{result: %{subtype: "error_during_execution", is_error: true}})
             )
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
