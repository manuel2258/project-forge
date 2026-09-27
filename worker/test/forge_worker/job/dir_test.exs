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

  # A reopened conversation's past arrives in its spec and is laid out as a file the manifest
  # names. Read-only, like every other thing the platform hands the agent to read.
  test "prepare/3 writes what a reopened conversation already said", %{root: root, spec: spec} do
    job_dir = Dir.prepare(root, %{spec | replay: "# The conversation so far\n\nhello\n"})
    path = Path.join(job_dir, "conversation.md")

    assert File.read!(path) == "# The conversation so far\n\nhello\n"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o444
  end

  # The directory is keyed by job id and outlives a process, so the file from one start is still
  # there at the next. A start with no past must not inherit one — and a later reopen must be
  # able to replace the read-only file the last one left.
  test "prepare/3 leaves no conversation behind that the spec does not carry", %{
    root: root,
    spec: spec
  } do
    job_dir = Dir.prepare(root, %{spec | replay: "the first time\n"})
    assert Dir.prepare(root, %{spec | replay: "the second time\n"}) == job_dir
    assert File.read!(Path.join(job_dir, "conversation.md")) == "the second time\n"

    Dir.prepare(root, spec)
    refute File.exists?(Path.join(job_dir, "conversation.md"))
  end

  test "prepare/2 refuses a job id that is not a UUID", %{root: root, spec: spec} do
    assert_raise ArgumentError, ~r/UUID/, fn ->
      Dir.prepare(root, %{spec | job_id: "../escape"})
    end
  end

  # The agent owns the job directory, so `out` itself is its to replace, and a path through a
  # link to a directory it cannot read would have this process — the more privileged user — read
  # it on the agent's behalf. What is read is decided by the file opened, not by the path.
  describe "what the agent may arrange under out/" do
    setup %{root: root, spec: spec} do
      job_dir = Dir.prepare(root, spec)
      out = Path.join(job_dir, "out")

      elsewhere = tmp_dir("elsewhere")
      File.write!(Path.join(elsewhere, "plan.md"), "# Somebody else's\n")
      File.write!(Path.join(elsewhere, "id_ed25519"), "-----BEGIN OPENSSH PRIVATE KEY-----\n")

      %{job_dir: job_dir, out: out, elsewhere: elsewhere, owner: File.lstat!(job_dir).uid}
    end

    test "out/ replaced by a link is not listed, for a job or a conversation", context do
      %{job_dir: job_dir, out: out, elsewhere: elsewhere, spec: spec} = context
      File.rm_rf!(out)
      File.ln_s!(elsewhere, out)

      assert Dir.documents(job_dir) == %{documents: %{}, invalid_documents: %{}}

      collected = Dir.collect(job_dir, spec)
      assert collected.documents == %{}
      assert "plan.md" in collected.missing
    end

    test "out/proposals replaced by a link is refused, and nothing in it is read", context do
      %{job_dir: job_dir, out: out, elsewhere: elsewhere} = context
      File.ln_s!(elsewhere, Path.join(out, "proposals"))

      assert %{proposals: proposals, invalid_proposals: invalid} = Dir.proposals(job_dir)
      assert proposals == %{}
      assert Map.keys(invalid) == ["proposals"]
      assert invalid["proposals"]["reason"] =~ "must be a directory, not a symlink"
      assert invalid["proposals"]["raw"] == nil
    end

    # What the handle says is the rule, so a file that is not the job's own is refused however
    # the path to it was arranged — a link swapped in after the check, a directory swapped under
    # it. A second Unix user is what would make one for real; naming another owner is the same
    # question asked the other way round.
    test "a file the job does not own is refused, wherever it is", context do
      %{job_dir: job_dir, out: out, spec: spec, owner: owner} = context
      File.write!(Path.join(out, "plan.md"), "---\noutcome: done\n---\n# Plan\n")
      File.mkdir_p!(Path.join(out, "proposals"))

      File.write!(
        Path.join([out, "proposals", "p.md"]),
        "# A proposal\n\nBecause it is needed.\n"
      )

      stranger = owner + 1

      assert %{invalid_documents: %{"plan.md" => reason}} = Dir.documents(job_dir, stranger)
      assert reason =~ "the job's own file"

      assert %{invalid_proposals: %{"p.md" => %{"reason" => reason, "raw" => nil}}} =
               Dir.proposals(job_dir, stranger)

      assert reason =~ "the job's own file"

      assert %{invalid: %{"plan.md" => [%{message: message}]}} =
               Dir.collect(job_dir, spec, stranger)

      assert message =~ "the job's own file"

      # And the job's own owner reads all three, which is what makes the refusal about the owner.
      assert %{documents: %{"plan.md" => _}} = Dir.documents(job_dir, owner)
      assert %{proposals: %{"p.md" => _}} = Dir.proposals(job_dir, owner)
      assert %{documents: %{"plan.md" => _}} = Dir.collect(job_dir, spec, owner)
    end

    test "a document larger than a mebibyte is refused where it is read", context do
      %{job_dir: job_dir, out: out} = context
      File.write!(Path.join(out, "big.md"), String.duplicate("a", 1024 * 1024 + 1))
      File.write!(Path.join(out, "fits.md"), String.duplicate("a", 1024 * 1024))

      assert %{documents: %{"fits.md" => _}, invalid_documents: %{"big.md" => reason}} =
               Dir.documents(job_dir)

      assert reason =~ "no larger than 1024 KiB"
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

  # A conversation declares nothing, so every file it leaves in `out/` is a document it means to
  # keep — held to a workflow job's rules where they apply. `docs/design/conversations.md`
  # § Commits.
  describe "a conversation's documents in out/" do
    setup do
      job_dir = Dir.prepare(tmp_dir("documents"), spec())
      %{job_dir: job_dir, out: Path.join(job_dir, "out")}
    end

    test "every file is one, as the text the agent wrote, and proposals are not", %{
      job_dir: job_dir,
      out: out
    } do
      File.write!(Path.join(out, "notes.md"), "# Notes\n\nWhat we found.\n")
      File.write!(Path.join(out, "plan.md"), "---\noutcome: done\n---\n# Plan\n")
      File.mkdir_p!(Path.join(out, "proposals"))
      File.write!(Path.join([out, "proposals", "p.md"]), "# A proposal\n")

      assert Dir.documents(job_dir) == %{
               documents: %{
                 "notes.md" => "# Notes\n\nWhat we found.\n",
                 "plan.md" => "---\noutcome: done\n---\n# Plan\n"
               },
               invalid_documents: %{}
             }
    end

    # Each of these is a row or a file the platform owns, and a document under the name would be
    # a new version of the ticket's body, its answers or its changeset, or a document passing
    # itself off as a proposal. Refused by name, before anything is read.
    test "a name the platform keeps, or one that is not a name, is refused with why", %{
      job_dir: job_dir,
      out: out
    } do
      for name <- ["ticket", "answers.md", "changeset", "proposal-x.md", ".hidden"] do
        File.write!(Path.join(out, name), "# A document\n")
      end

      %{documents: documents, invalid_documents: invalid} = Dir.documents(job_dir)

      assert documents == %{}
      assert invalid["ticket"] =~ "reserved"
      assert invalid["answers.md"] =~ "reserved"
      assert invalid["changeset"] =~ "reserved"
      assert invalid["proposal-x.md"] =~ "reserved for ticket proposals"
      assert invalid[".hidden"] =~ "single path segment"
    end

    # The worker manager is a more privileged user than the agent: a link would have it read a
    # file the agent cannot, and publish it as a document.
    test "a symlink or a directory is refused, not followed", %{job_dir: job_dir, out: out} do
      secret = Path.join(tmp_dir("secret-chat"), "key")
      File.write!(secret, "BEGIN PRIVATE KEY")
      File.ln_s!(secret, Path.join(out, "leak.md"))
      File.mkdir_p!(Path.join(out, "folder.md"))

      %{documents: documents, invalid_documents: invalid} = Dir.documents(job_dir)

      assert documents == %{}
      assert invalid["leak.md"] =~ "symlink"
      assert invalid["folder.md"] =~ "directory"
    end

    # Opening a FIFO blocks until something writes to it, and the agent can make one. The lstat
    # in front of the open is what keeps a turn from hanging on it for ever; run in a task with a
    # deadline, so a regression fails here rather than hanging the suite.
    test "a FIFO is refused without being opened", %{job_dir: job_dir, out: out} do
      fifo = Path.join(out, "pipe.md")
      {_output, 0} = System.cmd("mkfifo", [fifo])

      task = Task.async(fn -> Dir.documents(job_dir) end)

      assert {:ok, %{documents: documents, invalid_documents: invalid}} =
               Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

      assert documents == %{}
      assert invalid["pipe.md"] =~ "must be a regular file"
    end

    # An empty file is a document with nothing in it, not an unreadable one: `:file.read/2` says
    # `:eof` rather than handing back no bytes.
    test "an empty file is an empty document", %{job_dir: job_dir, out: out} do
      File.touch!(Path.join(out, "notes.md"))

      assert %{documents: %{"notes.md" => ""}, invalid_documents: invalid} =
               Dir.documents(job_dir)

      assert invalid == %{}
    end

    test "bytes that are not text are refused", %{job_dir: job_dir, out: out} do
      File.write!(Path.join(out, "image.md"), <<0x89, ?P, ?N, ?G, 0xFF>>)
      File.write!(Path.join(out, "nul.md"), "# Notes\n" <> <<0>>)

      %{documents: documents, invalid_documents: invalid} = Dir.documents(job_dir)

      assert documents == %{}
      assert invalid["image.md"] =~ "UTF-8 text"
      assert invalid["nul.md"] =~ "UTF-8 text"
    end

    test "a directory with no out/ at all has written nothing", %{job_dir: job_dir, out: out} do
      File.rm_rf!(out)

      assert Dir.documents(job_dir) == %{documents: %{}, invalid_documents: %{}}
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

    # Bytes that are not UTF-8 cannot be encoded into the JSON the result travels in, so one
    # such file took the whole result down with it — outcome, cost and every other document —
    # and the worker re-sent it for ever. Refused where it is read instead, in both readers.
    test "a declared output or a proposal that is not text is refused where it is read" do
      root = tmp_dir("not-text")
      spec = spec()
      job_dir = Dir.prepare(root, spec)
      File.write!(Path.join([job_dir, "out", "plan.md"]), <<"---\noutcome: done\n---\n", 0xFF>>)
      File.mkdir_p!(Path.join([job_dir, "out", "proposals"]))
      File.write!(Path.join([job_dir, "out", "proposals", "nul.md"]), "# Title\n\n" <> <<0>>)

      collected = Dir.collect(job_dir, spec)

      assert %{documents: %{}, invalid: %{"plan.md" => [error]}} = collected
      assert error.message =~ "UTF-8 text"
      assert collected.invalid_proposals["nul.md"]["reason"] =~ "UTF-8 text"
      # Nothing of it is carried, because nothing of it could be.
      assert collected.invalid_proposals["nul.md"]["raw"] == nil
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

  # `docs/design/commands.md` § How an agent invokes: read like `out/`, then removed.
  describe "invoke.json" do
    setup %{root: root, spec: spec} do
      job_dir = Dir.prepare(root, spec)
      %{job_dir: job_dir, path: Dir.invoke_path(job_dir), owner: File.stat!(job_dir).uid}
    end

    test "is nothing when the agent asked for nothing", %{job_dir: job_dir} do
      assert Dir.invocations(job_dir) == :none
    end

    test "is read once, then gone", %{job_dir: job_dir, path: path} do
      File.write!(path, ~s([{"command": "build", "args": ["--release"]}, {"command": "test"}]))

      assert Dir.invocations(job_dir) ==
               {:ok,
                [
                  %{"command" => "build", "args" => ["--release"]},
                  %{"command" => "test", "args" => []}
                ]}

      refute File.exists?(path)
      assert Dir.invocations(job_dir) == :none
    end

    test "that is not a list of invocations says why, and is gone too", %{
      job_dir: job_dir,
      path: path
    } do
      for {content, why} <- [
            {"not json", "invoke.json is not valid JSON"},
            {"[]", "invoke.json must be a non-empty JSON array"},
            {~s({"command": "build"}), "invoke.json must be a non-empty JSON array"},
            {~s([{"args": []}]), "invoke.json has an entry with no command name"},
            {~s([{"command": ""}]), "invoke.json has an entry with no command name"},
            {~s([{"command": "t", "args": [1]}]),
             "invoke.json has arguments that are not strings"},
            {~s([{"command": "t", "args": "x"}]), "invoke.json has args that are not a list"}
          ] do
        File.write!(path, content)
        assert {:error, reason} = Dir.invocations(job_dir)
        assert String.starts_with?(reason, why), "#{content}: #{reason}"
        refute File.exists?(path)
      end
    end

    # The same model as `out/`: what is read is the file the handle opened, owned by the job.
    test "a file the job does not own, or a link, is refused", %{
      job_dir: job_dir,
      path: path,
      owner: owner
    } do
      File.write!(path, ~s([{"command": "build"}]))
      assert {:error, reason} = Dir.invocations(job_dir, owner + 1)
      assert reason =~ "the job's own file"

      target = Path.join(job_dir, "elsewhere.json")
      File.write!(target, ~s([{"command": "build"}]))
      File.ln_s!(target, path)
      assert {:error, reason} = Dir.invocations(job_dir)
      assert reason =~ "regular file"
    end

    test "a request left from the run that parked is gone before the next one starts", %{
      root: root,
      spec: spec,
      path: path
    } do
      File.write!(path, ~s([{"command": "build"}]))
      Dir.prepare(root, spec, resume: true)
      refute File.exists?(path)
    end
  end

  describe "the command logs folder" do
    test "holds a resumed run's logs, read-only, and nothing named off the pattern", %{
      root: root,
      spec: spec
    } do
      source = Path.join(tmp_dir("logs"), "log")
      File.write!(source, "ok\n")

      job_dir =
        Dir.prepare(root, spec,
          command_logs: [
            {"1-build.log", source},
            {"../escape.log", source},
            {"1-../../escape.log", source},
            {"2-test.txt", source}
          ]
        )

      assert File.ls!(Path.join(job_dir, "commands")) == ["1-build.log"]
      assert File.read!(Path.join([job_dir, "commands", "1-build.log"])) == "ok\n"

      log = Path.join([job_dir, "commands", "1-build.log"])
      assert Bitwise.band(File.stat!(log).mode, 0o777) == 0o444
    end

    test "is gone when the run has none, so an old log is never read as new", %{
      root: root,
      spec: spec
    } do
      source = Path.join(tmp_dir("logs"), "log")
      File.write!(source, "old\n")
      job_dir = Dir.prepare(root, spec, command_logs: [{"1-build.log", source}])
      Dir.prepare(root, spec, resume: true)
      refute File.exists?(Path.join(job_dir, "commands"))
    end
  end

  # `docs/design/job-prompt.md` § Groups of files: staged through the guarded read, capped, and
  # refused with why rather than dropped.
  describe "stage_groups/4" do
    setup %{root: root, spec: spec} do
      job_dir = Dir.prepare(root, spec)
      shots = Path.join([job_dir, "out", "shots"])
      File.mkdir_p!(shots)

      %{
        job_dir: job_dir,
        shots: shots,
        staging: tmp_dir("staging"),
        owner: File.stat!(job_dir).uid
      }
    end

    defp stage(job_dir, staging, opts \\ []) do
      Dir.stage_groups(
        job_dir,
        Keyword.get(opts, :groups, ["shots"]),
        staging,
        Keyword.merge([max_bytes: 1024, max_files: 3], opts)
      )
    end

    test "copies each file out, bytes and all, named as its artifact", context do
      File.write!(Path.join(context.shots, "home.png"), <<137, 80, 78, 71, 0, 255>>)
      File.write!(Path.join(context.shots, "menu.png"), "menu")

      assert %{staged: [{"shots/home.png", home}, {"shots/menu.png", menu}], invalid: %{}} =
               stage(context.job_dir, context.staging)

      assert File.read!(home) == <<137, 80, 78, 71, 0, 255>>
      assert File.read!(menu) == "menu"
      assert String.starts_with?(home, context.staging)
    end

    test "a group with nothing in it, or no directory at all, keeps nothing", context do
      assert stage(context.job_dir, context.staging) == %{staged: [], invalid: %{}}

      assert stage(context.job_dir, context.staging, groups: ["absent"]) == %{
               staged: [],
               invalid: %{}
             }
    end

    test "refuses what it cannot keep, with why, and keeps the rest", context do
      File.write!(Path.join(context.shots, "a.png"), "ok")
      File.write!(Path.join(context.shots, "b.bin"), String.duplicate("x", 2048))
      File.write!(Path.join(context.shots, ".hidden"), "x")
      File.mkdir_p!(Path.join(context.shots, "nested"))
      File.ln_s!("/etc/hostname", Path.join(context.shots, "link"))

      assert %{staged: [{"shots/a.png", _path}], invalid: invalid} =
               stage(context.job_dir, context.staging, max_files: 10)

      assert invalid["shots/b.bin"] == "is larger than 1024 bytes"
      assert invalid["shots/.hidden"] =~ "is not a name"
      assert invalid["shots/nested"] =~ "must be a regular file, got directory"
      assert invalid["shots/link"] =~ "must be a regular file, got symlink"
    end

    test "keeps no more than the count, in name order", context do
      for name <- ~w(a b c d e), do: File.write!(Path.join(context.shots, name), name)

      assert %{staged: staged, invalid: invalid} = stage(context.job_dir, context.staging)
      assert Enum.map(staged, &elem(&1, 0)) == ["shots/a", "shots/b", "shots/c"]
      assert Map.keys(invalid) == ["shots/d", "shots/e"]
      assert invalid["shots/d"] =~ "one more than the 3 files"
    end

    test "a file the job does not own is refused", context do
      File.write!(Path.join(context.shots, "a.png"), "ok")

      assert %{staged: [], invalid: %{"shots/a.png" => reason}} =
               stage(context.job_dir, context.staging, owner: context.owner + 1)

      assert reason =~ "the job's own file"
    end

    # Not listed through a link: that would name the files of a directory the job cannot read.
    test "a group's directory that is a link is reported, not followed", context do
      elsewhere = tmp_dir("elsewhere")
      File.write!(Path.join(elsewhere, "secret.png"), "not the job's")
      File.rm_rf!(context.shots)
      File.ln_s!(elsewhere, context.shots)

      assert %{staged: [], invalid: %{"shots/*" => "must be a directory, not a symlink"}} =
               stage(context.job_dir, context.staging)
    end

    test "a group's name standing for a file, not a directory, is reported", context do
      File.rm_rf!(context.shots)
      File.write!(context.shots, "not a directory")

      assert %{staged: [], invalid: %{"shots/*" => "must be a directory, not a file"}} =
               stage(context.job_dir, context.staging)
    end

    test "a declared group's directory is not an undeclared output", %{root: root} do
      spec = spec(%{produces: ["plan.md", "shots/*"]})
      job_dir = Dir.prepare(root, spec)
      File.mkdir_p!(Path.join([job_dir, "out", "shots"]))
      File.write!(Path.join([job_dir, "out", "plan.md"]), "---\noutcome: done\n---\n# P\n")

      assert %{undeclared: []} = Dir.collect(job_dir, spec)
    end
  end
end
