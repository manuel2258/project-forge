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
end

defmodule ForgeWorker.Job.RunnerTest do
  use ExUnit.Case, async: true

  alias ForgeWorker.Job.RunnerTest.{RecordingSlice, RefusingSlice, WrapReportingSlice}

  import ForgeWorker.Fixtures

  alias ForgeCore.Document.Question
  alias ForgeCore.Job.Result
  alias ForgeWorker.Job.Runner

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
        extra_env: [{"FAKE_SCENARIO", scenario}]
      ] ++ Keyword.drop(extra, [:spec, :harness_opts])

    {:ok, pid} = Runner.start_link(opts)
    pid
  end

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

    # The credential is named and not valued: it is the one thing that must not be copied into
    # a list that ends up in an argument vector.
    assert "ANTHROPIC_API_KEY" in opts.secret_names
    refute List.keyfind(opts.env, "ANTHROPIC_API_KEY", 0)
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
  end

  test "the harness receives the composed prompt, the credential and the budget flags", context do
    pid = run(context, "success")
    {:ok, result} = Runner.await(pid, 5_000)
    job_dir = Path.dirname(result.stderr_path)

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
    job_dir = Path.dirname(result.stderr_path)
    env = File.read!(Path.join(job_dir, "fake-env-all.txt"))

    refute env =~ "FORGE_TEST_LEAK"
    assert env =~ "HOME=#{Path.join(job_dir, "home")}\n"
    assert env =~ "FORGE_JOB=#{job_dir}\n"
    assert env =~ "PATH="
    assert env =~ "ANTHROPIC_API_KEY=secret-key"
    # Secrets travel through the environment, never through argv.
    refute File.read!(Path.join(job_dir, "fake-args.txt")) =~ "secret-key"
  end

  test "a credential given as a function is resolved at spawn time", context do
    opts = [harness_opts: [executable: fake_executable(), credential: fn -> {:oauth, "tok"} end]]
    {:ok, result} = context |> run("success", opts) |> Runner.await(5_000)
    job_dir = Path.dirname(result.stderr_path)

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
    job_dir = Path.dirname(result.stderr_path)

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
      job_dir = Path.dirname(result.stderr_path)
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
      job_dir = Path.dirname(result.stderr_path)
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
      assert Path.dirname(home) == ForgeWorker.Job.Dir.blobs_dir(Path.dirname(result.stderr_path))
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

  test "a crash without a result is an error, and odd lines still become events", context do
    {:ok, result} = context |> run("crash") |> Runner.await(5_000)
    assert result.outcome == :error
    assert result.reason == "harness produced no result message"
    types = Enum.map(events(), & &1.type)
    assert "job.harness.malformed" in types
    assert "job.harness.unknown" in types
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
    {:ok, result} = context |> run("undeclared") |> Runner.await(5_000)
    assert {:error, "undeclared outputs: notes.md"} = {result.outcome, result.reason}

    {:ok, result} = context |> run("invalid_document") |> Runner.await(5_000)
    assert {:error, "invalid documents: plan.md"} = {result.outcome, result.reason}
  end

  test "the wall clock kills a hung harness and reports budget_exhausted", context do
    started = System.monotonic_time(:millisecond)

    {:ok, result} =
      context |> run("hang", wall_clock_ms: 300, grace_ms: 200) |> Runner.await(5_000)

    assert result.killed == :wall_clock
    assert result.outcome == :budget_exhausted
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

    assert_receive {:wrapped, "nix", ["develop", ".#implement", "--command" | rest]}
    assert [executable | _flags] = rest
    assert executable == fake_executable()
    {:ok, _result} = Runner.await(pid, 5_000)
  end

  test "without it the harness is run as it is", context do
    pid = run(context, "success", slice: WrapReportingSlice, slice_opts: %{reply_to: self()})

    assert_receive {:wrapped, executable, _args}
    assert executable == fake_executable()
    {:ok, _result} = Runner.await(pid, 5_000)
  end

  # A slice that cannot be made is a job that cannot run. The alternative — starting the
  # harness anyway — is an agent running unconfined as the worker's own user, which is the one
  # thing the slice exists to prevent, so this concludes with nothing started.
  test "a slice that cannot be made ends the job rather than running unconfined", context do
    pid = run(context, "success", slice: RefusingSlice)

    assert {:ok, result} = Runner.await(pid)
    assert result.outcome == :error

    # Nothing ran: no harness event, no exit status, and the document the state declared is
    # missing rather than invalid.
    assert events() == []
    assert result.exit_status == nil
    assert result.missing == ["plan.md"]
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
end
