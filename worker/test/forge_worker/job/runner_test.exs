defmodule ForgeWorker.Job.RunnerTest.RecordingSlice do
  @moduledoc "A slice that only reports what it was asked to make, and runs the command as it is."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts) do
    send(opts.reply_to, {:slice_prepared, opts})
    {:ok, opts}
  end

  @impl ForgeWorker.Slice
  def wrap(executable, args, _context), do: {executable, args}

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.RunnerTest.WrapReportingSlice do
  @moduledoc "Reports the command it was asked to confine, and runs it unchanged."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts), do: {:ok, opts}

  @impl ForgeWorker.Slice
  def wrap(executable, args, context) do
    send(context.reply_to, {:wrapped, executable, args})
    {executable, args}
  end

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.RunnerTest.RefusingSlice do
  @moduledoc "A slice that cannot be made: no such user, no cgroup, a systemd that said no."

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(_opts), do: {:error, :no_such_user}

  @impl ForgeWorker.Slice
  def wrap(executable, args, _context), do: {executable, args}

  @impl ForgeWorker.Slice
  def cleanup(_context), do: :ok

  @impl ForgeWorker.Slice
  defdelegate enter(job_id), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate own(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate run_as(owner, executable, args), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate leave(owner, paths), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.Job.RunnerTest do
  use ExUnit.Case, async: true

  alias ForgeWorker.Job.RunnerTest.{RecordingSlice, RefusingSlice, WrapReportingSlice}
  alias ForgeWorker.ScriptedSlice

  import ForgeWorker.Fixtures

  alias ForgeCore.Document.Question
  alias ForgeCore.Job.Result
  alias ForgeWorker.Job.{Dir, Runner}

  setup do
    %{root: tmp_dir("root"), worktree: tmp_dir("worktree")}
  end

  defp run(context, scenario, extra \\ []) do
    test_pid = self()

    opts =
      [
        spec: Keyword.get(extra, :spec, spec()),
        root: context.root,
        worktree: context.worktree,
        sink: fn event -> send(test_pid, {:event, event}) end,
        harness_opts:
          Keyword.get(extra, :harness_opts,
            executable: fake_executable(),
            credential: {:api_key, "secret-key"}
          ),
        # Merged, not appended: a second `:extra_env` key is one `Keyword.get/2` never reads, and a
        # test that passed a secret through it once passed without the secret ever arriving.
        extra_env: [{"FAKE_SCENARIO", scenario} | Keyword.get(extra, :extra_env, [])]
      ] ++ Keyword.drop(extra, [:spec, :harness_opts, :extra_env])

    {:ok, pid} = Runner.start_link(opts)
    pid
  end

  # The job directory a result's run used. Its stderr is kept beside it, in the worker's own.
  defp job_dir(%Result{stderr_path: path}),
    do: path |> Path.dirname() |> String.replace_suffix(".worker", "")

  defp events do
    receive_all([])
  end

  defp receive_all(acc) do
    receive do
      {:event, event} -> receive_all([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "the slice is told the environment the process will need", context do
    pid = run(context, "success", slice: RecordingSlice, slice_opts: %{reply_to: self()})

    assert_receive {:slice_prepared, opts}
    assert {:ok, %Result{}} = Runner.await(pid, 5_000)

    # A slice that starts the process somewhere else — which is what a transient unit is — sees
    # nothing of the runner's own environment, so everything the harness needs has to be here.
    assert opts.worktree == context.worktree
    assert String.starts_with?(opts.job_dir, context.root)
    assert {"HOME", home} = List.keyfind(opts.env, "HOME", 0)
    assert String.starts_with?(home, context.root)
    assert List.keyfind(opts.env, "FORGE_JOB", 0)
    assert List.keyfind(opts.env, "PATH", 0)

    # The credential is not in anything the slice is given, by name or by value: a unit's
    # environment is shown to every user on the machine. It is in the file the process loads, in
    # the worker's own directory, and the file is gone once the process has ended.
    refute List.keyfind(opts.env, "ANTHROPIC_API_KEY", 0)
    refute inspect(opts, limit: :infinity, printable_limit: :infinity) =~ "secret-key"
    assert Path.dirname(opts.secrets_file) == opts.job_dir <> ".worker"
    refute File.exists?(opts.secrets_file)

    # And the harness had it all the same.
    assert File.read!(Path.join(opts.job_dir, "fake-env.txt")) =~ "ANTHROPIC_API_KEY=secret-key"
  end

  test "a successful run converges with the declared outcome and full accounting", context do
    pid = run(context, "success")
    assert {:ok, %Result{} = result} = Runner.await(pid, 5_000)

    assert result.status == :finished
    assert result.outcome == :converged
    assert result.declared_outcome == "done"
    assert result.exit_status == 0
    assert result.killed == nil
    assert %{"plan.md" => %ForgeCore.Document{outcome: "done"}} = result.documents

    assert %{
             "session_id" => "sess-42",
             "model" => "fake-model",
             "turns" => 3,
             "cost_usd" => 0.0421,
             "subtype" => "success"
           } = result.harness

    assert Enum.map(events(), & &1.type) ==
             ~w(job.harness.started job.harness.text job.harness.tool_use job.harness.tool_result job.harness.finished)

    assert result.transcript_path |> File.read!() |> String.split("\n", trim: true) |> length() ==
             5

    assert File.read!(result.stderr_path) =~ "diagnostics on stderr"

    # In the worker's own directory, where the job cannot replace it with a link: the worker reads
    # it back as root, to quote its tail while the harness is starting.
    assert Path.dirname(result.stderr_path) == Dir.worker_dir(job_dir(result))
    refute File.exists?(Path.join(job_dir(result), "stderr.log"))
  end

  test "the harness receives the composed prompt, the credential and the budget flags", context do
    pid = run(context, "success")
    {:ok, result} = Runner.await(pid, 5_000)
    job_dir = job_dir(result)

    prompt = File.read!(Path.join(job_dir, "fake-prompt.txt"))
    assert prompt =~ "# You are one job in a ticket lifecycle"
    assert prompt =~ "Write a plan for the ticket."
    assert prompt =~ "- Job directory: `#{job_dir}`"

    assert File.read!(Path.join(job_dir, "fake-env.txt")) ==
             "ANTHROPIC_API_KEY=secret-key\nCLAUDE_CODE_OAUTH_TOKEN=unset\n"

    assert File.read!(Path.join(job_dir, "fake-args.txt")) =~
             "--max-turns 40 --max-budget-usd 2.00"
  end

  test "the harness sees an allowlisted environment, a private HOME and no worker secrets",
       context do
    System.put_env("FORGE_TEST_LEAK", "must-not-leak")
    on_exit(fn -> System.delete_env("FORGE_TEST_LEAK") end)

    {:ok, result} = context |> run("success") |> Runner.await(5_000)
    job_dir = job_dir(result)
    env = File.read!(Path.join(job_dir, "fake-env-all.txt"))

    refute env =~ "FORGE_TEST_LEAK"
    assert env =~ "HOME=#{Path.join(job_dir, "home")}\n"
    assert env =~ "FORGE_JOB=#{job_dir}\n"
    assert env =~ "PATH="
    assert env =~ "ANTHROPIC_API_KEY=secret-key"
    # Secrets travel through the environment, never through argv.
    refute File.read!(Path.join(job_dir, "fake-args.txt")) =~ "secret-key"
  end

  # The ceiling is the job's to know: an agent that sees exit 137 can only tell it for what it
  # most likely is if it can see the ceiling, and a build that sizes its parallelism by it has to
  # be able to read it. Absent, not zero, when the slice has none.
  test "the harness is told its memory ceiling, and nothing when there is none", context do
    ceiling = 2 * 1024 ** 3
    opts = [slice_opts: %{memory_max: ceiling}]
    {:ok, result} = context |> run("success", opts) |> Runner.await(5_000)
    env = File.read!(Path.join(job_dir(result), "fake-env-all.txt"))
    assert env =~ "FORGE_MEMORY_MAX=#{ceiling}\n"

    {:ok, result} = context |> run("success") |> Runner.await(5_000)
    refute File.read!(Path.join(job_dir(result), "fake-env-all.txt")) =~ "FORGE_MEMORY_MAX"
  end

  test "a credential given as a function is resolved at spawn time", context do
    opts = [harness_opts: [executable: fake_executable(), credential: fn -> {:oauth, "tok"} end]]
    {:ok, result} = context |> run("success", opts) |> Runner.await(5_000)
    job_dir = job_dir(result)

    assert File.read!(Path.join(job_dir, "fake-env.txt")) ==
             "ANTHROPIC_API_KEY=unset\nCLAUDE_CODE_OAUTH_TOKEN=tok\n"
  end

  test "a final line without a newline is still parsed", context do
    {:ok, result} = context |> run("noeol") |> Runner.await(5_000)
    assert result.outcome == :converged
    assert result.harness["subtype"] == "success"
  end

  test "a resumed run keeps earlier outputs and transcripts", context do
    spec = spec()
    {:ok, first} = context |> run("success", spec: spec) |> Runner.await(5_000)
    {:ok, second} = context |> run("noeol", spec: spec) |> Runner.await(5_000)

    assert Path.basename(first.transcript_path) == "transcript-1.jsonl"
    assert Path.basename(second.transcript_path) == "transcript-2.jsonl"
    assert File.exists?(first.transcript_path)
  end

  # The link uploads the transcript by its path, and the job's user owns every name in the job
  # directory: there, it could be a link to a file only the worker may read by the time it is.
  test "the transcript is written where the job cannot reach, not in its directory", context do
    {:ok, result} = context |> run("success") |> Runner.await(5_000)
    job_dir = job_dir(result)

    refute String.starts_with?(result.transcript_path, job_dir <> "/")
    assert Path.dirname(result.transcript_path) == ForgeWorker.Job.Dir.worker_dir(job_dir)
    assert %File.Stat{mode: mode} = File.stat!(Path.dirname(result.transcript_path))
    assert Bitwise.band(mode, 0o777) == 0o700
  end

  test "a declared outcome other than done is reported as such", context do
    {:ok, result} = context |> run("plan_invalid") |> Runner.await(5_000)
    assert {:converged, "plan_invalid"} = {result.outcome, result.declared_outcome}
  end

  test "a blocking question makes the job wait instead of finishing", context do
    {:ok, result} = context |> run("blocking") |> Runner.await(5_000)
    assert result.status == :waiting
    assert [%Question{key: "backend", blocking: true}] = result.questions
    assert result.outcome == nil
  end

  # The run's last window report goes in the result, where the platform reads it to tell a run
  # stopped by its account's limit from one that failed (`docs/design/credentials.md` § A limit
  # reached mid-run). The last one, not the first: the warning before it permitted.
  test "a run stopped by its limit carries the report that stopped it", context do
    {:ok, result} = context |> run("rate_limited") |> Runner.await(5_000)
    assert result.outcome == :error

    assert result.harness["rate_limit"] == %{
             "status" => "rejected",
             "resets_at" => 4_102_444_800,
             "rate_limit_type" => "five_hour"
           }

    {:ok, result} = context |> run("success") |> Runner.await(5_000)
    assert result.harness["rate_limit"] == nil
  end

  test "harness budget stops are budget_exhausted", context do
    {:ok, result} = context |> run("max_turns") |> Runner.await(5_000)
    assert result.outcome == :budget_exhausted
    assert result.exit_status == 1
    assert result.harness["cost_usd"] == 1.5
  end

  # **And the result says which ceiling it was**, because the outcome cannot
  # (`docs/design/capacity.md` § Four exhaustions, three treatments). The two scenarios end in
  # the same outcome from the same code path, so without this the whole distinction could be
  # dropped between the runner and the wire and the suite would stay green.
  test "a budget stop reports which ceiling stopped it, and nothing else does", context do
    {:ok, turns} = context |> run("max_turns") |> Runner.await(5_000)
    assert turns.exhausted == :turns

    {:ok, cost} = context |> run("max_budget") |> Runner.await(5_000)
    assert cost.outcome == :budget_exhausted
    assert cost.exhausted == :cost

    {:ok, converged} = context |> run("success") |> Runner.await(5_000)
    assert converged.outcome == :converged
    assert converged.exhausted == nil
  end

  # A job re-queued after its node died runs again under the same job id, and so in the same
  # job directory. It starts the harness cold, so anything the dead run left in out/ belongs
  # to no run that produced a result, and must not be collected as this run's output.
  test "a cold run does not collect a document left behind by a dead run", context do
    spec = spec()
    seed_output(context.root, spec, "written by the run that was killed")

    {:ok, result} = context |> run("max_turns", spec: spec) |> Runner.await(5_000)

    assert result.documents == %{}
    assert "plan.md" in result.missing
  end

  test "a resumed run keeps the output the earlier attempt produced", context do
    spec = spec()
    seed_output(context.root, spec, "---\noutcome: done\n---\n# Plan\n")

    pid =
      run(context, "max_turns",
        spec: spec,
        harness_opts: [
          executable: fake_executable(),
          credential: {:api_key, "secret-key"},
          resume_session: "sess-42"
        ]
      )

    {:ok, result} = Runner.await(pid, 5_000)

    assert Map.has_key?(result.documents, "plan.md")
    assert result.missing == []
  end

  # The prompt and `--resume` come from the same option, so they cannot disagree: a run that
  # resumes its session is handed what changed, and a cold start the whole prompt. Asserted on
  # what reached the harness — its stdin and its argv — because that is the pair that has to
  # match (`docs/design/job-prompt.md` § The continuation prompt).
  describe "which prompt goes with which invocation" do
    setup do
      answers = %ForgeCore.Job.Spec.Input{
        name: "answers.md",
        version: 2,
        content: "# Answers\n\n## backend\n\nQ: Which backend?\n\nA: sqlite\n"
      }

      spec = spec()
      %{spec: %{spec | inputs: spec.inputs ++ [answers]}}
    end

    test "a run that resumes its session gets the continuation", %{spec: spec} = context do
      pid =
        run(context, "success",
          spec: spec,
          head: "c0ffee",
          harness_opts: [
            executable: fake_executable(),
            credential: {:api_key, "secret-key"},
            resume_session: "sess-42"
          ]
        )

      {:ok, result} = Runner.await(pid, 5_000)
      job_dir = job_dir(result)
      prompt = File.read!(Path.join(job_dir, "fake-prompt.txt"))

      assert File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume sess-42"
      assert String.starts_with?(prompt, "# Continue this job")
      assert prompt =~ "A: sqlite"
      assert prompt =~ "`ticket/7`, at `c0ffee`"
      refute prompt =~ "# You are one job in a ticket lifecycle"

      # And the file the job directory keeps is what the harness was given. The fake reads its
      # stdin with `$(cat)`, which drops the final newline.
      assert File.read!(Path.join(job_dir, "prompt.md")) == prompt <> "\n"
    end

    test "a cold start gets the whole prompt, and no --resume", %{spec: spec} = context do
      {:ok, result} = context |> run("success", spec: spec, head: "c0ffee") |> Runner.await(5_000)
      job_dir = job_dir(result)
      prompt = File.read!(Path.join(job_dir, "fake-prompt.txt"))

      refute File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume"
      assert String.starts_with?(prompt, "# You are one job in a ticket lifecycle")
      refute prompt =~ "# Continue this job"
    end
  end

  defp seed_output(root, spec, content) do
    out = Path.join([root, spec.job_id, "out"])
    File.mkdir_p!(out)
    File.write!(Path.join(out, "plan.md"), content)
  end

  # `docs/design/commands.md` § How an agent invokes.
  describe "an agent that invokes commands" do
    defp invoking_spec,
      do: spec(%{may_invoke: %{"build" => %{"max" => 3}, "test" => %{"max" => 1}}})

    test "parks with what it asked for, and nothing is decided", context do
      pid = run(context, "invokes", spec: invoking_spec())
      assert {:ok, %Result{} = result} = Runner.await(pid, 5_000)

      assert result.status == :parked
      assert result.outcome == nil

      assert result.invocations == [
               %{"command" => "build", "args" => ["--release", "a b"]},
               %{"command" => "test", "args" => []}
             ]

      # Read once: the request has been handed on, and a resume must not find it again.
      assert Path.wildcard(Path.join([context.root, "*", "invoke.json"])) == []
    end

    test "a file that is not a list of invocations is reported, not dropped", context do
      pid = run(context, "invokes_badly", spec: invoking_spec())

      assert {:ok, %Result{status: :parked, invocations: [], invocation_error: reason}} =
               Runner.await(pid, 5_000)

      assert reason =~ "invoke.json must be a non-empty JSON array"
    end

    # A state that may not invoke is never told the file exists; one written anyway is removed
    # and the run ends as if it were not there.
    test "is ignored where the state may not invoke", context do
      pid = run(context, "invokes")
      assert {:ok, %Result{status: :finished, outcome: :converged}} = Runner.await(pid, 5_000)
      assert Path.wildcard(Path.join([context.root, "*", "invoke.json"])) == []
    end

    # A run the harness stopped is over, whatever it asked for.
    test "does not park a run that did not end cleanly", context do
      pid = run(context, "invokes_over_budget", spec: invoking_spec())

      assert {:ok, %Result{status: :finished, outcome: :budget_exhausted}} =
               Runner.await(pid, 5_000)
    end

    # Each half of "clean" on its own: an error flag on a success, and an error subtype without
    # the flag.
    test "does not park a run that errored, whichever way it says so", context do
      for scenario <- ["invokes_is_error", "invokes_error_subtype"] do
        pid = run(context, scenario, spec: invoking_spec())
        assert {:ok, %Result{status: :finished}} = Runner.await(pid, 5_000), scenario
      end
    end

    test "a resumed run finds the logs of what it invoked", context do
      source = Path.join(tmp_dir("logs"), "fetched")
      File.write!(source, "compiled 3 files\n")

      pid =
        run(context, "reads_logs", spec: invoking_spec(), command_logs: [{"1-build.log", source}])

      assert {:ok, %Result{documents: %{"plan.md" => plan}}} = Runner.await(pid, 5_000)
      assert plan.raw =~ "compiled 3 files"
    end
  end

  # `docs/design/job-prompt.md` § Groups of files: a finished run's files are staged for the link.
  describe "a group of files" do
    test "is staged when the run finishes, and a bad name is refused", context do
      spec = spec(%{produces: ["plan.md", "shots/*"]})
      pid = run(context, "shots", spec: spec)

      assert {:ok, %Result{status: :finished, outcome: :converged} = result} =
               Runner.await(pid, 5_000)

      assert %{"shots/home.png" => %{"path" => home}, "shots/menu.png" => %{"path" => _menu}} =
               result.blobs

      assert File.read!(home) == <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1>>
      assert Path.dirname(home) == ForgeWorker.Job.Dir.blobs_dir(job_dir(result))
      assert result.invalid_blobs["shots/.hidden"] =~ "is not a name"
      assert result.undeclared == []
    end

    test "is not staged for a run that parks", context do
      spec = spec(%{produces: ["plan.md", "shots/*"], may_invoke: %{"build" => %{"max" => 1}}})
      pid = run(context, "invokes_with_shots", spec: spec)

      assert {:ok, %Result{status: :parked, blobs: blobs}} = Runner.await(pid, 5_000)
      assert blobs == %{}
    end
  end

  # It said it started, so what went wrong is not that it never did: the reason stays the plain
  # fact, and stderr's last line is not dressed up as the cause.
  test "a crash without a result is an error, and odd lines still become events", context do
    {:ok, result} = context |> run("crash") |> Runner.await(5_000)
    assert result.outcome == :error
    assert result.reason == "harness produced no result message"
    types = Enum.map(events(), & &1.type)
    assert "job.harness.malformed" in types
    assert "job.harness.unknown" in types
  end

  # It never said it started and never said why it ended, so what it wrote to stderr last is the
  # only thing that can (`docs/design/claude-code-events.md` § A harness that never starts).
  test "a harness that exits before it starts says so, with stderr's last line", context do
    {:ok, result} = context |> run("no_start") |> Runner.await(5_000)
    assert result.outcome == :error

    assert result.reason ==
             "the harness exited with status 1 before it started; stderr: some diagnostics on stderr"
  end

  test "a harness that never authenticated says so in the reason", context do
    {:ok, result} = context |> run("unauthenticated") |> Runner.await(5_000)

    # The half that was missing: the parser reads `result` off the message, and the runner used
    # to drop it on the floor when it narrowed the result for `Outcome.decide`. The job then
    # reported "harness result: success" as the reason it failed.
    assert result.outcome == :error
    assert result.reason == "harness error: Not logged in · Please run /login"
    assert result.harness["subtype"] == "success"
    assert result.harness["is_error"] == true
  end

  test "undeclared and invalid outputs are errors", context do
    {:ok, result} =
      context |> run("undeclared", max_corrections: 0) |> Runner.await(5_000)

    assert {:error, "undeclared outputs: notes.md"} = {result.outcome, result.reason}

    {:ok, result} =
      context |> run("invalid_document", max_corrections: 0) |> Runner.await(5_000)

    assert {:error, "invalid documents: plan.md (front_matter: is not closed by a --- line)"} =
             {result.outcome, result.reason}
  end

  # The git token rides in `:extra_env` as a secret, and the runner keeps its spawn options for a
  # correction. A value in a process's state is a value in every crash report of it.
  test "the runner's state holds no secret it was given", context do
    # A project secret too, which the runner keeps sealed and opens only at spawn.
    secrets = sealed_secrets(%{"STRIPE_TEST_KEY" => "sk_never_shown"}, "runner-secrets")

    pid =
      run(context, "hang",
        extra_env: [{"FORGE_GIT_TOKEN", {:secret, "tok-never-shown"}}],
        secrets: secrets
      )

    state = inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity)
    refute state =~ "tok-never-shown"
    refute state =~ "sk_never_shown"

    Runner.cancel(pid)
    {:ok, _result} = Runner.await(pid, 5_000)
  end

  # Stopped before it started is stopped, and says so: a cancel is the reason, not the harness's
  # having exited, which it did only because it was told to.
  test "a harness cancelled before it started is cancelled, not one that exited", context do
    pid = run(context, "never_starts")
    Process.sleep(200)
    Runner.cancel(pid)

    {:ok, result} = Runner.await(pid, 15_000)
    assert result.killed == :operator
    assert result.reason == "cancelled by the operator"
  end

  # A resume the harness could not honour ends before `system/init`, with a result message of its
  # own: its words are the reason, and stderr's last line is not put in their place.
  test "a harness that answered before it started keeps its own words", context do
    {:ok, result} =
      context
      |> run("session",
        harness_opts: [
          executable: fake_executable(),
          credential: {:api_key, "k"},
          resume_session: "sess-nowhere"
        ]
      )
      |> Runner.await(5_000)

    assert result.exit_status == 1
    assert result.reason == "harness error: error_during_execution"
  end

  # `docs/design/claude-code-events.md` § Memory: what the slice reads of the job's memory while it
  # runs, said as `job.harness.memory`, and what the run ends with.
  describe "memory" do
    @gib 1024 ** 3

    defp reading(fields) do
      Map.merge(
        %{
          ceiling: 2 * @gib,
          current: @gib,
          peak: @gib,
          max_events: 0,
          oom_kills: 0,
          pressure: 0.0
        },
        Map.new(fields)
      )
    end

    defp scripted(readings, ending \\ %{}) do
      {:ok, agent} = Agent.start_link(fn -> readings end)

      [
        slice: ScriptedSlice,
        slice_opts: %{memory_max: 2 * @gib, readings: agent, ending: ending},
        memory_sample_ms: 10
      ]
    end

    defp memory_events do
      for %{type: "job.harness.memory", payload: payload} <- events(), do: payload
    end

    # Sampled while the process lives, and each rule's one event reaches the timeline: a kill per
    # increase, the ceiling once, and an episode of pressure once.
    test "is read while the process runs, and what it is worth is said", context do
      readings = [
        reading(oom_kills: 0),
        reading(oom_kills: 1, peak: 2 * @gib),
        reading(oom_kills: 1, max_events: 4, pressure: 30.0),
        reading(oom_kills: 1, max_events: 900, pressure: 35.0),
        reading(oom_kills: 1, max_events: 1800, pressure: 35.0)
      ]

      pid = run(context, "hang", scripted(readings))

      assert_receive {:event,
                      %{type: "job.harness.memory", payload: %{what: "pressure"} = pressure}},
                     5_000

      Runner.cancel(pid)
      {:ok, _result} = Runner.await(pid, 15_000)

      # Before it, in order, and after it nothing more, however long the episode went on.
      assert [kill, ceiling] = memory_events()
      assert %{what: "oom_kill", new_kills: 1, oom_kills: 1, peak: 2_147_483_648} = kill
      assert %{what: "ceiling", ceiling: 2_147_483_648} = ceiling
      assert %{what: "pressure", pressure: 35.0} = pressure
    end

    # `:memory_pressure_full` is how a node moves the threshold: at 60, two samples at 50 are not
    # an episode, where the default's twenty would have made one before the kill that follows.
    test "pressure is measured against the node's threshold", context do
      readings = [
        reading(pressure: 50.0),
        reading(pressure: 50.0),
        reading(pressure: 50.0, oom_kills: 1)
      ]

      pid = run(context, "hang", scripted(readings) ++ [memory_pressure_full: 60.0])

      assert_receive {:event, %{type: "job.harness.memory", payload: %{what: "oom_kill"}}}, 5_000
      Runner.cancel(pid)
      {:ok, _result} = Runner.await(pid, 15_000)

      # The kill was taken above; a pressure event would have come before it, and be left.
      assert memory_events() == []
    end

    # 2026-09-29's first chat: `starting` every two minutes with an empty stderr, and nothing that
    # said its ceiling was two bytes.
    test "a starting event says what memory is doing", context do
      opts = scripted([reading(ceiling: 2, current: 2, max_events: 40_000, pressure: 99.0)])

      {:ok, _result} =
        context
        |> run(
          "never_starts",
          opts ++ [start_notice_ms: 50, start_timeout_ms: 100, grace_ms: 100]
        )
        |> Runner.await(10_000)

      assert %{"ceiling" => 2, "current" => 2, "max_events" => 40_000, "pressure" => 99.0} =
               Enum.find_value(events(), fn
                 %{type: "job.harness.starting", payload: %{memory: memory}} -> memory
                 _other -> nil
               end)
    end

    # The unit's own last reading is what the run ends with: a harness killed for memory takes its
    # cgroup with it, and the sample before may be seconds older than the kill.
    test "the result says the ceiling, the peak and the kills, from the unit's last word",
         context do
      ending = %{memory: reading(peak: 2 * @gib, oom_kills: 2, current: nil)}

      {:ok, result} = context |> run("success", scripted([nil], ending)) |> Runner.await(5_000)

      assert result.harness["memory"] ==
               %{"ceiling" => 2 * @gib, "peak" => 2 * @gib, "oom_kills" => 2}

      # And the kills no sample saw are still said, before the result.
      assert [%{what: "oom_kill", new_kills: 2}] = memory_events()
    end

    test "nothing read is no memory at all", context do
      {:ok, result} = context |> run("success") |> Runner.await(5_000)
      assert result.harness["memory"] == nil
      assert memory_events() == []
    end

    # Its main process ended on SIGKILL and its unit counted an OOM kill: said in words, not as
    # "no result message" or an exit status.
    test "a harness killed at its ceiling says so", context do
      ending = %{
        exit: %{code: "killed", status: "KILL", result: "signal"},
        memory: reading(oom_kills: 1, peak: 2 * @gib)
      }

      {:ok, result} = context |> run("crash", scripted([nil], ending)) |> Runner.await(5_000)
      assert result.reason == "the harness was killed at its 2 GiB memory ceiling"
    end

    # Each half of the rule, alone, is something else: a SIGKILL nobody counted as an OOM kill, and
    # a kill of some other process while the harness went on to die of something else.
    test "a SIGKILL without an OOM kill, or an OOM kill without a SIGKILL, is not that",
         context do
      for ending <- [
            %{exit: %{code: "killed", status: "KILL"}, memory: reading(oom_kills: 0)},
            %{exit: %{code: "exited", status: "1"}, memory: reading(oom_kills: 3)},
            %{exit: %{code: "killed", status: "TERM"}, memory: reading(oom_kills: 3)}
          ] do
        {:ok, result} = context |> run("crash", scripted([nil], ending)) |> Runner.await(5_000)
        assert result.reason == "harness produced no result message", inspect(ending)
      end
    end

    # Each correction round's process has a cgroup of its own, whose counters start at nought: the
    # run's kills are the rounds' added up, and a round's first kill is news.
    test "a correction round counts its own kills, and the run adds them up", context do
      ending = %{memory: reading(oom_kills: 1, current: nil)}

      {:ok, result} =
        context |> run("fixes_when_resumed", scripted([nil], ending)) |> Runner.await(10_000)

      assert result.harness["corrections"] == 1
      assert result.harness["memory"]["oom_kills"] == 2
      assert [%{oom_kills: 1}, %{oom_kills: 2, new_kills: 1}] = memory_events()
    end

    # Stopped for never starting is that, and its reason says what it was waiting on.
    test "a harness stopped for never starting is that, whatever its unit counted", context do
      ending = %{exit: %{code: "killed", status: "KILL"}, memory: reading(oom_kills: 1)}

      opts =
        scripted([nil], ending) ++ [start_notice_ms: 50, start_timeout_ms: 100, grace_ms: 100]

      {:ok, result} = context |> run("never_starts", opts) |> Runner.await(10_000)
      assert result.reason =~ "the harness had not started after 0s"
    end

    # Stopped by the platform is stopped, whatever the unit counted on the way out.
    test "a harness cancelled is cancelled, whatever its unit counted", context do
      ending = %{exit: %{code: "killed", status: "KILL"}, memory: reading(oom_kills: 1)}
      pid = run(context, "hang", scripted([nil], ending))
      Process.sleep(200)
      Runner.cancel(pid)

      {:ok, result} = Runner.await(pid, 15_000)
      assert result.reason == "cancelled by the operator"
    end

    # A harness that finished said why it ended; a kill in its tree along the way does not change
    # that.
    test "a harness that produced its result is not one killed at its ceiling", context do
      ending = %{exit: %{code: "killed", status: "KILL"}, memory: reading(oom_kills: 1)}
      {:ok, result} = context |> run("success", scripted([nil], ending)) |> Runner.await(5_000)
      refute result.reason =~ "memory ceiling"
    end

    # Its reason names what the process wrote last, which is what the slice says it is — for a
    # unit, `systemd-run`'s own summary taken out.
    test "the last line a harness that never started gives is the slice's", context do
      ending = %{last_line: "error: flake does not provide attribute 'devShells.env'"}

      {:ok, result} = context |> run("no_start", scripted([nil], ending)) |> Runner.await(5_000)

      assert result.reason ==
               "the harness exited with status 1 before it started; stderr: " <>
                 "error: flake does not provide attribute 'devShells.env'"
    end
  end

  # `docs/design/worker-tier.md` § How a machine finds out: a `systemd-run` that could not reach
  # PID 1 is the machine's failure, and the machine's health hears of it before the run reports.
  describe "a slice supervisor that did not answer" do
    defp health do
      name = :"health-#{System.unique_integer([:positive])}"
      {:ok, _pid} = ForgeWorker.Health.start_link(name: name, link: self(), probe_ms: nil)
      name
    end

    test "makes the machine unhealthy, before the run's result", context do
      {:ok, readings} = Agent.start_link(fn -> [nil] end)
      health = health()
      reason = "systemd-run could not reach PID 1: Failed to start transient service unit: x"

      opts = [
        slice: ScriptedSlice,
        slice_opts: %{readings: readings, ending: %{unreachable: reason}},
        health: health
      ]

      {:ok, _result} = context |> run("no_start", opts) |> Runner.await(5_000)

      # Already here when the result came back: the link withholds a result it hears of after.
      assert_received {:unhealthy, ^reason}
      assert ForgeWorker.Health.unhealthy(health) == reason
    end

    test "a run that simply failed says nothing of the machine", context do
      health = health()
      {:ok, _result} = context |> run("no_start", health: health) |> Runner.await(5_000)

      refute_received {:unhealthy, _}
      assert ForgeWorker.Health.unhealthy(health) == nil
    end
  end

  describe "a harness that never starts" do
    test "is reported while it waits, with its stderr, and stopped at the limit", context do
      {:ok, result} =
        context
        |> run("never_starts", start_notice_ms: 100, start_timeout_ms: 350, grace_ms: 200)
        |> Runner.await(5_000)

      assert result.outcome == :error

      assert result.reason ==
               "the harness had not started after 0s; stderr: copying path " <>
                 "'/nix/store/abc-android-sdk' from 'https://cache.nixos.org'..."

      starting = Enum.filter(events(), &(&1.type == "job.harness.starting"))
      assert [%{payload: %{gave_up: false, stderr: stderr}} | _] = starting
      assert stderr =~ "android-sdk"
      assert %{payload: %{gave_up: true}} = List.last(starting)
      assert Enum.count(starting, & &1.payload.gave_up) == 1
    end

    # The reason quotes stderr's last line and the event carries its tail, not its head: a
    # `nix develop` writes far more than the tail, and what it was stuck on is at the end.
    test "the tail of a long stderr is what is quoted", context do
      {:ok, result} =
        context
        |> run("long_stderr", start_notice_ms: 100, start_timeout_ms: 300, grace_ms: 100)
        |> Runner.await(5_000)

      assert result.reason =~ "stderr: the last thing it said"

      assert [%{payload: %{stderr: stderr}} | _] =
               Enum.filter(events(), &(&1.type == "job.harness.starting"))

      assert byte_size(stderr) <= 2048
      refute stderr =~ "early line 1 of"
    end

    # `hang` says it started and then works on, well past the limit: a long job, not a stuck one.
    # Only the wall clock stops it, and nothing reports it as waiting to start.
    test "one that has started is never reported or stopped for it, however long it runs",
         context do
      {:ok, result} =
        context
        |> run("hang",
          start_notice_ms: 50,
          start_timeout_ms: 100,
          wall_clock_ms: 600,
          grace_ms: 100
        )
        |> Runner.await(5_000)

      assert result.killed == :wall_clock
      assert Enum.filter(events(), &(&1.type == "job.harness.starting")) == []
    end
  end

  # A job's directory is kept between its runs, and everything in it was the job's. A
  # `prompt.md` or `correction-<n>.md` the last run left as a link would have this run's write go
  # through it, as root, to whatever it names.
  test "files the run writes are replaced, not written through, where the job left links",
       context do
    spec = spec()
    job_dir = Path.join(context.root, spec.job_id)
    File.mkdir_p!(job_dir)
    victim = Path.join(tmp_dir("outside"), "victim")
    File.write!(victim, "untouched")
    names = ["prompt.md", "correction-1.md"]
    Enum.each(names, &File.ln_s!(victim, Path.join(job_dir, &1)))

    {:ok, _result} = context |> run("fixes_when_resumed", spec: spec) |> Runner.await(5_000)

    assert File.read!(victim) == "untouched"

    for name <- names,
        do: assert({:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(job_dir, name)))
  end

  describe "correcting the outputs" do
    # Two refinements failed in production on a `question` block that was not YAML, and each
    # was discarded with its questions. The session that wrote it is told what is wrong and
    # fixes it, and the platform hears one result: here, a job waiting on its question.
    test "a document that does not parse is fixed on the same session before anything is reported",
         context do
      {:ok, result} = context |> run("fixes_when_resumed") |> Runner.await(5_000)

      assert result.status == :waiting
      assert [%Question{key: "split", blocking: true}] = result.questions

      job_dir = job_dir(result)
      assert File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume sess-42"

      told = File.read!(Path.join(job_dir, "fake-prompt-2.txt"))
      assert told =~ "- plan.md: question[0]: block at line 6: invalid YAML"
      assert told =~ "correction 1 of 2"

      assert [%{payload: %{round: 1, of: 2, problems: [problem]}}] =
               Enum.filter(events(), &(&1.type == "job.harness.correction"))

      assert problem =~ "plan.md: question[0]"
    end

    # A correction round is a process of its own, spawned anew: it holds the job's secrets as the
    # first did, or a fix that needs one fails where the first round would not have.
    test "a correction round holds the job's secrets too", context do
      secrets = sealed_secrets(%{"STRIPE_TEST_KEY" => "sk_test_round-two"}, "runner-secrets")

      {:ok, result} =
        context |> run("fixes_when_resumed", secrets: secrets) |> Runner.await(5_000)

      assert result.harness["corrections"] == 1
      job_dir = job_dir(result)
      assert File.read!(Path.join(job_dir, "fake-args.txt")) =~ "--resume sess-42"

      assert File.read!(Path.join(job_dir, "fake-env-all.txt")) =~
               "STRIPE_TEST_KEY=sk_test_round-two"
    end

    # The platform adds a result's cost and turns to the job once. Reporting only the last
    # process's would lose what the first spent.
    test "the result reports what every round spent, and how many corrections ran", context do
      {:ok, result} = context |> run("fixes_when_resumed") |> Runner.await(5_000)

      assert result.harness["corrections"] == 1
      assert result.harness["turns"] == 6
      assert_in_delta result.harness["cost_usd"], 2 * 0.0421, 1.0e-9
      assert result.harness["duration_ms"] == 2 * 1234
      assert result.harness["session_id"] == "sess-42"
    end

    test "one transcript holds every round, in order", context do
      {:ok, result} = context |> run("fixes_when_resumed") |> Runner.await(5_000)

      inits =
        result.transcript_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.count(&String.contains?(&1, ~s("subtype":"init")))

      assert inits == 2
    end

    test "a run that stays broken is corrected at most max_corrections times, then fails",
         context do
      {:ok, result} = context |> run("invalid_document") |> Runner.await(5_000)

      assert result.outcome == :error
      assert result.reason =~ "invalid documents: plan.md"
      assert result.harness["corrections"] == 2

      # Three rounds of three turns each, all of them the job's.
      assert result.harness["turns"] == 9
      assert_in_delta result.harness["cost_usd"], 3 * 0.0421, 1.0e-9

      assert [1, 2] =
               events()
               |> Enum.filter(&(&1.type == "job.harness.correction"))
               |> Enum.map(& &1.payload.round)
    end

    test "max_corrections: 0 reports the first failure as it is", context do
      {:ok, result} =
        context |> run("invalid_document", max_corrections: 0) |> Runner.await(5_000)

      assert result.outcome == :error
      refute Map.has_key?(result.harness, "corrections")
      assert Enum.filter(events(), &(&1.type == "job.harness.correction")) == []
    end

    # The fake spends three turns a run. A budget of three leaves nothing for a correction to
    # start with, so none is started — the budget is the job's, not each process's.
    test "a correction is not started on a spent budget", context do
      spec = %{spec() | budget: %{turns: 3, cost: 2.0}}
      {:ok, result} = context |> run("invalid_document", spec: spec) |> Runner.await(5_000)

      assert result.outcome == :error
      assert Enum.filter(events(), &(&1.type == "job.harness.correction")) == []
    end

    test "a correction is given what is left of the budget, not the whole of it", context do
      {:ok, result} = context |> run("fixes_when_resumed") |> Runner.await(5_000)
      args = File.read!(Path.join(job_dir(result), "fake-args.txt"))

      assert args =~ "--max-turns 37"
      assert args =~ "--max-budget-usd 1.95"
    end

    # The cancel arrives after the harness printed its result and before it exited. It is a
    # cancel all the same: no correction starts, and the job reports it was cancelled.
    test "a cancel after the result and before the exit is still a cancel", context do
      pid = run(context, "result_then_linger", grace_ms: 200)
      assert_receive {:event, %{type: "job.harness.finished"}}, 5_000
      Runner.cancel(pid)
      {:ok, result} = Runner.await(pid, 5_000)

      assert result.outcome == :cancelled
      assert result.killed == :operator
      assert Enum.filter(events(), &(&1.type == "job.harness.correction")) == []
    end

    # The correction round is the one running now, and a cancel is its cancel: recorded as one,
    # with no round after it.
    test "a cancel during a correction round is a cancel", context do
      pid = run(context, "hangs_when_resumed", grace_ms: 200)
      assert_receive {:event, %{type: "job.harness.correction"}}, 5_000

      assert_receive {:event, %{type: "job.harness.started", payload: %{session_id: "sess-43"}}},
                     5_000

      Runner.cancel(pid)
      {:ok, result} = Runner.await(pid, 5_000)

      assert result.killed == :operator
      assert result.outcome == :cancelled
      # The first correction was taken off the mailbox above; none came after the cancel.
      refute Enum.any?(events(), &(&1.type == "job.harness.correction"))
    end

    # A correction round is watched from its own start like any process.
    test "a correction round that never starts is stopped as one", context do
      {:ok, result} =
        context
        |> run("hangs_when_resumed",
          extra_env: [{"FAKE_SILENT_RESUME", "1"}],
          start_notice_ms: 100,
          start_timeout_ms: 300,
          grace_ms: 100
        )
        |> Runner.await(5_000)

      assert result.reason =~ "the harness had not started after 0s"
      assert result.harness["corrections"] == 1
    end

    test "a run that is cancelled is not corrected", context do
      pid = run(context, "hang", grace_ms: 200)
      Process.sleep(100)
      Runner.cancel(pid)
      {:ok, result} = Runner.await(pid, 5_000)

      assert result.outcome == :cancelled
      assert Enum.filter(events(), &(&1.type == "job.harness.correction")) == []
    end
  end

  test "the wall clock kills a hung harness and reports budget_exhausted", context do
    started = System.monotonic_time(:millisecond)

    {:ok, result} =
      context |> run("hang", wall_clock_ms: 300, grace_ms: 200) |> Runner.await(5_000)

    assert result.killed == :wall_clock
    assert result.outcome == :budget_exhausted
    assert result.exhausted == :wall_clock
    assert System.monotonic_time(:millisecond) - started < 3_000
  end

  test "cancel stops the harness and reports cancelled", context do
    pid = run(context, "hang", grace_ms: 200)
    Process.sleep(100)
    Runner.cancel(pid)
    {:ok, result} = Runner.await(pid, 5_000)

    assert result.killed == :operator
    assert result.outcome == :cancelled
  end

  # `docs/decisions.md`: the environment is entered through `nix develop` on the project's own
  # flake, and the spec names which one. Nothing asserted the command that produces, so a
  # machine with `nix_env` on could have been running the harness outside the environment its
  # build needs and the job would only have failed later, in the build.
  # Both await the run before ending: the harness writes under `root`, which `on_exit` removes,
  # and a removal racing those writes fails the test for nothing it asserts.
  test "with nix_env the harness runs inside the project's environment", context do
    pid =
      run(context, "success",
        nix_env: true,
        slice: WrapReportingSlice,
        slice_opts: %{reply_to: self()}
      )

    # The secrets' loader is innermost, inside the environment: `nix develop` never holds them.
    assert_receive {:wrapped, "nix", ["develop", ".#implement", "--command" | rest]}
    assert ["/bin/sh", "-c", _loader, "forge-secrets", _file, executable | _flags] = rest
    assert executable == fake_executable()
    {:ok, _result} = Runner.await(pid, 5_000)
  end

  test "without it the harness is run as it is", context do
    pid = run(context, "success", slice: WrapReportingSlice, slice_opts: %{reply_to: self()})

    assert_receive {:wrapped, "/bin/sh", ["-c", _loader, "forge-secrets", _file, executable | _]}
    assert executable == fake_executable()
    {:ok, _result} = Runner.await(pid, 5_000)

    # A harness given no secret at all is started as it is.
    pid =
      run(context, "success",
        slice: WrapReportingSlice,
        slice_opts: %{reply_to: self()},
        harness_opts: [executable: fake_executable()]
      )

    assert_receive {:wrapped, executable, _args}
    assert executable == fake_executable()
    {:ok, _result} = Runner.await(pid, 5_000)
  end

  # A slice that cannot be made is a job that cannot run. The alternative — starting the
  # harness anyway — is an agent running unconfined as the worker's own user, which is the one
  # thing the slice exists to prevent, so this concludes with nothing started.
  test "a slice that cannot be made ends the job rather than running unconfined", context do
    spec = spec()
    pid = run(context, "success", slice: RefusingSlice, spec: spec)

    assert {:ok, result} = Runner.await(pid)
    assert result.outcome == :error

    # The credential written for a process that never started does not outlive it.
    worker_dir = Path.join(context.root, spec.job_id <> ".worker")
    assert File.dir?(worker_dir)
    refute File.exists?(Path.join(worker_dir, "secrets.env"))

    # Nothing ran: no harness event, no exit status, and the document the state declared is
    # missing rather than invalid. Nor does its reason say a harness exited: none was started.
    assert events() == []
    assert result.exit_status == nil
    assert result.missing == ["plan.md"]
    refute result.reason =~ "exited"
  end

  # The race the test above lost one run in several: a refused slice concludes within the call
  # that started the runner, before anyone has asked. The runner has to still be there with the
  # result, rather than having stopped and taken it along. Waiting for the conclusion first makes
  # the late caller certain instead of likely.
  test "a run that ended before anyone asked still answers the caller", context do
    pid = run(context, "success", slice: RefusingSlice)

    Enum.find_value(1..200, fn _ ->
      :sys.get_state(pid).result || Process.sleep(5)
    end)

    ref = Process.monitor(pid)
    assert {:ok, %{outcome: :error}} = Runner.await(pid)
    # And having handed it over, it goes.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "the runner exits after the job ends", context do
    pid = run(context, "success")
    ref = Process.monitor(pid)
    {:ok, _} = Runner.await(pid, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  # `docs/design/archive.md` § The worker's side: the folder is there before the harness starts and
  # gone when the job ends, and a job that is promised one and cannot have it does not start.
  describe "the archive" do
    setup do
      Application.put_env(:forge_worker, :archive_mount, ForgeWorker.RecordingMount)
      Application.put_env(:forge_worker, :archive_test_pid, self())

      on_exit(fn ->
        for key <- [:archive_mount, :archive_test_pid, :archive_test_mount],
            do: Application.delete_env(:forge_worker, key)
      end)
    end

    @grant %{url: "http://platform.test", token: "secret-token"}

    test "is mounted before the harness starts and released when the job ends", context do
      pid = run(context, "success", archive: @grant)
      assert {:ok, %Result{} = result} = Runner.await(pid, 5_000)

      # Released as the job starts (what an earlier run left), mounted, and released as it ends.
      folder = Path.join(job_dir(result), "archive")

      assert [{:unmounted, ^folder}, {:mounted, _socket, ^folder}, {:unmounted, ^folder}] =
               mounts()

      assert result.outcome == :converged
    end

    defp lifecycle do
      receive do
        {:slice_prepared, _} -> [:slice | lifecycle()]
        {:mounted, _, _} -> [:mounted | lifecycle()]
        {:unmounted, _} -> [:unmounted | lifecycle()]
      after
        0 -> []
      end
    end

    defp mounts do
      receive do
        {:mounted, _, _} = message -> [message | mounts()]
        {:unmounted, _} = message -> [message | mounts()]
      after
        0 -> []
      end
    end

    # `Slice.Systemd.prepare/1` hands the job directory to the job's user with a recursive `chown`,
    # which on a directory that already held the mount would walk it and fail on every file.
    test "is mounted after the slice is made and before it is released, never before", context do
      pid =
        run(context, "success",
          slice: RecordingSlice,
          slice_opts: %{reply_to: self()},
          archive: @grant
        )

      assert {:ok, _result} = Runner.await(pid, 5_000)
      assert lifecycle() == [:slice, :unmounted, :mounted, :unmounted]
    end

    test "is not made for a job with no grant", context do
      pid = run(context, "success")
      assert {:ok, _result} = Runner.await(pid, 5_000)

      refute_received {:mounted, _, _}
      refute File.exists?(Path.join([context.root, spec().job_id, "archive"]))
    end

    test "that cannot be mounted ends the job with nothing started", context do
      Application.put_env(:forge_worker, :archive_test_mount, {:error, :boom})
      pid = run(context, "success", archive: @grant)

      assert {:ok, result} = Runner.await(pid, 5_000)
      assert result.outcome == :error
      assert result.exit_status == nil
      assert events() == []
    end
  end
end
