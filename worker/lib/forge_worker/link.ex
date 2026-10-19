defmodule ForgeWorker.Link do
  @moduledoc """
  The worker's end of the channel: it dials the platform, joins its own topic, takes
  assignments and reports what happened. The protocol is `docs/design/worker-channel.md`;
  this module is its only implementation on this side.

  One process holds the connection; each job runs in its own task, which talks back to this
  process rather than pushing on its own. That keeps every message on the socket in one place
  and means a job that dies takes nothing with it.

  Terminal messages — result, hibernated, failed — are kept until the platform acks them and
  re-sent on every rejoin. Events are not: a lost one costs a line in the timeline, and the
  result is the contract.
  """

  use Slipstream, restart: :permanent

  alias ForgeCore.Job.Result
  alias ForgeCore.WorkerProtocol
  alias ForgeCore.Workflow.Resources
  alias ForgeWorker.{Checkout, Config, Health, Log, Slice, Stats, Store}

  alias ForgeWorker.Job.{
    Blobs,
    Command,
    Conversation,
    Credential,
    Dir,
    Runner,
    Secrets,
    Seed,
    Session,
    Workspace
  }

  require Logger

  @heartbeat_ms :timer.seconds(20)
  @stats_ms :timer.seconds(5)
  @refused_retry_ms :timer.minutes(5)

  # Twenty seconds against `worker_timeout_ms` on the platform, and far too long for a test to
  # wait out. Overridable only so that the suite can watch one arrive; nothing configures it.
  defp heartbeat_ms, do: Application.get_env(:forge_worker, :heartbeat_ms, @heartbeat_ms)

  # The workers page refreshes every five seconds, so a reading more often than that is one
  # nobody sees (`docs/design/worker-channel.md` § Live figures). Configurable like the heartbeat;
  # the test config sets it long, because a push in `Slipstream.SocketTest` is a call the test
  # has to answer, and one arriving unasked stalls the link for the call's timeout.
  defp stats_ms, do: Application.get_env(:forge_worker, :stats_ms, @stats_ms)

  # How long a machine the platform refused waits before asking again. Minutes, because only a
  # deploy on one side or the other changes the answer, and Slipstream's own rejoin backoff
  # settles at ten seconds — a log line and a refused join three hundred and sixty times an hour
  # (`docs/design/worker-channel.md` § Versions).
  defp refused_retry_ms,
    do: Application.get_env(:forge_worker, :refused_retry_ms, @refused_retry_ms)

  # Whether this machine's lines go to the platform at all (`docs/design/worker-log.md`). On,
  # except in the test config, for the reason `stats_ms` is long there: a push nobody asked for
  # stalls a `Slipstream.SocketTest` link. The tests about the log turn it on.
  defp log_stream?, do: Application.get_env(:forge_worker, :log_stream, true)

  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "What this worker is running, as the join payload reports it."
  @spec running(GenServer.server()) :: [map()]
  def running(link \\ __MODULE__), do: GenServer.call(link, :running)

  @doc "Terminal messages the platform has not acked. They are re-sent on every join."
  @spec unacked(GenServer.server()) :: [{String.t(), String.t()}]
  def unacked(link \\ __MODULE__), do: GenServer.call(link, :unacked)

  @impl Slipstream
  def init(opts) do
    worker_id = Keyword.get(opts, :worker_id) || Config.worker_id()

    config =
      opts
      |> Keyword.drop([:worker_id, :root])
      |> Keyword.put_new_lazy(:uri, &Config.socket_uri/0)
      |> Keyword.put_new_lazy(:headers, &Config.socket_headers/0)

    socket =
      new_socket()
      |> assign(:jobs, %{})
      # Runs stopped because the platform has given them up — the machine went unhealthy, a
      # `cancel` said so, or the platform refused this machine — whose endings are reported to
      # nobody (`give_up/3`).
      |> assign(:abandoned, MapSet.new())
      # Assignments for a job whose earlier run here is still stopping, started once it has
      # (`docs/design/worker-channel.md` § Reconnection).
      |> assign(:deferred, %{})
      # Whether the platform has answered this machine's `unhealthy`: said until it has, and not
      # again after — its join keeps the mark from then on (`docs/design/worker-channel.md` § An
      # unhealthy machine).
      |> assign(:unhealthy_answered, false)
      |> assign(:unacked, %{})
      |> assign(:acks, %{})
      |> assign(:root, Keyword.get(opts, :root, Config.root()))
      |> assign(:topic, "worker:" <> worker_id)
      |> assign(:ticking, false)
      |> assign(:retry, nil)
      |> assign(:cpu, nil)
      |> assign(:log, Log.empty())

    {:ok, connect!(socket, config)}
  end

  # -- the channel --------------------------------------------------------------------------

  @impl Slipstream
  def handle_connect(socket), do: {:ok, join(socket, socket.assigns.topic, join_payload(socket))}

  @impl Slipstream
  def handle_join(topic, _reply, socket) do
    # The line M4 watches for: joining is a phase of the cold start, and from outside the
    # machine it is otherwise indistinguishable from the release merely having started. The
    # version is here because a worker can now be updated without its image being rebuilt
    # (`docs/design/worker-tier.md` § Updating a worker), so "which release is this machine
    # running" stopped being answerable from the image alone.
    Logger.info(
      "joined #{topic} running #{version()}; ready with #{Config.memory_budget()} bytes " <>
        "and #{Config.cores() || "an unknown number of"} cores"
    )

    push(socket, socket.assigns.topic, "ready", ready_payload(socket))

    {:ok, socket |> tick() |> send_held() |> resend_unacked() |> report_unhealthy()}
  end

  # **Started once, at the first join, and never again.** These used to be started on every join,
  # so each reconnect added another heartbeat — five reconnects, five heartbeats every twenty
  # seconds, each a write to the row. A tick while the topic is not joined pushes nothing: `push/4`
  # answers `{:error, :not_joined}` and the next tick tries again.
  defp tick(%{assigns: %{ticking: true}} = socket), do: socket

  defp tick(socket) do
    :timer.send_interval(heartbeat_ms(), self(), :heartbeat)
    :timer.send_interval(stats_ms(), self(), :stats)
    assign(socket, :ticking, true)
  end

  @doc """
  What this machine tells the platform about itself at `ready`.

  **`cores` and `accepts` are left out rather than sent as null when the machine has nothing to
  say.** The platform reads an absent key as *unknown* and does not gate on that dimension,
  which is what a general-purpose worker means and what every worker meant before the keys
  existed (`docs/design/provisioning.md` § What a worker offers). `memory_budget` is always
  sent, because there not knowing is itself an instruction — see `ForgeWorker.Config.cores/0`.

  Public because it is the part of joining that can be checked without a socket, in the same
  spirit as `ForgeWorker.Slice.Systemd.flags/1`.
  """
  @spec ready_payload(Slipstream.Socket.t()) :: map()
  def ready_payload(socket) do
    %{
      "memory_budget" => Config.memory_budget(),
      "seeds" => Seed.present(socket.assigns.root),
      "root" => socket.assigns.root,
      "harness" => harness_offer()
    }
    |> put_unless_nil("cores", Config.cores())
    |> put_unless_nil("accepts", Config.accepts())
  end

  defp put_unless_nil(payload, _key, nil), do: payload
  defp put_unless_nil(payload, key, value), do: Map.put(payload, key, value)

  @impl Slipstream
  def handle_message(_topic, "assign", assignment, socket), do: {:ok, take(socket, assignment)}

  # **A `cancel` that says the platform has given the run up stops it unreported** — `not_ours`
  # from a rejoin, `retired` from a row the platform destroyed. The job is already back in the
  # queue, placed elsewhere or finished, and the run's ending would land on the job as it now is:
  # a re-queued job finished as an error, because its last push was refused with the credential the
  # re-queue revoked (`docs/design/worker-channel.md` § Reconnection). Any other reason —
  # `ticket_cancelled` — is reported as before, which is how the platform settles what the run
  # spent. A job with no runner yet is stopped the moment it has one, as an unhealthy machine's is.
  def handle_message(_topic, "cancel", %{"job_id" => job_id, "reason" => reason}, socket)
      when reason in ["not_ours", "retired"] do
    {:ok, give_up(socket, job_id, given_up(reason))}
  end

  # Any cancel ends the platform's interest in the job here, so an assignment held for it — its
  # next run on this machine, waiting for the old one to stop — goes with it, whatever the reason.
  def handle_message(_topic, "cancel", %{"job_id" => job_id}, socket) do
    case socket.assigns.jobs[job_id] do
      %{runner: runner} = job when is_pid(runner) -> cancel(job)
      _other -> Logger.info("asked to cancel #{job_id}, which is not running here")
    end

    {:ok, update_in(socket.assigns.deferred, &Map.delete(&1, job_id))}
  end

  # A conversation is spoken to while it runs, which no workflow job ever is. Each of these is
  # forwarded to the process holding that chat and does nothing at all for a job.
  def handle_message(_topic, "message", %{"job_id" => job_id} = payload, socket) do
    with_conversation(socket, job_id, "message", fn pid ->
      Conversation.send_message(pid, payload["message_id"], payload["text"])
    end)
  end

  def handle_message(_topic, "interrupt", %{"job_id" => job_id}, socket) do
    with_conversation(socket, job_id, "interrupt", &Conversation.interrupt/1)
  end

  def handle_message(_topic, "close", %{"job_id" => job_id} = payload, socket) do
    with_conversation(socket, job_id, "close", fn pid ->
      Conversation.close(pid, payload["reason"] || "closed")
    end)
  end

  def handle_message(topic, event, _payload, socket) do
    Log.line(
      "message.unknown",
      :warning,
      "unknown message #{inspect(event)} on #{topic}: the platform is a version apart"
    )

    {:ok, socket}
  end

  # What to do with an assignment, wherever it comes from: the platform's `assign`, or one held
  # until the earlier run of its job had stopped.
  defp take(socket, %{"job_id" => job_id} = assignment) do
    cond do
      # **A job whose run here was given up on is assigned again once that run has stopped.** The
      # scheduler prefers the machine a job last ran on, so a job re-queued off this machine can
      # come straight back while its old run is in its grace period. Dropped as *already running*,
      # it left the platform with a job marked `running` that nothing was running.
      Map.has_key?(socket.assigns.jobs, job_id) and
          MapSet.member?(socket.assigns.abandoned, job_id) ->
        Logger.info("job #{job_id} assigned again; starting it once its earlier run has stopped")
        put_in(socket.assigns.deferred[job_id], assignment)

      Map.has_key?(socket.assigns.jobs, job_id) ->
        Logger.info("already running job #{job_id}")
        socket

      # Nothing it is given now can run, and the platform has put it back in the queue — every
      # job running here when the report reached it, and any assignment its channel is handed
      # after that (`docs/design/worker-channel.md` § An unhealthy machine). So it is dropped, and
      # nothing is reported: a result from this machine would be recorded as the job's answer.
      why = Health.unhealthy() ->
        Log.line("job.refused", :warning, "not started: this machine is unhealthy: #{why}",
          job_id: job_id
        )

        socket

      reason = ceiling_refused(assignment) ->
        refuse(socket, assignment, reason)

      true ->
        Log.line("job.accepted", :info, accepted(assignment), job_id: job_id)
        start_job(socket, assignment)
    end
  end

  # **The last place a nonsense ceiling can be kept from systemd**, and it holds against a
  # platform older than this worker: a unit whose `memory.max` is too small to exec in is how a
  # machine's PID 1 stopped answering (`docs/design/worker-tier.md` § The job slice). A ceiling
  # nobody set is not one — the slice then sets none — and anything else must be a number of
  # bytes no smaller than the minimum.
  defp ceiling_refused(assignment) do
    case get_in(assignment, ["slice", "memory_max"]) do
      nil ->
        nil

      bytes when is_integer(bytes) ->
        unless Resources.enough_memory?(bytes) do
          "its memory ceiling of #{bytes(bytes)} is below the #{minimum()} minimum, the least a " <>
            "job can run in, so it was not started"
        end

      other ->
        "its memory ceiling #{inspect(other)} is not a number of bytes, and the least a job can " <>
          "run in is the #{minimum()} minimum, so it was not started"
    end
  end

  # Every refusal names the ceiling and the minimum; a ceiling of nought or less has no unit to
  # name it in (`Resources.size/1` takes a positive count), and says so in bytes.
  defp bytes(bytes) when bytes > 0, do: Resources.size(bytes)
  defp bytes(bytes), do: "#{bytes} bytes"

  defp minimum, do: Resources.size(Resources.minimum_memory())

  # Ended at once, as an error the platform records like any other: a workflow job's or a
  # command's `result`, and a chat's `failed`, which is the only ending a chat can fail with.
  defp refuse(socket, %{"job_id" => job_id} = assignment, reason) do
    Log.line("job.refused", :error, reason, job_id: job_id)

    terminal =
      case assignment["kind"] do
        "chat" ->
          {:terminal, job_id, "failed", %{"job_id" => job_id, "reason" => reason}}

        _job_or_command ->
          result = %Result{status: :finished, outcome: :error, reason: reason}
          {:terminal, job_id, "result", %{"job_id" => job_id, "result" => Result.to_map(result)}}
      end

    send(self(), terminal)
    socket
  end

  # Two clauses that do the same today — both cast `:cancel` — and so an equivalent mutant: kept
  # apart because they are two modules' APIs, and one may come to mean more.
  defp cancel(%{runner: runner, kind: :command}), do: Command.cancel(runner)
  defp cancel(%{runner: runner}), do: Runner.cancel(runner)

  # The platform's answer to `unhealthy` is its decision whether this machine reboots, so it goes
  # to the process that decides the rest (`ForgeWorker.Health`); every other reply only says a
  # message was recorded.
  @impl Slipstream
  def handle_reply(ref, reply, socket) do
    case socket.assigns.acks[ref] do
      nil ->
        {:ok, socket}

      {:machine, "unhealthy"} = key ->
        Health.answered(reply)
        {:ok, socket |> forget(ref, key) |> assign(:unhealthy_answered, true)}

      key ->
        {:ok, forget(socket, ref, key)}
    end
  end

  # -- what the jobs say --------------------------------------------------------------------

  @impl Slipstream
  def handle_info(:heartbeat, socket) do
    push(socket, socket.assigns.topic, "heartbeat", %{"running" => running_list(socket)})
    {:noreply, socket}
  end

  # Sampled on every tick, joined or not, so the first push after a reconnect already has a CPU
  # figure to difference against. Unacked: the next one is seconds away.
  def handle_info(:stats, socket) do
    {stats, cpu} = Stats.sample(socket.assigns.root, socket.assigns.cpu)
    push(socket, socket.assigns.topic, "stats", stats)
    {:noreply, assign(socket, :cpu, cpu)}
  end

  # The retry a refused join scheduled, **and only the latest one**. A reconnect while refused
  # joins afresh from `handle_connect/1`, and when that join is refused too it schedules its own
  # retry; the earlier one still fires, and the topic is `:closed` again by then, so `rejoin/3`
  # would act on it — one more retry chain, one more refused join and log line every few minutes,
  # for every reconnect. Each refusal therefore names its retry and replaces the last.
  def handle_info({:rejoin, topic, retry}, %{assigns: %{retry: retry}} = socket) do
    socket = assign(socket, :retry, nil)

    case rejoin(socket, topic, join_payload(socket)) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_info({:rejoin, _topic, _stale}, socket), do: {:noreply, socket}

  # A job abandoned before it had a runner is stopped the moment it has one: the platform has
  # already given that run up.
  def handle_info({:runner, job_id, pid}, socket) do
    socket = update_job(socket, job_id, &Map.put(&1, :runner, pid))

    if MapSet.member?(socket.assigns.abandoned, job_id),
      do: cancel(socket.assigns.jobs[job_id])

    {:noreply, socket}
  end

  # **This machine can run nothing more** (`ForgeWorker.Health`): the platform is told — acked, so
  # it hears even across a reconnect, and its reply decides the reboot — and every job here is
  # stopped and reported to nobody, since the platform puts them back in the queue as it would a
  # lost machine's (`docs/design/worker-tier.md` § What happens then).
  #
  # A mark is an episode, and said afresh: `ForgeWorker.Health` marks once per life, so a second
  # one is a health process that restarted, forgot, and found the machine unhealthy again.
  def handle_info({:unhealthy, _reason}, socket) do
    socket = socket |> assign(:unhealthy_answered, false) |> report_unhealthy()

    {:noreply,
     abandon(
       socket,
       "stopped because this machine is unhealthy; the platform puts it back in the queue"
     )}
  end

  def handle_info({:event, job_id, event}, socket) do
    push(socket, socket.assigns.topic, "event", %{
      "job_id" => job_id,
      "event" => %{"type" => event.type, "payload" => event.payload}
    })

    {:noreply, socket}
  end

  # Acked like a terminal message, and keyed by the turn as well as the job, because there is
  # one of these per turn rather than one per job.
  def handle_info({:chat_turn, job_id, index, payload}, socket) do
    {:noreply, send_acked(socket, {job_id, "turn", index}, "turn", payload)}
  end

  # An abandoned job's ending: its runner was stopped, or its `systemd-run` could not reach PID 1,
  # and the platform has given the run up either way — re-queued it, placed it elsewhere or
  # finished with it. Its own report would land on the job as it now is, so it goes nowhere.
  def handle_info({:terminal, job_id, message, payload}, socket) do
    if MapSet.member?(socket.assigns.abandoned, job_id),
      do: {:noreply, withhold(socket, job_id)},
      else: {:noreply, report(socket, job_id, message, payload)}
  end

  # A conversation that stopped without saying so. One that ends normally has already sent its
  # terminal message, which removed it from `jobs` before this arrives — a process's messages to
  # one receiver keep their order, and the monitor's comes after its last — so a chat still listed
  # here crashed, and the platform is told it failed rather than left holding a chat that is not
  # running anywhere.
  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Enum.find(socket.assigns.jobs, fn {_id, job} -> job[:monitor] == ref end) do
      {job_id, _job} ->
        why = "the conversation stopped: #{Exception.format_exit(reason)}"
        send(self(), {:terminal, job_id, "failed", %{"job_id" => job_id, "reason" => why}})

      nil ->
        :ok
    end

    {:noreply, socket}
  end

  # A line for this machine's log, from this process or any other (`ForgeWorker.Log.line/4`).
  def handle_info({:log, entry}, socket) do
    if log_stream?(), do: {:noreply, send_line(socket, entry)}, else: {:noreply, socket}
  end

  def handle_info(message, socket) do
    Logger.debug("link ignored #{inspect(message)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_call(:running, _from, socket), do: {:reply, running_list(socket), socket}

  def handle_call(:unacked, _from, socket),
    do: {:reply, Map.keys(socket.assigns.unacked), socket}

  # `reconnect/1` answers `{:ok, socket}` or `{:error, reason}`, and the callback's own return
  # is `{:ok, socket}` — wrapping one in the other crashes the link on the first failed dial,
  # which on a worker booting before the platform is reachable is every dial. A socket with no
  # configuration cannot be reconnected in place; stopping lets the supervisor start it again
  # with one, which is the only repair there is.
  #
  # **The refs it was waiting on replies for go with the connection.** A ref is a counter that
  # starts again on the next one, so a reply there to an untracked `ready` or `heartbeat` could
  # match a ref the old connection used for a terminal message and forget it unsent. The messages
  # themselves stay in `unacked`, and the next join sends every one of them again.
  #
  # **A platform that refuses the connection itself is a refusal too.** A row that is destroyed, or
  # a token that is not its, is turned away at the socket — `WorkerSocket.connect/3` answers 403 —
  # before any join, so `handle_topic_close/3` never hears of it; after a reconnect that is how a
  # retired machine is refused. Nothing it reports can be recorded, so it stops what it runs, as a
  # refused join does.
  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("disconnected from the platform: #{inspect(reason)}")
    socket = assign(socket, :acks, %{})

    socket =
      case reason do
        {:error, {:upgrade_failure, %{status_code: status}}} when status in [401, 403] ->
          abandon(
            socket,
            "stopped: the platform refused this machine's connection, so nothing it reports " <>
              "can be recorded, and it puts the job back in the queue"
          )

        _other ->
          socket
      end

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  # A channel the platform closed under us — a restart, a redeploy, a worker row it no longer
  # believes in. Rejoining is what makes the reconciliation in handle_join happen, and the
  # default here is to stop, which would lose every unacked result on this worker.
  #
  # **Except when the platform has said no for a reason only a deploy changes.** A protocol it
  # does not accept, or a row it has destroyed, is not answered differently ten seconds later, so
  # the machine says so in one line and asks again in minutes (`docs/design/worker-channel.md`
  # § Versions).
  #
  # **And it stops what it is running**, reporting nothing: no message reaches the platform from a
  # refused join, and the platform re-queues a refused machine's jobs — at once for a managed one
  # it destroys, after the unreachable timeout for a permanent one. A permanent machine that ran on
  # would spend its jobs' credentials on runs nobody would record, while the same jobs ran again
  # elsewhere (`docs/design/worker-channel.md` § Versions).
  @impl Slipstream
  def handle_topic_close(topic, {:failed_to_join, %{"reason" => reason} = reply}, socket)
      when reason in ["protocol", "destroyed"] do
    Logger.error(refused(reason, reply) <> "; asking again in #{div(refused_retry_ms(), 1000)}s")
    retry = make_ref()
    Process.send_after(self(), {:rejoin, topic, retry}, refused_retry_ms())

    socket =
      abandon(
        socket,
        "stopped: the platform refused this machine's join, so nothing it reports can be " <>
          "recorded, and it puts the job back in the queue"
      )

    {:ok, assign(socket, :retry, retry)}
  end

  def handle_topic_close(topic, reason, socket) do
    Logger.warning("channel #{topic} closed: #{inspect(reason)}")

    case rejoin(socket, topic, join_payload(socket)) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:ok, socket}
    end
  end

  defp report(socket, job_id, message, payload) do
    # **Every ending leaves masked, from here** (`docs/design/secrets.md` § Masking): a result's
    # documents and reason, a conversation's last report, and a failure's reason — which can be a
    # hook's output, a crash's message or the harness's last line of stderr. One place, because
    # every one of them comes through it.
    job = socket.assigns.jobs[job_id]
    payload = Secrets.mask(job && job[:secrets], payload)
    {level, how} = finished(message, payload)
    Log.line("job.finished", level, how <> ran(socket.assigns.jobs[job_id]), job_id: job_id)

    socket
    |> update_in([Access.key!(:assigns), Access.key!(:jobs)], &Map.delete(&1, job_id))
    |> send_terminal(job_id, message, payload)
  end

  # An abandoned run's ending, reported to nobody — and then the job's next assignment, if the
  # platform sent one while this run was stopping.
  defp withhold(socket, job_id) do
    Logger.info("job #{job_id} ended after the platform gave the run up; not reported")

    {next, deferred} = Map.pop(socket.assigns.deferred, job_id)

    socket =
      socket
      |> update_in([Access.key!(:assigns), Access.key!(:jobs)], &Map.delete(&1, job_id))
      |> update_in([Access.key!(:assigns), Access.key!(:abandoned)], &MapSet.delete(&1, job_id))
      |> assign(:deferred, deferred)

    if next, do: take(socket, next), else: socket
  end

  # Once, under its own key: re-sent after every reconnect until the platform answers it, never
  # twice while one is waiting, and **not again once answered** — every rejoin would otherwise ask
  # the platform again, which moves the time it said to reboot and with it the hour and the grace.
  # Answered with an error is answered too: a platform that does not know the message will not
  # know it on the next join either. Nothing when the machine is well.
  defp report_unhealthy(socket) do
    key = {:machine, "unhealthy"}

    case Health.unhealthy() do
      nil ->
        socket

      reason ->
        if socket.assigns.unhealthy_answered or Map.has_key?(socket.assigns.unacked, key),
          do: socket,
          else: send_acked(socket, key, "unhealthy", %{"reason" => reason})
    end
  end

  # Every job here given up at once, for the reason `why`: the machine is unhealthy, or the
  # platform refused it.
  defp abandon(socket, why) do
    socket.assigns.jobs
    |> Map.keys()
    |> Enum.reduce(socket, &give_up(&2, &1, why))
  end

  # **One run stopped and its ending reported to nobody**, because the platform has already given
  # it up (`docs/design/worker-log.md`, `job.abandoned`): the machine went unhealthy, the platform
  # cancelled it as no longer this machine's or retired the row, or it refused the machine. Logged
  # and cancelled once per run, whichever comes first — a second word (unhealthy, then a refused
  # join; two `not_ours`) finds it already abandoned; a job with no runner yet is stopped when it
  # has one.
  #
  # **An assignment held for the job goes too, whenever this is said.** It was the platform's next
  # run of the job on this machine, and a give-up that arrives while the old run is still stopping
  # is the platform giving that one up as well; started anyway, it ran on a credential the
  # platform had already let go of.
  defp give_up(socket, job_id, why) do
    job = socket.assigns.jobs[job_id]
    socket = update_in(socket.assigns.deferred, &Map.delete(&1, job_id))

    if is_nil(job) or MapSet.member?(socket.assigns.abandoned, job_id) do
      socket
    else
      Log.line("job.abandoned", :warning, why, job_id: job_id)
      if is_pid(job.runner), do: cancel(job)
      update_in(socket.assigns.abandoned, &MapSet.put(&1, job_id))
    end
  end

  defp given_up("not_ours"),
    do:
      "stopped: the platform no longer has it running here — re-queued, placed elsewhere or " <>
        "finished — so this run's ending goes unreported"

  defp given_up("retired"),
    do: "stopped: the platform retired this machine and put its jobs back in the queue"

  defp refused("protocol", reply) do
    "the platform refused this worker's protocol #{WorkerProtocol.current()}: it accepts " <>
      "#{reply["minimum"]}–#{reply["current"]}. Update this machine or the platform"
  end

  defp refused("destroyed", _reply) do
    "the platform has retired this machine and will not take it back. Provision it again " <>
      "with mix forge.worker.new, or switch it off"
  end

  # -- running one job ----------------------------------------------------------------------

  defp start_job(socket, %{"kind" => "chat"} = assignment) do
    link = self()

    case DynamicSupervisor.start_child(
           ForgeWorker.Job.Supervisor,
           {Conversation, assignment: assignment, link: link, root: socket.assigns.root}
         ) do
      {:ok, pid} ->
        put_in(socket.assigns.jobs[assignment["job_id"]], %{
          task: pid,
          # A conversation reports its own ending — unless it crashes, when nothing would, and the
          # platform would go on believing it runs here (`handle_info({:DOWN, …})`).
          monitor: Process.monitor(pid),
          runner: nil,
          attempt: 1,
          kind: :chat,
          # Sealed, as the assignment carried them: what its ending is masked with.
          secrets: Secrets.from_assignment(assignment),
          started: System.monotonic_time(:millisecond)
        })

      {:error, reason} ->
        Logger.error("could not start chat #{assignment["job_id"]}: #{inspect(reason)}")

        send(
          link,
          {:terminal, assignment["job_id"], "failed",
           %{"job_id" => assignment["job_id"], "reason" => inspect(reason)}}
        )

        socket
    end
  end

  defp start_job(socket, assignment) do
    link = self()
    root = socket.assigns.root

    {:ok, task} =
      Task.Supervisor.start_child(ForgeWorker.TaskSupervisor, fn ->
        run(link, assignment, root)
      end)

    put_in(socket.assigns.jobs[assignment["job_id"]], %{
      task: task,
      runner: nil,
      attempt: assignment["spec"]["attempt"],
      kind: if(assignment["kind"] == "command", do: :command, else: :workflow),
      secrets: Secrets.from_assignment(assignment),
      started: System.monotonic_time(:millisecond)
    })
  end

  defp with_conversation(socket, job_id, message, fun) do
    case Conversation.whereis(job_id) do
      pid when is_pid(pid) ->
        fun.(pid)

      # In the machine's log, not only the journal: the platform believes this chat runs here, and
      # a message that reached nobody is the one thing a person asking "why no reply" needs.
      nil ->
        Log.line(
          "chat.missing",
          :warning,
          "asked to #{message} a chat that is not running here",
          job_id: job_id
        )
    end

    {:ok, socket}
  end

  @doc false
  # Runs one job to its end and tells the link what happened. Anything that goes wrong here is
  # a failed job, reported as one: a task that dies quietly would leave the platform holding a
  # job it believes is running until the next rejoin.
  def run(link, assignment, root) do
    job_id = assignment["job_id"]
    secrets = Secrets.from_assignment(assignment)

    # What it reports is masked as it leaves, by the link (`report/4`).
    outcome =
      with :ok <- Secrets.check(secrets) do
        as_user(assignment, root, &prepare_and_run(link, assignment, root, &1))
      end

    case outcome do
      {:ok, {"result", result}} ->
        send(link, {:terminal, job_id, "result", %{"job_id" => job_id, "result" => result}})

      {:ok, {message, payload}} ->
        send(link, {:terminal, job_id, message, Map.put(payload, "job_id", job_id)})

      {:error, reason} ->
        Logger.error("job #{job_id} failed: #{inspect(reason)}")

        send(
          link,
          {:terminal, job_id, "failed", %{"job_id" => job_id, "reason" => inspect(reason)}}
        )
    end
  catch
    kind, reason ->
      formatted = Exception.format(kind, reason, __STACKTRACE__)
      Logger.error("job #{assignment["job_id"]} crashed: #{formatted}")

      send(
        link,
        {:terminal, assignment["job_id"], "failed",
         %{"job_id" => assignment["job_id"], "reason" => formatted}}
      )
  end

  # The job's Unix user, made before anything of the job exists on this machine and removed after
  # it, however it ended (`docs/design/worker-tier.md` § The job slice). A job that got as far as
  # its commit has already left, straight after it; this is for the endings that never got there,
  # and finds nothing to do for the ones that did.
  defp as_user(assignment, root, fun) do
    case Slice.enter(assignment["job_id"]) do
      {:ok, user} ->
        try do
          fun.(user)
        after
          # The worktree is usually discarded by now, and a path that is not there is no
          # failure to report.
          Slice.leave(user, Enum.filter(job_paths(assignment, root), &File.exists?/1))
        end

      {:error, reason} ->
        {:error, {:user, reason}}
    end
  end

  defp job_paths(assignment, root),
    do: [Workspace.dir(assignment, root), job_dir(root, assignment["job_id"])]

  # `docs/design/commands.md`: the checkout at the recorded commit, the script the spec carries,
  # the log to the store under the key the platform minted a token for. Nothing is committed or
  # pushed — a command's write is its log — and nothing is promoted: its tree is a commit, not a
  # ticket's work in progress.
  defp prepare_and_run(link, %{"kind" => "command"} = assignment, root, user) do
    job_id = assignment["job_id"]
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])

    with {:ok, worktree} <- Workspace.prepare(assignment, root, user),
         :ok <- Checkout.detach(worktree, spec.command["at"], Slice.as_user(user)),
         {:ok, command} <- start_command(assignment, spec, root, worktree) do
      send(link, {:runner, job_id, command})
      {:ok, result} = Command.await(command)

      Secrets.mask_file(
        Secrets.from_assignment(assignment),
        Command.log_path(job_dir(root, job_id))
      )

      result =
        result
        |> upload_log(assignment, job_dir(root, job_id))
        |> Blobs.upload(assignment, Dir.blobs_dir(job_dir(root, job_id)))

      Workspace.discard(assignment, root)
      {:ok, {"result", Result.to_map(result)}}
    end
  end

  defp prepare_and_run(link, assignment, root, user) do
    job_id = assignment["job_id"]

    with {:ok, worktree} <- Workspace.prepare(assignment, root, user),
         {:ok, logs} <- fetch_command_logs(assignment, root),
         {:ok, runner} <- start_runner(link, assignment, root, worktree, logs, user) do
      # Copied into the job directory by the time the runner has started (`Dir.prepare/3`).
      File.rm_rf(Dir.fetched_dir(job_dir(root, job_id)))
      send(link, {:runner, job_id, runner})
      {:ok, result} = Runner.await(runner)

      # The work goes to the branch before anything is reported: the platform records the
      # branch head as the changeset artifact the moment it hears from us, and a job that is
      # stopping must not lose what it did (`docs/decisions.md`). A platform that is not there
      # is waited for (`Workspace.commit_and_push/4`).
      changeset? = ForgeCore.Job.Spec.changeset?(ForgeCore.Job.Spec.from_map(assignment["spec"]))

      case keep(changeset?, assignment, worktree, user) do
        {:ok, head} -> finish(assignment, root, worktree, result, head, changeset?, user)
        {:error, reason} -> unpushed(result, reason, changeset?)
      end
    end
  end

  # **Only a state that declares `changeset` commits anything.** `changeset` is reserved and
  # means the diff of the job's branch, so a state that does not declare it has promised its
  # documents and its log and nothing else: its tree is scratch, and `Checkout.squash/5`'s
  # `add -A` would sweep whatever the run happened to leave there onto the branch a later
  # `merged` transition fast-forwards from. That is ticket 3 — a review killed mid-mutation,
  # its broken tree committed as `eaf0a5d` and nothing to catch it. The guard is here because
  # this is the only place that knows both that the run has ended and what the state promised;
  # `Workspace` and `Checkout` know neither. A scratch tree is discarded, not kept anywhere.
  #
  # The head such a run reports is the one it started from, which is all it can honestly claim.
  defp keep(true, assignment, worktree, user),
    do: Workspace.commit_and_push(assignment, worktree, commit_message(assignment), user)

  defp keep(false, assignment, worktree, user),
    do: Workspace.base(assignment, worktree, user)

  # **A cancelled run whose push is refused still says what it spent.** Cancelling a ticket
  # revokes its jobs' credentials as it sends the `cancel`, so a run with work to push is refused
  # by the time it gets there; reporting `failed` threw the run's result away, and with it the
  # cost the platform settles from a cancelled run's `hibernated` (`Jobs.hibernate/4`). The work
  # is the cancelled ticket's, and nobody is waiting for it. Any other run whose push failed has
  # lost its work, and fails. A no-`changeset` run reaches this having attempted no push at all,
  # so the line says which of the two it was rather than naming a push that never happened.
  defp unpushed(%Result{killed: :operator} = result, reason, changeset?) do
    Logger.warning("a cancelled run's #{attempted(changeset?)} failed: #{inspect(reason)}")

    {:ok,
     {"hibernated",
      %{"commit" => nil, "reason" => "cancelled", "result" => Result.to_map(result)}}}
  end

  # **Named for what was actually attempted.** A no-`changeset` run never pushes, so the only way
  # `keep/4` fails for one is `Workspace.base/3` not resolving the branch head — and reporting
  # that as `:push` sends the first person to debug it to the credential and the hook, which were
  # not involved.
  #
  # **Swapping these two tags is an uncatchable mutation here, and no test should claim it is
  # not.** Reaching the `false` clause through `Link` needs `rev-parse origin/<branch>` to fail
  # in a worktree whose checkout already resolved that same ref, so a branch the clone could not
  # fetch fails in `Workspace.prepare/3` long before a run ends. What is tested is the error
  # itself, one level down, where it can be provoked: `Job.WorkspaceTest`, "the base errors when
  # the branch has no fetched head".
  defp unpushed(_result, reason, true), do: {:error, {:push, reason}}
  defp unpushed(_result, reason, false), do: {:error, {:branch_head, reason}}

  # `attempted(false)` is on the same unreachable path as the clause above and is uncovered for
  # the same reason: a cancelled run whose `Workspace.base/3` failed. Labelled here too so the
  # next reader does not write a test for it that could only pass.
  defp attempted(true), do: "push"
  defp attempted(false), do: "read of the branch head"

  defp finish(assignment, root, worktree, result, head, changeset?, user) do
    job_id = assignment["job_id"]

    # That was the last git command in the tree, so the files come back to root and the user
    # goes — before the worker reads the job's outputs or keeps the tree as the ticket's
    # template, which must not belong to a uid the next `useradd` may hand to another job.
    Slice.leave(user, job_paths(assignment, root))

    Secrets.mask_file(Secrets.from_assignment(assignment), result.transcript_path)

    terminal =
      {:ok,
       result
       |> upload_transcript(assignment)
       |> upload_session(assignment, job_dir(root, job_id))
       |> Blobs.upload(assignment, Dir.blobs_dir(job_dir(root, job_id)))
       |> terminal(head)}

    # What this run compiled is kept as the ticket's template, so its next job starts here
    # rather than at the project's seed. After the push, never before: that is what leaves the
    # tree holding nothing but the checkout and its ignored build output. See
    # docs/design/worker-tier.md § The ticket volume.
    #
    # And only when there was a push. A state that produces no changeset left its tree uncommitted
    # on purpose (`keep/4`), so promoting it would hand the next job a tree holding work nobody
    # accepted — which that job's own `add -A` would then commit, putting on the branch by the
    # long way exactly what the guard above refused by the short one. The template is a cache: the
    # ticket keeps the one it had, and the next job starts colder.
    if changeset?, do: Workspace.promote(assignment, root, worktree)

    # Only once everything that had to leave the machine has left it. A worktree is a
    # snapshot of the seed and the next attempt takes a fresh one; keeping this one would
    # keep every job this machine ever ran.
    Workspace.discard(assignment, root)

    # And the job directories of runs old enough that nobody is going to resume them. A
    # worker that is never destroyed has nothing else to collect them; the end of a job is
    # already a moment spent on the filesystem. See docs/design/worker-tier.md § What a
    # machine that never dies accumulates.
    swept = Dir.sweep(Path.join(root, "jobs"), job_retention_ms())
    if swept > 0, do: Logger.info("swept #{swept} job director(ies) past their retention")

    # Ticket volumes go the same way and for the same reason. Nothing here is told that a
    # ticket merged, so age is what there is.
    Workspace.sweep(root, ticket_volume_retention_ms())

    terminal
  end

  # A job the platform stopped hibernates and resumes from the branch and the manifest. For a
  # state that declares `changeset` that branch holds what it did, because it committed; for a
  # state that declares none the head is the one the run started from and its tree is gone, which
  # is what such a state promised (`docs/design/git-hosting.md` § Non-fast-forward on a ticket
  # branch) and what its continuation prompt tells it. A job the wall clock stopped is over, and
  # reports a result like any other ending — the difference is whether anyone intends to
  # continue it.
  defp terminal(%Result{killed: :operator} = result, head),
    do:
      {"hibernated",
       %{"commit" => head, "reason" => "cancelled", "result" => Result.to_map(result)}}

  # A parked run that declares `changeset` pushed before it said so, and the commands it asked for
  # run at that push. One that declares none pushed nothing, so they run at the head it started
  # from — both halves of `docs/design/commands.md` § The ensured commit, and the prompt says
  # which one the agent is getting (`ForgeCore.Prompt.may_invoke/2`).
  defp terminal(%Result{status: :parked} = result, head),
    do: {"result", Result.to_map(%{result | commit: head})}

  defp terminal(%Result{} = result, _head), do: {"result", Result.to_map(result)}

  defp job_dir(root, job_id), do: Path.join([root, "jobs", job_id])

  defp start_command(assignment, spec, root, worktree) do
    slice = assignment["slice"] || %{}

    Command.start_link(
      spec: spec,
      root: Path.join(root, "jobs"),
      worktree: worktree,
      slice_opts: %{memory_max: slice["memory_max"], cpu_weight: slice["cpu_weight"]},
      secrets: Secrets.from_assignment(assignment),
      nix_env: Application.get_env(:forge_worker, :nix_env, true)
    )
  end

  # A command whose log will not upload has still run: its status is the result, and a missing
  # log is a line here rather than a failed job the platform would run again.
  defp upload_log(result, assignment, job_dir) do
    store = assignment["store"] || %{}
    path = Command.log_path(job_dir)

    cond do
      is_nil(Config.platform_url()) or is_nil(store["log_key"]) ->
        Log.line(
          "upload.failed",
          :warning,
          "nowhere to put the command's log: no platform url or no key",
          job_id: assignment["job_id"]
        )

        result

      not File.exists?(path) ->
        result

      true ->
        case Store.put(Config.platform_url(), store["log_key"], store["log_token"], path) do
          {:ok, _info} ->
            %{result | log: store["log_key"]}

          {:error, reason} ->
            Log.line(
              "upload.failed",
              :warning,
              "could not upload the command's log: #{inspect(reason)}",
              job_id: assignment["job_id"]
            )

            result
        end
    end
  end

  # A parked job's resume is handed the logs of what it invoked, each by a key and a `get` token
  # (`docs/design/job-prompt.md` § Commands). Fetched before the run starts, into a staging
  # folder `Dir.prepare/3` copies from. A log that will not download is left out rather than
  # failing the resume: the results in the manifest still say what happened.
  defp fetch_command_logs(%{"commands" => [_ | _] = logs, "job_id" => job_id}, root) do
    job_dir = job_dir(root, job_id)
    Dir.worker_dir!(job_dir)
    staging = Dir.fetched_dir(job_dir)
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    fetched =
      Enum.flat_map(logs, fn %{"file" => file, "key" => key, "token" => token} ->
        path = Path.join(staging, Integer.to_string(:erlang.unique_integer([:positive])))

        case Store.fetch(Config.platform_url(), key, token, path) do
          :ok ->
            [{file, path}]

          {:error, reason} ->
            Log.line(
              "commands.unwritten",
              :warning,
              "could not fetch the command's log #{file}, so it is left out: #{inspect(reason)}",
              job_id: job_id
            )

            []
        end
      end)

    {:ok, fetched}
  end

  defp fetch_command_logs(_assignment, _root), do: {:ok, []}

  defp start_runner(link, assignment, root, worktree, logs, user) do
    job_id = assignment["job_id"]
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])

    harness_opts =
      Application.get_env(:forge_worker, :harness_opts, [])
      |> Keyword.merge(resume_opts(assignment))
      |> put_model(spec)

    # Before the credential goes in: the check asks the harness its version, and that needs none.
    {harness_opts, session} =
      Session.restore(assignment, job_dir(root, job_id), worktree, harness_opts, harness())

    harness_opts = Credential.put(harness_opts, assignment, harness().driver())
    secrets = Secrets.from_assignment(assignment)

    slice = assignment["slice"] || %{}

    Runner.start_link(
      harness: harness(),
      spec: spec,
      root: Path.join(root, "jobs"),
      worktree: worktree,
      slice_opts: %{
        memory_max: slice["memory_max"],
        cpu_weight: slice["cpu_weight"]
      },
      sink: fn event -> send(link, {:event, job_id, Secrets.mask_event(secrets, event)}) end,
      harness_opts: harness_opts,
      secrets: secrets,
      backlog: assignment["backlog"],
      command_logs: logs,
      session: session,
      # Named in the continuation a resumed run is handed, read from the tree it is about to run
      # in rather than taken from the platform: what the agent will find is what it is told
      # (`docs/design/job-prompt.md` § The continuation prompt).
      head: head(worktree, user),
      wall_clock_ms: assignment["wall_clock_ms"] || :timer.hours(1),
      nix_env: Application.get_env(:forge_worker, :nix_env, true),
      extra_env: Application.get_env(:forge_worker, :extra_env, []) ++ git_env(assignment)
    )
  end

  # The agent works in a real clone and may fetch and push on its own, so it gets the same URL
  # and credential the worker uses. Marked secret, which is what keeps it out of argv, out of the
  # runner's state and out of the unit's properties: it reaches the process through the file the
  # process loads itself (`ForgeWorker.Job.Exec`).
  defp git_env(%{"git" => %{"url" => url, "token" => token}}) when is_binary(token),
    do: [{"FORGE_GIT_URL", url}, {"FORGE_GIT_TOKEN", {:secret, token}}]

  defp git_env(_assignment), do: []

  # Equivalent mutant in the second clause: a worktree `Workspace.prepare/3` returned was cloned
  # or reset onto a branch, so it always has a HEAD and nil is never what reaches the prompt.
  # Kept because a job must not fail over one sentence of its prompt.
  defp head(worktree, user) do
    case Workspace.head(worktree, user) do
      {:ok, sha} -> sha
      {:error, _reason} -> nil
    end
  end

  # A fork is a new attempt resuming its predecessor's session under an id of its own
  # (`docs/design/claude-code-events.md` § Resume).
  @doc false
  def resume_opts(%{"resume_session" => session} = assignment) when is_binary(session),
    do: [resume_session: session, fork_session: assignment["fork_session"] == true]

  def resume_opts(_assignment), do: []

  # The spec's model wins over the machine's, and a spec that names none leaves the machine's
  # alone. The platform resolved it — a state's, then the project's — because it knows the state
  # and the project and this machine knows neither; `FORGE_CLAUDE_MODEL` is what is left when
  # nobody upstream had an opinion.
  @spec put_model(keyword(), ForgeCore.Job.Spec.t()) :: keyword()
  defp put_model(opts, %ForgeCore.Job.Spec{model: model}) when is_binary(model),
    do: Keyword.put(opts, :model, model)

  defp put_model(opts, _spec), do: opts

  # Long enough that a job an operator is still thinking about survives, short enough that a
  # machine running for months does not keep every run it ever made. A week.
  defp job_retention_ms,
    do: Application.get_env(:forge_worker, :job_retention_ms, 7 * 24 * 60 * 60 * 1000)

  # Shorter than a job directory's, because a ticket volume is a warm build directory rather than
  # a few files: two days covers a ticket blocked on a question overnight and does not keep one
  # per ticket this machine ever touched.
  defp ticket_volume_retention_ms,
    do: Application.get_env(:forge_worker, :ticket_volume_retention_ms, 2 * 24 * 60 * 60 * 1000)

  defp commit_message(assignment) do
    spec = assignment["spec"]
    "#{spec["state"]}: attempt #{spec["attempt"]}\n\nJob #{assignment["job_id"]}.\n"
  end

  # The run's harness session, uploaded after the user has gone, so the file is read as root with
  # nothing left to swap a path (`ForgeWorker.Job.Dir.stage_session/4`). Reported inside the
  # harness summary, beside the session id and the version that wrote it, which is what the
  # platform records it with.
  defp upload_session(%Result{harness: harness} = result, assignment, job_dir) do
    case Session.upload(job_dir, harness["session_id"], assignment, 1) do
      nil -> result
      key -> %{result | harness: Map.put(harness, "session_blob", key)}
    end
  end

  # The transcript goes to the store under the key the platform minted a token for, and the
  # result carries the key rather than the bytes. A transcript that will not upload is not
  # worth failing a job over.
  defp upload_transcript(%Result{transcript_path: nil} = result, _assignment), do: result

  defp upload_transcript(%Result{} = result, assignment) do
    store = assignment["store"] || %{}

    if is_nil(Config.platform_url()) or is_nil(store["transcript_key"]) do
      Log.line(
        "upload.failed",
        :warning,
        "nowhere to put the transcript: no platform url or no key",
        job_id: assignment["job_id"]
      )

      result
    else
      put_transcript(result, store, assignment["job_id"])
    end
  end

  defp put_transcript(result, store, job_id) do
    case Store.put(
           Config.platform_url(),
           store["transcript_key"],
           store["transcript_token"],
           result.transcript_path
         ) do
      {:ok, _info} ->
        %{result | transcript: store["transcript_key"]}

      {:error, reason} ->
        Log.line("upload.failed", :warning, "could not upload the transcript: #{inspect(reason)}",
          job_id: job_id
        )

        result
    end
  end

  # -- bookkeeping --------------------------------------------------------------------------

  # The application version says almost nothing here — every dev-phase release is 0.1.0 — so the
  # build is named by the store path's hash, which is what actually changes when `bin/worker-update`
  # ships one. On anything that is not a Nix store path this degrades to the version alone.
  # What this machine can run, asked of the harness at join rather than declared by the platform
  # (`docs/design/worker-channel.md` § What a worker offers). It is asked here and not at boot so
  # that a rotated credential or a replaced binary is picked up on the next connection, and it
  # never prevents `ready`: a machine that cannot describe itself can still take work.
  #
  # **`"credential": "per_job"` is this release saying it takes a job's credential from the
  # assignment**, and it is said by the link rather than by the harness because it is this code
  # that does it (`ForgeWorker.Job.Credential`). The platform gives no agent job to a machine that
  # does not say it: an older release would run the job on whatever its own environment held
  # (`docs/design/credentials.md` § What a worker offers now). The driver's name is said even when
  # the probe raises, which is why it is a callback of its own: a machine whose harness cannot
  # describe itself can still run it.
  defp harness_offer do
    harness = harness()
    opts = Application.get_env(:forge_worker, :harness_opts, [])

    offer = harness.probe(opts)
    Logger.info("harness #{offer.name} #{offer.version || "?"}")

    offer
    |> Map.merge(%{capabilities: harness.capabilities(), credential: "per_job"})
    |> Map.new(fn {key, value} -> {Atom.to_string(key), encode_offer(value)} end)
  rescue
    error ->
      Log.line("harness.unprobed", :warning, "could not probe the harness: #{inspect(error)}")
      %{"driver" => harness().driver(), "credential" => "per_job"}
  end

  @doc "The harness this machine runs jobs with: `ForgeWorker.Harness.ClaudeCode` unless configured."
  @spec harness() :: module()
  def harness, do: Application.get_env(:forge_worker, :harness, ForgeWorker.Harness.ClaudeCode)

  defp encode_offer(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp encode_offer(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), encode_offer(value)} end)

  defp encode_offer(list) when is_list(list), do: Enum.map(list, &encode_offer/1)
  defp encode_offer(value), do: value

  defp version do
    vsn =
      case :application.get_key(:forge_worker, :vsn) do
        {:ok, value} -> to_string(value)
        :undefined -> "unknown"
      end

    case build() do
      nil -> vsn
      hash -> "#{vsn} (#{hash})"
    end
  end

  @doc """
  The build this release is, as the first twelve characters of its Nix store path's hash, or nil
  for a release that is not in the store — a development machine, or anything built without Nix.

  Twelve because that is what `nix build .#forge-worker` shows an operator, what `flake.nix`
  labels a snapshot with and builds the platform knowing (`docs/design/worker-tier.md`
  § Updating a worker), and what the join line has always logged.

  Only a `forge-worker` store path counts. Run from `mix`, the root is the Erlang the devshell
  put on the path — also in the store — and its hash names that Erlang, not this worker.
  """
  @spec build(charlist() | String.t()) :: String.t() | nil
  def build(root_dir \\ :code.root_dir()) do
    case Regex.run(~r"^/nix/store/([a-z0-9]{32})-forge-worker-", to_string(root_dir)) do
      [_all, hash] -> binary_part(hash, 0, 12)
      nil -> nil
    end
  end

  # What is speaking, in the join and not in `ready`, because the platform decides at the join
  # whether it will talk to this machine at all (`docs/design/worker-channel.md` § Versions).
  # `build` is left out rather than sent as null, like `cores`: absent is *unknown*.
  defp join_payload(socket) do
    %{
      "running" => running_list(socket),
      "memory_total" => Config.memory_budget(),
      "seeds" => Seed.present(socket.assigns.root),
      "root" => socket.assigns.root,
      "protocol" => WorkerProtocol.current(),
      "release" => version()
    }
    |> put_unless_nil("build", build())
    # For as long as it believes it: a join without it is what clears the platform's mark
    # (`docs/design/worker-channel.md` § An unhealthy machine).
    |> put_unless_nil("unhealthy", Health.unhealthy())
  end

  defp running_list(socket) do
    Enum.map(socket.assigns.jobs, fn {job_id, job} ->
      %{"job_id" => job_id, "attempt" => job.attempt}
    end)
  end

  defp send_terminal(socket, job_id, message, payload),
    do: send_acked(socket, {job_id, message}, message, payload)

  # The key is the caller's, because a job sends exactly one terminal message and a conversation
  # sends a `turn` per turn. Keyed by `{job_id, message}` alone, two unacked turns for one chat
  # would collide and one would be dropped for ever — taking its cost with it, which is the one
  # thing the daily cap is computed from.
  defp send_acked(socket, key, message, payload) do
    case push(socket, socket.assigns.topic, message, payload) do
      {:ok, ref} ->
        socket
        |> put_in([Access.key!(:assigns), Access.key!(:unacked), key], {message, payload})
        |> put_in([Access.key!(:assigns), Access.key!(:acks), ref], key)

      # Not connected: the message waits for the next join, which re-sends everything unacked.
      {:error, _reason} ->
        put_in(socket.assigns.unacked[key], {message, payload})
    end
  end

  defp resend_unacked(socket) do
    Enum.reduce(socket.assigns.unacked, socket, fn {key, {message, payload}}, socket ->
      send_acked(socket, key, message, payload)
    end)
  end

  defp forget(socket, ref, key) do
    socket
    |> update_in([Access.key!(:assigns), Access.key!(:unacked)], &Map.delete(&1, key))
    |> update_in([Access.key!(:assigns), Access.key!(:acks)], &Map.delete(&1, ref))
  end

  # -- the machine's log --------------------------------------------------------------------

  # **Pushed if joined, held if not**, and never acked: nothing is decided from this log, and a
  # line pushed into a connection that is dropping is lost like an event
  # (`docs/design/worker-log.md` § The `log` message).
  defp send_line(socket, entry) do
    case push(socket, socket.assigns.topic, "log", entry) do
      {:ok, _ref} -> socket
      {:error, _not_joined} -> assign(socket, :log, Log.hold(socket.assigns.log, entry))
    end
  end

  # At the join, after `ready`: what finished while the platform was away is in the log at the
  # time the machine says it finished.
  defp send_held(socket) do
    socket.assigns.log
    |> Log.drain()
    |> Enum.reduce(assign(socket, :log, Log.empty()), &send_line(&2, &1))
  end

  defp accepted(%{"kind" => "chat"}), do: "took on a chat"

  defp accepted(%{"kind" => "command"} = assignment),
    do: "took on a command: #{get_in(assignment, ["spec", "command", "name"])}"

  # Anything that is neither is a workflow job: those are the three kinds there are.
  defp accepted(assignment),
    do: "took on a workflow job, attempt #{assignment["spec"]["attempt"]}"

  # How the job ended, as the line says it. A failure's reason may be a whole stack trace; its
  # first line is what names it, and the journal has the rest.
  defp finished("result", %{"result" => result}),
    do: {:info, "ended with a result: #{result["status"]}, #{result["outcome"] || "no outcome"}"}

  defp finished("hibernated", payload), do: {:info, "hibernated: #{payload["reason"]}"}

  defp finished("failed", payload),
    do: {:error, "failed: #{payload["reason"] |> to_string() |> String.split("\n") |> hd()}"}

  # **Unreachable today, and an equivalent mutant to remove**: every terminal message is one of the
  # three above. It is here because this runs in the process holding every unacked result, and a
  # fourth kind of ending added elsewhere must cost a vague line, not the link.
  defp finished(message, _payload), do: {:info, message}

  # A chat that could not even start was never in the map, so there is no start to measure from.
  defp ran(%{started: started}),
    do: ", after #{Log.ran(System.monotonic_time(:millisecond) - started)}"

  defp ran(nil), do: ""

  defp update_job(socket, job_id, fun) do
    case socket.assigns.jobs[job_id] do
      nil -> socket
      job -> put_in(socket.assigns.jobs[job_id], fun.(job))
    end
  end
end
