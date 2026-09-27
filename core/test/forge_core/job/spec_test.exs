defmodule ForgeCore.Job.SpecTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Job.Spec

  import ForgeCore.Fixtures

  test "round-trips through JSON" do
    json = Spec.to_json(spec())
    assert {:ok, decoded} = Spec.from_json(json)
    assert decoded == spec()
  end

  test "builds from a map with string keys, as stored on the job row" do
    map = spec() |> Spec.to_json() |> Jason.decode!()
    assert Spec.from_map(map) == spec()
  end

  test "knows its groups of files, an agent's and a command's" do
    spec = %{spec() | produces: ["plan.md", "shots/*", "changeset", "pkg/*"]}
    assert Spec.group_outputs(spec) == ["shots", "pkg"]
    assert Spec.document_outputs(spec) == ["plan.md"]
    assert Spec.outcome_document(%{spec | produces: ["shots/*", "plan.md"]}) == "plan.md"

    command = %Spec{job_id: "c", branch: "b", kind: :command, command: %{"outputs" => ["pkg/*"]}}
    assert Spec.group_outputs(command) == ["pkg"]
    assert Spec.group_outputs(%{command | command: nil}) == []
  end

  test "knows its outcome document and document outputs" do
    assert Spec.outcome_document(spec()) == "plan.md"
    assert Spec.document_outputs(spec()) == ["plan.md"]
    assert Spec.outcome_document(%{spec() | produces: ["changeset"]}) == nil
  end

  # A conversation's spec is the one the round-trip tests above never build: no ticket, no state,
  # no budget, and a `kind` that has to survive the wire. The fixture has all three, so every
  # nil-handling clause in `from_map/1` was unexercised.
  defp chat_spec do
    %Spec{
      job_id: "chat-1",
      kind: :chat,
      prompt: "Tell me about this repository.",
      branch: "chat/2026-09-15-abc",
      commit: String.duplicate("b", 40),
      preamble_hash: "sha256:y"
    }
  end

  describe "a conversation's spec on the wire" do
    test "round-trips, keeping its kind" do
      json = Spec.to_json(chat_spec())

      assert {:ok, decoded} = Spec.from_json(json)
      assert decoded == chat_spec()

      # Named separately because losing it is silent and total: `Prompt.compose/2` dispatches on
      # `kind`, so a chat restored as a workflow is handed the job preamble and the job manifest.
      assert decoded.kind == :chat
    end

    # The comment above `ticket_from_map/1` names this exact trap: "`%{number: nil, title: nil}`
    # is truthy, and every `if spec.ticket` downstream would take the wrong branch". A map of
    # nils is not the same as no ticket, and `==` on the struct would not tell them apart if the
    # fixture had a ticket — which is why this asserts the fields themselves.
    test "an absent ticket comes back absent, not as a map of nils" do
      {:ok, decoded} = chat_spec() |> Spec.to_json() |> Spec.from_json()

      assert decoded.ticket == nil
      refute is_map(decoded.ticket)
    end

    test "an absent budget comes back absent, not as a map of nils" do
      {:ok, decoded} = chat_spec() |> Spec.to_json() |> Spec.from_json()

      assert decoded.budget == nil
      refute is_map(decoded.budget)
    end

    test "builds from a map with string keys, as stored on the job row" do
      map = chat_spec() |> Spec.to_json() |> Jason.decode!()

      assert Spec.from_map(map) == chat_spec()
    end

    # What a reopened conversation had already said crosses the wire in the spec, and the worker
    # writes it for the new process to read. Dropped on the way back in, the new process is told
    # nothing and answers the next message as though the conversation had just begun.
    test "what a reopened conversation already said survives the round trip" do
      spec = %{chat_spec() | replay: "# The conversation so far\n\nhello\n", prompt: nil}

      assert {:ok, decoded} = spec |> Spec.to_json() |> Spec.from_json()
      assert decoded.replay == "# The conversation so far\n\nhello\n"
      assert decoded.prompt == nil
    end

    test "a row written before kind existed is a workflow job" do
      assert Spec.from_map(%{"job_id" => "job-1", "branch" => "ticket/7"}).kind == :workflow
    end

    test "a kind nobody knows is refused, not guessed" do
      for bad <- ["bogus", :bogus, 3] do
        assert_raise ArgumentError, ~r/unknown job kind/, fn ->
          Spec.from_map(%{"job_id" => "job-1", "branch" => "ticket/7", "kind" => bad})
        end
      end
    end

    # Every list field defaults to a list rather than to nil. A `nil` here is not merely untidy:
    # `permitted_children` is read by the slice builder and `answered_keys` by `Outcome`, and
    # both iterate it. The `|| []` that guarantees this survived a mutation sweep, which means
    # nothing had ever built a spec from a map that omitted them.
    test "a row that omits the list fields gives back lists, not nils" do
      spec = Spec.from_map(%{"job_id" => "job-1", "branch" => "ticket/7"})

      assert spec.inputs == []
      assert spec.produces == []
      assert spec.permitted_children == []
      assert spec.answered_keys == []
      assert spec.absent_inputs == []
      assert spec.may_invoke == %{}
      assert spec.command_results == []

      # And the one that is not a list: a ticket's first job came from nowhere.
      assert spec.entered == nil

      # The one that is not empty: a job with nothing declared may still end with `done`.
      assert spec.outcomes == ["done"]
    end
  end

  describe "a command's spec" do
    defp command_spec do
      %Spec{
        job_id: "cmd-1",
        kind: :command,
        ticket: %{number: 7, title: "Persist the high score table"},
        state: "checking",
        attempt: 3,
        branch: "ticket/7",
        commit: String.duplicate("a", 40),
        env: "build",
        command: %{
          "name" => "test",
          "args" => ["--all"],
          "run" => ".forge/commands/test.sh",
          "script" => "#!/bin/sh\nexec mix test \"$@\"\n",
          "at" => String.duplicate("b", 40),
          "timeout_ms" => 1_800_000,
          "produces" => "test.log",
          "batch" => "batch-1",
          "concurrent" => 4
        }
      }
    end

    test "round-trips, keeping its kind and its command" do
      assert {:ok, command_spec()} == command_spec() |> Spec.to_json() |> Spec.from_json()
    end

    test "needs a script and a commit to run it at" do
      assert Spec.validate(command_spec()) == :ok

      spec = %{command_spec() | command: Map.drop(command_spec().command, ["script", "at"])}
      assert Spec.validate(spec) == {:error, [:script, :at]}
      assert Spec.validate(%{command_spec() | command: nil}) == {:error, [:script, :at]}
      assert Spec.validate(%{command_spec() | branch: nil}) == {:error, [:branch]}
    end

    # A spec built in memory has atom keys and one read back from the row has strings; the
    # manifest reads strings, and the two must render the same.
    test "an arrival reads the same whichever way its keys came" do
      entered = %{from: "reviewing", outcome: "changes_requested", by: "job", comment: nil}
      decoded = Spec.from_map(%{"job_id" => "c", "branch" => "b", "entered" => entered})

      assert decoded.entered == %{
               "from" => "reviewing",
               "outcome" => "changes_requested",
               "by" => "job",
               "comment" => nil
             }
    end
  end

  test "a workflow job's grant and a resume's results survive the wire" do
    spec = %{
      spec()
      | may_invoke: %{"build" => %{"max" => 40, "concurrent" => nil, "remaining" => 38}},
        command_results: [
          %{"command" => "build", "args" => [], "exit_status" => 0, "log" => "1-build.log"}
        ]
    }

    assert {:ok, ^spec} = spec |> Spec.to_json() |> Spec.from_json()
  end

  # `validate/1` exists because the struct no longer can: a conversation has no state, outcomes
  # or budget, so `@enforce_keys` cannot demand them. Its own docstring states the cost of
  # letting an incomplete spec through — "a job that fails on the machine after a credential has
  # been minted and a slice made" — and nothing called it.
  describe "validate/1" do
    test "passes a complete workflow spec" do
      assert Spec.validate(spec()) == :ok
    end

    test "names every workflow key that is missing" do
      assert {:error, missing} = Spec.validate(%{spec() | state: nil, budget: nil, commit: nil})

      assert Enum.sort(missing) == [:budget, :commit, :state]
    end

    test "names a single missing key rather than failing vaguely" do
      assert Spec.validate(%{spec() | budget: nil}) == {:error, [:budget]}
    end

    # A chat is held to what a chat actually needs, and to nothing else. Holding it to the
    # workflow keys would refuse every conversation ever built.
    test "a conversation needs only somewhere to run and something to run on" do
      assert Spec.validate(chat_spec()) == :ok
    end

    # Both, not either: a chat with no branch has nowhere to commit, and one with no job_id
    # cannot be spoken to. An `or` here would let each of those through on the strength of the
    # other.
    test "a conversation missing either of them is refused" do
      assert {:error, _keys} = Spec.validate(%{chat_spec() | branch: nil})
      assert {:error, _keys} = Spec.validate(%{chat_spec() | job_id: nil})
    end
  end
end
