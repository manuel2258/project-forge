defmodule ForgeWeb.WorkerChannelTest do
  @moduledoc """
  The wire itself: who may connect, what each message does, and what a rejoin reconciles.
  `Forge.FlowTest` drives the platform's side of the protocol without a socket; this drives
  the socket.
  """

  use ForgeWeb.ChannelCase, async: false

  import Forge.ForgeFixtures

  import Forge.GitFixtures

  alias Forge.{Conversations, Events, Jobs, Projects, Tickets, Workers}
  alias ForgeCore.Job.Result
  alias ForgeWeb.{WorkerChannel, WorkerSocket}

  # The credential travels in the handshake's headers, which Phoenix surfaces as `x_headers`.
  defp bearer(token),
    do: [connect_info: %{x_headers: [{"x-forge-worker-token", token}]}]

  setup do
    {:ok, worker, token} = Workers.create(%{provider: "local"})

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))
    on_exit(fn -> Application.put_env(:forge, Forge.Storage, store) end)

    %{worker: worker, token: token}
  end

  # A worker addresses a job by id in every write it sends. The socket says which worker it is;
  # nothing said the job was that worker's. See `docs/design/worker-channel.md` § Topic: the
  # blast radius of a leaked worker token is meant to stop at that worker's own jobs.
  describe "a worker may only write its own jobs" do
    setup %{worker: worker, token: token} do
      {:ok, victim_worker, _t} = Workers.create(%{provider: "local"})
      job = job_fixture()

      {:ok, job} =
        job
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: victim_worker.id})
        |> Forge.Repo.update()

      {:ok, _reply, socket} = join_worker(worker, token)
      %{socket: socket, victim_job: job, victim_worker: victim_worker}
    end

    test "failing another worker's job is refused", %{socket: socket, victim_job: job} do
      ref = push(socket, "failed", %{"job_id" => job.id, "reason" => "pwned"})
      assert_reply ref, :error, %{reason: _}

      assert Jobs.get!(job.id).status == :running
    end

    test "completing another worker's job is refused", %{socket: socket, victim_job: job} do
      ref =
        push(socket, "result", %{
          "job_id" => job.id,
          "result" => %{"outcome" => "converged", "documents" => %{"plan.md" => "theirs now"}}
        })

      assert_reply ref, :error, %{reason: _}

      assert Jobs.get!(job.id).status == :running
      assert Forge.Artifacts.versions(job.ticket_id, "plan.md") == []
    end

    test "hibernating another worker's job is refused", %{socket: socket, victim_job: job} do
      ref = push(socket, "hibernated", %{"job_id" => job.id})
      assert_reply ref, :error, %{reason: _}

      assert Jobs.get!(job.id).status == :running
    end

    test "an event for another worker's job is not recorded", %{socket: socket, victim_job: job} do
      # Unacked and best-effort, so the assertion is on the log rather than the reply: a forged
      # `type` lands in the victim's project timeline, attributed to their job.
      push(socket, "event", %{
        "job_id" => job.id,
        "event" => %{"type" => "job.finished", "payload" => %{"forged" => true}}
      })

      Process.sleep(200)

      refute Enum.any?(Events.for_job(job.id), &(&1.payload["forged"] == true))
    end

    test "a turn for another worker's conversation is refused", %{socket: socket} do
      {:ok, other_worker, _t} = Workers.create(%{provider: "local"})
      chat = chat_fixture(%{status: :running})

      {:ok, chat} =
        chat
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: other_worker.id})
        |> Forge.Repo.update()

      ref = push(socket, "turn", %{"job_id" => chat.id, "turn" => 1, "cost_usd" => 1_000_000.0})
      assert_reply ref, :error, %{reason: _}

      assert Decimal.equal?(Jobs.get!(chat.id).cost_usd, Decimal.new(0))
    end

    test "its own job it may still write", %{socket: socket, worker: worker} do
      job = job_fixture()

      {:ok, job} =
        job
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Forge.Repo.update()

      ref = push(socket, "failed", %{"job_id" => job.id, "reason" => "genuinely failed"})
      assert_reply ref, :ok, _

      assert Jobs.get!(job.id).status == :finished
    end
  end

  defp connect_worker(worker, token) do
    {:ok, socket} = connect(WorkerSocket, %{"worker_id" => worker.id}, bearer(token))
    socket
  end

  defp join_worker(worker, token, payload \\ %{}) do
    worker
    |> connect_worker(token)
    |> subscribe_and_join(WorkerChannel, "worker:#{worker.id}", payload)
  end

  # A join that declares the conversation, because the machine really is running it: a join that
  # did not would be reconciled as a lost job and the chat would go dormant before a word could
  # be sent to it.
  defp join_with_chat(worker, token, chat),
    do: join_worker(worker, token, %{"running" => [%{"job_id" => chat.id, "attempt" => 1}]})

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met in time")
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp ticket_with_job(_context) do
    {:ok, project} =
      register_owned!(%{
        name: "chan-#{System.unique_integer([:positive])}",
        repo_path: seeded_repo()
      })

    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, :system)
    [job] = Jobs.for_ticket(ticket.id)
    credential = funded!(project)
    %{project: project, ticket: ticket, job: job, credential: credential}
  end

  describe "connecting" do
    test "a worker with its own token gets in", %{worker: worker, token: token} do
      assert {:ok, socket} = connect(WorkerSocket, %{"worker_id" => worker.id}, bearer(token))
      assert socket.assigns.worker_id == worker.id
    end

    test "a wrong, missing or malformed token does not", %{worker: worker, token: token} do
      assert :error = connect(WorkerSocket, %{"worker_id" => worker.id}, bearer("nope"))
      assert :error = connect(WorkerSocket, %{"worker_id" => worker.id})
      assert :error = connect(WorkerSocket, %{}, bearer(token))

      # No query-parameter fallback: a URL reaches every proxy log on the path, and this token
      # is long lived. docs/design/worker-channel.md § Authentication.
      assert :error = connect(WorkerSocket, %{"worker_id" => worker.id, "token" => token})

      # And nothing else in the header is a credential.
      assert :error =
               connect(WorkerSocket, %{"worker_id" => worker.id},
                 connect_info: %{x_headers: [{"x-forge-worker-token", ""}]}
               )

      {:ok, other, _other_token} = Workers.create(%{provider: "local"})
      assert :error = connect(WorkerSocket, %{"worker_id" => other.id}, bearer(token))
    end

    test "a destroyed worker does not, even with a valid token", %{worker: worker, token: token} do
      {:ok, _worker} = Workers.status(worker, :destroyed)

      assert :error = connect(WorkerSocket, %{"worker_id" => worker.id}, bearer(token))
    end
  end

  describe "joining" do
    test "the worker's own topic, once", %{worker: worker, token: token} do
      assert {:ok, _reply, _socket} = join_worker(worker, token)
      assert Workers.connected?(worker.id)

      assert {:error, %{reason: "already_connected"}} = join_worker(worker, token)
    end

    test "not someone else's", %{worker: worker, token: token} do
      {:ok, other, _token} = Workers.create(%{provider: "local"})
      socket = connect_worker(worker, token)

      assert {:error, %{reason: "not_your_worker"}} =
               subscribe_and_join(socket, WorkerChannel, "worker:#{other.id}", %{})

      assert {:error, %{reason: "unknown_topic"}} =
               subscribe_and_join(socket, WorkerChannel, "nonsense:1", %{})
    end
  end

  describe "messages" do
    setup :ticket_with_job
    setup :assigned_to_worker

    test "ready records what the machine has to give out", %{worker: worker, token: token} do
      {:ok, _reply, socket} = join_worker(worker, token)

      ref = push(socket, "ready", %{"memory_budget" => 8_000_000_000})
      assert_reply ref, :ok

      # Idle, because the join put the job back: this worker rejoined without it, so nothing is
      # running on it (`Forge.Workers.ready/2`).
      assert %{status: :idle, memory_budget: 8_000_000_000, last_seen_at: seen} =
               Workers.get!(worker.id)

      assert seen
    end

    # The `harness` half of that same message, which is how the platform learns which models
    # exist at all — it holds no credential and cannot ask for itself.
    test "ready records what its harness offers", %{worker: worker, token: token} do
      {:ok, _reply, socket} = join_worker(worker, token)

      ref =
        push(socket, "ready", %{
          "memory_budget" => 8_000_000_000,
          "harness" => %{
            "driver" => "claude_code",
            "version" => "2.1.220",
            "credential" => "per_job",
            "aliases" => ["opus"]
          }
        })

      assert_reply ref, :ok

      recorded = Workers.get!(worker.id)
      assert recorded.harness["version"] == "2.1.220"
      assert Workers.runs?(recorded, "claude_code")
      assert Workers.offered(nil).aliases == ["opus"]
    end

    test "heartbeat says we are still here", %{worker: worker, token: token} do
      {:ok, _reply, socket} = join_worker(worker, token)
      {:ok, _worker} = Workers.update(Workers.get!(worker.id), %{last_seen_at: nil})
      refute Workers.get!(worker.id).last_seen_at

      ref = push(socket, "heartbeat", %{"running" => []})
      assert_reply ref, :ok
      assert Workers.get!(worker.id).last_seen_at
    end

    test "an assignment reaches the socket", %{worker: worker, token: token, job: job} do
      {:ok, _reply, _socket} = join_worker(worker, token)
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})

      {:ok, _job} = Jobs.assign(job, worker)

      job_id = job.id
      assert_push "assign", %{"job_id" => ^job_id, "git" => git, "store" => store}
      assert git["branch"] == "ticket/1"
      assert store["transcript_key"] =~ job_id
    end

    # **The job's credential crosses sealed for this worker and this job**, and nothing on the way
    # holds it in the clear: not the assignment, not the channel's message, not the frame
    # (`docs/design/credentials.md` § Delivery to the machine). This worker, with its own token,
    # opens it; the job is recorded against the credential that paid for it.
    test "an assignment carries the job's credential, sealed for this worker and this job",
         %{worker: worker, token: token, job: job, credential: credential} do
      {:ok, _reply, _socket} = join_worker(worker, token)
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})

      {:ok, _job} = Jobs.assign(job, worker)

      job_id = job.id
      assert_push "assign", %{"job_id" => ^job_id} = assignment

      assert %{"harness" => "claude_code", "kind" => "oauth", "sealed" => sealed} =
               assignment["credential"]

      refute inspect(assignment, limit: :infinity) =~ "sk-ant-oat01-fixture"

      {:ok, hash} = ForgeCore.Job.Credential.token_hash(token)
      assert ForgeCore.Job.Credential.open(sealed, hash, job_id) == {:ok, "sk-ant-oat01-fixture"}
      assert Jobs.get!(job_id).credential_id == credential.id
    end

    # The transcript is uploaded when the job stops, up to its preparation and its whole wall
    # clock after this token was minted. With the store's own lifetime at zero, only those two
    # keep it.
    test "the transcript token lasts as long as the job may", %{worker: worker, job: job} do
      previous = Application.get_env(:forge, Forge.Storage, [])
      Application.put_env(:forge, Forge.Storage, Keyword.put(previous, :token_max_age, 0))
      on_exit(fn -> Application.put_env(:forge, Forge.Storage, previous) end)

      :ok = Workers.connected(worker.id)
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      # Back in the queue, as a rejoin would put it: `assign/2` starts only a pending job.
      {:ok, job} = Jobs.requeue(job.id, :worker_lost)
      {:ok, _job} = Jobs.assign(job, worker)

      assert_receive {:assign, %{"store" => store}}

      assert :ok =
               Forge.Storage.Token.verify(
                 store["transcript_token"],
                 :put,
                 store["transcript_key"]
               )
    end

    test "an event becomes a line in the timeline", %{worker: worker, token: token} = context do
      %{ticket: ticket, job: job} = context
      {:ok, _reply, socket} = join_worker(worker, token)

      push(socket, "event", %{
        "job_id" => job.id,
        "event" => %{"type" => "job.harness.text", "payload" => %{"text" => "thinking"}}
      })

      # Unacked by design, so wait for the write rather than for a reply.
      ref = push(socket, "heartbeat", %{})
      assert_reply ref, :ok

      assert %{type: "job.harness.text", payload: %{"text" => "thinking"}} =
               ticket.id |> Events.for_ticket() |> List.last()
    end

    test "an event with no type is dropped, not written", %{worker: worker, token: token} = ctx do
      %{ticket: ticket, job: job} = ctx
      {:ok, _reply, socket} = join_worker(worker, token)
      before = ticket.id |> Events.for_ticket() |> length()

      push(socket, "event", %{"job_id" => job.id, "event" => %{"payload" => %{}}})
      ref = push(socket, "heartbeat", %{})
      assert_reply ref, :ok

      assert ticket.id |> Events.for_ticket() |> length() == before
    end

    test "a result is recorded, and a second one is acked and dropped", context do
      %{worker: worker, token: token, job: job, ticket: ticket} = context
      {:ok, _reply, socket} = join_worker(worker, token)

      result =
        Result.to_map(%Result{
          status: :finished,
          outcome: :converged,
          declared_outcome: "done",
          harness: %{"session_id" => "sess-1", "turns" => 2, "cost_usd" => 0.01},
          documents: %{
            "refinement.md" => ForgeCore.Document.parse!("---\noutcome: done\n---\nRefined.\n")
          }
        })

      ref = push(socket, "result", %{"job_id" => job.id, "result" => result})
      assert_reply ref, :ok, %{}, 2_000

      assert Jobs.get!(job.id).status == :finished
      assert Forge.Artifacts.latest(ticket.id, "refinement.md")

      # The worker re-sends until it is acked, so the same result must be safe to hear twice.
      ref = push(socket, "result", %{"job_id" => job.id, "result" => result})
      assert_reply ref, :ok, %{}, 2_000
      assert Forge.Artifacts.versions(ticket.id, "refinement.md") |> length() == 1
    end

    test "a hibernation is recorded with the commit it left behind", context do
      %{worker: worker, token: token, job: job, ticket: ticket} = context
      {:ok, _reply, socket} = join_worker(worker, token)
      sha = String.duplicate("a", 40)

      ref =
        push(socket, "hibernated", %{
          "job_id" => job.id,
          "commit" => sha,
          "reason" => "cancelled"
        })

      assert_reply ref, :ok

      assert Jobs.get!(job.id).status == :hibernated

      assert %{type: "job.hibernated", payload: %{"commit" => ^sha}} =
               ticket.id |> Events.for_ticket() |> List.last()
    end

    test "a failure ends the job and lets the engine decide", context do
      %{worker: worker, token: token, job: job} = context
      {:ok, _reply, socket} = join_worker(worker, token)

      ref = push(socket, "failed", %{"job_id" => job.id, "reason" => "slice was killed"})
      assert_reply ref, :ok, %{}, 2_000

      assert %{status: :finished, outcome: :error} = Jobs.get!(job.id)
    end

    test "a message nobody knows is refused rather than ignored", %{worker: w, token: token} do
      {:ok, _reply, socket} = join_worker(w, token)

      ref = push(socket, "nonsense", %{})
      assert_reply ref, :error, %{reason: "unknown_message"}
    end
  end

  describe "speaking to a conversation" do
    setup :ticket_with_job

    # A chat that is running on this worker: the arrangement every message below assumes, and
    # the one `Forge.Conversations` reads back out of the row before it sends anything.
    setup %{project: project, worker: worker} do
      chat =
        %{project: project}
        |> Forge.ForgeFixtures.chat_fixture()
        |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
        |> Forge.Repo.update!()

      %{chat: chat}
    end

    # `Forge.ConversationsTest` registers the test process itself as the worker's connection, so
    # what it proves is that `Conversations` sends the right tuple — the channel's own
    # `handle_info` clause is never run there, and a chat on a real machine would go silent with
    # the whole conversations suite green. This is the other half: the tuple arriving at a joined
    # channel and leaving it as a push. See `docs/design/conversations.md` § Talking to a run and
    # `docs/design/worker-channel.md`.
    test "a message reaches the machine as a push", %{worker: w, token: t, chat: chat} do
      {:ok, _reply, _socket} = join_with_chat(w, t, chat)

      {:ok, _event} = Conversations.send(chat, "are you there?")

      chat_id = chat.id
      assert_push "message", %{"job_id" => ^chat_id, "text" => "are you there?"} = payload
      assert payload["message_id"]
    end

    test "an interrupt reaches the machine as a push", %{worker: w, token: t, chat: chat} do
      {:ok, _reply, _socket} = join_with_chat(w, t, chat)

      :ok = Conversations.stop(chat)

      chat_id = chat.id
      assert_push "interrupt", %{"job_id" => ^chat_id}
    end

    test "a close reaches the machine as a push, with its reason", %{
      worker: w,
      token: t,
      chat: chat
    } do
      {:ok, _reply, _socket} = join_with_chat(w, t, chat)

      :ok = Conversations.close(chat, "operator closed it")

      chat_id = chat.id
      assert_push "close", %{"job_id" => ^chat_id, "reason" => "operator closed it"}
    end
  end

  # Reporting on a job means the scheduler assigned it first, and the channel refuses a job that
  # is not the caller's. The rejoin block deliberately does not use this: it builds its own
  # assignment state, which is what reconciliation is about.
  defp assigned_to_worker(%{worker: worker, job: job}) do
    job =
      job
      |> Jobs.Job.progress_changeset(%{status: :running, worker_id: worker.id})
      |> Forge.Repo.update!()

    %{job: job}
  end

  describe "how long an assignment lasts" do
    setup :ticket_with_job

    setup %{worker: worker} do
      :ok = Workers.connected(worker.id)
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})

      jobs = Application.get_env(:forge, Jobs, [])
      store = Application.get_env(:forge, Forge.Storage, [])

      on_exit(fn ->
        Application.put_env(:forge, Jobs, jobs)
        Application.put_env(:forge, Forge.Storage, store)
      end)

      %{worker: worker}
    end

    defp configure(app, opts),
      do:
        Application.put_env(
          :forge,
          app,
          Keyword.merge(Application.get_env(:forge, app, []), opts)
        )

    defp token_row(job_id), do: Forge.Repo.get_by!(Forge.Git.Token, job_id: job_id)

    defp lifetime(token),
      do: DateTime.diff(token.expires_at, DateTime.utc_now(:second))

    test "a conversation runs for a day and a workflow job for its hour", context do
      %{worker: worker, job: job, project: project} = context
      chat = chat_fixture(%{project: project})

      {:ok, _} = Jobs.assign(job, worker)
      {:ok, _} = Jobs.assign(chat, worker)

      job_id = job.id
      chat_id = chat.id
      assert_receive {:assign, %{"job_id" => ^job_id, "wall_clock_ms" => 3_600_000}}
      assert_receive {:assign, %{"job_id" => ^chat_id, "wall_clock_ms" => 86_400_000}}
    end

    # Each kind by its own clock, set here so that neither is inside the fixed ninety minutes a
    # token had before: a workflow job's default hour would pass either way.
    test "a job's git token outlives its own clock, whatever its kind", context do
      %{worker: worker, job: job, project: project} = context
      configure(Jobs, wall_clock_ms: :timer.hours(3), chat_wall_clock_ms: :timer.hours(30))
      chat = chat_fixture(%{project: project})

      {:ok, _} = Jobs.assign(job, worker)
      {:ok, _} = Jobs.assign(chat, worker)

      assert lifetime(token_row(job.id)) > 3 * 3600
      assert lifetime(token_row(chat.id)) > 30 * 3600
      assert lifetime(token_row(job.id)) < 30 * 3600
    end

    # Against literals, with nothing configured here: `docs/design/storage.md` § Serving says two
    # hours and a quarter for a workflow job and twenty-five hours and a quarter for a
    # conversation — the clock, then the preparation margin, then the store's own fifteen
    # minutes. The worker starts the clock only once the clone and the seed are ready, so a token
    # sized to the clock alone lapsed for any job whose preparation outran its fifteen minutes.
    test "the transcript token outlasts the job's preparation as well as its clock", context do
      %{worker: worker, job: job, project: project} = context
      chat = chat_fixture(%{project: project})

      {:ok, _} = Jobs.assign(job, worker)
      {:ok, _} = Jobs.assign(chat, worker)

      job_id = job.id
      chat_id = chat.id
      assert_receive {:assign, %{"job_id" => ^job_id, "store" => %{"transcript_token" => j}}}
      assert_receive {:assign, %{"job_id" => ^chat_id, "store" => %{"transcript_token" => c}}}

      assert store_token_lifetime(j) == 2 * 3600 + 15 * 60
      assert store_token_lifetime(c) == 25 * 3600 + 15 * 60
    end

    # And no longer: a second of clock, no preparation and no ordinary lifetime is a token dead
    # after a second. The margin is set to nothing here, so a margin read from anywhere but its
    # configuration would keep the token alive.
    test "the transcript token dies with the job's clock", %{worker: worker, job: job} do
      configure(Jobs, wall_clock_ms: 1_000, preparation_margin_ms: 0)
      configure(Forge.Storage, token_max_age: 0)

      {:ok, _} = Jobs.assign(job, worker)
      assert_receive {:assign, %{"store" => %{"transcript_key" => key, "transcript_token" => t}}}

      assert :ok = Forge.Storage.Token.verify(t, :put, key)
      Process.sleep(1_100)
      assert {:error, :expired} = Forge.Storage.Token.verify(t, :put, key)
    end
  end

  describe "rejoining" do
    setup :ticket_with_job

    test "a job the worker no longer has goes back in the queue", context do
      %{worker: worker, token: token, job: job} = context
      {:ok, _reply, first} = join_worker(worker, token)
      {:ok, worker} = Workers.ready(worker, %{"memory_budget" => 8_000_000_000})
      {:ok, _job} = Jobs.assign(job, worker)
      assert Jobs.get!(job.id).status == :running

      # The machine rebooted: the channel process goes, then the same worker joins again with
      # the same token and no jobs.
      Process.unlink(first.channel_pid)
      ref = leave(first)
      assert_reply ref, :ok
      wait_until(fn -> not Workers.connected?(worker.id) end)

      {:ok, _reply, socket} = join_worker(worker, token, %{"running" => []})

      ref = push(socket, "heartbeat", %{})
      assert_reply ref, :ok

      assert Jobs.get!(job.id).status == :pending
      assert "job.interrupted" in (job.ticket_id |> Events.for_ticket() |> Enum.map(& &1.type))
    end

    test "a job the platform has finished with is cancelled", context do
      %{worker: worker, token: token, job: job} = context

      {:ok, _reply, _socket} =
        join_worker(worker, token, %{"running" => [%{"job_id" => job.id, "attempt" => 1}]})

      assert_push "cancel", %{"job_id" => job_id, "reason" => "not_ours"}
      assert job_id == job.id
    end
  end
end
