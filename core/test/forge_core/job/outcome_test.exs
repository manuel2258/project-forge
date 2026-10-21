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

  # `docs/design/workflow-grammar-v1.md` § Semantics: `optional` excuses a document from the one
  # rule that a declared output must be written, and from nothing else. Without this a workflow
  # could not say that a presentation is a nicety — the job would end `error` for not writing it,
  # and the ticket would never reach the state after it.
  test "an optional output may be absent, and a required one beside it may not" do
    spec = %{spec() | produces: ["plan.md", "deck.md!"], optional: ["deck.md"]}

    assert {:finished, :converged, "done", _} =
             Outcome.decide(
               spec,
               run(%{documents: %{"plan.md" => plan("done")}, missing: ["deck.md"]})
             )

    assert {:finished, :error, nil, "missing outputs: plan.md"} =
             Outcome.decide(spec, run(%{missing: ["plan.md", "deck.md"]}))
  end

  # The state whose only document is optional: absent, there is no front matter to read an outcome
  # from, and the answer is the one a state producing no document at all gets. Fetching it would
  # raise, which on the platform is a job whose result can never be recorded.
  test "a job whose optional outcome document is absent is done" do
    spec = %{spec() | produces: ["deck.md!", "changeset"], optional: ["deck.md"]}

    assert {:finished, :converged, "done", "deck.md was not written, and is optional"} =
             Outcome.decide(spec, run(%{missing: ["deck.md"]}))

    assert {:finished, :converged, "done", "agent declared done"} =
             Outcome.decide(spec, run(%{documents: %{"deck.md" => plan("done")}}))
  end

  # The grammar refuses this workflow (`ForgeCore.Workflow.Validator`), so a spec that says it
  # arrived from somewhere the parser is not: `done` is then an outcome the state never declared,
  # no transition can match it, and the ticket sticks behind a job that reported success. An
  # error is recoverable — a stuck ticket, by a job that succeeded, is not.
  test "an absent optional outcome document is not done where the state does not accept done" do
    spec = %{
      spec()
      | produces: ["verdict.md!"],
        optional: ["verdict.md"],
        outcomes: ["approved", "rejected"]
    }

    assert {:finished, :error, nil, why} = Outcome.decide(spec, run(%{missing: ["verdict.md"]}))
    assert why == "verdict.md was not written, and this state does not accept \"done\""
  end

  test "outputs must be complete, declared and parseable" do
    assert {:finished, :error, nil, "missing outputs: plan.md"} =
             Outcome.decide(spec(), run(%{missing: ["plan.md"]}))

    assert {:finished, :error, nil, "undeclared outputs: notes.md"} =
             Outcome.decide(
               spec(),
               run(%{documents: %{"plan.md" => plan("done")}, undeclared: ["notes.md"]})
             )

    assert {:finished, :error, nil, "invalid documents: plan.md ([:bad])"} =
             Outcome.decide(spec(), run(%{invalid: %{"plan.md" => [:bad]}}))
  end

  # The document's name was once the whole reason, and the parse errors were thrown away with the
  # document — so a failed refinement said which file was wrong and never what was wrong with it.
  test "an invalid document is named with what is wrong with it, one line" do
    errors = [
      ForgeCore.Error.new("question[2].options", "must be a non-empty list of strings"),
      ForgeCore.Error.new("question[2].default", "must be a string")
    ]

    assert {:finished, :error, nil, reason} =
             Outcome.decide(
               spec(),
               run(%{invalid: %{"plan.md" => errors, "notes.md" => "is not UTF-8"}})
             )

    assert reason ==
             "invalid documents: notes.md (is not UTF-8); plan.md (question[2].options: " <>
               "must be a non-empty list of strings; question[2].default: must be a string)"
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

  # `budget_exhausted` says a job ran out; only this says out of what, and "ran out of money"
  # and "ran out of turns" want different responses from whoever reads the job row
  # (`docs/design/capacity.md` § Four exhaustions, three treatments). Before it, the three were
  # one atom and the distinction survived only inside the free-text reason.
  describe "which ceiling stopped the run" do
    test "the turn ceiling, the cost ceiling and the wall clock are told apart" do
      assert Outcome.exhausted(run(%{result: %{subtype: "error_max_turns", is_error: true}})) ==
               :turns

      assert Outcome.exhausted(run(%{result: %{subtype: "error_max_budget_usd", is_error: true}})) ==
               :cost

      # Exit 2 with an error result is the cost ceiling too (`claude-code-events.md` § Outcome
      # mapping, rule 3) — the subtype names no budget at all.
      assert Outcome.exhausted(
               run(%{
                 exit_status: 2,
                 result: %{subtype: "error_during_execution", is_error: true}
               })
             ) == :cost

      assert Outcome.exhausted(run(%{killed: :wall_clock})) == :wall_clock
    end

    test "no ceiling stopped a run that converged, failed, was cancelled, or never reported" do
      assert Outcome.exhausted(run(%{})) == nil
      assert Outcome.exhausted(run(%{killed: :operator})) == nil
      assert Outcome.exhausted(run(%{result: nil, exit_status: 2})) == nil

      assert Outcome.exhausted(
               run(%{result: %{subtype: "error_during_execution", is_error: true}})
             ) ==
               nil

      # Exit 2 on a run the harness did not call an error is not the cost ceiling.
      assert Outcome.exhausted(run(%{exit_status: 2, result: @success})) == nil
    end

    # The invariant that keeps the two from drifting apart: `decide/2` and `exhausted/1` read the
    # same facts, so a run one of them calls a budget stop is one the other names a ceiling for.
    # Without it a later edit to either could leave a `budget_exhausted` job with no ceiling, or
    # a converged job carrying one.
    test "a ceiling is named for exactly the runs that finish budget_exhausted" do
      runs = [
        run(%{documents: %{"plan.md" => plan("done")}}),
        run(%{missing: ["plan.md"]}),
        run(%{killed: :operator}),
        run(%{killed: :wall_clock}),
        run(%{result: nil, exit_status: 1}),
        run(%{result: %{subtype: "error_max_turns", is_error: true}}),
        run(%{result: %{subtype: "error_max_budget_usd", is_error: true}}),
        run(%{exit_status: 2, result: %{subtype: "error_during_execution", is_error: true}}),
        run(%{result: %{subtype: "error_during_execution", is_error: true}}),
        run(%{result: %{subtype: "success", is_error: true, text: "Not logged in"}})
      ]

      for one <- runs do
        {:finished, outcome, _declared, _reason} = Outcome.decide(spec(), one)

        assert outcome == :budget_exhausted == (Outcome.exhausted(one) != nil),
               "#{inspect(outcome)} against ceiling #{inspect(Outcome.exhausted(one))} " <>
                 "for #{inspect(one)}"
      end
    end
  end
end
