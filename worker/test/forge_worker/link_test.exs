defmodule ForgeWorker.LinkTest.CrashingHarness do
  @moduledoc """
  A driver that raises while the runner builds the command — the moment before the credential is
  opened, and the one crash whose report would print whatever form the credential was carried in.
  """

  @behaviour ForgeWorker.Harness

  @impl true
  def capabilities, do: %{resume: true, streaming_input: true}

  @impl true
  def command(_spec, _job_dir, _opts) do
    send(Application.get_env(:forge_worker, :crashing_harness_test), :crashing)
    raise("this driver cannot build a command")
  end

  @impl true
  def parse_line(_line), do: []

  @impl true
  def encode_message(text), do: [text, "\n"]

  @impl true
  def encode_interrupt(id), do: [id, "\n"]

  @impl true
  def driver, do: "claude_code"

  @impl true
  def probe(_opts), do: %{driver: "claude_code", name: "Crashing", version: nil, aliases: []}
end

defmodule ForgeWorker.LinkTest.RaisingHarness do
  @moduledoc """
  A driver whose probe blows up instead of answering. `ClaudeCode.probe/1` swallows its own
  failures — a missing binary, an unreachable API — so it is the one thing that cannot reach
  the rescue in `Link.harness_offer/0`, which is what the rescue is for.
  """

  @behaviour ForgeWorker.Harness

  @impl true
  def capabilities, do: %{resume: true, streaming_input: true}

  @impl true
  def command(_spec, _job_dir, _opts), do: {"/bin/true", [], []}

  @impl true
  def parse_line(_line), do: []

  @impl true
  def encode_message(text), do: [text, "\n"]

  @impl true
  def encode_interrupt(id), do: [id, "\n"]

  @impl true
  def driver, do: "raising"

  @impl true
  def probe(_opts), do: raise("this driver cannot describe itself")
end

defmodule ForgeWorker.LinkTest.RecordingSlice do
  @moduledoc """
  `Slice.Direct`, plus a note to the test of what it was asked to confine.

  The interesting part of that note is how the environment was split. A plain value becomes
  `--setenv=NAME=VALUE` on the `systemd-run` command line and an assignment in the wrapper
  shell's own argv; a secret is in neither, nor anywhere else the slice is told, only in the file
  the process loads itself. That split is the difference between a push credential no other user
  can see and one any of them can read out of `/proc/*/cmdline` or the unit's properties —
  `docs/design/secrets.md` § Delivery.
  """

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  def prepare(opts) do
    if test = Application.get_env(:forge_worker, :slice_reporter), do: send(test, {:slice, opts})
    ForgeWorker.Slice.Direct.prepare(opts)
  end

  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate cleanup(context), to: ForgeWorker.Slice.Direct

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

