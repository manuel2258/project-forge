defmodule ForgeWorker.Job.RunnerTest do
  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeCore.Document.Question
  alias ForgeWorker.Job.{Result, Runner}

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
        harness_opts: [executable: fake_executable(), credential: {:api_key, "secret-key"}],
        extra_env: [{"FAKE_SCENARIO", scenario}]
      ] ++ Keyword.drop(extra, [:spec])

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
             session_id: "sess-42",
             model: "fake-model",
             turns: 3,
             cost_usd: 0.0421,
             subtype: "success"
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
    assert result.harness.cost_usd == 1.5
  end

  test "a crash without a result is an error, and odd lines still become events", context do
    {:ok, result} = context |> run("crash") |> Runner.await(5_000)
    assert result.outcome == :error
    assert result.reason == "harness produced no result message"
    types = Enum.map(events(), & &1.type)
    assert "job.harness.malformed" in types
    assert "job.harness.unknown" in types
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
