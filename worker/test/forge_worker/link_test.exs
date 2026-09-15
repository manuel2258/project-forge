defmodule ForgeWorker.LinkTest do
  @moduledoc """
  The worker's end of the protocol, against a simulated platform: what it says on joining,
  what it does with an assignment, and what it keeps saying until it is acked.
  """

  use Slipstream.SocketTest

  import ForgeWorker.Fixtures

  alias ForgeWorker.Link

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
