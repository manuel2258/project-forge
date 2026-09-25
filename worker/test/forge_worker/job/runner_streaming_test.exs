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
        harness_opts: [
          executable: fake_executable(),
          credential: {:api_key, "secret-key"},
          mode: :streaming
        ],
        extra_env: [{"FAKE_SCENARIO", "chat"} | Keyword.get(extra, :extra_env, [])]
      ] ++ Keyword.drop(extra, [:spec, :extra_env])

    {:ok, pid} = Runner.start_link(opts)
    {pid, spec}
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
