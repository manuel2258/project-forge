defmodule ForgeWorker.Job.DirTest do
  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Dir

  setup do
    %{root: tmp_dir("dir"), spec: spec()}
  end

  test "prepare/2 lays out spec, read-only inputs and an empty out", %{root: root, spec: spec} do
    job_dir = Dir.prepare(root, spec)

    assert job_dir == Path.join(root, spec.job_id)

    assert {:ok, decoded} =
             job_dir |> Path.join("spec.json") |> File.read!() |> ForgeCore.Job.Spec.from_json()

    assert decoded == spec
    assert File.read!(Path.join([job_dir, "inputs", "ticket"])) == "Scores vanish on restart."

    assert Bitwise.band(File.stat!(Path.join([job_dir, "inputs", "ticket"])).mode, 0o777) == 0o444

    assert File.ls!(Path.join(job_dir, "out")) == []
  end

  test "prepare/2 on an existing job keeps out/ and refuses non-UUID ids", %{
    root: root,
    spec: spec
  } do
    job_dir = Dir.prepare(root, spec)
    File.write!(Path.join([job_dir, "out", "plan.md"]), "kept")
    File.write!(Path.join([job_dir, "inputs", "stale"]), "gone")

    assert Dir.prepare(root, spec) == job_dir
    assert File.read!(Path.join([job_dir, "out", "plan.md"])) == "kept"
    refute File.exists?(Path.join([job_dir, "inputs", "stale"]))
    assert File.dir?(Dir.home_dir(job_dir))

    assert_raise ArgumentError, ~r/UUID/, fn ->
      Dir.prepare(root, %{spec | job_id: "../escape"})
    end
  end

  test "collect/2 rejects outputs that are not regular files", %{root: root, spec: spec} do
    job_dir = Dir.prepare(root, spec)
    File.mkdir_p!(Path.join([job_dir, "out", "plan.md"]))

    assert %{
             invalid: %{"plan.md" => [%{message: "output must be a regular file, got directory"}]}
           } =
             Dir.collect(job_dir, spec)
  end

  test "collect/2 sorts outputs into documents, invalid, missing and undeclared", %{
    root: root,
    spec: spec
  } do
    job_dir = Dir.prepare(root, spec)

    assert %{documents: %{}, invalid: %{}, missing: ["plan.md"], undeclared: []} =
             Dir.collect(job_dir, spec)

    File.write!(Path.join([job_dir, "out", "plan.md"]), "---\noutcome: done\n---\n# Plan\n")
    File.write!(Path.join([job_dir, "out", "extra.md"]), "x")

    assert %{
             documents: %{"plan.md" => %ForgeCore.Document{outcome: "done"}},
             missing: [],
             undeclared: ["extra.md"]
           } = Dir.collect(job_dir, spec)

    File.write!(Path.join([job_dir, "out", "plan.md"]), "---\noutcome: done\n")
    assert %{documents: %{}, invalid: %{"plan.md" => [_]}} = Dir.collect(job_dir, spec)
  end
end
