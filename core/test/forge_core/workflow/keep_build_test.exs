defmodule ForgeCore.Workflow.KeepBuildTest do
  @moduledoc """
  `keep_build` and `warm_start` in the grammar (`docs/design/workflow-grammar-v1.md` § Commands):
  which exit statuses of a command keep its tree for the ticket's next command, and whether the
  command starts from that tree. Commands only, and a wrong value is refused naming the command.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow.Parser

  @base """
  version: 1
  initial: implementing
  commands:
    gate:
      run: .forge/commands/gate.sh
      timeout: 10m
  states:
    implementing:
      prompt: agents/implement.md
      produces: [changeset]
      may_invoke:
        gate: { max: 1 }
      budget: { turns: 10, tokens: 200k }
    building:
      invoke: [gate]
      exit: { 0: done, "*": failed }
    done: {}
  transitions:
    - { from: implementing, to: building }
    - { from: building, to: done }
    - { from: building, to: implementing, when: failed }
  limits:
    ticket_tokens: 1M
  """

  defp base_map do
    {:ok, map} = YamlElixir.read_from_string(@base)
    map
  end

  defp messages(map) do
    case Parser.from_map(map) do
      {:ok, _workflow} -> []
      {:error, errors} -> Enum.map(errors, &{&1.path, &1.message})
    end
  end

  defp put_gate(map, key, value), do: put_in(map, ["commands", "gate", key], value)

  test "a command that says nothing keeps nothing and starts from the copy" do
    assert {:ok, workflow} = Parser.from_map(base_map())
    assert workflow.commands["gate"].keep_build == []
    assert workflow.commands["gate"].warm_start == true
  end

  test "the statuses kept and the start turned off are read" do
    map = base_map() |> put_gate("keep_build", [0, 1, 1, 255]) |> put_gate("warm_start", false)

    assert {:ok, workflow} = Parser.from_map(map)
    assert workflow.commands["gate"].keep_build == [0, 1, 255]
    assert workflow.commands["gate"].warm_start == false
  end

  test "a status that is not a whole number from 0 to 255 is refused, naming the command" do
    for bad <- [[256], [-1], ["0"], [1.5], ["*"], [nil], [0, "x"]] do
      assert [{"commands.gate.keep_build", message}] =
               base_map() |> put_gate("keep_build", bad) |> messages()

      assert message =~ "is not a list of exit statuses"
    end
  end

  test "keep_build that is not a non-empty list is refused, quoting the value" do
    for bad <- [[], 0, "0", %{"0" => true}, true] do
      assert [{"commands.gate.keep_build", message}] =
               base_map() |> put_gate("keep_build", bad) |> messages()

      assert message =~ inspect(bad)
      assert message =~ "non-empty list"
    end
  end

  test "warm_start that is not true or false is refused, quoting the value" do
    for bad <- ["no", 0, [], "false"] do
      assert [{"commands.gate.warm_start", message}] =
               base_map() |> put_gate("warm_start", bad) |> messages()

      assert message =~ inspect(bad)
      assert message =~ "must be true or false"
    end
  end

  test "either key on a state or under defaults is refused as an unknown key" do
    for key <- ["keep_build", "warm_start"] do
      on_state = put_in(base_map(), ["states", "building", key], [0])
      assert [{"states.building." <> ^key, "unknown key"}] = messages(on_state)

      under_defaults = Map.put(base_map(), "defaults", %{key => [0]})
      assert [{"defaults." <> ^key, "unknown key"}] = messages(under_defaults)
    end
  end
end
