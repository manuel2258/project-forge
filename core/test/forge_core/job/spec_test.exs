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

  test "knows its outcome document and document outputs" do
    assert Spec.outcome_document(spec()) == "plan.md"
    assert Spec.document_outputs(spec()) == ["plan.md"]
    assert Spec.outcome_document(%{spec() | produces: ["changeset"]}) == nil
  end
end
