defmodule ForgeWorker.Job.RunnerStreamingTest.NoStreaming do
  @moduledoc "A driver that cannot be written to, which is the thing a conversation must refuse."

  @behaviour ForgeWorker.Harness

  @impl true
  def capabilities, do: %{resume: true, streaming_input: false}

  @impl true
  def command(_spec, _job_dir, _opts), do: {"/bin/true", [], []}

  @impl true
  def parse_line(_line), do: []

  @impl true
  def encode_message(text), do: [text, "\n"]

  @impl true
  def encode_interrupt(id), do: [id, "\n"]

  @impl true
  def driver, do: "none"

  @impl true
  def probe(_opts), do: %{driver: "none", name: "None", version: nil, aliases: []}
end

defmodule ForgeWorker.Job.RunnerStreamingTest do
  @moduledoc """
  A harness that can still be spoken to after it starts.

  Everything here fails against the runner as it was, and mostly fails silently, which is why
  each test says what the old behaviour looked like. The invocation is the one
  `measure/lib/streaming.sh` measured against the real harness; the fake reproduces its three
  load-bearing behaviours (`FAKE_SCENARIO=chat`).
  """

  use ExUnit.Case, async: true

  import ForgeWorker.Fixtures

  alias ForgeWorker.Job.Runner
  alias ForgeWorker.Job.RunnerStreamingTest.NoStreaming

  setup do
    %{root: tmp_dir("root"), worktree: tmp_dir("worktree")}
  end

  defp chat(context, extra \\ []) do
    test_pid = self()
    spec = Keyword.get(extra, :spec, spec())

    opts =
      [
        spec: spec,
        root: context.root,
        worktree: context.worktree,
        owner: test_pid,
        sink: fn event -> send(test_pid, {:event, event}) end,
        harness_opts:
          [
            executable: fake_executable(),
            credential: {:api_key, "secret-key"},
            mode: :streaming
          ] ++ Keyword.get(extra, :harness_opts, []),
        extra_env: [{"FAKE_SCENARIO", "chat"} | Keyword.get(extra, :extra_env, [])]
      ] ++ Keyword.drop(extra, [:spec, :extra_env, :harness_opts])

    {:ok, pid} = Runner.start_link(opts)
    {pid, spec}
  end

  # A reopened conversation with nothing waiting holds its prompt until someone writes; its
  # harness is silent because it has been given nothing, and that is not a harness failing to
  # start. The watch begins when the prompt goes down, not when the process does: held for twice
  # the limit, it is neither noticed nor stopped. Once the message is down it is watched like any
  # other, so whether a notice follows then depends on how fast the harness answers, which under
  # a loaded test run is not fast enough to assert on.
  test "a held prompt is not a harness that never started", context do
    {pid, _spec} =
      chat(context, hold_prompt: true, start_notice_ms: 100, start_timeout_ms: 200)

    Process.sleep(400)
    assert Process.alive?(pid)
    refute_received {:event, %{type: "job.harness.starting"}}

    assert Runner.send_message(pid, "now there is something") == :ok
    assert_receive {:turn, _job_id, 1, _event}, 5_000
    Runner.close(pid)
  end

  # Held, and then given its first message: from there its silence counts like anyone's.
  test "a held prompt is watched from the message that carries it", context do
    {pid, _spec} =
      chat(context,
        hold_prompt: true,
        extra_env: [{"FAKE_SCENARIO", "never_starts"}],
        start_notice_ms: 50,
        start_timeout_ms: 100,
        grace_ms: 100
      )

    assert Runner.send_message(pid, "anyone there?") == :ok
    assert_receive {:event, %{type: "job.harness.starting", payload: %{gave_up: true}}}, 5_000
    assert_receive {:ended, _job_id, %{reason: "the harness had not started after 0s"}}, 5_000
  end

  # The conversation that sat for 38 minutes: given its prompt, never said it started.
  test "one given its prompt that never starts is stopped, and says why", context do
    {_pid, _spec} =
      chat(context,
        extra_env: [{"FAKE_SCENARIO", "never_starts"}],
        start_notice_ms: 50,
        start_timeout_ms: 100,
        grace_ms: 100
      )

    assert_receive {:event, %{type: "job.harness.starting", payload: %{gave_up: true}}}, 5_000
    assert_receive {:ended, _job_id, result}, 5_000
    # The fake reads stdin to its end before it writes anything, and a conversation's stdin does
    # not end, so there is no stderr to quote here — the reason is the sentence alone.
    assert result.reason == "the harness had not started after 0s"
  end

  # **The second chat of 2026-09-29.** `systemd-run` could not reach PID 1, said so and exited —
  # and the run sat in `starting` for thirty minutes, because the relay in front of the harness was
  # waiting on the port's stdin for a line that was never coming, and the shell waited for the
  # relay. The prompt is written before the fake exits, which is what left the relay blocked.
  test "a harness that exits without reading ends the run at once, and says why", context do
    {_pid, spec} =
      chat(context, extra_env: [{"FAKE_SCENARIO", "exits_unread"}], start_timeout_ms: 60_000)

    assert_receive {:ended, _job_id, result}, 5_000
    assert result.exit_status == 1

    assert result.reason ==
             "the harness exited with status 1 before it started; stderr: " <>
               "Failed to start transient service unit: Connection timed out"

    # And the relay went with it: nothing of the run is left in its process group.
    pgid = context |> job_dir(spec) |> Path.join("fake-pgid.txt") |> File.read!() |> String.trim()
    assert {_none, 1} = System.cmd("pgrep", ["-g", pgid])

    # The wrapper ignores `USR1` so the relay's is the only process it ends; the harness is started
    # with the default back, as it always was.
    ignored = context |> job_dir(spec) |> Path.join("fake-sigign.txt") |> File.read!()
    usr1 = Bitwise.bsl(1, 10 - 1)
    assert ignored |> String.trim() |> String.to_integer(16) |> Bitwise.band(usr1) == 0
  end

  # Held, nothing has gone down the pipe at all, and the relay is in `read` from the start: no
  # start watch either, since nothing was delivered — so this one used to wait for ever.
  test "a held prompt whose harness exits ends the run too", context do
    {_pid, _spec} =
      chat(context,
        hold_prompt: true,
        extra_env: [{"FAKE_SCENARIO", "exits_unread"}, {"FAKE_EXIT_AFTER", "0"}]
      )

    assert_receive {:ended, _job_id, result}, 5_000
    assert result.exit_status == 1
    assert result.reason =~ "before it started"
  end

  # `<"$prompt"` made stdin a regular file already at EOF and threw the port's pipe away, so
  # nothing written to a running harness could ever arrive. This is the blocker the whole
  # feature sat behind, and it is why the first message goes down the pipe like every other.
  test "the first message reaches the harness through the port, not a redirect", context do
    {pid, spec} = chat(context)

    assert_receive {:turn, _job_id, 1, _event}, 5_000
    assert Runner.send_message(pid, "spoken-after-start") == :ok
    assert_receive {:turn, _job_id, 2, _event}, 5_000

    # What the harness actually received, rather than how many turns it produced. With the
    # prompt redirected into stdin the harness still reads lines and still answers them — the
    # prompt's own — so counting turns passes while nothing the runner said ever arrives.
    received = File.read!(Path.join(job_dir(context, spec), "fake-messages.txt"))
    assert received =~ "spoken-after-start"
  end

  defp job_dir(context, spec), do: Path.join(context.root, spec.job_id)

  # A conversation reports a summary per turn, and its memory is part of it: as it stood when the
  # turn ended (`docs/design/claude-code-events.md` § Memory).
  test "each turn carries the job's memory as it ended", context do
    gib = 1024 ** 3
    reading = %{ceiling: gib, current: gib, peak: gib, max_events: 0, oom_kills: 1, pressure: 0.0}
    {:ok, agent} = Agent.start_link(fn -> [reading] end)

    {pid, _spec} =
      chat(context,
        slice: ForgeWorker.ScriptedSlice,
        slice_opts: %{memory_max: gib, readings: agent}
      )

    assert_receive {:turn, _job_id, 1, turn}, 5_000
    assert turn.payload.memory == %{"ceiling" => gib, "peak" => gib, "oom_kills" => 1}
    Runner.close(pid)
  end

  # The runner kept one `finished_event`, so every turn after the first overwrote the one
  # before it and the count of turns did not exist. Asserting on the runner's own turn index
  # rather than on how often the sink was called is deliberate: the sink is called before the
  # state is updated, so a test counting sink calls passes while the bug is present.
  test "each turn is reported with its own index", context do
    {pid, _spec} = chat(context)

    assert_receive {:turn, job_id, 1, first}, 5_000
    Runner.send_message(pid, "two")
    assert_receive {:turn, ^job_id, 2, second}, 5_000
    Runner.send_message(pid, "three")
    assert_receive {:turn, ^job_id, 3, third}, 5_000

    # Cumulative, as measured on the real harness. Recorded per turn by adding, a conversation
    # would report 0.01, 0.03, 0.06 — plausible, monotonic and wrong.
    assert first.payload.total_cost_usd == 0.01
    assert second.payload.total_cost_usd == 0.02
    assert third.payload.total_cost_usd == 0.03
  end

  test "a message is echoed back when the harness takes it, which is delivery", context do
    {pid, _spec} = chat(context)
    assert_receive {:turn, _job_id, 1, _}, 5_000

    Runner.send_message(pid, "a question")
    assert_receive {:turn, _job_id, 2, _}, 5_000

    delivered =
      events()
      |> Enum.filter(&(&1.type == "job.harness.delivered"))
      |> Enum.map(& &1.payload.text)

    assert "a question" in delivered
  end

  # A reopened conversation whose last word was the agent's has nothing to answer. Delivering
  # the prompt at start, as a first start does, is a billed turn spent answering the opening
  # message a second time as though it were new — which is what the old path did, because the
  # platform handed a reopen the first `chat.message` as its prompt.
  # A conversation's documents are collected every turn, so what its last process left in
  # `out/` is recorded; a reopen that resumes its session clears it as a cold one does, whether
  # or not the resume is a fork.
  test "a resumed conversation starts with nothing in out/", context do
    held = spec(%{kind: :chat, prompt: nil, branch: "chat/held"})
    stale = Path.join([job_dir(context, held), "out", "stale.md"])
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "recorded last time\n")

    {pid, _spec} =
      chat(context, spec: held, hold_prompt: true, harness_opts: [resume_session: "sess-42"])

    refute File.exists?(stale)

    # Stopped before the test's directory is removed: the harness, which finds no session to
    # resume, is still writing into it.
    ref = Process.monitor(pid)
    Runner.close(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # Composed when the message arrives, into a directory the conversation's last process had for
  # its own: a `prompt.md` it left as a link is replaced, not written through.
  test "a held prompt is written new, not through a link the last process left", context do
    held = spec(%{kind: :chat, prompt: nil, replay: "# So far\n", branch: "chat/held"})
    job_dir = job_dir(context, held)
    File.mkdir_p!(job_dir)
    victim = Path.join(tmp_dir("outside"), "victim")
    File.write!(victim, "untouched")
    File.ln_s!(victim, Path.join(job_dir, "prompt.md"))

    {pid, _spec} = chat(context, spec: held, hold_prompt: true)
    assert Runner.send_message(pid, "hello") == :ok
    assert_receive {:turn, _job_id, 1, _event}, 5_000
    Runner.close(pid)

    assert File.read!(victim) == "untouched"
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(job_dir, "prompt.md"))
  end

  test "a held prompt waits for the first message and goes down with it", context do
    held =
      spec(%{
        kind: :chat,
        prompt: nil,
        replay: "# The conversation so far\n",
        branch: "chat/held"
      })

    {pid, spec} = chat(context, spec: held, hold_prompt: true)
    lines = Path.join(job_dir(context, spec), "fake-lines.jsonl")

    # Nothing was sent, so nothing was answered: no turn, and the harness has read no line.
    refute_receive {:turn, _job_id, _index, _event}, 500
    refute File.exists?(lines)
    refute File.exists?(Path.join(job_dir(context, spec), "prompt.md"))

    assert Runner.send_message(pid, "and what about the tests?") == :ok
    assert_receive {:turn, _job_id, 1, _event}, 5_000

    # One message, carrying both: the context a first start would have been given, and what
    # the person said next as its end. Two messages would be two turns, the first of them the
    # one this exists to avoid.
    assert [line] = lines |> File.read!() |> String.split("\n", trim: true)
    %{"message" => %{"content" => [%{"text" => text}]}} = Jason.decode!(line)

    assert String.starts_with?(text, "# You are in a conversation")
    assert text =~ "## This conversation was reopened"
    assert String.ends_with?(String.trim_trailing(text), "and what about the tests?")

    # `prompt.md` is the prompt as the harness was given it, which is this one.
    assert File.read!(Path.join(job_dir(context, spec), "prompt.md")) == text

    # And the one after it is an ordinary message: the prompt went once.
    assert Runner.send_message(pid, "thanks") == :ok
    assert_receive {:turn, _job_id, 2, _event}, 5_000
    assert [_first, second] = lines |> File.read!() |> String.split("\n", trim: true)
    assert %{"message" => %{"content" => [%{"text" => "thanks"}]}} = Jason.decode!(second)
  end

  # An interrupted turn reports `error_during_execution` with a null result — exactly what a
  # genuine failure reports. Only the runner knows it asked, so only the runner can say; left
  # to the payload, an operator's own Stop renders in their conversation as an error.
  test "an interrupted turn is labelled as interrupted, not as the error it claims", context do
    {pid, _spec} = chat(context, extra_env: [{"FAKE_TURN_SECONDS", "3"}])
    assert_receive {:turn, _job_id, 1, _}, 5_000

    Runner.send_message(pid, "SLOW please")
    Process.sleep(200)
    assert Runner.interrupt(pid) == :ok

    assert_receive {:turn, _job_id, 2, cut}, 5_000
    assert cut.payload.subtype == "error_during_execution"
    assert cut.payload.is_error == true
    assert cut.payload[:interrupted] == true

    # And the next turn is ordinary: the process survived the interrupt.
    Runner.send_message(pid, "after")
    assert_receive {:turn, _job_id, 3, after_turn}, 5_000
    assert after_turn.payload.subtype == "success"
    refute after_turn.payload[:interrupted]
  end

  # `kill/2` declined to record a reason whenever a result had already been seen, which is right
  # for a job — a result means the work finished and the signal only hurried the exit. A
  # conversation produces one every turn, so from turn two onwards a cancel silently stopped
  # being recorded as a cancel and the conversation looked like it ended on its own.
  test "cancelling after a turn has completed is still recorded as a cancel", context do
    {pid, _spec} = chat(context)
    assert_receive {:turn, _job_id, 1, _}, 5_000

    Runner.cancel(pid)

    # The reason, not the death: the process ends either way, so a test that only watches it
    # exit passes while the cancel goes unrecorded and the conversation reads as having
    # stopped by itself.
    assert {:ok, result} = Runner.await(pid, 10_000)
    assert result.killed == :operator
  end

  test "closing ends the process without cutting the turn in flight", context do
    {pid, _spec} = chat(context)
    assert_receive {:turn, _job_id, 1, _}, 5_000

    ref = Process.monitor(pid)
    assert Runner.close(pid) == :ok

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
  end

  # Started and then never answering looks exactly like a conversation that has stopped
  # replying, so it is refused where it can still be reported.
  test "a harness that cannot take streaming input is refused, not started", context do
    Process.flag(:trap_exit, true)

    assert {:error, {:unsupported, :streaming_input}} =
             Runner.start_link(
               spec: spec(),
               root: context.root,
               worktree: context.worktree,
               harness: NoStreaming,
               harness_opts: [mode: :streaming]
             )
  end

  test "the conversation controls are refused on an ordinary job", context do
    {:ok, pid} =
      Runner.start_link(
        spec: spec(),
        root: context.root,
        worktree: context.worktree,
        harness_opts: [executable: fake_executable(), credential: {:api_key, "k"}],
        extra_env: [{"FAKE_SCENARIO", "hang"}]
      )

    assert Runner.send_message(pid, "hello") == {:error, :unsupported}
    assert Runner.interrupt(pid) == {:error, :unsupported}
    assert Runner.close(pid) == {:error, :unsupported}

    # `hang` sleeps for a minute; left running it outlives the temporary directories the test
    # removes on exit, and complains about it on the way out.
    ref = Process.monitor(pid)
    Runner.cancel(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 20_000
  end

  defp events, do: receive_all([])

  defp receive_all(acc) do
    receive do
      {:event, event} -> receive_all([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
