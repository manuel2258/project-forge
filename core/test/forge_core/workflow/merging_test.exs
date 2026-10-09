defmodule ForgeCore.Workflow.MergingTest do
  @moduledoc """
  `on_conflict`, the merging state's say in where a conflict goes, and what the graph makes of it
  (`docs/design/workflow-grammar-v1.md` § Merging, § Validation).
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Engine, Workflow}
  alias ForgeCore.Workflow.{Parser, Transition}

  @fixture Path.expand("../../fixtures/workflow_example.yml", __DIR__)

  # The grammar example with a conflict sending the ticket to an integrating job, which reads what
  # planning wrote and goes back through verifying — route (a), as the note's opening example has.
  setup_all do
    {:ok, map} = YamlElixir.read_from_string(File.read!(@fixture))

    map =
      map
      |> put_in(["states", "merged", "on_conflict"], "integrating")
      |> put_in(["states", "integrating"], %{
        "prompt" => "agents/integrate.md",
        "inputs" => ["plan.md", "changeset"],
        "produces" => ["integration.md", "changeset"],
        "budget" => %{"turns" => 80, "cost" => 4.0}
      })
      |> Map.update!("transitions", &(&1 ++ [%{"from" => "integrating", "to" => "verifying"}]))

    %{map: map}
  end

  describe "the grammar" do
    test "a merging state names a job state to go to on a conflict", %{map: map} do
      assert {:ok, workflow} = Parser.from_map(map)

      assert workflow.states["merged"].on_conflict == "integrating"
      assert Workflow.on_conflict(workflow, "merged") == "integrating"
      assert Workflow.on_conflict(workflow, "review_ready") == nil
      assert Workflow.integrating?(workflow, "integrating")
      refute Workflow.integrating?(workflow, "implementing")
    end

    # It is not a transition: nothing may choose it and no outcome selects it, so the state that
    # merges is as terminal as it ever was, and a ticket that merged is done.
    test "the merging state stays terminal", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert Workflow.terminal?(workflow, "merged")
      assert Workflow.transitions_from(workflow, "merged") == []

      assert [%Transition{from: "merged", to: "integrating", when: "merge_conflict"}] =
               Workflow.edges_from(workflow, "merged")
    end

    test "the edge a conflict takes leaves from wherever the ticket was", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert %Transition{from: "review_ready", to: "integrating", when: "merge_conflict"} =
               Workflow.conflict_transition(workflow, "review_ready", "merged")

      assert Workflow.conflict_transition(workflow, "review_ready", "review_ready") == nil
    end

    test "a human state may be the target", %{map: map} do
      map =
        map
        |> put_in(["states", "integrating"], %{})
        |> Map.update!("transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "integrating")) ++
            [%{"from" => "integrating", "to" => "implementing"}]
        end)

      assert {:ok, workflow} = Parser.from_map(map)
      assert Workflow.on_conflict(workflow, "merged") == "integrating"
    end

    # The two routes the owner requires both to be expressible (`workflow-grammar-v1.md`
    # § Merging): back to an earlier step and the usual approval, or straight to the merge.
    test "route (a): back to a person, who approves the merge again", %{map: map} do
      map =
        map
        |> put_in(["states", "human_testing"], %{})
        |> Map.update!("transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "integrating")) ++
            [
              %{"from" => "integrating", "to" => "human_testing"},
              %{"from" => "human_testing", "to" => "merged", "approve" => ["changeset"]}
            ]
        end)

      assert {:ok, workflow} = Parser.from_map(map)
      assert ["merged"] == Enum.map(Workflow.transitions_from(workflow, "human_testing"), & &1.to)
    end

    test "route (b): straight back to the merge", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "integrating")) ++
            [%{"from" => "integrating", "to" => "merged"}]
        end)

      assert {:ok, workflow} = Parser.from_map(map)
      assert ["merged"] == Enum.map(Workflow.transitions_from(workflow, "integrating"), & &1.to)
    end
  end

  describe "the graph follows it" do
    # Nothing but a conflict reaches an integrating state, so a reachability walk that followed
    # declared transitions alone would refuse every workflow that has one.
    test "an integrating state is reachable by it alone", %{map: map} do
      assert {:ok, _workflow} = Parser.from_map(map)
    end

    # `plan.md` is written by planning, which runs before anything merges; an approval rule or an
    # input rule that walked declared transitions only would not find planning upstream of a state
    # the merge sends to.
    test "what ran before the merge counts as before the integrating state", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert Workflow.required_input?(workflow, "integrating", "plan.md")
    end

    # A person's notes are never a required input, because nothing obliges the person to write
    # them — which the walk can only conclude by reaching the integrating state at all. Walked
    # along declared transitions alone, it is reached by nothing, and every input would read as
    # one the job is certain to have.
    test "a document a person may not have written stays optional on the way in", %{map: map} do
      map =
        map
        |> put_in(["states", "review_ready", "produces"], ["review-notes.md"])
        |> put_in(["states", "integrating", "inputs"], ["plan.md", "review-notes.md"])

      {:ok, workflow} = Parser.from_map(map)

      refute Workflow.required_input?(workflow, "integrating", "review-notes.md")
    end

    test "an approval on the way back may name what ran before the merge", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "integrating")) ++
            [%{"from" => "integrating", "to" => "verifying", "approve" => ["plan.md"]}]
        end)

      assert {:ok, _workflow} = Parser.from_map(map)
    end
  end

  describe "validation" do
    test "only the state that merges may name one", %{map: map} do
      map = put_in(map, ["states", "review_ready", "on_conflict"], "integrating")

      assert messages(map) == [
               {"states.review_ready.on_conflict",
                "only the state that merges may say where a conflict goes"}
             ]
    end

    test "a job state may not name one either", %{map: map} do
      map = put_in(map, ["states", "verifying", "on_conflict"], "integrating")

      assert {"states.verifying.on_conflict",
              "only the state that merges may say where a conflict goes"} in messages(map)
    end

    test "the target must exist", %{map: map} do
      map = put_in(map, ["states", "merged", "on_conflict"], "integrate")

      assert {"states.merged.on_conflict", ~s|names an unknown state "integrate"|} in messages(
               map
             )
    end

    test "the target cannot be the merging state itself", %{map: map} do
      map = put_in(map, ["states", "merged", "on_conflict"], "merged")

      assert {"states.merged.on_conflict",
              "cannot be the state that merges: a conflict has to leave it"} in messages(map)
    end

    test "the target cannot be a command state", %{map: map} do
      map =
        map
        |> put_in(["commands"], %{
          "rebase" => %{"run" => ".forge/commands/rebase.sh", "timeout" => "10m"}
        })
        |> put_in(["states", "integrating"], %{
          "invoke" => ["rebase"],
          "exit" => %{0 => "done", "*" => "failed"}
        })
        |> Map.update!("transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "integrating")) ++
            [%{"from" => "integrating", "to" => "verifying"}]
        end)

      assert messages(map) == [
               {"states.merged.on_conflict",
                "must be a job state or a human state: a command's checkout has no default branch to merge"}
             ]
    end

    # What makes a job an integration is the state it is in, so a state ordinary work also
    # arrives at would make every one of its jobs one — `implementing` the case that would have.
    test "a job state named as the target is reached by nothing else", %{map: map} do
      map = put_in(map, ["states", "merged", "on_conflict"], "implementing")

      assert {"states.merged.on_conflict",
              ~s|names "implementing", which a transition also leads into: an integrating state is reached by a conflict only|} in messages(
               map
             )
    end

    # A person's state runs nothing, so arriving at it other ways changes nothing about it.
    test "a human state named as the target may be reached other ways", %{map: map} do
      map =
        map
        |> put_in(["states", "merged", "on_conflict"], "review_ready")
        |> Map.update!("states", &Map.delete(&1, "integrating"))
        |> Map.update!("transitions", fn ts -> Enum.reject(ts, &(&1["from"] == "integrating")) end)

      assert {:ok, workflow} = Parser.from_map(map)
      assert Workflow.on_conflict(workflow, "merged") == "review_ready"
    end

    test "the target has a transition out, or a conflict would end the ticket", %{map: map} do
      map =
        map
        |> put_in(["states", "merged", "on_conflict"], "abandoned")
        |> put_in(["states", "abandoned"], %{})

      assert {"states.merged.on_conflict",
              ~s|names "abandoned", which has no transition out: a conflict there would end the ticket unmerged|} in messages(
               map
             )
    end

    test "merge_conflict is the platform's outcome, never declared", %{map: map} do
      map =
        put_in(map, ["states", "verifying", "outcomes"], [
          "done",
          "tests_failed",
          "merge_conflict"
        ])

      assert {"states.verifying.outcomes",
              ~s|"merge_conflict" is the platform's: a merge conflict is recorded on it|} in messages(
               map
             )
    end

    test "nor mapped to by a command state's exit", %{map: map} do
      map =
        map
        |> put_in(["commands"], %{
          "build" => %{"run" => ".forge/commands/build.sh", "timeout" => "10m"}
        })
        |> put_in(["states", "building"], %{
          "invoke" => ["build"],
          "exit" => %{0 => "done", "*" => "merge_conflict"}
        })
        |> Map.update!(
          "transitions",
          &(&1 ++
              [
                %{"from" => "verifying", "to" => "building", "when" => "tests_failed"},
                %{"from" => "building", "to" => "review_ready"}
              ])
        )
        |> Map.update!("transitions", fn ts ->
          Enum.reject(ts, &(&1["from"] == "verifying" and &1["to"] == "implementing"))
        end)

      assert {"states.building.exit",
              ~s|"merge_conflict" is the platform's: a merge conflict is recorded on it|} in messages(
               map
             )
    end

    test "it is a state's name, not anything else", %{map: map} do
      map = put_in(map, ["states", "merged", "on_conflict"], ["integrating"])

      assert {"states.merged.on_conflict", "must be a non-empty string"} in messages(map)
    end
  end

  # The bound on the integrate-then-merge loop (`workflow-grammar-v1.md` § Merging): three times in
  # a row by the engine, never for a person.
  describe "what a conflict at the check does" do
    test "without on_conflict, what it always did", %{map: map} do
      {:ok, workflow} = map |> pop_in(["states", "merged", "on_conflict"]) |> elem(1) |> plain()

      assert Engine.conflict(workflow, "review_ready", "merged", :person, 0) == :refuse
      assert Engine.conflict(workflow, "review_ready", "merged", :engine, 0) == :refuse
    end

    test "the engine goes round while it has gone round fewer than three times", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      for rounds <- 0..2 do
        assert {:route, %Transition{from: "integrating", to: "integrating"}} =
                 Engine.conflict(workflow, "integrating", "merged", :engine, rounds)
      end

      assert Engine.conflict(workflow, "integrating", "merged", :engine, 3) ==
               {:stuck, {:conflict_rounds, 3}}
    end

    test "a person is never bounded", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert {:route, %Transition{from: "review_ready", to: "integrating"}} =
               Engine.conflict(workflow, "review_ready", "merged", :person, 10)
    end
  end

  # The example without its integrating state, as a workflow from before `on_conflict` existed.
  defp plain(map) do
    map
    |> Map.update!("states", &Map.delete(&1, "integrating"))
    |> Map.update!("transitions", fn ts -> Enum.reject(ts, &(&1["from"] == "integrating")) end)
    |> Parser.from_map()
  end

  defp messages(map) do
    {:error, errors} = Parser.from_map(map)
    Enum.map(errors, &{&1.path, &1.message})
  end
end
