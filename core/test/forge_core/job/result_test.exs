defmodule ForgeCore.Job.ResultTest do
  use ExUnit.Case, async: true

  alias ForgeCore.{Document, Proposal}
  alias ForgeCore.Document.Question
  alias ForgeCore.Document.Question.Option
  alias ForgeCore.Job.Result

  # Every question field is populated deliberately. The moduledoc claims the round trip is
  # lossless — "a result that survived a round trip must record exactly as the one that did not"
  # — and a fixture whose `anchor`, `default` and `assumption` were all nil proved that claim
  # with nil on both sides of the `==`. `anchor` is what puts a question next to the passage it
  # concerns, an option's `recommended` is the answer the form starts with, and `assumption` is
  # the record of what a non-blocking question proceeded with; all three could vanish between the
  # worker and the platform with the suite green.
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
      anchor: "## Storage"
      options:
        - label: "Postgres"
          detail: "Where the rest of the data is."
          recommended: true
        - label: "A file"
          detail: "Nothing to run."
      blocking: true
      ```

      ```question
      key: cache
      text: Cache the reads?
      assumption: proceeding without a cache
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
      proposals: %{"score-table.md" => Proposal.parse!("# Extract the score table\n\nWhy.")},
      invalid_proposals: %{
        "half.md" => %{
          "reason" => "title: must begin with a level-one heading (# Title)",
          "raw" => "no heading here\n"
        }
      },
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

  # The wire is JSON, so what `to_map/1` emits must already be keyed the way it will arrive.
  # A struct passed through `Map.from_struct/1` is keyed by atoms before encoding and by strings
  # after, and a reader on the worker side of an in-process send sees the first.
  test "sends proposals keyed as they will arrive" do
    assert %{"proposals" => %{"score-table.md" => proposal}} = Result.to_map(result())

    assert Map.keys(proposal) |> Enum.sort() == ["body", "raw", "ticket_type", "title"]
  end

  # The type a proposal suggests crosses the wire with it, and a worker built before there was one
  # sends none, which is no suggestion rather than a failure.
  test "carries the type a proposal suggests, and its absence" do
    typed = %{
      result()
      | proposals: %{"a.md" => Proposal.parse!("---\ntype: bug\n---\n# A\n\nB.")}
    }

    round_tripped = typed |> Result.to_map() |> Jason.encode!() |> Jason.decode!()

    assert %Result{proposals: %{"a.md" => %Proposal{ticket_type: "bug"}}} =
             Result.from_map(round_tripped)

    older = update_in(round_tripped, ["proposals", "a.md"], &Map.delete(&1, "ticket_type"))

    assert %Result{proposals: %{"a.md" => %Proposal{ticket_type: nil, title: "A"}}} =
             Result.from_map(older)
  end

  test "carries a waiting result's questions" do
    result = %{result() | status: :waiting, outcome: nil, declared_outcome: nil}
    round_tripped = result |> Result.to_map() |> Jason.encode!() |> Jason.decode!()

    assert %Result{status: :waiting, questions: [blocking, proceeded]} =
             Result.from_map(round_tripped)

    assert blocking.key == "backend"
    assert blocking.blocking

    assert blocking.options == [
             %Option{
               label: "Postgres",
               detail: "Where the rest of the data is.",
               recommended: true
             },
             %Option{label: "A file", detail: "Nothing to run.", recommended: false}
           ]

    # The three fields the fixture used to leave nil at both ends of the `==`, named one by one
    # so that losing any of them is a failure with that field's name on it.
    assert blocking.anchor == "## Storage"
    assert Question.recommended(blocking).label == "Postgres"
    assert proceeded.assumption == "proceeding without a cache"
    refute proceeded.blocking
  end

  # A worker released before options had details sends each one as its label alone. The wire is
  # read, not refused: the platform re-parses the document itself, so what is lost is a detail
  # nobody wrote, not the question.
  test "reads an option sent as a bare label" do
    map = Result.to_map(%{result() | status: :waiting, outcome: nil, declared_outcome: nil})
    [question | rest] = map["questions"]
    map = %{map | "questions" => [%{question | options: ["Postgres", 5]} | rest]}

    # And a value that is neither is read rather than raised on: the channel would crash on it,
    # for a field the platform does not read.
    assert %Result{
             questions: [
               %{options: [%Option{label: "Postgres", detail: nil}, %Option{label: "5"}]} | _
             ]
           } = map |> Jason.encode!() |> Jason.decode!() |> Result.from_map()
  end

  # `docs/design/commands.md` § How an agent invokes: a parked run is reported with what it asked
  # for and the commit every command runs against, and neither may be lost on the way.
  test "carries a parked run's invocations and the commit it pushed" do
    parked = %Result{
      status: :parked,
      commit: String.duplicate("c", 40),
      invocations: [
        %{"command" => "build", "args" => ["--release"]},
        %{"command" => "test", "args" => []}
      ],
      invocation_error: nil
    }

    assert ^parked =
             parked |> Result.to_map() |> Jason.encode!() |> Jason.decode!() |> Result.from_map()

    unreadable = %Result{status: :parked, invocation_error: "invoke.json is not a JSON array"}

    assert %Result{status: :parked, invocations: [], invocation_error: "invoke.json" <> _} =
             unreadable
             |> Result.to_map()
             |> Jason.encode!()
             |> Jason.decode!()
             |> Result.from_map()
  end

  test "carries a run's groups of files, kept and refused" do
    result = %Result{
      status: :finished,
      outcome: :converged,
      blobs: %{"pkg/app.tar.gz" => %{"key" => "job/j/out-x/1", "size" => 12}},
      invalid_blobs: %{"pkg/big.bin" => "is larger than 1024 bytes"}
    }

    assert ^result =
             result |> Result.to_map() |> Jason.encode!() |> Jason.decode!() |> Result.from_map()

    assert %Result{blobs: %{}, invalid_blobs: %{}} = Result.from_map(%{"status" => "finished"})
  end

  test "carries a command's exit status, log and duration" do
    command = %Result{
      status: :finished,
      outcome: :converged,
      exit_status: 3,
      log: "job/abc/log-1-x.txt",
      duration_ms: 4200
    }

    assert ^command =
             command |> Result.to_map() |> Jason.encode!() |> Jason.decode!() |> Result.from_map()
  end

  test "refuses a status or an outcome it does not know" do
    assert_raise ArgumentError, fn -> Result.from_map(%{"status" => "sideways"}) end

    assert_raise ArgumentError, fn ->
      Result.from_map(%{"status" => "finished", "outcome" => "vibes"})
    end
  end

  # A worker sends only what it has. Every collection field defaults to an empty collection
  # rather than to nil, because the platform folds over all of them — `missing` and `undeclared`
  # are rendered into the job's outcome, and `nil` there is a crash rather than an empty list.
  # The `|| []` guaranteeing it survived a mutation sweep: no test had built a result from a map
  # that left them out, which is exactly what a minimal failure result looks like.
  test "a result that omits its collections gives back empty ones, not nils" do
    result = Result.from_map(%{"status" => "finished", "outcome" => "error"})

    assert result.questions == []
    assert result.documents == %{}
    assert result.invalid == %{}
    assert result.missing == []
    assert result.undeclared == []
    assert result.harness == %{}
    assert result.invocations == []
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

  # Parse errors used to cross as `inspect` of their structs, which is what the platform then had
  # to show a person. They cross as the lines `ForgeCore.Error.format/1` writes.
  test "invalid outputs that are parse errors cross as their lines" do
    errors = [
      ForgeCore.Error.new("question[0].options", "must be a non-empty list of options"),
      ForgeCore.Error.new("question[0].text", "must be a non-empty string")
    ]

    map = Result.to_map(%{result() | invalid: %{"plan.md" => errors}})

    assert map["invalid"] == %{
             "plan.md" =>
               "question[0].options: must be a non-empty list of options\n" <>
                 "question[0].text: must be a non-empty string"
           }
  end
end
