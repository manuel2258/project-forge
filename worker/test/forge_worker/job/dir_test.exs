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

  test "prepare/3 on a resume keeps what the job already produced", %{root: root, spec: spec} do
    job_dir = Dir.prepare(root, spec)
    File.write!(Path.join([job_dir, "out", "plan.md"]), "kept")
    File.write!(Path.join([job_dir, "inputs", "stale"]), "gone")

    assert Dir.prepare(root, spec, resume: true) == job_dir
    assert File.read!(Path.join([job_dir, "out", "plan.md"])) == "kept"
    refute File.exists?(Path.join([job_dir, "inputs", "stale"]))
    assert File.dir?(Dir.home_dir(job_dir))
  end

  # A job re-queued after its node died starts the harness cold, with no session to resume.
  # Whatever the dead run left in out/ was not written by this run, and `collect/2` would
  # otherwise read it and decide an outcome on it.
  test "prepare/3 on a cold start discards out/ from a dead run", %{root: root, spec: spec} do
    job_dir = Dir.prepare(root, spec)
    File.write!(Path.join([job_dir, "out", "plan.md"]), "written by the run that was killed")

    assert Dir.prepare(root, spec) == job_dir
    assert File.ls!(Path.join(job_dir, "out")) == []
    assert File.dir?(Dir.home_dir(job_dir))
  end

  test "prepare/2 refuses a job id that is not a UUID", %{root: root, spec: spec} do
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

  describe "sweep/2" do
    @tag :tmp_dir
    test "removes what nothing has touched, and keeps what something has", %{tmp_dir: tmp_dir} do
      old = Path.join(tmp_dir, "11111111-1111-1111-1111-111111111111")
      recent = Path.join(tmp_dir, "22222222-2222-2222-2222-222222222222")
      File.mkdir_p!(Path.join(old, "home"))
      File.mkdir_p!(Path.join(recent, "home"))

      # A week and a day ago, as the filesystem sees it.
      long_ago = System.os_time(:second) - 8 * 24 * 60 * 60
      File.touch!(old, long_ago)

      assert Dir.sweep(tmp_dir, 7 * 24 * 60 * 60 * 1000) == 1
      refute File.exists?(old)
      assert File.dir?(recent)
    end

    @tag :tmp_dir
    test "a root that is not there yet is not an error", %{tmp_dir: tmp_dir} do
      assert Dir.sweep(Path.join(tmp_dir, "no-jobs-have-run"), 1000) == 0
    end
  end

  describe "the platform folder" do
    # Every job and every conversation gets it. On disk rather than in the prompt: the prompt
    # names the folder, so an agent reads it when the machinery is the question and pays nothing
    # for it when it is not.
    test "is written for every job, read-only" do
      root = tmp_dir("root")
      job_dir = Dir.prepare(root, spec())

      platform = Path.join(job_dir, "platform")
      assert File.read!(Path.join(platform, "platform.md")) =~ "The platform you are running on"
      assert File.read!(Path.join(platform, "workflow-grammar.md")) =~ "Workflow grammar"

      # What a workflow may contain is the thing a conversation asked to bootstrap needs, and it
      # is the design note itself rather than a copy of it.
      assert File.read!(Path.join(platform, "workflow-grammar.md")) =~ ".forge/workflow.yml"

      %File.Stat{mode: mode} = File.stat!(Path.join(platform, "platform.md"))
      assert Bitwise.band(mode, 0o222) == 0
    end

    # A resumed run gets the current documents, not the ones its first attempt was handed.
    test "is rewritten on a resume" do
      root = tmp_dir("root")
      spec = spec()
      job_dir = Dir.prepare(root, spec)

      path = Path.join([job_dir, "platform", "platform.md"])
      File.chmod!(path, 0o644)
      File.write!(path, "stale")

      Dir.prepare(root, spec, resume: true)

      assert File.read!(path) =~ "The platform you are running on"
    end
  end
end
