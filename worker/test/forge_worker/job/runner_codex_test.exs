defmodule ForgeWorker.Job.RunnerCodexTest do
  @moduledoc """
  A job on the Codex driver, through the runner and a stand-in app-server
  (`test/support/fake_codex.sh`, written to OpenAI's description and not captured from a real
  `codex`: `docs/design/codex.md` § Not verified here).

  What is held here is forge's side of the arrangement: the conversation with the process runs
  inside a job, usage is counted per call and the run stopped past its budget, the login reaches
  the process as a file and never as argv or a variable, and a job is one turn.
  """

  # Not async: a returned login is sealed with the machine's token, which is application
  # environment, and other tests set and delete it (`ForgeWorker.Fixtures.worker_token_hash/0`).
  use ExUnit.Case, async: false

  import ForgeWorker.Fixtures

  alias ForgeCore.Job.Result
  alias ForgeWorker.Harness.Codex
  alias ForgeWorker.Job.Runner

  setup do
    %{root: tmp_dir("root"), worktree: tmp_dir("worktree")}
  end

  defp run(context, scenario, extra \\ []) do
    test_pid = self()

    opts =
      [
        harness: Codex,
        spec: Keyword.get(extra, :spec, spec()),
        root: context.root,
        worktree: context.worktree,
        sink: fn event -> send(test_pid, {:event, event}) end,
        harness_opts:
          Keyword.get(extra, :harness_opts,
            codex_executable: fake_codex_executable(),
            credential: {:chatgpt_login, ~s({"tokens":{"refresh_token":"rt-secret"}})}
          ),
        extra_env: [{"FAKE_CODEX_SCENARIO", scenario} | Keyword.get(extra, :extra_env, [])]
      ] ++ Keyword.drop(extra, [:spec, :harness_opts, :extra_env])

    {:ok, pid} = Runner.start_link(opts)
    pid
  end

  defp job_dir(%Result{stderr_path: path}),
    do: path |> Path.dirname() |> String.replace_suffix(".worker", "")

  defp events, do: receive_all([])

  defp receive_all(acc) do
    receive do
      {:event, event} -> receive_all([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a job is one turn: the prompt goes in as a message, the document comes out, stdin closes",
       context do
    {:ok, result} = context |> run("success") |> Runner.await(10_000)

    assert result.status == :finished
    assert result.outcome == :converged
    assert result.declared_outcome == "done"
    assert result.killed == nil
    assert %{"plan.md" => %ForgeCore.Document{outcome: "done"}} = result.documents

    # The version that wrote the session rides with it: a session recorded with none is never
    # resumed (`ForgeWorker.Job.Session`), so a Codex thread would always start cold.
    assert %{
             "session_id" => "th-fake",
             "subtype" => "success",
             "is_error" => false,
             "version" => "9.9.9"
           } = result.harness

    types = Enum.map(events(), & &1.type)
    assert "job.harness.started" in types
    assert "job.harness.tool_use" in types
    assert "job.harness.text" in types
    assert "job.harness.finished" in types
  end

  test "usage is the weighted sum of each call once: the repeat is not another", context do
    {:ok, result} = context |> run("success") |> Runner.await(10_000)

    # Call one: 600 fresh + 400 cached + 200 out; call two: 500 fresh + 1000 cached + 100 out.
    assert result.harness["tokens"] == %{
             input: 1100,
             cache_write: 0,
             cache_read: 1400,
             output: 300
           }

    assert result.harness["usage"] == 1100 + 140 + 1500
  end

  test "the account's windows reach the result as the last report of the run", context do
    {:ok, result} = context |> run("success") |> Runner.await(10_000)

    assert %{"status" => "allowed", "rate_limit_type" => "seven_day"} =
             result.harness["rate_limit"]

    assert Enum.any?(events(), &(&1.type == "job.harness.rate_limit"))
  end

  test "a run past its token budget is stopped during the run", context do
    spec = %{spec() | budget: %{turns: 40, tokens: 120_000}}
    {:ok, result} = context |> run("runaway", spec: spec) |> Runner.await(15_000)

    assert result.killed == :tokens
    assert result.outcome == :budget_exhausted
    assert result.exhausted == :tokens
  end

  test "a usage limit is the rate limit report Claude's reads as", context do
    {:ok, result} = context |> run("limit") |> Runner.await(10_000)

    assert %{"status" => "rejected"} = result.harness["rate_limit"]
    assert result.harness["is_error"] == true
  end

  describe "the login" do
    test "reaches the process as a file under umask 077, and as nothing else", context do
      {:ok, result} = context |> run("success") |> Runner.await(10_000)
      dir = job_dir(result)

      assert File.read!(Path.join(dir, "fake-auth.json")) =~ "rt-secret"
      assert String.trim(File.read!(Path.join(dir, "fake-auth-mode.txt"))) == "600"

      # Unset before Codex ran, and in neither argv nor the second variable.
      assert File.read!(Path.join(dir, "fake-auth-env.txt")) == "unset"
      assert File.read!(Path.join(dir, "fake-token-env.txt")) == "unset"
      args = File.read!(Path.join(dir, "fake-args.txt"))
      refute args =~ "rt-secret"
      assert args =~ "app-server"
    end

    test "an access token is a variable and writes no file", context do
      {:ok, result} =
        context
        |> run("success",
          harness_opts: [
            codex_executable: fake_codex_executable(),
            credential: {:access_token, "tok-1"}
          ]
        )
        |> Runner.await(10_000)

      dir = job_dir(result)
      assert File.read!(Path.join(dir, "fake-token-env.txt")) == "tok-1"
      refute File.exists?(Path.join(dir, "fake-auth.json"))
      refute File.read!(Path.join(dir, "fake-args.txt")) =~ "tok-1"
    end
  end

  describe "what the run leaves of its login" do
    # Codex refreshes it by itself and a copy another run refreshed first stops working, so what is
    # left comes back: sealed to this machine and this job, under a purpose of its own.
    test "a login Codex rewrote comes back sealed for this job, and only as a return", context do
      # The token the run seals with is read when it ends, so it is set first.
      hash = worker_token_hash()
      job = spec()
      {:ok, result} = context |> run("rotates", spec: job) |> Runner.await(10_000)
      job_id = job.job_id

      sealed = result.harness["credential_return"]
      assert is_binary(sealed)
      assert {:ok, text} = ForgeCore.Job.Credential.open(sealed, hash, job_id, :return)
      assert text =~ "rotated"

      assert ForgeCore.Job.Credential.open(sealed, hash, job_id) == :error
      refute inspect(result.harness) =~ "rt-secret"
    end

    # Round two of a correction is a process of its own, and its shell prefix writes whatever login
    # it was handed over `auth.json`. Handed the one the run began with, it would run on a refresh
    # token Codex had already spent, and return nothing of round one's.
    test "a correction round starts from the login the last round left, and returns it",
         context do
      hash = worker_token_hash()
      job = spec()

      {:ok, result} =
        context
        |> run("rotates_then_fixes", spec: job, slice: ForgeWorker.Slice.Direct)
        |> Runner.await(10_000)

      assert result.harness["corrections"] == 1
      dir = job_dir(result)
      assert File.read!(Path.join(dir, "fake-auth-round-1.json")) =~ "rt-secret"
      assert File.read!(Path.join(dir, "fake-auth-round-2.json")) =~ "rotated"

      sealed = result.harness["credential_return"]
      assert {:ok, text} = ForgeCore.Job.Credential.open(sealed, hash, job.job_id, :return)
      assert text =~ "rotated"
    end

    test "a login left as it was is not returned", context do
      worker_token_hash()
      {:ok, result} = context |> run("success") |> Runner.await(10_000)
      refute Map.has_key?(result.harness, "credential_return")
    end

    test "a file too large to be a login is not read", context do
      worker_token_hash()
      {:ok, result} = context |> run("huge") |> Runner.await(10_000)
      refute Map.has_key?(result.harness, "credential_return")
    end

    test "a link in place of the login's directory is not followed either", context do
      worker_token_hash()
      {:ok, result} = context |> run("linkdir") |> Runner.await(10_000)
      refute Map.has_key?(result.harness, "credential_return")
    end

    test "a link in the login's place is not followed", context do
      worker_token_hash()
      {:ok, result} = context |> run("linked") |> Runner.await(10_000)
      refute Map.has_key?(result.harness, "credential_return")
    end

    test "a run that was handed an access token has nothing to hand back", context do
      worker_token_hash()

      {:ok, result} =
        context
        |> run("rotates",
          harness_opts: [
            codex_executable: fake_codex_executable(),
            credential: {:access_token, "tok-1"}
          ]
        )
        |> Runner.await(10_000)

      refute Map.has_key?(result.harness, "credential_return")
    end
  end

  describe "a session to resume" do
    defmodule NoResume do
      @moduledoc false
      def capabilities, do: %{resume: false}
    end

    # A harness that cannot resume starts cold whatever the assignment says; Codex can, now that its
    # rollout is carried (`ForgeWorker.Job.Session`).
    test "is dropped for a harness that cannot resume", _context do
      assignment = %{
        "session" => %{"key" => "k", "token" => "t", "id" => "th-old", "version" => "9.9.9"},
        "resume_session" => "th-old"
      }

      opts = [resume_session: "th-old", fork_session: true, model: "gpt-x"]

      assert {[model: "gpt-x"], nil} =
               ForgeWorker.Job.Session.restore(assignment, "/nowhere", "/nowhere", opts, NoResume)
    end

    test "is resumed for Codex, which says where its session is kept", _context do
      assert Codex.capabilities().resume
      assert Codex.capabilities().session_layout == :rollout
      assert ForgeWorker.Harness.ClaudeCode.capabilities().resume
    end
  end

  describe "a conversation on Codex" do
    defp chat(context, scenario) do
      test_pid = self()

      {:ok, pid} =
        Runner.start_link(
          harness: Codex,
          spec: spec(),
          root: context.root,
          worktree: context.worktree,
          owner: test_pid,
          sink: fn event -> send(test_pid, {:event, event}) end,
          harness_opts: [
            mode: :streaming,
            codex_executable: fake_codex_executable(),
            credential: {:chatgpt_login, ~s({"tokens":{"refresh_token":"rt-secret"}})}
          ],
          extra_env: [{"FAKE_CODEX_SCENARIO", scenario}]
        )

      pid
    end

    # Ended before the test is: a runner still writing into its directory when the directory is
    # removed fails the removal.
    defp close(pid) do
      Runner.close(pid)
      assert_receive {:ended, _job, _result}, 10_000
    end

    # Each turn's report carries what Codex left of the login — once per change, so the next turn
    # does not hand the same login back (`ForgeWorker.Job.Conversation` puts it in the report).
    test "a rewritten login comes back with the turn it was rewritten in, once", context do
      worker_token_hash()
      pid = chat(context, "rotates")

      assert Runner.send_message(pid, "one") == :ok
      assert_receive {:turn, _job, 1, first}, 10_000
      assert is_binary(first.payload.credential_return)

      assert Runner.send_message(pid, "two") == :ok
      assert_receive {:turn, _job, 2, second}, 10_000
      assert second.payload.credential_return == nil
      close(pid)
    end

    test "an interrupt with no turn in flight writes nothing and labels nothing", context do
      pid = chat(context, "success")

      assert Runner.interrupt(pid) == :ok
      assert Runner.send_message(pid, "hello") == :ok
      assert_receive {:turn, _job, 1, event}, 10_000
      refute Map.get(event.payload, :interrupted)
      close(pid)
    end
  end
end
