defmodule ForgeCore.Job.ResultTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Document
  alias ForgeCore.Job.Result

  defp result do
    document =
      Document.parse!("""
      ---
      outcome: done
      ---
      # Plan

      ```question
      key: backend
      text: Which store?
      options: [a, b]
      blocking: true
      ```
      """)

    %Result{
      status: :finished,
      outcome: :converged,
      declared_outcome: "done",
      reason: nil,
      killed: nil,
      exit_status: 0,
      transcript: "job/j1/transcript-1.jsonl",
      transcript_path: "/var/lib/forge/jobs/j1/transcript-1.jsonl",
      stderr_path: "/var/lib/forge/jobs/j1/stderr.log",
      questions: document.questions,
      documents: %{"plan.md" => document},
      invalid: %{},
      missing: [],
      undeclared: ["notes.md"],
      harness: %{"session_id" => "sess-42", "cost_usd" => 0.0421, "turns" => 3}
    }
  end

  test "survives the wire unchanged" do
    result = result()

    assert ^result =
             result
             |> Result.to_map()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Result.from_map()
  end

  test "carries a waiting result's questions" do
    result = %{result() | status: :waiting, outcome: nil, declared_outcome: nil}
    round_tripped = result |> Result.to_map() |> Jason.encode!() |> Jason.decode!()

    assert %Result{status: :waiting, questions: [question]} = Result.from_map(round_tripped)
    assert question.key == "backend"
    assert question.blocking
    assert question.options == ["a", "b"]
  end

  test "refuses a status or an outcome it does not know" do
    assert_raise ArgumentError, fn -> Result.from_map(%{"status" => "sideways"}) end

    assert_raise ArgumentError, fn ->
      Result.from_map(%{"status" => "finished", "outcome" => "vibes"})
    end
  end

  test "accepts atom keys, so an in-process result needs no encoding" do
    assert %Result{status: :finished, outcome: :error} =
             Result.from_map(%{status: :finished, outcome: :error})
  end

  test "invalid outputs cross as their reason, rendered" do
    result = %{result() | invalid: %{"plan.md" => {:parse_error, [:missing_outcome]}}}
    round_tripped = result |> Result.to_map() |> Jason.encode!() |> Jason.decode!()

    assert %Result{invalid: %{"plan.md" => rendered}} = Result.from_map(round_tripped)
    assert rendered =~ "missing_outcome"
  end
end
