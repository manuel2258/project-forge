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

  describe "the backlog folder" do
    defp backlog do
      %{
        "index" => "| 12 | implementing | active | Scores vanish |\n",
        "tickets" => [%{"file" => "12.md", "content" => "# Scores vanish\n\nOn restart.\n"}],
        "proposals" => [%{"file" => "p1.md", "content" => "# Extract the table\n\nWhy.\n"}]
      }
    end

    test "is written for any job that is handed one, read-only" do
      root = tmp_dir("backlog")
      job_dir = Dir.prepare(root, spec(), backlog: backlog())
      dir = Path.join(job_dir, "tickets")

      assert File.read!(Path.join(dir, "index.md")) =~ "Scores vanish"
      assert File.read!(Path.join(dir, "12.md")) =~ "On restart."
      assert File.read!(Path.join([dir, "proposals", "p1.md"])) =~ "Extract the table"

      # Read-only like `inputs/`: it is the platform's account of the project, not the agent's
      # to edit, and an edit that looked as though it worked would be lost in silence.
      for path <- [Path.join(dir, "index.md"), Path.join(dir, "12.md")] do
        assert Bitwise.band(File.stat!(path).mode, 0o222) == 0
      end
    end

    test "is absent when the platform sent none" do
      root = tmp_dir("backlog-none")
      job_dir = Dir.prepare(root, spec())

      refute File.exists?(Path.join(job_dir, "tickets"))
    end

    # A ticket accepted, merged or renumbered between two runs of the same job would otherwise
    # leave a file behind saying it is still open — worse than having no folder at all.
    test "is rewritten whole, so a stale ticket never survives a resume" do
      root = tmp_dir("backlog-stale")
      spec = spec()
      job_dir = Dir.prepare(root, spec, backlog: backlog())
      assert File.exists?(Path.join([job_dir, "tickets", "12.md"]))

      Dir.prepare(root, spec,
        resume: true,
        backlog: %{"index" => "nothing open\n", "tickets" => [], "proposals" => []}
      )

      refute File.exists?(Path.join([job_dir, "tickets", "12.md"]))
      assert File.read!(Path.join([job_dir, "tickets", "index.md"])) == "nothing open\n"
    end

    # `prepare/3` runs in `Runner.init/1`, so a raise here is a job that never starts — and the
    # backlog is recomposed identically on every assignment, so it would never start again. The
    # job matters and the context does not.
    test "a name the filesystem refuses costs the job nothing" do
      root = tmp_dir("backlog-toolong")
      too_long = String.duplicate("a", 300) <> ".md"

      job_dir =
        Dir.prepare(root, spec(),
          backlog: %{
            "index" => "i",
            "tickets" => [%{"file" => too_long, "content" => "nope"}]
          }
        )

      assert File.dir?(job_dir)
      assert File.exists?(Path.join(job_dir, "spec.json"))
    end

    # The file name arrives over the channel, so it is checked with the same model the write
    # uses. A traversal must leave nothing outside the folder and must not take the rest of the
    # backlog down with it.
    test "refuses a file name that leaves the folder, and writes the rest" do
      root = tmp_dir("backlog-escape")

      job_dir =
        Dir.prepare(root, spec(),
          backlog: %{
            "index" => "i",
            "tickets" => [
              %{"file" => "../../escaped.md", "content" => "nope"},
              %{"file" => "nested/deep.md", "content" => "nope"},
              %{"file" => "9.md", "content" => "fine"}
            ]
          }
        )

      assert File.read!(Path.join([job_dir, "tickets", "9.md"])) == "fine"
      refute File.exists?(Path.join(root, "escaped.md"))
      refute File.exists?(Path.expand(Path.join(job_dir, "../../escaped.md")))
      refute File.exists?(Path.join([job_dir, "tickets", "nested", "deep.md"]))
    end

    test "refuses an entry with no file name, and writes the rest" do
      root = tmp_dir("backlog-nameless")

      job_dir =
        Dir.prepare(root, spec(),
          backlog: %{
            "index" => "i",
            "tickets" => [%{"content" => "orphan"}, %{"file" => "9.md", "content" => "fine"}]
          }
        )

      assert File.ls!(Path.join(job_dir, "tickets")) |> Enum.sort() == ["9.md", "index.md"]
    end
  end

  describe "proposals in out/" do
    test "are read, and the reserved directory is never an undeclared output" do
      root = tmp_dir("proposals")
      spec = spec()
      job_dir = Dir.prepare(root, spec)
      dir = Path.join([job_dir, "out", "proposals"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "score-table.md"), "# Extract the score table\n\nBecause.")

      collected = Dir.collect(job_dir, spec)

      assert %{"score-table.md" => %ForgeCore.Proposal{title: "Extract the score table"}} =
               collected.proposals

      # The load-bearing half: an undeclared output ends the job with `error`, so a job that
      # proposed anything would fail for having done so.
      assert collected.undeclared == []
    end

    test "that cannot be read are reported with a reason rather than dropped" do
      root = tmp_dir("proposals-bad")
      spec = spec()
      job_dir = Dir.prepare(root, spec)
      dir = Path.join([job_dir, "out", "proposals"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "half.md"), "no heading here")
      File.mkdir_p!(Path.join(dir, "a-directory.md"))

      collected = Dir.collect(job_dir, spec)

      assert collected.proposals == %{}
      assert collected.invalid_proposals["half.md"]["reason"] =~ "level-one heading"
      assert collected.invalid_proposals["a-directory.md"]["reason"] =~ "regular file"

      # The text goes with the reason, so the platform can keep what the agent wrote rather than
      # only what was wrong with it. A directory has no text, and says so with nil.
      assert collected.invalid_proposals["half.md"]["raw"] == "no heading here"
      assert collected.invalid_proposals["a-directory.md"]["raw"] == nil
    end

    # `File.stat/2` follows symlinks and this runs in the worker manager, a more privileged uid
    # than the agent's transient user — so a symlink would have the platform read a file the
    # agent cannot, and publish it into an artifact and every later backlog.
    test "a symlink is refused, not followed" do
      root = tmp_dir("proposals-symlink")
      spec = spec()
      job_dir = Dir.prepare(root, spec)
      dir = Path.join([job_dir, "out", "proposals"])
      File.mkdir_p!(dir)

      secret = Path.join(tmp_dir("secret"), "key")
      File.write!(secret, "# worker credential\n\nBEGIN PRIVATE KEY")
      File.ln_s!(secret, Path.join(dir, "leak.md"))

      collected = Dir.collect(job_dir, spec)

      assert collected.proposals == %{}
      assert collected.invalid_proposals["leak.md"]["reason"] =~ "symlink"
      # Nothing of the target is carried, which is the point of refusing it.
      assert collected.invalid_proposals["leak.md"]["raw"] == nil
    end

    # The same trap, in the reader that has had it since before proposals existed.
    test "a symlinked declared output is refused too" do
      root = tmp_dir("document-symlink")
      spec = spec()
      job_dir = Dir.prepare(root, spec)

      secret = Path.join(tmp_dir("secret-doc"), "key")
      File.write!(secret, "---\noutcome: done\n---\n# Not the agent's to read\n")
      File.ln_s!(secret, Path.join([job_dir, "out", "plan.md"]))

      assert %{documents: %{}, invalid: %{"plan.md" => [error]}} = Dir.collect(job_dir, spec)
      assert error.message =~ "symlink"
    end

    test "a job that proposed nothing reports none, and is otherwise ordinary" do
      root = tmp_dir("proposals-none")
      spec = spec()
      job_dir = Dir.prepare(root, spec)

      assert %{proposals: %{}, invalid_proposals: %{}, undeclared: []} =
               Dir.collect(job_dir, spec)
    end

    test "a regular file where the directory should be is reported, not mistaken for one" do
      root = tmp_dir("proposals-file")
      spec = spec()
      job_dir = Dir.prepare(root, spec)
      File.write!(Path.join([job_dir, "out", "proposals"]), "not a directory")

      collected = Dir.collect(job_dir, spec)

      assert collected.invalid_proposals["proposals"]["reason"] =~ "must be a directory"
      assert collected.undeclared == []
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