defmodule ForgeWorker.LinkTest.UserSlice do
  @moduledoc """
  `Slice.Direct`, telling the test what happened to the job's user and in what order: made,
  handed the tree, a git command run as it, and gone — with, at that last, whether the ticket's
  template had already been kept, which is what must not happen while the user still owns it.
  """

  @behaviour ForgeWorker.Slice

  @impl ForgeWorker.Slice
  defdelegate prepare(opts), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate wrap(executable, args, context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate cleanup(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  def enter(job_id) do
    tell({:enter, job_id})
    {:ok, %{job_id: job_id}}
  end

  @impl ForgeWorker.Slice
  def own(_owner, paths) do
    tell({:own, paths})
    :ok
  end

  @impl ForgeWorker.Slice
  def run_as(_owner, executable, args) do
    tell({:as, git_command(args)})
    {executable, args}
  end

  # Whether the ticket's template — which the test names, since only it knows where — was already
  # there when the user went.
  @impl ForgeWorker.Slice
  def leave(_owner, paths) do
    kept =
      case Application.get_env(:forge_worker, :template_probe) do
        nil -> nil
        template -> File.exists?(template)
      end

    tell({:leave, paths, kept})
    :ok
  end

  defp tell(message) do
    if test = Application.get_env(:forge_worker, :slice_reporter),
      do: send(test, {:user, message})
  end

  defp git_command(["-c", _setting | rest]), do: git_command(rest)
  defp git_command([command | _rest]), do: command
  @impl ForgeWorker.Slice
  defdelegate memory(context), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate ended(context, output), to: ForgeWorker.Slice.Direct

  @impl ForgeWorker.Slice
  defdelegate probe(), to: ForgeWorker.Slice.Direct
end

defmodule ForgeWorker.LinkTest do
  @moduledoc """
  The worker's end of the protocol, against a simulated platform: what it says on joining,
  what it does with an assignment, and what it keeps saying until it is acked.
  """

  use Slipstream.SocketTest

  import ForgeWorker.Fixtures

  alias ForgeWorker.Link
  alias ForgeWorker.LinkTest.{CrashingHarness, RaisingHarness, RecordingSlice, UserSlice}

  @topic "worker:w-1"

  setup do
    origin = Path.join(tmp_dir("origin"), "project.git")
    work = tmp_dir("seed")
    git!(nil, ["init", "--bare", "--quiet", origin])
    git!(nil, ["clone", "--quiet", origin, work])
    git!(work, ["config", "user.name", "seed"])
    git!(work, ["config", "user.email", "seed@forge"])
    File.write!(Path.join(work, "README.md"), "# Game\n")
    git!(work, ["add", "."])
    git!(work, ["commit", "--quiet", "-m", "seed"])
    git!(work, ["branch", "-M", "main"])
    git!(work, ["push", "--quiet", "origin", "main"])
    git!(work, ["push", "--quiet", "origin", "main:ticket/1"])
    git!(nil, ["-C", origin, "symbolic-ref", "HEAD", "refs/heads/main"])

    root = tmp_dir("root")

    # The store is a plug rather than a platform: what matters here is that the transcript is
    # uploaded to the key the assignment names, with the token it carries.
    test = self()

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)

        send(
          test,
          {:uploaded, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
           conn.query_string, body}
        )

        Req.Test.json(conn, %{"key" => conn.request_path, "size" => byte_size(body)})
      end
    )

    Application.put_env(:forge_worker, :harness_opts, executable: fake_executable())
    Application.put_env(:forge_worker, :platform_url, "http://platform.test")
    stats_ms = Application.fetch_env!(:forge_worker, :stats_ms)

    on_exit(fn ->
      # A job outliving its test would carry on against directories that are about to go.
      ForgeWorker.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.each(&Process.exit(&1, :kill))

      Application.delete_env(:forge_worker, :req_options)
      Application.delete_env(:forge_worker, :harness_opts)
      Application.delete_env(:forge_worker, :platform_url)
      Application.delete_env(:forge_worker, :extra_env)
      Application.delete_env(:forge_worker, :harness)
      Application.delete_env(:forge_worker, :heartbeat_ms)
      Application.delete_env(:forge_worker, :refused_retry_ms)
      # Put back rather than deleted: the test config sets it long, and deleting it would leave
      # the five-second default for every test after this one.
      Application.put_env(:forge_worker, :stats_ms, stats_ms)
      Application.delete_env(:forge_worker, :slice)
      Application.delete_env(:forge_worker, :slice_reporter)
      Application.delete_env(:forge_worker, :token)
    end)

    client =
      start_supervised!(
        {Link,
         [
           uri: "ws://localhost/worker/websocket",
           test_mode?: true,
           worker_id: "w-1",
           root: root
         ]}
      )

    %{client: client, origin: origin, root: root}
  end

  defp assignment(origin, opts \\ []) do
    if scenario = Keyword.get(opts, :scenario) do
      harness = Application.get_env(:forge_worker, :harness_opts, [])
      Application.put_env(:forge_worker, :harness_opts, harness)
      env = [{"FAKE_SCENARIO", scenario} | Keyword.get(opts, :env, [])]
      Application.put_env(:forge_worker, :extra_env, env)
    end

    %{
      "job_id" => Keyword.get(opts, :job_id, uuid()),
      "spec" => spec() |> ForgeCore.Job.Spec.to_json() |> Jason.decode!(),
      "resume_session" => Keyword.get(opts, :resume_session),
      "wall_clock_ms" => 10_000,
      "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil},
      "store" => %{
        "transcript_key" => "job/j1/transcript-1.jsonl",
        "transcript_token" => "put-token"
      }
    }
  end

  # Every push from the client is a blocking call that a matching assert_push answers, so a
  # test that waits for one message has to consume the ones before it. A job pushes an event
  # per harness line before its result.
  defmacrop take_push(until) do
    quote do
      Enum.reduce_while(1..50, [], fn _i, seen ->
        assert_push(@topic, name, payload, ref, 5_000)
        Process.put(:last_push_ref, ref)

        if name == unquote(until),
          do: {:halt, {payload, Enum.reverse(seen)}},
          else: {:cont, [{name, payload} | seen]}
      end)
    end
  end

  defp last_push_ref, do: Process.get(:last_push_ref)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  # What the job's user went through, oldest first: `UserSlice`'s reports.
  defp user_story(acc \\ []) do
    receive do
      {:user, event} -> user_story([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp as_user(events), do: for({:as, command} <- events, do: command)

  # Nothing ran as the user once it was gone, and nothing ran before it had the tree.
  defp in_order!(events) do
    first_own = Enum.find_index(events, &match?({:own, _}, &1))
    first_as = Enum.find_index(events, &match?({:as, _}, &1))
    first_leave = Enum.find_index(events, &match?({:leave, _, _}, &1))

    last_as =
      events |> Enum.with_index() |> Enum.filter(&match?({{:as, _}, _}, &1)) |> List.last()

    assert match?({:enter, _}, hd(events)), "the user was not made first: #{inspect(events)}"
    assert first_own < first_as, "git ran before the tree was the user's: #{inspect(events)}"
    assert first_leave, "the user never went: #{inspect(events)}"
    assert elem(last_as, 1) < first_leave, "git ran after the user went: #{inspect(events)}"
  end

  # A store that answers every request the same way, and not with what was asked for.
  defp store_answers(status, body) do
    Application.put_env(:forge_worker, :req_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, status, body) end
    )
  end

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  test "it joins its own topic, reporting what it is running and what it has", %{client: client} do
    connect_and_assert_join(client, @topic, %{"running" => [], "memory_total" => budget}, :ok)
    assert budget > 0

    assert_push(@topic, "ready", %{"memory_budget" => ^budget, "cores" => cores})
    assert cores > 0
  end

  # What is speaking, in the join, because the platform decides there — before any work — whether
  # it will talk to this machine at all (`docs/design/worker-channel.md` § Versions).
  test "the join says which protocol and which release is speaking", %{client: client} do
    connect_and_assert_join(client, @topic, payload, :ok)

    assert payload["protocol"] == ForgeCore.WorkerProtocol.current()
    assert payload["release"] == to_string(Application.spec(:forge_worker, :vsn))

    # Not in the Nix store, so no build: absent rather than null, like `cores`.
    refute Map.has_key?(payload, "build")
  end

  test "a release in the Nix store is named by the first twelve characters of its hash" do
    hash = "8rh57whmgk6mxxxxxxxxxxxxxxxxxxxx"

    assert Link.build(~c"/nix/store/#{hash}-forge-worker-0.2.1") == "8rh57whmgk6m"
    assert Link.build("/nix/store/#{hash}-forge-worker-0.2.1") == "8rh57whmgk6m"

    # Anything else is no build at all, never a guess from a path that merely looks like one.
    assert Link.build("/usr/lib/forge_worker") == nil
    assert Link.build("/nix/store/short-forge-worker") == nil
    assert Link.build("/home/me/nix/store/#{hash}-forge-worker") == nil

    # The Erlang a `mix` run starts from is in the store too, and is not this worker's build.
    assert Link.build("/nix/store/#{hash}-erlang-28.5.0.6/lib/erlang") == nil
  end

  describe "what ready says about the gate's other two dimensions" do
    setup %{root: root} do
      previous = {
        Application.get_env(:forge_worker, :cores),
        Application.get_env(:forge_worker, :accepts)
      }

      on_exit(fn ->
        {cores, accepts} = previous
        restore(:cores, cores)
        restore(:accepts, accepts)
      end)

      Application.delete_env(:forge_worker, :cores)
      Application.delete_env(:forge_worker, :accepts)
      %{socket: Slipstream.Socket.assign(Slipstream.Socket.new(), %{root: root})}
    end

    defp restore(key, nil), do: Application.delete_env(:forge_worker, key)
    defp restore(key, value), do: Application.put_env(:forge_worker, key, value)

    test "a machine that restricts itself says so", %{socket: socket} do
      Application.put_env(:forge_worker, :cores, 4)
      Application.put_env(:forge_worker, :accepts, ["command"])

      assert %{"cores" => 4, "accepts" => ["command"]} = Link.ready_payload(socket)
    end

    # The key is *absent*, not null. The platform reads a missing key as "takes anything" and a
    # missing core count as "do not gate me on cores"; sending nulls would mean the same thing
    # only as long as nobody wrote `Map.has_key?` on the other side.
    test "a machine that restricts itself in neither way says neither", %{socket: socket} do
      payload = Link.ready_payload(socket)

      refute Map.has_key?(payload, "accepts")
      assert Map.has_key?(payload, "cores")
    end

    # Memory is always sent, because there not knowing is itself an instruction: a worker that
    # cannot measure its own memory offers nothing and the platform assigns it nothing. The two
    # dimensions are deliberately not symmetric — see `ForgeWorker.Config.cores/0`.
    test "memory is reported whatever it is", %{socket: socket} do
      Application.put_env(:forge_worker, :memory_budget, 0)
      on_exit(fn -> Application.delete_env(:forge_worker, :memory_budget) end)

      assert %{"memory_budget" => 0} = Link.ready_payload(socket)
    end
  end

  # `seeds` and `root` are the rest of the self-report and both were asserted only as an empty
  # list on a machine that had nothing — which an omitted key matches just as well. The seeds
  # are what make a worker worth reusing for a project (docs/design/worker-channel.md § Topic),
  # and they are reported twice, in `join` and again in `ready`, because the two are minutes
  # apart on a real machine and a rejoin re-reads them.
  test "join and ready both name the seeds this machine holds, and where they live", context do
    %{client: client, root: root} = context
    key = "seed/demo/sha256-abc"
    File.mkdir_p!(ForgeWorker.Job.Seed.path(root, key))

    connect_and_assert_join(client, @topic, %{"seeds" => [^key], "root" => ^root}, :ok)
    assert_push(@topic, "ready", %{"seeds" => [^key], "root" => ^root})
  end

  # `last_seen_at` is written by every heartbeat, and a worker the platform has not heard from
  # within `worker_timeout_ms` has its jobs re-queued, its machine destroyed and its row marked
  # `destroyed` — docs/design/worker-channel.md § When the machine goes away. Nothing in this
  # suite had ever seen one sent, so a worker that stopped heartbeating would have been swept
  # mid-job with the suite green. The interval is shortened for the test; see `Link.heartbeat_ms/0`.
  test "it heartbeats on its own, saying what it is running", context do
    %{client: client, origin: origin, root: root} = context
    Application.put_env(:forge_worker, :heartbeat_ms, 100)

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin, scenario: "hang")
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"running" => running}, _events} = take_push("heartbeat")
    assert running == [%{"job_id" => job_id, "attempt" => 1}]

    # A job is running from the moment it is taken, so the heartbeat can arrive while its clone
    # and its harness are still writing under `root` — which `on_exit` removes, and a removal
    # racing a write fails this test for nothing it asserts. The fake's last new file is the mark
    # that both are done.
    last = Path.join([root, "jobs", job["spec"]["job_id"], "fake-env-all.txt"])
    wait_until(fn -> File.exists?(last) end)
  end

  # How full the machine is, for the workers page, on a timer of its own and apart from the
  # heartbeat: the heartbeat is written to the row and this is written nowhere
  # (`docs/design/worker-channel.md` § Live figures).
  test "it reports how full it is on its own, and a CPU figure from the second reading", %{
    client: client
  } do
    Application.put_env(:forge_worker, :stats_ms, 100)

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    assert_push(@topic, "stats", first, _ref, 2_000)
    refute Map.has_key?(first, "cpu")
    assert first["memory_total"] > 0
    assert first["memory_used"] <= first["memory_total"]
    assert first["disk_used"] <= first["disk_total"]

    assert_push(@topic, "stats", second, _ref, 2_000)
    assert is_float(second["cpu"])
  end

  # The timers are started at the first join and never again. They used to be started at every
  # join, so each reconnect added another heartbeat — each a write to the row — for the life of
  # the machine.
  test "a rejoin does not start a second heartbeat", %{client: client} do
    Application.put_env(:forge_worker, :heartbeat_ms, 100)

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    send(client, topic_closed(@topic))
    assert_join(@topic, %{}, :ok, 2_000)
    assert_push(@topic, "ready", %{})

    # One timer beats five times in half a second and two beat ten. Counted with room either
    # side, because a timer's first tick is not aligned with the window.
    assert heartbeats_within(500) <= 7
  end

  defp heartbeats_within(ms) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn -> deadline - System.monotonic_time(:millisecond) end)
    |> Enum.reduce_while(0, fn
      left, count when left <= 0 ->
        {:halt, count}

      left, count ->
        receive do
          {:"$gen_call", from,
           {:__slipstream_command__,
            %Slipstream.Commands.PushMessage{topic: @topic, event: "heartbeat"}}} ->
            GenServer.reply(from, inspect(make_ref()))
            {:cont, count + 1}
        after
          left -> {:halt, count}
        end
    end)
  end

  describe "a platform that refuses it" do
    # One line and minutes, not Slipstream's own backoff: that settles at ten seconds, and only a
    # deploy changes the answer (`docs/design/worker-channel.md` § Versions).
    test "an unaccepted protocol is asked about again in minutes, not seconds", %{
      client: client,
      root: root
    } do
      Application.put_env(:forge_worker, :refused_retry_ms, 1_500)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          connect_and_assert_join(
            client,
            @topic,
            %{},
            {:error, %{"reason" => "protocol", "protocol" => 1, "minimum" => 2, "current" => 3}}
          )

          # Slipstream would have asked again 100ms later.
          refute_join(@topic, %{}, 1_000)
        end)

      assert log =~ "refused this worker's protocol #{ForgeCore.WorkerProtocol.current()}"
      assert log =~ "it accepts 2–3"

      # And it does ask again, once the wait is up, with its self-report as it is *now* — a seed
      # that arrived during the wait is in it, not the one the refused join carried.
      key = "seed/demo/sha256-new"
      File.mkdir_p!(ForgeWorker.Job.Seed.path(root, key))

      assert_join(@topic, %{"protocol" => _, "seeds" => [^key]}, :ok, 2_000)
      assert_push(@topic, "ready", %{})
    end

    # A reconnect while refused joins afresh and is refused afresh, which schedules its own retry.
    # The one before it must not also fire: every reconnect — every platform deploy — would add
    # another refused join and log line every few minutes, for as long as the machine is refused.
    test "a reconnect while refused leaves one retry, not two", %{client: client} do
      Application.put_env(:forge_worker, :refused_retry_ms, 1_500)
      refused = {:error, %{"reason" => "protocol", "minimum" => 2, "current" => 3}}

      ExUnit.CaptureLog.capture_log(fn ->
        connect_and_assert_join(client, @topic, %{}, refused)

        disconnect(client, :closed)
        connect_and_assert_join(client, @topic, %{}, refused)

        # The latest refusal's retry, refused again: that schedules the next one, minutes out.
        assert_join(@topic, %{}, refused, 3_000)

        # The first refusal's retry would land here.
        refute_join(@topic, %{}, 1_200)
      end)
    end

    # And it stops what it is running: nothing it reports from here can reach the platform, which
    # puts a refused machine's jobs back in the queue (`docs/design/worker-channel.md` § Versions).
    # A permanent machine that ran on would spend their credentials on runs nobody records.
    test "a refused join stops what the machine is running, and reports none of it", context do
      %{client: client, origin: origin} = context
      Application.put_env(:forge_worker, :refused_retry_ms, 60_000)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        disconnect(client, :closed)
        accept_connect(client)
        assert_join(@topic, %{}, {:error, %{"reason" => "destroyed"}})
      end)

      wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
      assert Link.unacked(client) == []
    end

    # After a reconnect a retired row is turned away at the socket — `WorkerSocket.connect/3`
    # answers 403 before any join — so the refused-join path above never hears of it.
    test "a connection the platform refuses stops what the machine is running", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        disconnect(client, {:error, {:upgrade_failure, %{status_code: 403}}})
        wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
      end)

      assert Link.unacked(client) == []
    end

    test "a retired machine is asked about in minutes too", %{client: client} do
      Application.put_env(:forge_worker, :refused_retry_ms, 60_000)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          connect_and_assert_join(client, @topic, %{}, {:error, %{"reason" => "destroyed"}})
          refute_join(@topic, %{}, 1_000)
        end)

      assert log =~ "retired this machine"
    end

    # Any other refusal is Slipstream's to retry: an `already_connected` is a stale channel of
    # this machine's own that is gone in a moment.
    test "any other refusal is retried as before", %{client: client} do
      Application.put_env(:forge_worker, :refused_retry_ms, 60_000)

      connect_and_assert_join(client, @topic, %{}, {:error, %{"reason" => "already_connected"}})
      assert_join(@topic, %{}, :ok, 2_000)
    end
  end

  # `ready` is the message that says what this machine can offer: its memory, and its harness.
  # Nothing about an account — a machine holds none — and, said by the link rather than the
  # harness, that this release takes a job's credential from the assignment, which is what the
  # platform gates on (`docs/design/credentials.md` § What a worker offers now).
  test "ready reports the harness, its capabilities, and that it takes a job's credential", %{
    client: client
  } do
    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})

    assert harness["driver"] == "claude_code"
    assert harness["version"] == "9.9.9"
    assert harness["credential"] == "per_job"
    refute Map.has_key?(harness, "login")
    refute Map.has_key?(harness, "models")

    # Computed since the first worker and never told to anyone until the probe existed.
    assert harness["capabilities"]["streaming_input"] == true
  end

  test "a worker whose harness binary is missing still goes ready, and says whose it is", %{
    client: client
  } do
    Application.put_env(:forge_worker, :harness_opts, executable: "/nonexistent/claude")

    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})

    # A version nobody could read is `nil` on the wire and not the string "nil": the offer is
    # encoded by walking it and turning atoms into strings, and `nil` is an atom. The platform
    # renders this figure straight onto the workers page, where "nil" would read as a version.
    assert harness["version"] == nil
    assert harness["driver"] == "claude_code"
    assert harness["credential"] == "per_job"
  end

  # The rescue around the whole of `harness_offer/0`: `ClaudeCode.probe/1` swallows its own
  # failures, so only a driver that genuinely raises — a new one, a bad option, a bug — gets
  # there. It still says which driver this is and that it takes a job's credential, because a
  # platform that heard neither would give it no agent job at all.
  test "a harness whose probe raises does not stop this machine going ready", %{client: client} do
    Application.put_env(:forge_worker, :harness, RaisingHarness)

    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})
    assert harness == %{"driver" => "raising", "credential" => "per_job"}
  end

  test "a dropped connection is retried rather than fatal", %{client: client} do
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    disconnect(client, :closed)

    # A worker boots minutes before anyone dials it back, and it is destroyed and recreated
    # several times a day: losing the connection is the normal case, not the exceptional one.
    # This link used to die on the first one and take the release with it.
    Process.sleep(100)
    assert Process.alive?(client)
    assert Link.unacked(client) == []
  end

  # A transcript the store will not take is not worth the job: the token may have lapsed
  # (`docs/design/storage.md` § Serving) or the store may be down, and the outcome is what the
  # engine acts on. The result arrives without a transcript key rather than not at all.
  test "a transcript the store refuses does not cost the job its result", context do
    %{client: client, origin: origin} = context

    Application.put_env(:forge_worker, :req_options,
      plug: fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"reason" => "expired_token"}})
      end
    )

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

    assert result["outcome"] == "converged"
    assert result["transcript"] == nil
  end

  # And with nowhere to put it — an assignment with no key — nothing is attempted.
  test "a transcript with no key to go to is not uploaded", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = origin |> assignment() |> Map.put("store", %{})
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

    assert result["outcome"] == "converged"
    assert result["transcript"] == nil
    refute_received {:uploaded, _path, _authorization, _query, _body}
  end

  test "an assignment is run, and its events and result reported", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, before} = take_push("result")

    # Everything the harness said, in order, as events on this job.
    assert [{"event", %{"event" => %{"type" => "job.harness.started"}}} | _rest] = before

    assert Enum.all?(before, fn {name, payload} ->
             name == "event" and payload["job_id"] == job_id
           end)

    assert result["status"] == "finished"
    assert result["outcome"] == "converged"
    assert result["transcript"] == "job/j1/transcript-1.jsonl"

    # The transcript went to the key the platform minted a token for, and nowhere else.
    assert_receive {:uploaded, "/store/job/j1/transcript-1.jsonl", authorization, query, body}

    # In the header, and *not* in the URL: a query string reaches every proxy log between the
    # worker and the platform. docs/design/storage.md § The token is a header.
    assert authorization == ["Bearer put-token"]
    refute query =~ "put-token"
    assert body =~ "\"type\":"

    # The agent's work reached the branch before the result was sent.
    assert git!(nil, ["-C", origin, "show", "refs/heads/ticket/1:CHANGED.md"]) =~ "by the agent"
  end

  # `docs/design/git-hosting.md` § Non-fast-forward on a ticket branch: the squash belongs to a
  # state that declares `changeset`. A state that declares none — `reviewing`, whose output is its
  # report — works in a scratch tree, and whatever is left in it when the run ends is nobody's
  # work. Ticket 3: a review killed mid-mutation had its broken tree committed and pushed, and
  # the branch is what merges.
  describe "a state whose produces holds no changeset" do
    defp reviewing(origin, opts) do
      origin
      |> assignment(Keyword.merge([env: [{"FAKE_DOC", "report.md"}]], opts))
      |> put_in(["spec", "produces"], ["report.md"])
    end

    test "leaves the ticket branch where it found it, whatever the run left in the tree",
         context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"])
      job = reviewing(origin, scenario: "leaves_dirty")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _events} = take_push("result")

      # The run itself converged: its document is its output, and it was accepted.
      assert %{"status" => "finished", "outcome" => "converged"} = result

      # And nothing of its tree reached the branch — not the tracked file it modified, not the
      # untracked one it wrote, and no commit at all.
      assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) == before
    end

    # The template is the other way the same tree reaches the branch: the ticket's next job
    # starts from it and, if it declares a changeset, commits what it inherited. Promoting a
    # scratch tree would launder a mutation into the next run's `add -A`.
    test "does not keep its scratch tree as the ticket's template", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = reviewing(origin, scenario: "leaves_dirty")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, _events} = take_push("result")

      refute File.dir?(Path.join([root, "volumes", "ticket", "1"]))
    end

    # Criterion 1 names three endings — converged, failed, and killed partway through with the
    # tree left dirty. The test above drives the first; this drives the third, which is the
    # ticket's own reproduction: a review stopped from outside between breaking the code and
    # restoring it. `terminal(%Result{killed: :operator}, head)` now reports the base for such a
    # state, and its only other test uses the default changeset spec.
    test "a cancelled run hibernates at the head it started from, committing nothing", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim()
      job = reviewing(origin, scenario: "dirties_then_hangs")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      # Not before the harness is really running: the tree is dirtied by its first lines.
      {_payload, _seen} = take_push("event")
      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "ticket_cancelled"})

      {%{"job_id" => ^job_id, "commit" => commit}, _events} = take_push("hibernated")

      # It still says what it spent, and it names the head it started from rather than one of
      # its own — because it made none.
      assert commit == before

      assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() ==
               before
    end

    # Criterion 3 of the refinement: the head a run reports is the one it started from, and a
    # state that never calls the push still has to name it. A parked run is where that head is
    # read — the commands it asked for run at it.
    #
    # The agent commits one of its own, which is what makes this the branch head and not the
    # worktree's: reporting `HEAD` here would name a commit that is on no ref anybody else can
    # fetch, and the commands would be asked to run at it.
    test "a parked run reports the head it started from", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim()

      job =
        origin
        |> reviewing(
          scenario: "invokes",
          env: [{"FAKE_DOC", "report.md"}, {"FAKE_COMMIT", "NOTES.md"}]
        )
        |> put_in(["spec", "may_invoke"], %{"build" => %{"max" => 2}, "test" => %{"max" => 2}})

      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _events} = take_push("result")

      assert result["status"] == "parked"
      assert result["commit"] == before
    end
  end

  # `docs/design/commands.md`: a command is checked out at its commit, runs the script its spec
  # carries, and reports its status and where its log went — and pushes nothing.
  describe "a command" do
    defp command_assignment(origin, script) do
      at =
        origin
        |> then(&git!(nil, ["-C", &1, "rev-parse", "refs/heads/ticket/1"]))
        |> String.trim()

      job_id = uuid()

      spec = %ForgeCore.Job.Spec{
        job_id: job_id,
        kind: :command,
        branch: "ticket/1",
        commit: at,
        command: %{
          "name" => "build",
          "args" => ["--all"],
          "script" => script,
          "at" => at,
          "timeout_ms" => 10_000
        }
      }

      %{
        "job_id" => job_id,
        "kind" => "command",
        "spec" => spec |> ForgeCore.Job.Spec.to_json() |> Jason.decode!(),
        "wall_clock_ms" => 10_000,
        "git" => %{"url" => origin, "branch" => "ticket/1", "base" => nil},
        "store" => %{"log_key" => "job/#{job_id}/log-1.txt", "log_token" => "log-token"}
      }
    end

    test "runs at its commit and reports its status and log", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"])
      job = command_assignment(origin, "#!/bin/sh\ncat README.md\necho \"args: $*\"\nexit 4\n")
      job_id = job["job_id"]
      log_key = job["store"]["log_key"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

      assert %{"status" => "finished", "outcome" => "converged", "exit_status" => 4} = result
      assert result["log"] == log_key
      assert is_integer(result["duration_ms"])

      path = "/store/" <> log_key
      assert_receive {:uploaded, ^path, ["Bearer log-token"], _query, "# Game\nargs: --all\n"}

      # A command writes its log, not the branch.
      assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) == before
    end

    # The script holds its secret in its environment, and a log that prints it leaves masked: the
    # log is what an agent that invoked the command reads, and what every member can open.
    test "a command's log leaves masked", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job =
        origin
        |> command_assignment("#!/bin/sh\necho \"token: $CARGO_REGISTRY_TOKEN\"\n")
        |> with_secrets(%{"CARGO_REGISTRY_TOKEN" => "cio_printed-by-a-build"})

      push(client, @topic, "assign", job)
      {%{"result" => %{"exit_status" => 0}}, _before} = take_push("result")

      path = "/store/" <> job["store"]["log_key"]
      assert_receive {:uploaded, ^path, _auth, _query, "token: [secret CARGO_REGISTRY_TOKEN]\n"}
    end

    # A packaging command's build, uploaded as a workflow job's groups are: without the upload the
    # result would carry a path on this machine, which the platform drops.
    test "uploads the groups of files its script wrote", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      script =
        "#!/bin/sh\nmkdir -p \"$FORGE_OUT/pkg\"\nprintf built > \"$FORGE_OUT/pkg/app.bin\"\n"

      job = command_assignment(origin, script)
      job = put_in(job, ["spec", "command", "outputs"], ["pkg/*"])
      job = Map.put(job, "outputs", %{"prefix" => "job/j1/out-abc/", "token" => "prefix-token"})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

      assert result["blobs"] == %{"pkg/app.bin" => %{"key" => "job/j1/out-abc/1", "size" => 5}}
      assert_receive {:uploaded, "/store/job/j1/out-abc/1", ["Bearer prefix-token"], _q, "built"}
      refute File.exists?(ForgeWorker.Job.Dir.blobs_dir(Path.join([root, "jobs", job_id])))
    end

    test "a commit that is not one is refused before anything runs", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\necho ran\n")
      job = put_in(job, ["spec", "command", "at"], "HEAD~1; rm -rf /")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("failed")
      assert reason =~ "not_a_commit"
    end

    # A sha is forty hex digits and then the end of the string: `$` let one more newline through.
    test "a commit with a trailing newline is refused as not one", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\necho ran\n")
      job = update_in(job, ["spec", "command", "at"], &(&1 <> "\n"))
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("failed")
      assert reason =~ "not_a_commit"
    end

    # `docs/design/worker-channel.md` § Reconnection: a run the platform has given up on — no
    # longer this machine's, or its row retired — is stopped and its ending reported to nobody. It
    # used to be reported, and the report landed on the job as it then was: a re-queued job
    # finished as an error, or left hibernated where nothing resumes it.
    test "a run the platform gave up on is stopped and reports nothing", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      for reason <- ["not_ours", "retired"] do
        job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
        job_id = job["job_id"]
        push(client, @topic, "assign", job)

        wait_until(fn ->
          match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
        end)

        push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => reason})

        wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
        refute_push(@topic, "result", _payload, 300)
        assert Link.unacked(client) == []
      end
    end

    # The scheduler prefers the machine a job last ran on, so a job re-queued off this machine can
    # come straight back while its old run is stopping. Dropped as *already running*, the platform
    # held a job marked `running` that nothing ran; it starts once the old run has stopped.
    test "a job assigned again while its given-up run stops is started once it has", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "not_ours"})
      push(client, @topic, "assign", put_in(job, ["spec", "command", "script"], "#!/bin/sh\n"))

      # The second run's answer — it exits 0 — and not the first's, which was cancelled.
      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")
      assert result["exit_status"] == 0
    end

    # A give-up that arrives while the old run is still stopping is the platform giving up the
    # held assignment too; started anyway, it ran on a credential the platform had let go of.
    test "a held assignment goes when the platform gives the job up again", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "not_ours"})
      push(client, @topic, "assign", put_in(job, ["spec", "command", "script"], "#!/bin/sh\n"))
      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "retired"})

      wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
      refute_push(@topic, "result", _payload, 500)
      assert :sys.get_state(client).assigns.deferred == %{}
    end

    # Any cancel ends the platform's interest in the job here: a held assignment goes with a
    # ticket's cancel as surely as with a give-up.
    test "a held assignment goes when the job's ticket is cancelled", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "not_ours"})
      push(client, @topic, "assign", put_in(job, ["spec", "command", "script"], "#!/bin/sh\n"))
      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "ticket_cancelled"})

      wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
      refute_push(@topic, "result", _payload, 500)
    end

    # A held assignment is taken as any assignment is when it starts — the ceiling, the machine's
    # health — not started as it stood when it was held.
    test "a held assignment is checked like any other when it starts", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "not_ours"})
      push(client, @topic, "assign", Map.put(job, "slice", %{"memory_max" => 1}))

      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")
      assert result["outcome"] == "error"
      assert result["reason"] =~ "minimum"
    end

    test "is stopped by a cancel, and says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      push(client, @topic, "cancel", %{"job_id" => job_id})

      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")
      assert %{"outcome" => "cancelled", "exit_status" => nil} = result
    end
  end

  # `docs/design/commands.md` § How an agent invokes: the run parks, and what it asked for runs at
  # the commit it pushed.
  test "an agent that invokes pushes its work and parks with what it asked for", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job =
      origin
      |> assignment(scenario: "invokes")
      |> put_in(["spec", "may_invoke"], %{"build" => %{"max" => 2}, "test" => %{"max" => 2}})

    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

    assert result["status"] == "parked"
    assert [%{"command" => "build"}, %{"command" => "test"}] = result["invocations"]

    assert result["commit"] ==
             String.trim(git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]))
  end

  # `docs/design/worker-tier.md` § A machine whose systemd stops answering, as the link carries it:
  # the platform is told, the jobs here are stopped and reported to nobody, nothing new is started,
  # and the platform's answer decides the reboot — with the machine's own say on top.
  describe "an unhealthy machine" do
    setup do
      name = :"link-health-#{System.unique_integer([:positive])}"
      Application.put_env(:forge_worker, :health, name)
      on_exit(fn -> Application.delete_env(:forge_worker, :health) end)
      %{health: name}
    end

    defp health(%{health: name}, managed, link \\ ForgeWorker.Link) do
      test = self()

      start_supervised!(
        {ForgeWorker.Health,
         name: name,
         link: link,
         probe_ms: nil,
         managed: fn -> managed end,
         reboot: fn ->
           send(test, :rebooted)
           :ok
         end}
      )

      name
    end

    @why "systemd-run could not reach PID 1: Failed to start transient service unit: " <>
           "Connection timed out"

    test "says so, stops its jobs and reports none of them", context do
      %{client: client, origin: origin} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      # A command, because it says nothing while it runs: an agent's events are pushes the test
      # would have to answer, and the stopping is the same either way.
      job = command_assignment(origin, "#!/bin/sh\nexec sleep 30\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      wait_until(fn ->
        match?(%{runner: pid} when is_pid(pid), :sys.get_state(client).assigns.jobs[job_id])
      end)

      ForgeWorker.Health.unreachable(@why, health)
      {%{"reason" => @why}, _before} = take_push("unhealthy")

      # Stopped, and its ending reported to nobody: the platform has put it back in the queue,
      # and a result from here would be recorded as the job's own.
      wait_until(fn -> :sys.get_state(client).assigns.jobs == %{} end)
      refute_push(@topic, "result", _payload, 200)
      assert Link.unacked() == [{:machine, "unhealthy"}]
    end

    test "starts nothing it is given afterwards, and reports nothing of it", context do
      %{client: client, origin: origin} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")

      push(client, @topic, "assign", assignment(origin))
      refute_push(@topic, "result", _payload, 500)
      assert Link.running() == []
    end

    test "reboots on the platform's yes when a driver made it", context do
      %{client: client} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      reply(client, last_push_ref(), {:ok, %{"reboot" => true, "why" => "told to reboot"}})

      assert_receive :rebooted, 2_000
      wait_until(fn -> Link.unacked() == [] end)
    end

    # **An unmanaged machine never reboots itself**, whatever the platform says.
    test "does not reboot on the platform's yes when no driver made it", context do
      %{client: client} = context
      health = health(context, false)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      reply(client, last_push_ref(), {:ok, %{"reboot" => true}})

      refute_receive :rebooted, 500
    end

    test "does not reboot on the platform's no", context do
      %{client: client} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      reply(client, last_push_ref(), {:ok, %{"reboot" => false, "why" => "within the hour"}})

      refute_receive :rebooted, 500
    end

    # A worker that restarted its link, or joined again, is still unhealthy: its join says so —
    # which is what keeps the platform's mark — and the report goes again until it is acked. The
    # health process here told a link that is not this one, as it would have told the link that
    # crashed: this one hears of it only by asking, at its join.
    test "says so in its join, and reports it after the join", context do
      %{client: client} = context
      health = health(context, true, :a_link_that_is_gone)
      ForgeWorker.Health.unreachable(@why, health)

      connect_and_assert_join(client, @topic, %{"unhealthy" => @why}, :ok)
      assert_push(@topic, "ready", %{})
      {%{"reason" => @why}, _before} = take_push("unhealthy")
    end

    # Re-sent after a reconnect because it was not acked — and once: the join asks too, and a
    # report still waiting is not made again.
    test "an unacked report goes again after a reconnect, once", context do
      %{client: client} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      disconnect(client, :closed)

      accept_connect(client)
      assert_join(@topic, %{"unhealthy" => @why}, :ok)
      {%{"reason" => @why}, _before} = take_push("unhealthy")
      refute_push(@topic, "unhealthy", _again, 200)
    end

    # Answered is answered: a rejoin keeps the platform's mark by its join alone, and asking again
    # would move the time it said to reboot, and with it the hour and the grace.
    test "an answered report is not made again after a reconnect", context do
      %{client: client} = context
      health = health(context, false)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      reply(client, last_push_ref(), {:ok, %{"reboot" => false, "why" => "not ours"}})
      wait_until(fn -> Link.unacked() == [] end)

      disconnect(client, :closed)
      accept_connect(client)
      assert_join(@topic, %{"unhealthy" => @why}, :ok)
      assert_push(@topic, "ready", %{})
      refute_push(@topic, "unhealthy", _again, 300)
    end

    # A health process that restarted has forgotten, and a mark it makes again is a new episode —
    # said again, or a platform whose mark a healthy-looking join cleared would never hear of it.
    test "a new mark after an answered one is reported again", context do
      %{client: client} = context
      health = health(context, false)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")
      reply(client, last_push_ref(), {:ok, %{"reboot" => false, "why" => "not ours"}})
      wait_until(fn -> Link.unacked() == [] end)

      stop_supervised!(ForgeWorker.Health)
      health = health(context, false)
      ForgeWorker.Health.unreachable(@why, health)
      {%{"reason" => @why}, _before} = take_push("unhealthy")
    end

    # Abandoned between its assignment and its runner — the window of a clone, held still here —
    # and stopped the moment the runner exists: the platform put it back in the queue already.
    test "stops a job it abandoned before the job had a runner, once it has one", context do
      %{client: client} = context
      health = health(context, true)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      :sys.replace_state(client, fn socket ->
        put_in(socket.assigns.jobs["j-1"], %{runner: nil, kind: :command, attempt: 1, started: 0})
      end)

      ForgeWorker.Health.unreachable(@why, health)
      take_push("unhealthy")

      send(client, {:runner, "j-1", self()})
      assert_receive {:"$gen_cast", :cancel}, 1_000
    end

    test "a healthy machine's join says nothing of it", context do
      %{client: client} = context
      health(context, true)

      connect_and_assert_join(client, @topic, join, :ok)
      refute Map.has_key?(join, "unhealthy")
    end
  end

  # `docs/design/worker-tier.md` § The job slice: the worker refuses a ceiling too small to run in,
  # whatever the platform sent — the last place one can be kept from systemd, where two bytes made
  # a machine's PID 1 stop answering. Ended at once, as an error naming both figures.
  describe "a ceiling below the minimum" do
    @minimum 536_870_912

    defp with_ceiling(job, bytes),
      do: Map.put(job, "slice", %{"memory_max" => bytes, "cpu_weight" => 100})

    test "a workflow job is not started, and ends as an error naming the ceiling and the minimum",
         context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      before = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"])
      job = origin |> assignment() |> with_ceiling(2)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, pushed} = take_push("result")

      assert %{"status" => "finished", "outcome" => "error"} = result
      assert result["reason"] =~ "memory ceiling of 2 B is below the 512 MiB minimum"
      # Nothing ran: no harness said a word, and nothing reached the branch.
      refute Enum.any?(pushed, &match?({"event", _}, &1))
      assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) == before
      assert Link.running() == []
    end

    test "the minimum itself runs", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> assignment() |> with_ceiling(@minimum)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _pushed} = take_push("result")
      assert result["outcome"] == "converged"
    end

    test "a byte below it is refused, and so is a ceiling that is not a number", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      # Each names the ceiling and the minimum (`docs/design/worker-tier.md` § The job slice).
      for {ceiling, says} <- [
            {@minimum - 1, "ceiling of 536870911 B is below the 512 MiB minimum"},
            {"2GiB",
             ~s(ceiling "2GiB" is not a number of bytes, and the least a job can run in is ) <>
               "the 512 MiB minimum"},
            {0, "ceiling of 0 bytes is below the 512 MiB minimum"}
          ] do
        job = origin |> assignment() |> with_ceiling(ceiling)
        job_id = job["job_id"]
        push(client, @topic, "assign", job)

        {%{"job_id" => ^job_id, "result" => result}, _pushed} = take_push("result")
        assert result["outcome"] == "error"
        assert result["reason"] =~ says
      end
    end

    test "a command is refused the same way", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> command_assignment("#!/bin/sh\necho ran\n") |> with_ceiling(2)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "result" => result}, _pushed} = take_push("result")
      assert %{"outcome" => "error", "exit_status" => nil} = result
      assert result["reason"] =~ "below the 512 MiB minimum"
    end

    # A chat can only fail, and that is what it does: it never had a process to hibernate.
    test "a chat fails, with the same reason", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job_id = uuid()

      job =
        with_ceiling(
          %{
            "job_id" => job_id,
            "kind" => "chat",
            "spec" =>
              spec()
              |> Map.put(:job_id, job_id)
              |> ForgeCore.Job.Spec.to_json()
              |> Jason.decode!(),
            "git" => %{"url" => "/nowhere", "branch" => "chat/" <> job_id}
          },
          2
        )

      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id, "reason" => reason}, _pushed} = take_push("failed")
      assert reason =~ "memory ceiling of 2 B is below the 512 MiB minimum"
      assert ForgeWorker.Job.Conversation.whereis(job_id) == nil
    end
  end

  # `docs/design/claude-code-events.md` § Resume: the session a resume needs is a file in the
  # harness's `HOME`, carried between machines through the store. `session` in the fake CLI keeps
  # one where Claude Code does and reads it back on `--resume` — from any project directory, and
  # with nothing there exits before `init`, as measured.
  describe "the harness session" do
    @session ~s({"type":"user","sessionId":"sess-42","parentUuid":null,"uuid":"u1","message":{"content":"remember PELICAN"}}\n)

    # A store that serves `files` by path and records every upload.
    defp store_serving(files) do
      test = self()

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          case {conn.method, Map.fetch(files, conn.request_path)} do
            {"GET", {:ok, body}} ->
              Plug.Conn.send_resp(conn, 200, body)

            {"GET", :error} ->
              Plug.Conn.send_resp(conn, 404, "no such key")

            _put ->
              {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)
              auth = Plug.Conn.get_req_header(conn, "authorization")
              send(test, {:uploaded, conn.request_path, auth, conn.query_string, body})
              Req.Test.json(conn, %{"key" => conn.request_path, "size" => byte_size(body)})
          end
        end
      )
    end

    # One job id for the assignment and its spec, as the platform sends them: the job directory
    # the runner prepares and the one the link reads the session back from are the same.
    defp session_job(origin, extra \\ %{}) do
      job = assignment(origin, scenario: "session")
      job = put_in(job, ["spec", "job_id"], job["job_id"])

      job
      |> put_in(["store", "session_prefix"], "job/#{job["job_id"]}/session-abc/")
      |> put_in(["store", "session_token"], "session-token")
      |> Map.merge(extra)
    end

    defp carried(version \\ "9.9.9"),
      do: %{
        "key" => "job/j0/session-x/1.jsonl",
        "token" => "get",
        "id" => "sess-42",
        "version" => version
      }

    defp run_job(client, job) do
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")
      result
    end

    defp job_file(root, job, name), do: File.read!(Path.join([root, "jobs", job["job_id"], name]))

    defp uploaded_paths(acc \\ []) do
      receive do
        {:uploaded, path, _auth, _q, _body} -> uploaded_paths([path | acc])
      after
        0 -> acc
      end
    end

    setup %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      :ok
    end

    test "a run uploads its session under the assignment's prefix, and says what wrote it",
         context do
      %{client: client, origin: origin} = context
      store_serving(%{})
      job = session_job(origin)

      result = run_job(client, job)

      key = "job/#{job["job_id"]}/session-abc/1.jsonl"
      assert result["harness"]["session_blob"] == key
      assert result["harness"]["session_id"] == "sess-42"
      assert result["harness"]["version"] == "9.9.9"

      assert_receive {:uploaded, "/store/" <> ^key, ["Bearer session-token"], _q, body}
      assert body =~ ~s("sessionId":"sess-42")
    end

    test "a run with nowhere to put its session keeps it to itself", context do
      %{client: client, origin: origin} = context
      store_serving(%{})
      job = origin |> session_job() |> Map.update!("store", &Map.drop(&1, ["session_prefix"]))

      result = run_job(client, job)

      refute Map.has_key?(result["harness"], "session_blob")
      refute Enum.any?(uploaded_paths(), &String.contains?(&1, "/session-"))
    end

    # The machine never ran this job: without the carried file there is nothing to resume.
    test "a resume on another machine restores the carried session", context do
      %{client: client, origin: origin, root: root} = context
      store_serving(%{"/store/job/j0/session-x/1.jsonl" => @session})
      job = session_job(origin, %{"resume_session" => "sess-42", "session" => carried()})

      result = run_job(client, job)

      assert result["documents"]["plan.md"]["raw"] =~ "Remembered PELICAN."
      assert job_file(root, job, "fake-args.txt") =~ "--resume sess-42"
      assert job_file(root, job, "prompt.md") =~ "# Continue this job"
    end

    test "a new attempt that came back forks its predecessor's session", context do
      %{client: client, origin: origin, root: root} = context
      store_serving(%{"/store/job/j0/session-x/1.jsonl" => @session})

      job =
        origin
        |> session_job(%{
          "resume_session" => "sess-42",
          "fork_session" => true,
          "session" => carried()
        })
        |> put_in(["spec", "attempt"], 2)

      result = run_job(client, job)

      assert result["harness"]["session_id"] == "sess-42-fork"
      assert result["documents"]["plan.md"]["raw"] =~ "Remembered PELICAN."
      assert job_file(root, job, "fake-args.txt") =~ "--resume sess-42 --fork-session"
      assert job_file(root, job, "prompt.md") =~ "# A new attempt of"
    end

    # A fork is told its output directory is empty. Run again on the machine that lost it, what
    # the lost run left there is not this run's.
    test "a fork run again where it ran before starts with nothing in out/", context do
      %{client: client, origin: origin, root: root} = context
      store_serving(%{"/store/job/j0/session-x/1.jsonl" => @session})

      job =
        origin
        |> session_job(%{
          "resume_session" => "sess-42",
          "fork_session" => true,
          "session" => carried()
        })
        |> put_in(["spec", "attempt"], 2)

      stale = Path.join([root, "jobs", job["job_id"], "out", "stale.md"])
      File.mkdir_p!(Path.dirname(stale))
      File.write!(stale, "left by the run that was lost\n")

      result = run_job(client, job)

      assert result["documents"]["plan.md"]["raw"] =~ "Remembered PELICAN."
      refute File.exists?(stale)
    end

    # A file restored onto another CLI, or one that is not the session's own, starts a session
    # with no memory rather than failing (`docs/measurements.md` § Session resume). So neither is
    # restored, and the run is a cold start: no `--resume`, the whole prompt.
    test "a session written by another version of the CLI is not restored", context do
      %{client: client, origin: origin, root: root} = context
      store_serving(%{"/store/job/j0/session-x/1.jsonl" => @session})
      job = session_job(origin, %{"resume_session" => "sess-42", "session" => carried("1.0.0")})

      result = run_job(client, job)

      assert result["documents"]["plan.md"]["raw"] =~ "Remembered nothing."
      refute job_file(root, job, "fake-args.txt") =~ "--resume"
      assert job_file(root, job, "prompt.md") =~ "# You are one job in a ticket lifecycle"
    end

    test "a file that is not the session's own is not restored", context do
      %{client: client, origin: origin, root: root} = context
      # The harness's stdout: JSON, the session's id, and no chained record.
      stdout = ~s({"type":"system","subtype":"init","session_id":"sess-42"}\n)
      store_serving(%{"/store/job/j0/session-x/1.jsonl" => stdout})
      job = session_job(origin, %{"resume_session" => "sess-42", "session" => carried()})

      result = run_job(client, job)

      assert result["documents"]["plan.md"]["raw"] =~ "Remembered nothing."
      refute job_file(root, job, "fake-args.txt") =~ "--resume"
    end

    # Nothing to check, so nothing to drop: the resume goes ahead and finds what the machine
    # holds, which here is nothing — and the harness says so before it starts, which the
    # platform re-queues as a cold start.
    test "a session that will not download leaves the resume to the machine", context do
      %{client: client, origin: origin, root: root} = context
      store_serving(%{})
      job = session_job(origin, %{"resume_session" => "sess-42", "session" => carried()})

      result = run_job(client, job)

      assert job_file(root, job, "fake-args.txt") =~ "--resume sess-42"
      assert result["outcome"] == "error"
      assert result["harness"]["model"] == nil
    end
  end

  # `docs/design/storage.md` § Serving: each staged file goes to the assignment's prefix with its
  # prefix token, and the result names keys — never a path on this machine.
  test "a job's groups of files are uploaded under its prefix", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job =
      origin
      |> assignment(scenario: "shots")
      |> put_in(["spec", "produces"], ["plan.md", "shots/*"])
      |> Map.put("outputs", %{"prefix" => "job/j1/out-abc/", "token" => "prefix-token"})

    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

    assert result["blobs"] == %{
             "shots/home.png" => %{"key" => "job/j1/out-abc/1", "size" => 10},
             "shots/menu.png" => %{"key" => "job/j1/out-abc/2", "size" => 6}
           }

    assert result["invalid_blobs"]["shots/.hidden"] =~ "is not a name"
    assert_receive {:uploaded, "/store/job/j1/out-abc/1", ["Bearer prefix-token"], _q, body}
    assert body == <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1>>
    assert_receive {:uploaded, "/store/job/j1/out-abc/2", _auth, _q, "second"}
    refute File.exists?(ForgeWorker.Job.Dir.blobs_dir(Path.join([root, "jobs", job_id])))
  end

  test "a group with nowhere to be uploaded is reported, not lost silently", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job =
      origin
      |> assignment(scenario: "shots")
      |> put_in(["spec", "produces"], ["plan.md", "shots/*"])

    push(client, @topic, "assign", job)
    {%{"result" => result}, _before} = take_push("result")

    assert result["blobs"] == %{}

    assert result["invalid_blobs"]["shots/home.png"] ==
             "the assignment named nowhere to upload it"

    assert result["outcome"] == "converged"
  end

  test "a resumed job is handed the logs of what it invoked", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job =
      origin
      |> assignment(scenario: "reads_logs")
      |> Map.put("commands", [
        %{"file" => "1-build.log", "key" => "job/c1/log-1.txt", "token" => "get-token"}
      ])

    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "result" => result}, _before} = take_push("result")

    # The store here answers every request with where it was asked; the agent read that back.
    assert result["documents"]["plan.md"]["raw"] =~ "/store/job/c1/log-1.txt"
  end

  test "a result is held until the platform acks it on the channel", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)
    {%{"job_id" => ^job_id}, _events} = take_push("result")

    # The reply the transport made above is not the platform's: nothing came back on the
    # channel, so the client is still holding the message for the next join to re-send.
    assert Link.unacked(client) == [{job_id, "result"}]

    reply(client, last_push_ref(), {:ok, %{}})
    wait_until(fn -> Link.unacked(client) == [] end)
  end

  # The other half of § Delivery, and the one that is easy to lose: a terminal message the
  # socket would not take is *kept*, not dropped. A worker outlives its connection by design —
  # the platform is redeployed, the machine's network blips — and the result is the whole
  # record of what a billed run produced. Dropping it here loses the job's outcome silently;
  # what the platform then sees is a job that runs for ever until the rejoin reconciliation
  # re-queues it and pays for it twice.
  test "a result produced while the platform is away is delivered on the next join", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)
    disconnect(client, :closed)

    # The job runs to its end against a socket that is not there: its events go nowhere and
    # the result has nowhere to go but the unacked map.
    wait_until(fn -> Link.unacked(client) == [{job_id, "result"}] end, 300)

    accept_connect(client)
    assert_join(@topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    {%{"job_id" => ^job_id, "result" => result}, _events} = take_push("result")
    assert result["status"] == "finished"
  end

  # And a message that *was* pushed and never answered is pushed again. The platform acks only
  # after the transaction recording the result commits, so a platform that died in between has
  # not recorded it — the worker's copy is the only one left, and every rejoin offers it again.
  test "an unacked result is sent again after the connection comes back", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)
    {%{"job_id" => ^job_id}, _events} = take_push("result")
    assert Link.unacked(client) == [{job_id, "result"}]

    disconnect(client, :closed)
    accept_connect(client)
    assert_join(@topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    {%{"job_id" => ^job_id}, _events} = take_push("result")
  end

  # A reply belongs to the connection it came on. Refs are a counter that starts again with each
  # connection, so the old connection's ref for an unacked result could be the new connection's
  # ref for an untracked `ready` — and its reply forgot the result, which the next drop then lost.
  test "a reply on a new connection cannot forget what the old one was waiting on", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)
    {%{"job_id" => ^job_id}, _events} = take_push("result")
    old = last_push_ref()

    disconnect(client, :closed)
    accept_connect(client)
    assert_join(@topic, %{}, :ok)
    assert_push(@topic, "ready", %{})
    {%{"job_id" => ^job_id}, _events} = take_push("result")
    refute last_push_ref() == old

    reply(client, old, :ok)
    Process.sleep(100)
    assert Link.unacked(client) == [{job_id, "result"}]
  end

  # A channel the platform closed under us — a redeploy, a restart, a row it no longer believes
  # in — is not the end of this worker. Slipstream's default for this callback is to stop, which
  # on a `restart: :permanent` release means losing every unacked result this machine is holding;
  # rejoining is also what re-runs the reconciliation § Reconnection describes.
  test "a channel the platform closed is rejoined rather than fatal", %{client: client} do
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    send(client, topic_closed(@topic))

    # Slipstream backs a rejoin off — the first attempt is 100ms out — so this waits longer
    # than the default assertion timeout.
    assert_join(@topic, %{}, :ok, 2_000)
    assert_push(@topic, "ready", %{})
    assert Process.alive?(client)
  end

  # `Slipstream.SocketTest` can emulate a dropped connection but not a channel closed under a
  # live one, so the event is built by hand. The tuple is Slipstream's own `event/1` signature.
  defp topic_closed(topic) do
    {:__slipstream_event__,
     %Slipstream.Events.TopicJoinClosed{topic: topic, reason: :closed_by_platform}}
  end

  # `docs/design/worker-log.md`: the lines this machine sends about itself. The stream is off in
  # the test config, since a push nobody asked for stalls this link, and on for these.
  describe "the machine's log" do
    setup do
      stream = Application.get_env(:forge_worker, :log_stream)
      Application.put_env(:forge_worker, :log_stream, true)
      on_exit(fn -> Application.put_env(:forge_worker, :log_stream, stream) end)
    end

    # `job.abandoned`, once per run whichever give-up comes first: a second word about a run
    # already given up neither says it again nor cancels it again.
    test "a run given up on is a line once, and cancelled once", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      test = self()

      :sys.replace_state(client, fn socket ->
        put_in(socket.assigns.jobs["j-1"], %{
          runner: test,
          kind: :command,
          attempt: 1,
          started: 0
        })
      end)

      push(client, @topic, "cancel", %{"job_id" => "j-1", "reason" => "not_ours"})

      assert_push(@topic, "log", %{"type" => "job.abandoned", "job_id" => "j-1", "message" => why})

      assert why =~ "no longer has it running here"
      assert_receive {:"$gen_cast", :cancel}, 1_000

      push(client, @topic, "cancel", %{"job_id" => "j-1", "reason" => "retired"})
      refute_push(@topic, "log", %{"type" => "job.abandoned"}, 300)
      refute_receive {:"$gen_cast", :cancel}, 300
    end

    test "a job accepted and a job finished are a line each, tied to the job", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> assignment() |> put_in(["spec", "attempt"], 3)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [{"log", accepted} | _events] = before
      assert accepted["type"] == "job.accepted"
      assert accepted["job_id"] == job_id
      assert accepted["message"] == "took on a workflow job, attempt 3"

      assert_push(@topic, "log", finished)
      assert finished["type"] == "job.finished"
      assert finished["level"] == "info"
      assert finished["job_id"] == job_id
      assert finished["message"] =~ ~r/^ended with a result: finished, converged, after \d+s$/
    end

    test "a job that failed is an error line, with the first line of why", context do
      %{client: client} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = assignment("/nowhere/there-is-no-repository.git")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _before} = take_push("failed")

      assert_push(@topic, "log", finished)
      assert {finished["type"], finished["level"]} == {"job.finished", "error"}
      assert finished["message"] =~ ~r/^failed: .*there-is-no-repository.*, after \d+s$/
      refute finished["message"] =~ "\n"
    end

    test "a chat taken on and closed is a line each", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, before} = take_push("turn")
      assert {"log", %{"type" => "job.accepted", "message" => "took on a chat"}} = hd(before)

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done talking"})
      {%{"job_id" => ^job_id}, _before} = take_push("hibernated")

      assert_push(@topic, "log", %{"type" => "job.finished", "job_id" => ^job_id} = finished)
      assert finished["message"] =~ ~r/^hibernated: done talking, after \d+s$/
      assert finished["level"] == "info"
    end

    # A conversation that crashed used to leave the platform believing it ran here, for ever:
    # nothing monitored it, and it had no chance to say it was going.
    test "a chat that crashes is reported as failed", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _before} = take_push("turn")

      job_id |> ForgeWorker.Job.Conversation.whereis() |> Process.exit(:kill)

      {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("failed")
      assert reason == "the conversation stopped: killed"
    end

    test "a crash for any reason says which", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _before} = take_push("turn")

      job["job_id"] |> ForgeWorker.Job.Conversation.whereis() |> GenServer.stop(:boom)

      {%{"reason" => reason}, _before} = take_push("failed")
      assert reason == "the conversation stopped: :boom"
    end

    # The chat that sat for 38 minutes. Its harness never said it started; it is stopped, and
    # the platform is told why it ended rather than "ended".
    test "a chat whose harness never starts ends saying so", context do
      %{client: client, origin: origin} = context
      Application.put_env(:forge_worker, :start_notice_ms, 50)
      Application.put_env(:forge_worker, :start_timeout_ms, 100)

      on_exit(fn ->
        Application.delete_env(:forge_worker, :start_notice_ms)
        Application.delete_env(:forge_worker, :start_timeout_ms)
      end)

      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin, env: [{"FAKE_SCENARIO", "never_starts"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("hibernated")
      assert reason == "the harness had not started after 0s"
    end

    test "a message for a chat not running here is a line in the machine's log", %{
      client: client
    } do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      push(client, @topic, "message", %{"job_id" => "gone", "message_id" => "1", "text" => "hi"})

      assert_push(@topic, "log", %{"type" => "chat.missing", "job_id" => "gone"} = line)
      assert line["message"] == "asked to message a chat that is not running here"
    end

    # A crash's reason is its whole stack trace; the line keeps what names it, and the journal
    # has the rest. Sent as a job's process sends it, for a job this link never started — a chat
    # that could not — so there is no start to say how long it ran from.
    test "a failure is a line of one line", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      job_id = uuid()

      reason = "** (RuntimeError) the harness fell over\n    (forge_worker) lib/x.ex:1: X.y/0"
      send(client, {:terminal, job_id, "failed", %{"job_id" => job_id, "reason" => reason}})

      assert_push(@topic, "failed", %{"job_id" => ^job_id})
      assert_push(@topic, "log", %{"type" => "job.finished", "level" => "error"} = finished)
      assert finished["message"] == "failed: ** (RuntimeError) the harness fell over"
    end

    # An assignment for a job already running is not a job taken on.
    test "a job assigned twice is accepted once", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = assignment(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")
      accepted = for {"log", %{"type" => "job.accepted"} = line} <- before, do: line
      assert length(accepted) == 1
    end

    # A result is ended with whatever it says; one with no outcome says so rather than nothing.
    test "a result with no outcome says so", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      job_id = uuid()

      result = %{"status" => "waiting", "outcome" => nil}
      send(client, {:terminal, job_id, "result", %{"job_id" => job_id, "result" => result}})

      assert_push(@topic, "result", %{"job_id" => ^job_id})
      assert_push(@topic, "log", %{"type" => "job.finished", "level" => "info"} = finished)
      assert finished["message"] == "ended with a result: waiting, no outcome"
    end

    test "a message this release does not know is a line", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      push(client, @topic, "drain", %{})

      assert_push(@topic, "log", %{"type" => "message.unknown", "level" => "warning"} = line)
      assert line["message"] =~ ~s(unknown message "drain")
    end

    test "a harness that cannot describe itself is a line", %{client: client} do
      Application.put_env(:forge_worker, :harness, RaisingHarness)

      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      assert_push(@topic, "log", %{"type" => "harness.unprobed", "level" => "warning"} = line)
      assert line["message"] =~ "this driver cannot describe itself"
    end

    # **Held while the platform is away, and sent after `ready` at the next join**, so a job that
    # finished meanwhile is in the log at the time the machine says it finished. A hundred at
    # most, and a line saying how many more there were.
    test "lines written while not joined are held, and sent at the next join", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      disconnect(client, :closed)

      for n <- 1..102, do: send(client, {:log, %{"type" => "line", "message" => "#{n}"}})

      accept_connect(client)
      assert_join(@topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      assert_push(@topic, "log", %{"type" => "log.dropped", "message" => dropped})
      assert dropped =~ "2 line(s)"

      for n <- 3..102 do
        message = to_string(n)
        assert_push(@topic, "log", %{"type" => "line", "message" => ^message})
      end

      refute_push(@topic, "log", _anything)

      # Sent once: the next join has nothing held.
      disconnect(client, :closed)
      accept_connect(client)
      assert_join(@topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      refute_push(@topic, "log", _anything)
    end

    test "with the stream off, nothing is sent and nothing is held", %{client: client} do
      Application.put_env(:forge_worker, :log_stream, false)
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      send(client, {:log, %{"type" => "line", "message" => "joined"}})
      refute_push(@topic, "log", _anything)

      disconnect(client, :closed)
      send(client, {:log, %{"type" => "line", "message" => "away"}})
      accept_connect(client)
      assert_join(@topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      refute_push(@topic, "log", _anything)
    end

    # What the worker could not do for a job, tied to the job (`docs/design/worker-log.md` § What
    # goes in, and what does not). What a process reaches without a link is in
    # `ForgeWorker.JobLinesTest`; these need the job run the way the link runs it.
    test "a turn it could not push is an error line, and the turn carries no commit", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      # The repository refuses every push. A worker whose git will not run in the worktree at
      # all ends in the same place: the turn's work never leaves the machine.
      hook = Path.join([origin, "hooks", "pre-receive"])
      File.write!(hook, "#!/bin/sh\necho 'refused by the test' >&2\nexit 1\n")
      File.chmod!(hook, 0o755)

      job = chat(origin, env: [{"FAKE_COMMIT", "1"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1, "commit" => nil}, before} = take_push("turn")

      assert [line] = for({"log", %{"type" => "turn.uncommitted"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["level"] == "error"
      assert line["message"] =~ "could not commit turn 1"
      assert line["message"] =~ "refused by the test"
    end

    # The same line, when what the push was refused with names one of the chat's secrets: the
    # machine's log is read off the machine, by its owner, who need not be in the project.
    test "a turn refused on output naming its secret logs it masked", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      hook = Path.join([origin, "hooks", "pre-receive"])
      File.write!(hook, "#!/bin/sh\necho 'refused: found sk_test_in-a-turn' >&2\nexit 1\n")
      File.chmod!(hook, 0o755)

      job =
        origin
        |> chat(env: [{"FAKE_COMMIT", "1"}])
        |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_in-a-turn"})

      push(client, @topic, "assign", job)
      {%{"turn" => 1, "commit" => nil}, before} = take_push("turn")

      assert [line] = for({"log", %{"type" => "turn.uncommitted"} = l} <- before, do: l)
      assert line["message"] =~ "refused: found [secret STRIPE_TEST_KEY]"
      refute line["message"] =~ "in-a-turn"
    end

    test "a history entry that would leave its folder is refused, and says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = Map.put(chat(origin), "history", [%{"dir" => "../../escaped", "metadata" => "no"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1}, before} = take_push("turn")

      assert [line] = for({"log", %{"type" => "history.unwritten"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ ~s("../../escaped")
    end

    test "history that will not be written says why", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      # Not text, so the write raises — and the conversation still starts.
      job = Map.put(chat(origin), "history", [%{"dir" => "planning/1", "metadata" => 42}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1}, before} = take_push("turn")

      assert [line] = for({"log", %{"type" => "history.unwritten"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "could not write the history"
    end

    test "a conversation's transcript that will not upload says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      store_answers(507, "the store is full")

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _before} = take_push("turn")

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done talking"})
      {%{"job_id" => ^job_id}, before} = take_push("hibernated")

      assert [line] = for({"log", %{"type" => "upload.failed"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "could not upload the transcript"
      assert line["message"] =~ "the store is full"
    end

    test "a job's transcript that will not upload says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      store_answers(507, "the store is full")

      job = assignment(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [line] = for({"log", %{"type" => "upload.failed"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "could not upload the transcript"
      assert line["message"] =~ "the store is full"
    end

    test "a job's transcript with nowhere to go says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> assignment() |> Map.put("store", %{})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [line] = for({"log", %{"type" => "upload.failed"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "nowhere to put the transcript"
    end

    test "a command's log that will not upload says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      store_answers(507, "the store is full")

      job = command_assignment(origin, "#!/bin/sh\necho built\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [line] = for({"log", %{"type" => "upload.failed"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "could not upload the command's log"
      assert line["message"] =~ "the store is full"
    end

    test "a command's log with nowhere to go says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> command_assignment("#!/bin/sh\necho built\n") |> Map.put("store", %{})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [line] = for({"log", %{"type" => "upload.failed"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "nowhere to put the command's log"
    end

    test "a command's log a resumed job cannot fetch is left out, and says so", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      store_answers(404, "no such key")

      job =
        origin
        |> assignment()
        |> Map.put("commands", [
          %{"file" => "1-build.log", "key" => "job/c1/log-1.txt", "token" => "get-token"}
        ])

      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id}, before} = take_push("result")

      assert [line] = for({"log", %{"type" => "commands.unwritten"} = l} <- before, do: l)
      assert line["job_id"] == job_id
      assert line["message"] =~ "1-build.log"
      assert line["message"] =~ "no such key"
    end
  end

  # `drain` is gone from both ends, so a platform one release behind can still send it — or any
  # message this release has never heard of. It is logged and the link carries on.
  test "a message this release does not know changes nothing", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    push(client, @topic, "drain", %{})

    job = assignment(origin)
    push(client, @topic, "assign", job)

    job_id = job["job_id"]
    assert {%{"job_id" => ^job_id}, _events} = take_push("result")
  end

  test "a job already running is not started twice", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    push(client, @topic, "assign", job)
    push(client, @topic, "assign", job)

    job_id = job["job_id"]
    {%{"job_id" => ^job_id}, before} = take_push("result")

    # Nothing but the run's own events before its result, and nothing about the job after it. A
    # second run started over the first fails on the worktree they share, and its `failed` lands
    # among the pushes `take_push/1` walks past on the way to the result — so refuting a second
    # result alone passed with the guard removed.
    assert Enum.all?(before, fn {name, _payload} -> name == "event" end)
    refute_push(@topic, _anything, %{"job_id" => ^job_id}, 500)

    # Nor held for later: only a job whose run was given up has its next assignment held.
    assert :sys.get_state(client).assigns.deferred == %{}
  end

  test "a cancelled job commits what it has and hibernates", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin, scenario: "hang")
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    # Wait until the harness is really running before asking for it to stop. A ticket cancelled
    # is the reason that is still reported: it is how the platform settles what the run spent.
    {_payload, _seen} = take_push("event")
    push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "ticket_cancelled"})

    {%{"job_id" => ^job_id, "commit" => commit}, _events} = take_push("hibernated")
    assert String.length(commit) == 40

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() ==
             commit
  end

  # Cancelling a ticket revokes its jobs' credentials as it sends the `cancel`, so a run with work
  # to push is refused when it gets there. It still says what it spent — the platform settles a
  # cancelled run's cost from its `hibernated` — where it used to crash into a `failed` that
  # carried nothing.
  test "a cancelled run whose push is refused hibernates with its result", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})
    refuse_pushes(origin)

    # A run with work to push: it commits, then hangs until the cancel.
    job = assignment(origin, scenario: "hang")

    Application.put_env(:forge_worker, :extra_env, [
      {"FAKE_SCENARIO", "hang"},
      {"FAKE_COMMIT", "work.txt"}
    ])

    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {_payload, _seen} = take_push("event")
    push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "ticket_cancelled"})

    {%{"job_id" => ^job_id, "commit" => nil, "result" => result}, _events} =
      take_push("hibernated")

    assert result["killed"] == "operator"
  end

  # Any other run whose push is refused has lost its work, and says so as what it is.
  test "a run whose push is refused fails, naming the push", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})
    refuse_pushes(origin)

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "reason" => reason}, _events} = take_push("failed")
    assert reason =~ ":push"
    assert reason =~ "pre-receive hook declined"
  end

  # A failure's reason can quote what the run wrote — here a remote's secret scanner naming what
  # it found in the push — and it leaves masked like a result (`ForgeWorker.Link`'s `report/4`).
  test "a run that fails on output naming its secret reports it masked", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\necho 'refused: found sk_test_in-a-hook' >&2\nexit 1\n")
    File.chmod!(hook, 0o755)

    job = origin |> assignment() |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_in-a-hook"})
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "reason" => reason}, _events} = take_push("failed")
    assert reason =~ "refused: found [secret STRIPE_TEST_KEY]"
    refute reason =~ "in-a-hook"
  end

  defp refuse_pushes(origin) do
    hook = Path.join([origin, "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
  end

  # A workflow job takes a different path to the harness than a conversation does — its own
  # `start_runner/4` — so it needs its own test. Writing only the conversation's left this
  # unproved: removing the workflow path's model handling failed nothing at all.
  test "a job runs on the model its spec names, over the machine's", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    Application.put_env(:forge_worker, :harness_opts,
      executable: fake_executable(),
      model: "the-machines"
    )

    job = assignment(origin)
    spec = Map.put(job["spec"], "model", "the-specs")
    push(client, @topic, "assign", Map.put(job, "spec", spec))

    {%{"result" => _result}, _events} = take_push("result")

    args = File.read!(Path.join([root, "jobs", spec["job_id"], "fake-args.txt"]))
    assert args =~ "--model the-specs"
    refute args =~ "the-machines"
  end

  # The job's credential, sealed for this machine and this job the way the platform seals it
  # (`ForgeCore.Job.Credential`), with this machine's token configured to open it.
  defp with_credential(job, secret, kind \\ "oauth", sealed_for \\ nil) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    Application.put_env(:forge_worker, :token, token)
    {:ok, hash} = ForgeCore.Job.Credential.token_hash(token)

    Map.put(job, "credential", %{
      "harness" => "claude_code",
      "kind" => kind,
      "sealed" => ForgeCore.Job.Credential.seal(secret, hash, sealed_for || job["job_id"])
    })
  end

  defp harness_env(root, job) do
    File.read!(Path.join([root, "jobs", job["spec"]["job_id"], "fake-env.txt"]))
  end

  # **The job's credential, and nothing else.** A machine used to boot with the node's token and
  # spend it on every job; now the assignment carries the job's own, opened only at spawn
  # (`docs/design/credentials.md` § Delivery to the machine).
  test "a job runs on the credential its assignment carries", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = origin |> assignment() |> with_credential("sk-ant-oat01-the-jobs")
    push(client, @topic, "assign", job)
    {%{"result" => _result}, _events} = take_push("result")

    env = harness_env(root, job)
    assert env =~ "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-the-jobs"
    assert env =~ "ANTHROPIC_API_KEY=unset"

    # Nothing that outlived the run held it: the link only ever had it sealed.
    refute inspect(:sys.get_state(client), limit: :infinity) =~ "sk-ant-oat01-the-jobs"
  end

  # The job's project secrets, sealed for this machine, this job and the purpose `:secrets`, the
  # way the platform seals them (`Forge.Secrets.for_wire/3`).
  defp with_secrets(job, secrets),
    do: Map.put(job, "secrets", sealed_secrets(secrets, job["job_id"]).sealed)

  # **What a job holds, it holds in its environment; what it prints is masked on the way out**
  # (`docs/design/secrets.md` § Delivery, § Masking). The value has a quote in it, so the line the
  # harness writes carries it escaped; a reserved name the platform should never have sent is
  # refused here too.
  test "a job's secrets reach its environment, and what it prints of them leaves masked",
       context do
    %{client: client, origin: origin, root: root} = context
    Application.put_env(:forge_worker, :slice, RecordingSlice)
    Application.put_env(:forge_worker, :slice_reporter, self())
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    value = ~s(sk_test_"leaked"-value)

    job =
      origin
      |> assignment(scenario: "leaks_secret")
      |> with_secrets(%{
        "STRIPE_TEST_KEY" => value,
        "ANTHROPIC_BASE_URL" => "https://evil.example"
      })

    push(client, @topic, "assign", job)
    {%{"result" => result}, events} = take_push("result")

    # In the harness's environment, by name through the slice and never as an argument.
    env = File.read!(Path.join([root, "jobs", job["spec"]["job_id"], "fake-env-all.txt"]))
    assert env =~ "STRIPE_TEST_KEY=#{value}"
    refute env =~ "evil.example"
    assert_receive {:slice, slice}
    assert is_binary(slice.secrets_file)
    refute inspect(slice, limit: :infinity, printable_limit: :infinity) =~ "leaked"
    refute File.exists?(slice.secrets_file)

    # Masked in what it reported, in every event, and in the transcript it uploaded.
    assert inspect(result, limit: :infinity, printable_limit: :infinity) =~
             "[secret STRIPE_TEST_KEY]"

    refute inspect({result, events}, limit: :infinity, printable_limit: :infinity) =~ "leaked"

    assert_receive {:uploaded, "/store/job/j1/transcript-1.jsonl", _auth, _query, transcript}
    assert transcript =~ "[secret STRIPE_TEST_KEY]"
    refute transcript =~ "leaked"

    # Never in the link's own state, which only ever held it sealed.
    refute inspect(:sys.get_state(client), limit: :infinity) =~ "leaked"
  end

  # Secrets that will not open — sealed for another job — fail the job before anything of it runs:
  # a run without the secrets its state names would fail later and less clearly.
  test "a job whose secrets do not open fails before it runs", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = origin |> assignment() |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_x"})
    job = Map.put(job, "secrets", sealed_secrets(%{}, "another").sealed)
    job_id = job["job_id"]

    ExUnit.CaptureLog.capture_log(fn ->
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("failed")
      assert reason =~ "secrets_unopened"
    end)

    refute File.exists?(Path.join([root, "jobs", job["spec"]["job_id"], "fake-args.txt"]))
  end

  test "an api key is set as one", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = origin |> assignment() |> with_credential("sk-ant-api03-key", "api_key")
    push(client, @topic, "assign", job)
    {%{"result" => _result}, _events} = take_push("result")

    assert harness_env(root, job) =~
             "ANTHROPIC_API_KEY=sk-ant-api03-key\nCLAUDE_CODE_OAUTH_TOKEN=unset"
  end

  # **Opened at spawn and not before**, which is what keeps it out of the crash report of a runner
  # that dies on the way there. The runner's report prints the message it was handling — the
  # options it was started with — so a credential opened when the assignment arrived would be in
  # the log in the clear. Carried as a function, it prints as one.
  test "a runner that dies before it spawns logs no credential", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})
    Application.put_env(:forge_worker, :harness, CrashingHarness)
    Application.put_env(:forge_worker, :crashing_harness_test, self())
    on_exit(fn -> Application.delete_env(:forge_worker, :crashing_harness_test) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        job = origin |> assignment() |> with_credential("sk-ant-oat01-never-in-a-log")
        push(client, @topic, "assign", job)
        assert_receive :crashing, 10_000
        # The report is written by the process that died, after it died.
        Process.sleep(300)
      end)

    # The crash was reported, or the refutation below proves nothing.
    assert log =~ "this driver cannot build a command"
    refute log =~ "sk-ant-oat01-never-in-a-log"
  end

  # A job the platform recorded against one credential must not run on another, and a machine's
  # own configuration is exactly the other one that was there before.
  test "a job with no credential runs with none, whatever the machine was configured with",
       context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    Application.put_env(:forge_worker, :harness_opts,
      executable: fake_executable(),
      credential: {:api_key, "the-machines-own"}
    )

    job = assignment(origin)
    push(client, @topic, "assign", job)
    {%{"result" => _result}, _events} = take_push("result")

    assert harness_env(root, job) =~ "ANTHROPIC_API_KEY=unset\nCLAUDE_CODE_OAUTH_TOKEN=unset"
  end

  # The associated data at work: a credential sealed for one job does not open for another.
  test "a credential sealed for another job opens as none", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = origin |> assignment() |> with_credential("sk-ant-oat01-elsewhere", "oauth", uuid())
    push(client, @topic, "assign", job)
    {%{"result" => _result}, _events} = take_push("result")

    assert harness_env(root, job) =~ "ANTHROPIC_API_KEY=unset\nCLAUDE_CODE_OAUTH_TOKEN=unset"
  end

  # The continuation names the commit the agent will find, and the only place that knows it is
  # the tree this machine just made: the platform's idea of the branch is not what the harness
  # runs in. See docs/design/job-prompt.md § The continuation prompt.
  test "a resumed job is told the commit its worktree is at", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    tip = git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim()
    job = assignment(origin, resume_session: "sess-42")
    push(client, @topic, "assign", job)

    {%{"result" => _result}, _events} = take_push("result")

    prompt = File.read!(Path.join([root, "jobs", job["spec"]["job_id"], "prompt.md"]))
    assert String.starts_with?(prompt, "# Continue this job")
    assert prompt =~ ", at `#{tip}`, checked out in the worktree"
  end

  # The agent gets the worker's own push credential, because it works in a real clone and may
  # fetch and push on its own. It is marked `{:secret, _}` at two independent places — here and
  # in `Conversation.git_env/1` — and this is the first of them.
  #
  # What the mark buys is the route the value takes. A plain value becomes an assignment in the
  # wrapper shell's argv and a `--setenv=NAME=VALUE` on `systemd-run`'s command line, both of
  # which any user on the machine can read — the second for the unit's whole life, from systemd.
  # A secret is in neither: it is written to a file only root can read, and the process loads it
  # itself. See docs/design/secrets.md § Delivery.
  test "the push credential reaches the job as a secret, never as an argument", context do
    %{client: client, origin: origin} = context
    Application.put_env(:forge_worker, :slice, RecordingSlice)
    Application.put_env(:forge_worker, :slice_reporter, self())

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = put_in(assignment(origin), ["git", "token"], "push-secret")
    push(client, @topic, "assign", job)
    {%{"result" => _result}, _events} = take_push("result")

    assert_receive {:slice, slice}
    assert is_binary(slice.secrets_file)
    refute inspect(slice, limit: :infinity, printable_limit: :infinity) =~ "push-secret"
    refute List.keyfind(slice.env, "FORGE_GIT_TOKEN", 0)
  end

  # The promotion is wired after the push and before the worktree goes, and the order is the
  # whole of what makes it safe: promote before `commit_and_push` and the template holds the
  # agent's own commits and its untracked files, which the next job would inherit into a tree
  # that is deliberately not cleaned. See docs/design/worker-tier.md § The ticket volume.
  test "a finished run leaves the ticket a clean template for its next job", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id}, _events} = take_push("result")

    template = Path.join([root, "volumes", "ticket", "1"])
    assert File.dir?(template)
    assert git!(template, ["status", "--porcelain"]) == ""
    assert git!(template, ["show", "HEAD:CHANGED.md"]) =~ "by the agent"

    # And the worktree it came from is still thrown away: the template is a copy, not a reprieve.
    refute File.exists?(ForgeWorker.Job.Workspace.dir(job, root))
  end

  test "a job that cannot be prepared is reported as failed, not forgotten", context do
    %{client: client} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment("/nowhere/there-is-no-repository.git")
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"job_id" => ^job_id, "reason" => reason}, _events} = take_push("failed")
    assert reason =~ "there-is-no-repository"
  end

  # The backlog and the proposals are the two halves of the same path, so they are proved
  # together: what the platform sent reaches the agent as files, and what the agent wrote
  # comes back over the channel as a result.
  test "the backlog reaches the agent and its proposals come back", context do
    %{client: client, origin: origin, root: root} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job =
      origin
      |> assignment(scenario: "proposes")
      |> Map.put("backlog", %{
        "index" => "| 7 | verifying | active | Fix the leaderboard |\n",
        "tickets" => [
          %{"file" => "7.md", "content" => "# Fix the leaderboard\n\nIt sorts up.\n"}
        ]
      })

    push(client, @topic, "assign", job)
    {%{"result" => result}, _} = take_push("result")

    # The *spec's* id, not the assignment's: `Dir.prepare/3` names the directory after it, and
    # the fixture gives the two different values. Looking under the assignment's id finds an
    # empty path and proves nothing — the trap the chat fixture above already records.
    job_dir = Path.join([root, "jobs", job["spec"]["job_id"]])
    assert File.read!(Path.join([job_dir, "tickets", "7.md"])) =~ "It sorts up."
    assert File.read!(Path.join(job_dir, "fake-backlog.txt")) =~ "Fix the leaderboard"

    assert %{"proposals" => proposals, "invalid_proposals" => invalid} = result
    assert proposals["score-table.md"]["title"] == "Extract the score table"
    assert invalid["half.md"]["reason"] =~ "level-one heading"
    assert invalid["half.md"]["raw"] =~ "no heading"

    # The job's own outcome is untouched by either: a proposal is not in `produces`, and a
    # malformed one must not cost a finished job its result.
    assert result["outcome"] == "converged"
    assert result["declared_outcome"] == "done"
    assert result["undeclared"] == []
  end

  # `docs/design/worker-tier.md` § The job slice: a repository's hooks and configuration are
  # programs the job could have written, so the worker's git in a job's tree runs as the job's
  # user — made first, handed the tree before the first git command, gone after the last.
  describe "the job's user" do
    setup do
      Application.put_env(:forge_worker, :slice, UserSlice)
      Application.put_env(:forge_worker, :slice_reporter, self())
      on_exit(fn -> Application.delete_env(:forge_worker, :template_probe) end)
    end

    test "a job's git is its user's, and the user goes before the tree is kept", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      %{root: root} = context
      job = assignment(origin)
      Application.put_env(:forge_worker, :extra_env, [{"FAKE_COMMIT", "NOTES.md"}])
      template = ForgeWorker.Job.Workspace.template(job, root)
      Application.put_env(:forge_worker, :template_probe, template)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _events} = take_push("result")

      events = user_story()
      in_order!(events)
      assert {:enter, job_id} == hd(events)
      assert "commit" in as_user(events)
      assert "push" in as_user(events)

      # The clone is the worker's, so the first git as the user is the head the harness is told.
      assert hd(as_user(events)) == "rev-parse"

      # Handed back before the tree became the ticket's template, not after — and it did become
      # it, or the first half says nothing.
      assert {:leave, _paths, false} = Enum.find(events, &match?({:leave, _, _}, &1))
      assert File.dir?(template)
    end

    test "every turn is committed as the conversation's user, and it goes at the end", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin, env: [{"FAKE_COMMIT", "1"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1, "commit" => commit}, _before} = take_push("turn")
      assert is_binary(commit)
      turn = user_story()
      assert "commit" in as_user(turn)
      assert "push" in as_user(turn)
      refute Enum.any?(turn, &match?({:leave, _, _}, &1))

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done talking"})
      {%{"job_id" => ^job_id}, _before} = take_push("hibernated")

      ending = user_story()
      in_order!(turn ++ ending)

      # The head the ending reports is read as the user too, and before it goes.
      assert [{:as, "rev-parse"}, {:leave, _paths, _kept} | _rest] = ending

      # At the ending, with the tree still there to give back: before the discard, not after it.
      {:leave, paths, _kept} = Enum.find(ending, &match?({:leave, _, _}, &1))
      assert Enum.any?(paths, &String.ends_with?(&1, "/worktrees/" <> job_id))
    end

    # The user is made before anything that can fail, so everything that can fail removes it.
    test "a job that could not start still removes its user", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = assignment("/nowhere/there-is-no-repository.git")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _before} = take_push("failed")

      events = user_story()
      assert {:enter, job_id} == hd(events)
      assert Enum.any?(events, &match?({:leave, _, _}, &1))
    end

    test "a conversation that could not start still removes its user", %{client: client} do
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job_id = uuid()

      job = %{
        "job_id" => job_id,
        "kind" => "chat",
        "spec" =>
          spec() |> Map.put(:job_id, job_id) |> ForgeCore.Job.Spec.to_json() |> Jason.decode!(),
        "git" => %{"url" => "/nowhere/there-is-no-repository.git", "branch" => "chat/" <> job_id}
      }

      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _before} = take_push("failed")

      wait_until(fn -> ForgeWorker.Job.Conversation.whereis(job_id) == nil end)
      events = user_story()
      assert {:enter, job_id} == hd(events)
      assert Enum.any?(events, &match?({:leave, _, _}, &1))
    end

    # Refused before anything of the job exists: no user, so nothing to take back.
    test "a ceiling below the minimum makes no user", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> assignment() |> Map.put("slice", %{"memory_max" => 2})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _before} = take_push("result")

      assert user_story() == []
    end

    test "a command's checkout is its user's", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = command_assignment(origin, "#!/bin/sh\necho built\n")
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"job_id" => ^job_id}, _before} = take_push("result")

      events = user_story()
      in_order!(events)
      assert "checkout" in as_user(events)
    end
  end

  describe "a conversation" do
    defp chat(origin, opts \\ []) do
      job_id = Keyword.get(opts, :job_id, uuid())

      harness = Application.get_env(:forge_worker, :harness_opts, [])
      Application.put_env(:forge_worker, :harness_opts, harness)

      Application.put_env(
        :forge_worker,
        :extra_env,
        [{"FAKE_SCENARIO", "chat"} | Keyword.get(opts, :env, [])]
      )

      # The branch exists before the conversation is assigned, the way a ticket's does: the
      # platform creates `chat/<id>` when it creates the conversation. A worker asked for a
      # branch that is not there reports it rather than inventing one.
      git!(nil, ["-C", origin, "branch", "chat/" <> job_id, "main"])

      assignment = assignment(origin, job_id: job_id)

      assignment
      |> Map.merge(%{
        "kind" => "chat",
        "idle_ms" => Keyword.get(opts, :idle_ms, 60_000),
        "git" => %{"url" => origin, "branch" => "chat/" <> job_id, "base" => nil},
        # The same id in both places, as the platform sends it: `Dir.prepare/3` names the job
        # directory after the *spec's* id, so a fixture that gave the two different ones put the
        # directory somewhere nothing else looked — which is how the history folder came to be
        # written where the harness would never find it.
        "spec" => Map.put(assignment["spec"], "job_id", job_id)
      })
    end

    # The turn's summary carries the job's memory as the turn ended, which is what the platform
    # keeps on its `chat.turn` (`docs/design/claude-code-events.md` § Memory).
    test "each turn's summary says what memory did", context do
      %{client: client, origin: origin} = context
      gib = 1024 ** 3

      {:ok, readings} =
        Agent.start_link(fn ->
          [%{ceiling: gib, current: gib, peak: gib, max_events: 1, oom_kills: 2, pressure: 0.0}]
        end)

      Application.put_env(:forge_worker, :slice, ForgeWorker.ScriptedSlice)
      Application.put_env(:forge_worker, :scripted_readings, readings)
      on_exit(fn -> Application.delete_env(:forge_worker, :scripted_readings) end)

      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> chat() |> Map.put("slice", %{"memory_max" => gib, "cpu_weight" => 100})
      push(client, @topic, "assign", job)
      {%{"turn" => 1, "harness" => harness}, _} = take_push("turn")

      assert harness["memory"] == %{"ceiling" => gib, "peak" => gib, "oom_kills" => 2}
      push(client, @topic, "close", %{"job_id" => job["job_id"], "reason" => "done"})
      take_push("hibernated")
    end

    # `docs/design/conversations.md` § Lifetime: every turn leaves the session with the platform,
    # because a conversation can stop by losing its machine, when nothing is left to upload it.
    test "uploads its session after every turn, and says so with the turn", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job =
        origin
        |> chat()
        |> put_in(["store", "session_prefix"], "job/c1/session-s/")
        |> put_in(["store", "session_token"], "session-token")

      push(client, @topic, "assign", job)
      {%{"turn" => 1, "harness" => harness}, _} = take_push("turn")

      assert harness["session_blob"] == "job/c1/session-s/1.jsonl"
      assert harness["version"] == "9.9.9"

      assert_receive {:uploaded, "/store/job/c1/session-s/1.jsonl", ["Bearer session-token"], _q,
                      body}

      assert body =~ ~s("sessionId":"sess-42")

      push(client, @topic, "message", %{
        "job_id" => job["job_id"],
        "message_id" => "m-2",
        "text" => "more"
      })

      {%{"turn" => 2, "harness" => harness}, _} = take_push("turn")
      assert harness["session_blob"] == "job/c1/session-s/2.jsonl"
    end

    # A reopen on another machine: the carried session is restored, forked so that its turns,
    # numbered from one again, are not taken for the old process's, and the conversation is
    # told only that it was reopened — not handed the replay a cold reopen reads.
    test "a reopen resumes the carried session as a fork", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      session =
        ~s({"type":"user","sessionId":"sess-42","parentUuid":null,"uuid":"u1","message":{"content":"remember PELICAN"}}\n)

      test = self()

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          if conn.method == "GET" do
            Plug.Conn.send_resp(conn, 200, session)
          else
            {:ok, body, conn} = Plug.Conn.read_body(conn, length: 8_000_000)
            send(test, {:uploaded, conn.request_path, [], "", body})
            Req.Test.json(conn, %{"key" => conn.request_path, "size" => byte_size(body)})
          end
        end
      )

      job =
        origin
        |> chat()
        |> put_in(["spec", "kind"], "chat")
        |> put_in(["spec", "prompt"], "Did it land?")
        |> put_in(["spec", "replay"], "# The conversation so far\n")
        |> Map.merge(%{
          "resume_session" => "sess-42",
          "fork_session" => true,
          "session" => %{
            "key" => "job/c1/session-s/3.jsonl",
            "token" => "get",
            "id" => "sess-42",
            "version" => "9.9.9"
          }
        })

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1, "harness" => harness}, _} = take_push("turn")

      assert harness["session_id"] == "sess-42-fork"
      dir = Path.join([root, "jobs", job_id])
      assert File.read!(Path.join(dir, "fake-remembered.txt")) == "PELICAN\n"
      assert File.read!(Path.join(dir, "fake-args.txt")) =~ "--resume sess-42 --fork-session"

      opening = File.read!(Path.join(dir, "prompt.md"))
      assert opening =~ "# This conversation was reopened"
      assert opening =~ "Did it land?"
      refute opening =~ "conversation.md"
    end

    # A job's resume that finds nothing is re-queued cold by the platform; a conversation's is not,
    # so a session that will not download is a cold reopen, with the replay.
    test "a reopen whose session will not download starts cold, with the replay", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})
      store_answers(404, "no such key")

      job =
        origin
        |> chat()
        |> put_in(["spec", "kind"], "chat")
        |> put_in(["spec", "prompt"], "Did it land?")
        |> put_in(["spec", "replay"], "# The conversation so far\n")
        |> Map.merge(%{
          "resume_session" => "sess-42",
          "fork_session" => true,
          "session" => %{
            "key" => "job/c1/session-s/3.jsonl",
            "token" => "get",
            "id" => "sess-42",
            "version" => "9.9.9"
          }
        })

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      dir = Path.join([root, "jobs", job_id])
      refute File.read!(Path.join(dir, "fake-args.txt")) =~ "--resume"
      assert File.read!(Path.join(dir, "prompt.md")) =~ "conversation.md"
    end

    # Everything said had been answered, so the process waits for the person — and what it sends
    # with their message is still a resume's opening, not the cold one with the replay.
    test "a reopen with nothing waiting resumes with the person's next message", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      session =
        ~s({"type":"user","sessionId":"sess-42","parentUuid":null,"uuid":"u1","message":{"content":"remember PELICAN"}}\n)

      Application.put_env(:forge_worker, :req_options,
        plug: fn conn ->
          if conn.method == "GET",
            do: Plug.Conn.send_resp(conn, 200, session),
            else: Req.Test.json(conn, %{"key" => conn.request_path, "size" => 0})
        end
      )

      job =
        origin
        |> chat()
        |> put_in(["spec", "kind"], "chat")
        |> put_in(["spec", "prompt"], nil)
        |> put_in(["spec", "replay"], "# The conversation so far\n")
        |> Map.merge(%{
          "resume_session" => "sess-42",
          "fork_session" => true,
          "session" => %{
            "key" => "job/c1/session-s/3.jsonl",
            "token" => "get",
            "id" => "sess-42",
            "version" => "9.9.9"
          }
        })

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      dir = Path.join([root, "jobs", job_id])
      wait_until(fn -> File.exists?(Path.join(dir, "fake-args.txt")) end)
      refute File.exists?(Path.join(dir, "prompt.md"))

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-1",
        "text" => "What now?"
      })

      {%{"turn" => 1}, _} = take_push("turn")

      opening = File.read!(Path.join(dir, "prompt.md"))
      assert opening =~ "# This conversation was reopened"
      assert String.ends_with?(opening, "What now?\n")
      refute opening =~ "conversation.md"
    end

    # A workflow job blocks on `Runner.await/1` and does everything after it. A conversation has
    # no after until a person says so, so the turn has to be reported — and committed — while
    # the process it came from is still running.
    test "reports each turn while it goes on running", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "turn" => 1, "commit" => commit}, _} = take_push("turn")
      assert String.length(commit) == 40

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-2",
        "text" => "the second thing"
      })

      {%{"turn" => 2, "harness" => harness}, seen} = take_push("turn")
      assert harness["subtype"] == "success"

      # The cost of the turn, which is the one number the platform's daily cap is computed
      # from: a turn that reported none is a turn that spends nothing as far as the ceiling is
      # concerned, so a conversation could run all day against a cap it never moved. Cumulative
      # across the session on the real harness, which is what the fake reproduces — two turns
      # of a hundredth each.
      assert harness["cost_usd"] == 0.02

      # The message reached the harness, and the delivery says which message it was. The
      # harness echoes the text and not the id, so this correlation is the worker's own.
      # Payload keys are atoms here: in test mode the push is not serialised, and over a real
      # socket the same map arrives with string keys.
      assert Enum.any?(seen, fn
               {"event", %{"event" => %{"type" => "job.harness.delivered", "payload" => p}}} ->
                 p[:message_id] == "m-2"

               _other ->
                 false
             end)
    end

    # A reopened conversation whose last word was the agent's has nothing to answer, and the
    # platform says so with a spec that has no prompt. Started the way a first start is, it would
    # answer its opening message again as though it were new, and bill a turn for it.
    test "reopened with nothing waiting, it answers nothing until the person speaks", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]

      spec =
        Map.merge(job["spec"], %{
          "kind" => "chat",
          "prompt" => nil,
          "replay" => "# The conversation so far\n\nhello\n"
        })

      push(client, @topic, "assign", Map.put(job, "spec", spec))

      # Not a turn and not an event: the harness has been given nothing to answer.
      refute_push(@topic, _event, _payload, 500)
      assert File.read!(Path.join([root, "jobs", job_id, "conversation.md"])) =~ "hello"

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-7",
        "text" => "and now?"
      })

      {%{"turn" => 1}, seen} = take_push("turn")

      # The first echo is the person's message with the prompt riding in it, so it is that
      # message's delivery. Taken for the prompt's own echo it would be dropped, and the page
      # would say "queued" beside a message that had been answered.
      assert Enum.any?(seen, fn
               {"event", %{"event" => %{"type" => "job.harness.delivered", "payload" => p}}} ->
                 p[:message_id] == "m-7"

               _other ->
                 false
             end)
    end

    # Nothing to answer is also a prompt of nothing but whitespace — the messages after the last
    # reply, joined, with nothing in them. Started with it, the harness would take a blank line as
    # the person's words and bill a turn answering it.
    test "a prompt of nothing but whitespace is held like no prompt", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)

      spec =
        Map.merge(job["spec"], %{
          "kind" => "chat",
          "prompt" => " \n\n ",
          "replay" => "# The conversation so far\n\nhello\n"
        })

      push(client, @topic, "assign", Map.put(job, "spec", spec))

      refute_push(@topic, _event, _payload, 500)
    end

    # `Link.send_terminal/4` keyed unacked messages `{job_id, message}`, which is sound when a
    # job sends exactly one. A conversation sends a `turn` per turn, so two unacked turns would
    # collide and one would be lost for ever — with the cost the daily cap is computed from.
    test "two unacked turns both survive a rejoin", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1}, _} = take_push("turn")

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-2",
        "text" => "again"
      })

      {%{"turn" => 2}, _} = take_push("turn")

      # Neither was acked: `assert_push` reads them off the socket without replying.
      wait_until(fn -> length(Link.unacked(client)) == 2 end)
      assert Enum.sort(Link.unacked(client)) == [{job_id, "turn", 1}, {job_id, "turn", 2}]
    end

    # An interrupted turn reports `error_during_execution` with a null result — exactly what a
    # genuine execution error reports. Only this worker knows it was asked to stop, so only it
    # can say so, and it says so in the turn it sends the platform. Left to the harness's own
    # payload, an operator's own Stop renders in their conversation as the harness having
    # failed. docs/design/conversations.md § Turns. The runner's own labelling is tested; that
    # the label survives into what crosses the channel was not.
    test "a turn the operator stopped is reported as interrupted, not as a failure", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin, env: [{"FAKE_TURN_SECONDS", "5"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      # An ordinary turn says so too, which is what makes the flag worth reading.
      {%{"turn" => 1, "interrupted" => false}, _} = take_push("turn")

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-2",
        "text" => "SLOW please"
      })

      # Both arrive as casts on the conversation in the order they were sent, so the interrupt
      # is written after the message and cuts the turn that message starts.
      push(client, @topic, "interrupt", %{"job_id" => job_id})

      {%{"turn" => 2, "interrupted" => true, "harness" => harness}, _} = take_push("turn")

      # The harness still calls it an error. That is the point: the two are distinguished here
      # and nowhere else.
      assert harness["subtype"] == "error_during_execution"
      assert harness["is_error"] == true
    end

    # What is left of the day, decided by the platform and passed through to the harness, which
    # refuses the turn at the ceiling rather than the worker refusing it afterwards.
    # docs/design/conversations.md § Spend has the cap enforced twice — by the harness, per
    # turn, and by the node once the day is gone. A conversation that dropped this on the floor
    # enforces it once, after the fact, which is the half that cannot stop a turn.
    test "the day's remaining allowance becomes the harness's ceiling", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin) |> Map.put("max_cost_usd", 1.5)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      assert File.read!(Path.join([root, "jobs", job_id, "fake-args.txt"])) =~
               "--max-budget-usd 1.50"
    end

    # The transcript leaves the machine and the result carries the *key*, not the bytes. A
    # conversation that hibernated without one is one the platform can show nothing for — and
    # unlike a workflow job, whose path asserts this, the conversation copied the shape without
    # the assertion.
    test "the transcript goes to the store and the result carries its key", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done"})
      {%{"result" => result}, _} = take_push("hibernated")

      assert result["transcript"] == "job/j1/transcript-1.jsonl"

      # And it is really there, under the key the platform minted a token for.
      assert_receive {:uploaded, "/store/job/j1/transcript-1.jsonl", ["Bearer put-token"], _query,
                      body}

      assert body =~ "\"type\":"
    end

    # The second of the two places the push credential is marked `{:secret, _}`. A conversation
    # takes its own route to the runner — `Conversation.runner_opts/1`, not `Link.start_runner/4`
    # — so the workflow test above proves nothing about it, and CLAUDE.md § Rules says to fix
    # the class rather than the instance.
    test "the push credential reaches a chat as a secret, never as an argument", context do
      %{client: client, origin: origin} = context
      Application.put_env(:forge_worker, :slice, RecordingSlice)
      Application.put_env(:forge_worker, :slice_reporter, self())

      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = put_in(chat(origin), ["git", "token"], "push-secret")
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      assert_receive {:slice, slice}
      assert is_binary(slice.secrets_file)
      refute inspect(slice, limit: :infinity, printable_limit: :infinity) =~ "push-secret"
      refute List.keyfind(slice.env, "FORGE_GIT_TOKEN", 0)
    end

    # A conversation takes its own route to the runner (`Conversation.runner_opts/1`), so the
    # workflow job's test above proves nothing about it: its secrets reach the harness by name, and
    # a message that carries one comes back masked in the echo and in the uploaded transcript.
    test "a chat holds its secrets, and what it says of them leaves masked", context do
      %{client: client, origin: origin} = context
      Application.put_env(:forge_worker, :slice, RecordingSlice)
      Application.put_env(:forge_worker, :slice_reporter, self())
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      # The fake harness writes this word into its session file, so the session holds the value.
      job =
        origin
        |> chat(env: [{"FAKE_WORD", "sk_test_said-in-a-chat"}])
        |> put_in(["store", "session_prefix"], "job/c1/session-s/")
        |> put_in(["store", "session_token"], "session-token")
        |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_said-in-a-chat"})

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      assert_receive {:slice, slice}
      assert is_binary(slice.secrets_file)

      # `FAKE_WORD` is the test's own plain variable, set to the value so the session holds it.
      refute Enum.any?(slice.env, fn {name, value} ->
               name != "FAKE_WORD" and value == "sk_test_said-in-a-chat"
             end)

      assert_receive {:uploaded, "/store/job/c1/session-s/1.jsonl", _auth, _query, session}
      assert session =~ "remember [secret STRIPE_TEST_KEY]"

      push(client, @topic, "message", %{
        "job_id" => job_id,
        "message_id" => "m-2",
        "text" => "the key is sk_test_said-in-a-chat"
      })

      {turn, events} = take_push("turn")
      refute inspect({turn, events}, limit: :infinity, printable_limit: :infinity) =~ "said-in"

      assert inspect(events, limit: :infinity, printable_limit: :infinity) =~
               "[secret STRIPE_TEST_KEY]"

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done"})
      {%{"result" => _result} = hibernated, _} = take_push("hibernated")
      refute inspect(hibernated, limit: :infinity, printable_limit: :infinity) =~ "said-in"

      assert_receive {:uploaded, "/store/job/j1/transcript-1.jsonl", _auth, _query, transcript}
      refute transcript =~ "said-in"
    end

    # The conversation's own route to the same rule as a workflow job's: secrets that will not
    # open — sealed for another job — stop it before a harness starts.
    test "a chat whose secrets do not open fails before it starts", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> chat() |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_x"})
      job = Map.put(job, "secrets", sealed_secrets(%{}, "another").sealed)
      job_id = job["job_id"]

      ExUnit.CaptureLog.capture_log(fn ->
        push(client, @topic, "assign", job)
        {%{"job_id" => ^job_id, "reason" => reason}, _before} = take_push("failed")
        assert reason == "the conversation's secrets would not open"
      end)

      refute File.exists?(Path.join([root, "jobs", job["spec"]["job_id"], "fake-args.txt"]))
    end

    # The report a chat ends with carries its result, and a result can carry what the agent wrote —
    # a harness that died says why with its last line of stderr (`Runner`'s `with_stderr/2`). The
    # fake harness's stderr never reaches a chat's result here, so the result is handed to the
    # conversation directly and the runner stopped before it can send its own.
    test "the report a chat ends with is masked", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> chat() |> with_secrets(%{"STRIPE_TEST_KEY" => "sk_test_on-stderr"})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      conversation = ForgeWorker.Job.Conversation.whereis(job_id)
      %{runner: runner} = :sys.get_state(conversation)

      send(
        conversation,
        {:ended, job_id,
         %ForgeCore.Job.Result{
           status: :finished,
           reason: "stderr: could not use sk_test_on-stderr"
         }}
      )

      Process.exit(runner, :kill)

      {%{"job_id" => ^job_id, "reason" => reason} = hibernated, _} = take_push("hibernated")
      assert reason == "stderr: could not use [secret STRIPE_TEST_KEY]"
      refute inspect(hibernated, limit: :infinity, printable_limit: :infinity) =~ "on-stderr"
    end

    test "closing ends it and gives the machine back", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      push(client, @topic, "close", %{"job_id" => job_id, "reason" => "done talking"})

      {%{"job_id" => ^job_id, "reason" => "done talking", "turns" => 1, "result" => result}, _} =
        take_push("hibernated")

      # A conversation has no outcome, ever. Left to `Outcome.decide/2` the last turn would be
      # read for a declared outcome and the spec's own list consulted, handing the engine
      # something to act on for a job with no state to leave and no transition to select.
      assert result["outcome"] == nil
      assert result["declared_outcome"] == nil
      assert result["status"] == "finished"

      assert Link.running(client) == []
    end

    # The platform resolved which model this runs on — a state's, then the project's — because it
    # knows the state and the project and this machine knows neither. What the machine was built
    # with is what is left when nobody upstream had an opinion.
    test "the spec's model reaches the harness, over the machine's", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      Application.put_env(:forge_worker, :harness_opts,
        executable: fake_executable(),
        model: "the-machines"
      )

      job = chat(origin)
      job_id = job["job_id"]
      spec = Map.put(job["spec"], "model", "the-specs")
      push(client, @topic, "assign", Map.put(job, "spec", spec))

      {%{"turn" => 1}, _} = take_push("turn")

      args = File.read!(Path.join([root, "jobs", job_id, "fake-args.txt"]))
      assert args =~ "--model the-specs"
      refute args =~ "the-machines"
    end

    test "a spec that names no model leaves the machine's alone", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      Application.put_env(:forge_worker, :harness_opts,
        executable: fake_executable(),
        model: "the-machines"
      )

      job = chat(origin)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"turn" => 1}, _} = take_push("turn")

      assert File.read!(Path.join([root, "jobs", job_id, "fake-args.txt"])) =~
               "--model the-machines"
    end

    # The conversation starts its runner through a path of its own (`Conversation.runner_opts/1`),
    # so the credential reaching it is a separate claim from a workflow job's.
    test "a conversation runs on the credential its assignment carries", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = origin |> chat() |> with_credential("sk-ant-oat01-the-chats")
      push(client, @topic, "assign", job)

      {%{"turn" => 1}, _} = take_push("turn")

      assert File.read!(Path.join([root, "jobs", job["job_id"], "fake-env.txt"])) =~
               "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-the-chats"

      # Held for the life of the conversation, and still only sealed: in the link, in the
      # conversation process, and in the runner it keeps — each of which a crash report prints.
      conversation = :sys.get_state(client).assigns.jobs[job["job_id"]].task
      runner = :sys.get_state(conversation).runner

      for pid <- [client, conversation, runner] do
        refute inspect(:sys.get_state(pid), limit: :infinity, printable_limit: :infinity) =~
                 "sk-ant-oat01-the-chats"
      end
    end

    test "a branch that is not there is reported as failed, not forgotten", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin) |> Map.put("git", %{"url" => origin, "branch" => "chat/nope"})
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "reason" => reason}, _} = take_push("failed")
      assert reason =~ "chat/nope"
    end

    # Preparation that *raises* rather than returning an error — a root that cannot be created,
    # a full disk. A workflow job runs in a task with a catch-all around it; this is a process
    # and needs its own, or the platform believes the conversation is running for ever and holds
    # a slice against it. Driven directly, because the link's root is the whole worker's.
    test "a conversation whose preparation raises is reported as failed too", context do
      %{origin: origin} = context
      job = chat(origin)

      {:ok, pid} =
        ForgeWorker.Job.Conversation.start_link(
          assignment: job,
          link: self(),
          root: "/proc/forge-cannot-exist"
        )

      ref = Process.monitor(pid)
      job_id = job["job_id"]

      assert_receive {:terminal, ^job_id, "failed", %{"reason" => reason}}, 5_000
      assert reason =~ "Error"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    # A conversation has no result and never calls `Jobs.complete/2`, so a proposal it wrote
    # reaches the platform on the turn or not at all. `out/` is not committed either, which is
    # why it cannot wait for the conversation to close: an idle timeout nobody is present for
    # would take it with the machine.
    test "a proposal written during a turn goes out with that turn", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      push(client, @topic, "assign", job)
      {_first, _} = take_push("turn")

      push(client, @topic, "message", %{
        "job_id" => job["job_id"],
        "message_id" => "m-2",
        "text" => "PROPOSE a follow-up"
      })

      {%{"turn" => 2, "proposals" => proposals}, _} = take_push("turn")

      assert proposals["score-table.md"]["title"] == "Extract the score table"
    end

    # A conversation has no result, so a document it wrote reaches the platform with a turn or
    # not at all — and `out/` is not committed, so waiting for the end would lose it to an idle
    # timeout nobody was there for.
    test "a document written during a turn goes out with that turn, and every turn after",
         context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      push(client, @topic, "assign", job)
      {%{"turn" => 1, "documents" => none}, _} = take_push("turn")
      assert none == %{}

      push(client, @topic, "message", %{
        "job_id" => job["job_id"],
        "message_id" => "m-2",
        "text" => "WRITE the notes"
      })

      {%{"turn" => 2, "documents" => documents, "invalid_documents" => invalid}, _} =
        take_push("turn")

      assert documents == %{"notes.md" => "# Notes\n\nWhat the conversation found.\n"}
      assert invalid == %{}

      # Still there next turn: the platform records by content, so this costs nothing and a
      # turn that was never acked cannot be the only one that carried it.
      push(client, @topic, "message", %{
        "job_id" => job["job_id"],
        "message_id" => "m-3",
        "text" => "thanks"
      })

      {%{"turn" => 3, "documents" => again}, _} = take_push("turn")
      assert again == documents
    end

    # What the worker refuses goes to the platform too, with why, so the page can list it: a
    # document that did not arrive has to be visible rather than merely absent. Every other test
    # left `out/` clean, and a turn that always sent no refusals passed them all.
    test "a file the worker refuses goes out with the turn, with why", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin)
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      File.write!(Path.join([root, "jobs", job["job_id"], "out", "image.png"]), <<0xFF, 0xFE, 0>>)

      push(client, @topic, "message", %{
        "job_id" => job["job_id"],
        "message_id" => "m-2",
        "text" => "thanks"
      })

      {%{"turn" => 2, "documents" => documents, "invalid_documents" => invalid}, _} =
        take_push("turn")

      refute Map.has_key?(documents, "image.png")
      assert invalid["image.png"] =~ "UTF-8"
    end

    # The folder is what a ticket chat is told to read, so it has to be there before the first
    # message is delivered — `Dir.prepare/3` clears `inputs/` and `out/` and nothing else, which
    # is why it can be written first.
    test "what already ran on the ticket is laid out before the harness starts", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job =
        chat(origin)
        |> Map.put("history", [
          %{"dir" => "planning/1", "metadata" => "# planning, attempt 1\n"},
          %{"dir" => "implementing/2", "metadata" => "# implementing, attempt 2\n"}
        ])

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      history = Path.join([root, "jobs", job_id, "history"])
      assert File.read!(Path.join(history, "planning/1/job.md")) =~ "planning, attempt 1"
      assert File.read!(Path.join(history, "implementing/2/job.md")) =~ "implementing, attempt 2"
    end

    # The name arrives over the channel and is joined to a path. Checked against the same model
    # the write uses rather than against the string.
    test "a history folder that would leave the job directory is refused", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job =
        chat(origin)
        |> Map.put("history", [%{"dir" => "../../escaped", "metadata" => "nope"}])

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      refute File.exists?(Path.join([root, "jobs", "escaped"]))
      refute File.exists?(Path.join(root, "escaped"))
      # And the conversation still ran: bad context is not a reason to refuse to talk.
      assert File.dir?(Path.join([root, "jobs", job_id]))
    end

    # The boundary, which `"../../escaped"` does not reach: that one leaves the job directory
    # by so much that even a weakened guard refuses it, so it proves only that *something* is
    # checked. A sibling that shares the folder's name as a prefix is what separates the two
    # readings — `history-evil` starts with `history` and is not inside it — and a guard
    # written as a prefix test on the string rather than on the path would take it. CLAUDE.md
    # § Rules is about this exact check.
    test "a history folder beside the folder, sharing its name, is refused too", context do
      %{client: client, origin: origin, root: root} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job =
        chat(origin)
        |> Map.put("history", [
          %{"dir" => "../history-evil", "metadata" => "a sibling, not a child"},
          %{"dir" => "/etc/forge", "metadata" => "somewhere else entirely"}
        ])

      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      job_dir = Path.join([root, "jobs", job_id])
      refute File.exists?(Path.join(job_dir, "history-evil"))

      # An absolute name is not refused but neutralised: `Path.join/2` drops the leading slash,
      # so it lands inside the folder rather than at the root of the machine. Written down
      # because the guard reads as though it refused one, and what it does is this.
      refute File.exists?("/etc/forge")
      assert File.exists?(Path.join([job_dir, "history", "etc", "forge", "job.md"]))
    end

    test "going idle closes it without anyone asking", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin, idle_ms: 300)
      job_id = job["job_id"]
      push(client, @topic, "assign", job)

      {%{"job_id" => ^job_id, "reason" => "idle"}, _} = take_push("hibernated")
    end

    test "its work is on its own branch, one commit per turn", context do
      %{client: client, origin: origin} = context
      connect_and_assert_join(client, @topic, %{}, :ok)
      assert_push(@topic, "ready", %{})

      job = chat(origin, env: [{"FAKE_COMMIT", "yes"}])
      job_id = job["job_id"]
      push(client, @topic, "assign", job)
      {%{"turn" => 1}, _} = take_push("turn")

      push(client, @topic, "message", %{"job_id" => job_id, "message_id" => "m", "text" => "more"})

      {%{"turn" => 2}, _} = take_push("turn")

      # Pushing moves the remote-tracking ref that `Checkout.squash/4` resets to, so turn two
      # is built on turn one rather than replacing it. Both turns' work is on the branch.
      branch = "refs/heads/chat/" <> job_id
      files = git!(nil, ["-C", origin, "ls-tree", "--name-only", branch])
      assert files =~ "turn-1.md"
      assert files =~ "turn-2.md"
    end
  end
end
