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
end

defmodule ForgeWorker.Job.RunnerTest do
  use ExUnit.Case, async: true

  alias ForgeWorker.Job.RunnerTest.RecordingSlice

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
    job_dir = Path.dirname(result.transcript_path)

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
    job_dir = Path.dirname(result.transcript_path)
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
    job_dir = Path.dirname(result.transcript_path)

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

  defp seed_output(root, spec, content) do
    out = Path.join([root, spec.job_id, "out"])
    File.mkdir_p!(out)
    File.write!(Path.join(out, "plan.md"), content)
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

  test "the runner exits after the job ends", context do
    pid = run(context, "success")
    ref = Process.monitor(pid)
    {:ok, _} = Runner.await(pid, 5_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end
end
