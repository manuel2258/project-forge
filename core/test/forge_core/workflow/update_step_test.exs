defmodule ForgeCore.Workflow.UpdateStepTest do
  @moduledoc """
  `on_enter: update`, the state that brings a ticket's branch up to date and runs no job
  (`docs/design/workflow-grammar-v1.md` § Bringing the branch up to date, § Validation).
  """

  use ExUnit.Case, async: true

  alias ForgeCore.{Engine, Workflow}
  alias ForgeCore.Workflow.{Parser, State, Transition}

  @fixture Path.expand("../../fixtures/workflow_example.yml", __DIR__)

  # The grammar example with an update step between implementing and verifying, whose conflict goes
  # to an integrating job that leads back to it, and a human state that may try the step again.
  setup_all do
    {:ok, map} = YamlElixir.read_from_string(File.read!(@fixture))

    map =
      map
      |> put_in(["states", "refresh"], %{"on_enter" => "update", "on_conflict" => "resolving"})
      |> put_in(["states", "resolving"], %{
        "prompt" => "agents/integrate.md",
        "inputs" => ["plan.md"],
        "outcomes" => ["done", "gave_up"],
        "produces" => ["integration.md"],
        "budget" => %{"turns" => 80, "tokens" => 800_000}
      })
      |> put_in(["states", "stuck_here"], %{})
      |> Map.update!("transitions", fn transitions ->
        transitions
        |> Enum.map(fn
          %{"from" => "implementing", "to" => "verifying"} = t -> %{t | "to" => "refresh"}
          t -> t
        end)
        |> Kernel.++([
          %{"from" => "refresh", "to" => "verifying"},
          %{"from" => "resolving", "to" => "verifying"},
          %{"from" => "resolving", "to" => "stuck_here", "when" => "gave_up"},
          %{"from" => "stuck_here", "to" => "refresh"}
        ])
      end)

    %{map: map}
  end

  defp errors(map) do
    {:error, errors} = Parser.from_map(map)
    Enum.map(errors, &{&1.path, &1.message})
  end

  # The same workflow with no conflict state at all: `resolving` and what only it led to are gone.
  defp without_conflict_state(map) do
    map
    |> update_in(["states", "refresh"], &Map.delete(&1, "on_conflict"))
    |> update_in(["states"], &Map.drop(&1, ["resolving", "stuck_here"]))
    |> Map.update!("transitions", fn transitions ->
      Enum.reject(transitions, &(&1["from"] in ["resolving", "stuck_here"]))
    end)
  end

  describe "the grammar" do
    test "accepts a step, a job as its conflict state, and a human state back into it", %{
      map: map
    } do
      assert {:ok, workflow} = Parser.from_map(map)

      assert State.updates?(workflow.states["refresh"])
      refute State.updates?(workflow.states["verifying"])
      assert Workflow.updates_on_enter?(workflow, "refresh")
      refute Workflow.updates_on_enter?(workflow, "verifying")
      refute Workflow.updates_on_enter?(workflow, "nowhere")
      assert Workflow.on_conflict(workflow, "refresh") == "resolving"
      assert Workflow.integrating?(workflow, "resolving")
    end

    test "a step is not a human state, and does not wait for a person", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      refute State.human?(workflow.states["refresh"])
      assert State.human?(workflow.states["stuck_here"])
      refute State.runs?(workflow.states["refresh"])
    end

    test "more than one step, sharing a conflict state", %{map: map} do
      map =
        map
        |> put_in(["states", "refresh_again"], %{
          "on_enter" => "update",
          "on_conflict" => "resolving"
        })
        |> Map.update!("transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "stuck_here", "to" => "refresh"} = t -> %{t | "to" => "refresh_again"}
            t -> t
          end) ++ [%{"from" => "refresh_again", "to" => "verifying"}]
        end)

      assert {:ok, _workflow} = Parser.from_map(map)
    end

    test "a step with no conflict state is allowed", %{map: map} do
      assert {:ok, workflow} = Parser.from_map(without_conflict_state(map))
      assert Workflow.on_conflict(workflow, "refresh") == nil
    end

    test "its conflict is an edge out of it for every walk of the graph", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert [
               %Transition{from: "refresh", to: "verifying", when: nil},
               %Transition{from: "refresh", to: "resolving", when: "merge_conflict"}
             ] = Workflow.edges_from(workflow, "refresh")
    end

    test "may lead straight into a merging state, as route (b) does", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh", "to" => "verifying"} = t -> %{t | "to" => "merged"}
            t -> t
          end)
        end)

      assert {:ok, _workflow} = Parser.from_map(map)
    end

    # The merging state here names no `on_conflict`: the only integrating state is the one the
    # update step names, so an edge out of it into the merge needs an approval on record
    # (`workflow-grammar-v1.md` § Merging). Fails if `integrating?/2` stops counting update steps.
    test "an edge from a step's conflict state into a merge approves the changeset", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "resolving", "to" => "verifying"} = t -> %{t | "to" => "merged"}
            t -> t
          end)
        end)

      assert {:ok, workflow} = Parser.from_map(map)
      assert Workflow.on_conflict(workflow, "merged") == nil
      assert Workflow.integrating?(workflow, "resolving")

      [edge] =
        for t <- workflow.transitions, t.from == "resolving", t.to == "merged", do: t

      assert edge.approve == []
      assert Workflow.integrates_into_merge?(workflow, edge)
      assert Workflow.approving(workflow, edge).approve == ["changeset"]
    end
  end

  describe "the validator refuses each misuse, saying what is wrong" do
    test "a state that both merges and updates", %{map: map} do
      map = put_in(map, ["states", "merged", "on_enter"], ["merge", "update"])

      assert {"states.merged.on_enter", "a state merges or updates, not both"} in errors(map)
    end

    test "produces", %{map: map} do
      map = put_in(map, ["states", "refresh", "produces"], ["note.md"])

      assert {"states.refresh.produces",
              "not allowed on an update step: it runs no job to write anything"} in errors(map)
    end

    test "a prompt, since entry already runs a job", %{map: map} do
      map = put_in(map, ["states", "refresh", "prompt"], "agents/x.md")

      assert Enum.any?(errors(map), fn {path, message} ->
               path == "states.refresh.on_enter" and message =~ "not allowed on a job state"
             end)
    end

    test "no transition out", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.reject(transitions, &(&1["from"] == "refresh"))
        end)

      assert {"states.refresh",
              "an update step has no transition out: \"refresh\" has to lead somewhere once the branch is current"} in errors(
               map
             )
    end

    test "two transitions out", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          transitions ++ [%{"from" => "refresh", "to" => "implementing"}]
        end)

      assert {"states.refresh",
              "an update step has exactly one transition out; \"refresh\" has 2"} in errors(map)
    end

    test "a `when` on its edge", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh"} = t -> Map.put(t, "when", "done")
            t -> t
          end)
        end)

      messages = errors(map)

      assert Enum.any?(messages, fn {path, message} ->
               path =~ ~r/^transitions\[\d+\]\.when$/ and
                 message =~ "not allowed on a transition out of an update step"
             end)

      # And not also called an unknown outcome: the step has none.
      refute Enum.any?(messages, fn {_path, message} -> message =~ "is not an outcome" end)
    end

    test "an `approve` on its edge", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh"} = t -> Map.put(t, "approve", ["plan.md"])
            t -> t
          end)
        end)

      assert Enum.any?(errors(map), fn {path, message} ->
               path =~ ~r/^transitions\[\d+\]\.approve$/ and
                 message =~ "nobody is there to approve"
             end)
    end

    test "an edge into another step", %{map: map} do
      map =
        map
        |> put_in(["states", "second"], %{"on_enter" => "update"})
        |> Map.update!("transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh"} = t -> %{t | "to" => "second"}
            t -> t
          end) ++ [%{"from" => "second", "to" => "verifying"}]
        end)

      assert Enum.any?(errors(map), fn {path, message} ->
               path =~ ~r/^transitions\[\d+\]\.to$/ and
                 message == "an update step cannot lead into another: \"second\" is one"
             end)
    end

    test "as the initial state", %{map: map} do
      map = Map.put(map, "initial", "refresh")

      assert {"initial",
              "names an update step: a ticket's branch is cut up to date when it is admitted"} in errors(
               map
             )
    end

    test "as another state's conflict target", %{map: map} do
      map =
        map
        |> put_in(["states", "merged", "on_conflict"], "refresh")

      assert Enum.any?(errors(map), fn {path, message} ->
               path == "states.merged.on_conflict" and message =~ "an update step"
             end)
    end

    test "on_conflict on a state that neither merges nor updates", %{map: map} do
      map = put_in(map, ["states", "review_ready", "on_conflict"], "resolving")

      assert {"states.review_ready.on_conflict",
              "only the state that merges, or an update step, may say where a conflict goes"} in errors(
               map
             )
    end

    test "an on_conflict naming the step itself", %{map: map} do
      map = put_in(map, ["states", "refresh", "on_conflict"], "refresh")

      assert Enum.any?(errors(map), fn {path, message} ->
               path == "states.refresh.on_conflict" and
                 message == "cannot be the state that merges: a conflict has to leave it"
             end)
    end

    test "a queue on its edge", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh"} = t -> Map.put(t, "queue", true)
            t -> t
          end)
        end)

      assert Enum.any?(errors(map), fn {_path, message} ->
               message =~ "only an edge into a merging state"
             end)
    end
  end

  describe "ForgeCore.Engine" do
    test "step/4 will not decide from an update step: it has no outcome", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert {:error, {:human_state, "refresh"}} = Engine.step(workflow, "refresh", "done", %{})
    end

    test "after_update/4 takes the one edge out when the branch is current", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)

      assert {:transition, %Transition{from: "refresh", to: "verifying"}} =
               Engine.after_update(workflow, "refresh", :done, %{})
    end

    test "after_update/4 binds the edge's max", %{map: map} do
      map =
        Map.update!(map, "transitions", fn transitions ->
          Enum.map(transitions, fn
            %{"from" => "refresh"} = t -> Map.put(t, "max", 2)
            t -> t
          end)
        end)

      {:ok, workflow} = Parser.from_map(map)
      [edge] = Workflow.transitions_from(workflow, "refresh")
      counts = %{Transition.id(edge) => 2}

      assert {:stuck, {:max_exceeded, ^edge}} =
               Engine.after_update(workflow, "refresh", :done, counts)

      assert {:transition, ^edge} =
               Engine.after_update(workflow, "refresh", :done, %{Transition.id(edge) => 1})
    end

    test "after_update/4 sends a conflict to the step's conflict state, whatever the counts", %{
      map: map
    } do
      {:ok, workflow} = Parser.from_map(map)
      counts = %{{"refresh", "resolving", "merge_conflict"} => 50}

      assert {:conflict, %Transition{from: "refresh", to: "resolving", when: "merge_conflict"}} =
               Engine.after_update(workflow, "refresh", :conflict, counts)
    end

    # What a stored pin could hold that the validator would refuse: a step with no way out.
    test "after_update/4 sticks a step with no edge out rather than raising", %{map: map} do
      {:ok, workflow} = Parser.from_map(map)
      bare = %{workflow | transitions: Enum.reject(workflow.transitions, &(&1.from == "refresh"))}

      assert {:stuck, :no_edge} = Engine.after_update(bare, "refresh", :done, %{})
    end

    test "after_update/4 sticks a conflict that has nowhere to go", %{map: map} do
      {:ok, workflow} = Parser.from_map(without_conflict_state(map))

      assert {:stuck, :no_conflict_state} =
               Engine.after_update(workflow, "refresh", :conflict, %{})
    end
  end
end
