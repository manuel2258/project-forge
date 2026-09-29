defmodule ForgeWeb.WorkerChannel do
  @moduledoc """
  One channel per worker, `worker:<id>`. Everything the platform says to a machine goes out
  through here, and everything a machine says arrives here. The protocol is
  `docs/design/worker-channel.md`; this module is its only implementation.

  Events are best-effort, terminal messages are acked after the transaction that records them
  commits, and a rejoin reconciles what the worker is running against what the platform
  believes. The reconciliation is the whole reason the join payload carries `running`.
  """

  use Phoenix.Channel

  alias Forge.{Conversations, Jobs, Workers}
  alias Forge.Workers.Log
  alias ForgeCore.Job.{Event, Result}
  alias ForgeCore.WorkerProtocol

  require Logger

  # **Whether the platform will talk to this machine is decided here, before anything else**:
  # its own topic; no channel of it already open — asked before anything is written, so a second
  # join, which is what a copy of a live machine's token makes, cannot touch the row, destroy the
  # machine or teach its template anything; a row that is not destroyed and a protocol this
  # platform accepts (`docs/design/worker-channel.md` § Versions). Only then is the channel
  # registered, so a refused machine is never reachable by `Workers.push/2` and never assigned
  # anything — an order no test can see, since a refused channel exits either way, and so a
  # window of milliseconds rather than a test.
  @impl true
  def join("worker:" <> worker_id, payload, socket) do
    with :ok <- mine(worker_id, socket),
         :ok <- alone(worker_id),
         :ok <- admit(worker_id, payload),
         :ok <- register(worker_id) do
      send(self(), {:after_join, payload})
      {:ok, socket}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  defp mine(worker_id, socket) do
    if worker_id == socket.assigns.worker_id,
      do: :ok,
      else: {:error, %{reason: "not_your_worker"}}
  end

  defp admit(worker_id, payload) do
    case Workers.admit(worker_id, if(is_map(payload), do: payload, else: %{})) do
      :ok ->
        :ok

      {:error, {:protocol, protocol}} ->
        {:error,
         %{
           reason: "protocol",
           protocol: protocol,
           minimum: WorkerProtocol.minimum(),
           current: WorkerProtocol.current()
         }}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  defp alone(worker_id) do
    if Workers.connected?(worker_id),
      do: {:error, %{reason: "already_connected"}},
      else: :ok
  end

  defp register(worker_id) do
    case Workers.connected(worker_id) do
      :ok -> :ok
      {:error, _reason} -> {:error, %{reason: "already_connected"}}
    end
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    case Workers.get!(socket.assigns.worker_id) do
      # Retired between the join's check and the registration, when a `:retired` had no channel
      # to reach: the row is read again here, after the channel is reachable, and the channel
      # closes itself.
      %{status: :destroyed} ->
        {:stop, {:shutdown, :retired}, socket}

      worker ->
        {:ok, _worker} = Workers.touch(worker)
        Log.record(worker.id, "joined", :info, joined(worker))
        reconcile(worker.id, payload["running"] || [])
        {:noreply, assign(socket, :joined, true)}
    end
  end

  # The platform's side of `Workers.push/2`. Nothing else in the platform knows how to reach
  # a machine, so nothing else can forget the worker might not be there.
  def handle_info({:assign, assignment}, socket) do
    push(socket, "assign", assignment)
    {:noreply, socket}
  end

  def handle_info({:cancel, job_id, reason}, socket) do
    push(socket, "cancel", %{"job_id" => job_id, "reason" => to_string(reason)})
    {:noreply, socket}
  end

  # A conversation is spoken to while it runs. `Forge.Conversations` sends these; the channel
  # only carries them, as it carries an assignment.
  def handle_info({message, %{"job_id" => _id} = payload}, socket)
      when message in ["message", "interrupt", "close"] do
    push(socket, message, payload)
    {:noreply, socket}
  end

  # The row was destroyed — retired from the workers page or the command line, lost, or refused —
  # and a connection outlives its row. The jobs still running there are cancelled first: a
  # retired permanent machine goes on running, and a requeued job would otherwise run on it and
  # again elsewhere. Then the channel closes, so the machine's next join meets the row as it now
  # is (`docs/design/worker-channel.md` § Authentication).
  def handle_info({:retired, jobs}, socket) do
    for job_id <- jobs, do: push(socket, "cancel", %{"job_id" => job_id, "reason" => "retired"})
    {:stop, {:shutdown, :retired}, socket}
  end

  @impl true
  def handle_in("ready", payload, socket) do
    worker = Workers.get!(socket.assigns.worker_id)
    {:ok, _worker} = Workers.ready(worker, payload)
    {:reply, :ok, socket}
  end

  def handle_in("heartbeat", _payload, socket) do
    {:ok, _worker} = socket.assigns.worker_id |> Workers.get!() |> Workers.touch()
    {:reply, :ok, socket}
  end

  # How full the machine is, for the workers page, kept as this channel's registry value and
  # written nowhere else — **not a heartbeat**, so it does not touch the row, and unacked like an
  # event because the next one is seconds away (`docs/design/worker-channel.md` § Live figures).
  def handle_in("stats", payload, socket) do
    if is_map(payload), do: Workers.put_stats(socket.assigns.worker_id, payload)
    {:noreply, socket}
  end

  # A line the machine wrote about itself (`docs/design/worker-log.md`), unacked like `stats` and
  # bounded field by field by `Log.accept/2`. The socket, not the payload, says whose it is.
  def handle_in("log", payload, socket) do
    if is_map(payload), do: Log.accept(socket.assigns.worker_id, payload)
    {:noreply, socket}
  end

  # Best-effort, and unacked: a lost event costs a line in the timeline, never a decision.
  # The platform records the gap rather than pretending there was none.
  def handle_in("event", %{"job_id" => job_id} = payload, socket) do
    with :ok <- owns(socket, job_id),
         {:ok, event} <- Event.from_map(payload["event"] || %{}) do
      Jobs.record_harness_event(job_id, event)
    else
      {:error, :not_your_job} -> :ok
      :error -> Logger.warning("worker sent an event with no type for job #{job_id}")
    end

    {:noreply, socket}
  end

  def handle_in("result", %{"job_id" => job_id, "result" => result}, socket) do
    ack(with(:ok <- owns(socket, job_id), do: record(job_id, Result.from_map(result))), socket)
  end

  # Acked after the transaction commits, like a result, because it carries the turn's cost and
  # the cost is what the daily cap is computed from. Idempotent on `(job_id, session, turn)`
  # (`Conversations.record_turn/2`): the worker re-sends until it is acked, so the platform has to
  # be able to hear the same turn twice.
  def handle_in("turn", %{"job_id" => job_id} = payload, socket) do
    ack(with(:ok <- owns(socket, job_id), do: record_turn(job_id, payload)), socket)
  end

  def handle_in("hibernated", %{"job_id" => job_id} = payload, socket) do
    ack(with(:ok <- owns(socket, job_id), do: hibernate(job_id, payload)), socket)
  end

  def handle_in("failed", %{"job_id" => job_id} = payload, socket) do
    ack(
      with(:ok <- owns(socket, job_id), do: Jobs.fail(job_id, {:worker, payload["reason"]})),
      socket
    )
  end

  def handle_in(message, _payload, socket) do
    Logger.warning("worker #{socket.assigns.worker_id} sent unknown message #{inspect(message)}")
    {:reply, {:error, %{reason: "unknown_message"}}, socket}
  end

  @impl true
  def terminate(reason, socket) do
    # The row stays; only the connection went. What happens to its jobs is the timeout's
    # decision, not the socket's: a worker that reconnects in two seconds has lost nothing.
    Logger.info("worker #{socket.assigns.worker_id} disconnected")

    # **Only a channel that joined says it left.** A refused join ends here too, and its refusal
    # is the line; a `disconnected` after it would be a connection that never was.
    if socket.assigns[:joined] do
      {level, why} = parting(reason)
      Log.record(socket.assigns.worker_id, "disconnected", level, why)
    end
  end

  defp joined(worker) do
    "release #{worker.release || "unknown"}, build #{worker.build || "unknown"}, protocol " <>
      "#{worker.protocol}"
  end

  # **A shutdown is how a channel ends, and not news**: any `{:shutdown, _}`, which is what Phoenix
  # hands a channel when its transport goes — `:peer_closed` and `:local_closed` from the socket
  # server, `:draining` from a restart — and not only the reasons `Phoenix.ChannelTest` makes.
  # Anything else is a crash, and says only what kind: the stack trace is the platform's and this
  # page is the machine owner's, so the journal keeps it.
  defp parting(:shutdown), do: {:info, "the platform shut down"}
  defp parting({:shutdown, why}), do: {:info, shutdown(why)}
  defp parting({reason, stack}) when is_list(stack), do: {:warning, "crashed: #{kind(reason)}"}
  defp parting(reason), do: {:warning, "ended: #{kind(reason)}"}

  defp shutdown(:peer_closed), do: "the machine closed the connection"
  defp shutdown(:local_closed), do: "the platform closed the connection"
  defp shutdown(:closed), do: "the connection closed"
  defp shutdown(:left), do: "left the channel"
  defp shutdown(:retired), do: "closed by the platform: the row was retired"
  defp shutdown(:draining), do: "the platform is restarting"
  defp shutdown(why), do: "shut down: #{kind(why)}"

  defp kind(%{__exception__: true} = exception), do: inspect(exception.__struct__)
  defp kind(reason) when is_atom(reason), do: inspect(reason)

  defp kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: inspect(elem(reason, 0))

  defp kind(_reason), do: "an error"

  # A second `result` for a job already recorded is acked and dropped. The worker retries
  # until it is acked, so the platform has to be able to hear the same thing twice.
  defp record(job_id, result) do
    case Jobs.complete(job_id, result) do
      {:ok, _job} -> :ok
      {:error, :already_recorded} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_turn(job_id, payload) do
    case Jobs.get!(job_id) do
      %{kind: :chat} = chat -> Conversations.record_turn(chat, payload)
      %{} -> {:error, :not_a_conversation}
    end
  end

  # A conversation ending is not a job hibernating: a job resumes from its branch and its
  # manifest, a conversation waits for a person. They arrive on the same message because from
  # the worker's side both are "it stopped without a result".
  defp hibernate(job_id, payload) do
    case Jobs.get!(job_id) do
      %{kind: :chat} = chat ->
        Conversations.ended(chat, payload["commit"], payload["reason"], result: payload["result"])

      %{} ->
        Jobs.hibernate(job_id, payload["commit"], payload["reason"], payload["result"])
    end
  end

  # The socket says which worker this is; nothing said the job was that worker's. Every write
  # above addresses a job by an id off the wire, so each one asks. Without this a single worker
  # token finishes, fails, hibernates or writes artifacts into *any* job on the node, and forges
  # events into any project's timeline — which is exactly the blast radius
  # `docs/design/worker-channel.md` § Topic promises a leaked token does not have.
  defp owns(socket, job_id) do
    mine = socket.assigns.worker_id

    case Jobs.get(job_id) do
      %{worker_id: ^mine} ->
        :ok

      _not_ours ->
        Logger.warning("worker #{mine} addressed job #{inspect(job_id)}, which is not its own")
        {:error, :not_your_job}
    end
  end

  defp ack(:ok, socket), do: {:reply, :ok, socket}
  defp ack({:ok, _anything}, socket), do: {:reply, :ok, socket}

  defp ack({:error, reason}, socket) do
    Logger.error("worker #{socket.assigns.worker_id} message failed: #{inspect(reason)}")
    {:reply, {:error, %{reason: "not_recorded"}}, socket}
  end

  # Platform says running, worker does not have it: the run is gone — the machine rebooted,
  # the release restarted, the slice was killed — so the job is re-queued and scheduled
  # afresh. The other direction is a job the platform has already finished with, which the
  # worker is told to stop.
  defp reconcile(worker_id, running) do
    theirs = MapSet.new(running, fn job -> job["job_id"] end)
    ours = MapSet.new(Jobs.running_on(worker_id), & &1.id)

    Enum.each(MapSet.difference(ours, theirs), fn job_id ->
      Logger.warning("worker #{worker_id} rejoined without job #{job_id}; re-queueing it")
      Jobs.requeue(job_id, :worker_lost_job)

      Log.record(
        worker_id,
        "job.lost",
        :warning,
        "rejoined without a job the platform had running here; requeued it",
        job_id: job_id
      )
    end)

    Enum.each(MapSet.difference(theirs, ours), fn job_id ->
      Workers.push(worker_id, {:cancel, job_id, :not_ours})
    end)
  end
end
