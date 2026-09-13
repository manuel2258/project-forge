defmodule ForgeCore.Job.EventTest do
  use ExUnit.Case, async: true

  alias ForgeCore.Job.Event

  test "an event from the wire looks like one that never left" do
    event = %{type: "tool_use", payload: %{"name" => "Edit", "path" => "lib/a.ex"}}

    assert {:ok, ^event} =
             event |> Event.to_map() |> Jason.encode!() |> Jason.decode!() |> Event.from_map()
  end

  test "a missing payload is an empty one" do
    assert {:ok, %{type: "finished", payload: %{}}} = Event.from_map(%{"type" => "finished"})
  end

  test "an event with no type has nowhere to go" do
    assert :error = Event.from_map(%{"payload" => %{}})
    assert :error = Event.from_map(%{"type" => ""})
    assert :error = Event.from_map(%{"type" => "ok", "payload" => "not a map"})
    assert :error = Event.from_map("not an event")
  end
end
