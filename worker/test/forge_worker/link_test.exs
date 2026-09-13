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
        send(test, {:uploaded, conn.request_path, conn.query_string, body})
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
    assert_receive {:uploaded, "/store/job/j1/transcript-1.jsonl", query, body}
    assert query =~ "token=put-token"
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
end
