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
  def probe(_opts), do: raise("this driver cannot describe itself")
end

defmodule ForgeWorker.LinkTest.RecordingSlice do
  @moduledoc """
  `Slice.Direct`, plus a note to the test of what it was asked to confine.

  The interesting part of that note is how the environment was split. A plain value becomes
  `--setenv=NAME=VALUE` on the `systemd-run` command line and an assignment in the wrapper
  shell's own argv; a secret is carried across by name only. That split is the difference
  between a push credential the job's unprivileged user cannot see and one it can read out of
  `/proc/*/cmdline` — `docs/design/worker-tier.md` § The job slice.
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
end

defmodule ForgeWorker.LinkTest do
  @moduledoc """
  The worker's end of the protocol, against a simulated platform: what it says on joining,
  what it does with an assignment, and what it keeps saying until it is acked.
  """

  use Slipstream.SocketTest

  import ForgeWorker.Fixtures

  alias ForgeWorker.Link
  alias ForgeWorker.LinkTest.{RaisingHarness, RecordingSlice}

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
      Application.delete_env(:forge_worker, :slice)
      Application.delete_env(:forge_worker, :slice_reporter)
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
      Application.put_env(:forge_worker, :extra_env, [{"FAKE_SCENARIO", scenario}])
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

  defp git!(dir, args) do
    args = if dir, do: ["-C", dir | args], else: args
    {out, status} = System.cmd("git", args, stderr_to_stdout: true)
    if status != 0, do: raise("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  test "it joins its own topic, reporting what it is running and what it has", %{client: client} do
    connect_and_assert_join(client, @topic, %{"running" => [], "memory_total" => budget}, :ok)
    assert budget > 0

    assert_push(@topic, "ready", %{"memory_budget" => ^budget})
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
    %{client: client, origin: origin} = context
    Application.put_env(:forge_worker, :heartbeat_ms, 100)

    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin, scenario: "hang")
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    {%{"running" => running}, _events} = take_push("heartbeat")
    assert running == [%{"job_id" => job_id, "attempt" => 1}]
  end

  # `ready` is the message that says what this machine can offer, and until now it said only how
  # much memory. The harness and the models its credential may use are the rest of that answer —
  # the platform holds no credential and so can only be told. See docs/design/worker-channel.md
  # § What a worker offers.
  test "ready reports the harness, its capabilities and the models it may run", %{client: client} do
    Application.put_env(:forge_worker, :harness_opts,
      executable: fake_executable(),
      credential: {:oauth, "tok"},
      req_options: [
        plug: &Req.Test.json(&1, %{"data" => [%{"id" => "m-1", "display_name" => "One"}]})
      ]
    )

    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})

    assert harness["driver"] == "claude_code"
    assert harness["version"] == "9.9.9"
    assert harness["models"] == [%{"id" => "m-1", "name" => "One"}]

    # Every atom is a string on the wire, including the ones nested inside: a payload that
    # reaches the platform as atoms would not survive the JSON it is encoded to.
    assert harness["login"] == "ok"

    # Computed since the first worker and never told to anyone until now.
    assert harness["capabilities"]["streaming_input"] == true
  end

  # A machine whose probe answered nothing still goes ready. Refusing to would turn a network
  # blip into a worker that takes no work at all, which is worse than one whose model list is
  # briefly unknown.
  test "a worker whose probe reaches nothing still goes ready", %{client: client} do
    Application.put_env(:forge_worker, :harness_opts,
      executable: "/nonexistent/claude",
      credential: {:oauth, "tok"},
      req_options: [plug: &Req.Test.transport_error(&1, :econnrefused)]
    )

    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})
    assert harness["login"] == "unknown"
    assert harness["models"] == []

    # A version nobody could read is `nil` on the wire and not the string "nil": the offer is
    # encoded by walking it and turning atoms into strings, and `nil` is an atom. The platform
    # renders this figure straight onto the workers page, where "nil" would read as a version.
    assert harness["version"] == nil
  end

  # The rescue around the whole of `harness_offer/0`, which neither test above reaches:
  # `ClaudeCode.probe/1` swallows its own failures, so only a driver that genuinely raises —
  # a new one, a bad option, a bug — gets there. § What a worker offers: a probe that fails
  # never prevents `ready`, because refusing to go ready turns one bad answer into a machine
  # that takes no work at all.
  test "a harness whose probe raises does not stop this machine going ready", %{client: client} do
    Application.put_env(:forge_worker, :harness, RaisingHarness)

    connect_and_assert_join(client, @topic, %{}, :ok)

    assert_push(@topic, "ready", %{"harness" => harness})
    assert harness["login"] == "unknown"
    assert harness["models"] == []
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

  test "a job already running is not started twice", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin)
    push(client, @topic, "assign", job)
    push(client, @topic, "assign", job)

    job_id = job["job_id"]
    {%{"job_id" => ^job_id}, _events} = take_push("result")
    refute_push(@topic, "result", %{"job_id" => ^job_id}, 500)
  end

  test "a drained worker takes no more work", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    push(client, @topic, "drain", %{})
    push(client, @topic, "assign", assignment(origin))

    refute_push(@topic, "result", %{}, 500)
  end

  test "a cancelled job commits what it has and hibernates", context do
    %{client: client, origin: origin} = context
    connect_and_assert_join(client, @topic, %{}, :ok)
    assert_push(@topic, "ready", %{})

    job = assignment(origin, scenario: "hang")
    job_id = job["job_id"]
    push(client, @topic, "assign", job)

    # Wait until the harness is really running before asking for it to stop.
    {_payload, _seen} = take_push("event")
    push(client, @topic, "cancel", %{"job_id" => job_id, "reason" => "drained"})

    {%{"job_id" => ^job_id, "commit" => commit}, _events} = take_push("hibernated")
    assert String.length(commit) == 40

    assert git!(nil, ["-C", origin, "rev-parse", "refs/heads/ticket/1"]) |> String.trim() ==
             commit
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

  # The agent gets the worker's own push credential, because it works in a real clone and may
  # fetch and push on its own. It is marked `{:secret, _}` at two independent places — here and
  # in `Conversation.git_env/1` — and this is the first of them.
  #
  # What the mark buys is the route the value takes. A plain value becomes an assignment in the
  # wrapper shell's argv and a `--setenv=NAME=VALUE` on `systemd-run`'s command line, both of
  # which the unprivileged user the job runs as can read straight out of `/proc/*/cmdline`. A
  # secret crosses by name only and its value goes over systemd's own bus. See
  # docs/design/worker-tier.md § The job slice.
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
    assert "FORGE_GIT_TOKEN" in slice.secret_names

    refute Enum.any?(slice.env, fn {name, value} ->
             name == "FORGE_GIT_TOKEN" or value == "push-secret"
           end)
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
      assert "FORGE_GIT_TOKEN" in slice.secret_names

      refute Enum.any?(slice.env, fn {name, value} ->
               name == "FORGE_GIT_TOKEN" or value == "push-secret"
             end)
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

      # Pushing moves the remote-tracking ref that `Checkout.squash/3` resets to, so turn two
      # is built on turn one rather than replacing it. Both turns' work is on the branch.
      branch = "refs/heads/chat/" <> job_id
      files = git!(nil, ["-C", origin, "ls-tree", "--name-only", branch])
      assert files =~ "turn-1.md"
      assert files =~ "turn-2.md"
    end
  end
end
