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
  alias ForgeWorker.{Config, Store}
  alias ForgeWorker.Job.{Dir, Runner, Seed, Workspace}

  require Logger

  @heartbeat_ms :timer.seconds(20)

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

    socket =
      new_socket()
      |> assign(:jobs, %{})
      |> assign(:unacked, %{})
      |> assign(:acks, %{})
      |> assign(:draining, false)
      |> assign(:root, Keyword.get(opts, :root, Config.root()))
      |> assign(:topic, "worker:" <> worker_id)

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
      "joined #{topic} running #{version()}; ready with #{Config.memory_budget()} bytes"
    )

    push(socket, socket.assigns.topic, "ready", %{
      "memory_budget" => Config.memory_budget(),
      "seeds" => Seed.present(socket.assigns.root),
      "root" => socket.assigns.root
    })

    :timer.send_interval(@heartbeat_ms, self(), :heartbeat)
    {:ok, resend_unacked(socket)}
  end

  @impl Slipstream
  def handle_message(_topic, "assign", assignment, socket) do
    cond do
      socket.assigns.draining ->
        Logger.info("refusing an assignment while draining")
        {:ok, socket}

      Map.has_key?(socket.assigns.jobs, assignment["job_id"]) ->
        Logger.info("already running job #{assignment["job_id"]}")
        {:ok, socket}

      true ->
        {:ok, start_job(socket, assignment)}
    end
  end

  def handle_message(_topic, "cancel", %{"job_id" => job_id}, socket) do
    case socket.assigns.jobs[job_id] do
      %{runner: runner} when is_pid(runner) -> Runner.cancel(runner)
      _other -> Logger.info("asked to cancel #{job_id}, which is not running here")
    end

    {:ok, socket}
  end

  def handle_message(_topic, "drain", _payload, socket) do
    Logger.info("draining: no new work")
    {:ok, assign(socket, :draining, true)}
  end

  def handle_message(topic, event, _payload, socket) do
    Logger.warning("unknown message #{inspect(event)} on #{topic}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, _reply, socket) do
    case socket.assigns.acks[ref] do
      nil -> {:ok, socket}
      key -> {:ok, forget(socket, ref, key)}
    end
  end

  # -- what the jobs say --------------------------------------------------------------------

  @impl Slipstream
  def handle_info(:heartbeat, socket) do
    push(socket, socket.assigns.topic, "heartbeat", %{"running" => running_list(socket)})
    {:noreply, socket}
  end

  def handle_info({:runner, job_id, pid}, socket) do
    {:noreply, update_job(socket, job_id, &Map.put(&1, :runner, pid))}
  end

  def handle_info({:event, job_id, event}, socket) do
    push(socket, socket.assigns.topic, "event", %{
      "job_id" => job_id,
      "event" => %{"type" => event.type, "payload" => event.payload}
    })

    {:noreply, socket}
  end

  def handle_info({:terminal, job_id, message, payload}, socket) do
    socket =
      socket
      |> update_in([Access.key!(:assigns), Access.key!(:jobs)], &Map.delete(&1, job_id))
      |> send_terminal(job_id, message, payload)

    {:noreply, socket}
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
  @impl Slipstream
  def handle_disconnect(reason, socket) do
    Logger.warning("disconnected from the platform: #{inspect(reason)}")

    case reconnect(socket) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> {:stop, reason, socket}
    end
  end

  # A channel the platform closed under us — a restart, a redeploy, a worker row it no longer
  # believes in. Rejoining is what makes the reconciliation in handle_join happen, and the
  # default here is to stop, which would lose every unacked result on this worker.
  @impl Slipstream
  def handle_topic_close(topic, reason, socket) do
    Logger.warning("channel #{topic} closed: #{inspect(reason)}")

    case rejoin(socket, topic, join_payload(socket)) do
      {:ok, socket} -> {:ok, socket}
      {:error, _reason} -> {:ok, socket}
    end
  end

  # -- running one job ----------------------------------------------------------------------

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
      attempt: assignment["spec"]["attempt"]
    })
  end

  @doc false
  # Runs one job to its end and tells the link what happened. Anything that goes wrong here is
  # a failed job, reported as one: a task that dies quietly would leave the platform holding a
  # job it believes is running until the next rejoin.
  def run(link, assignment, root) do
    job_id = assignment["job_id"]

    case prepare_and_run(link, assignment, root) do
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

  defp prepare_and_run(link, assignment, root) do
    job_id = assignment["job_id"]

    with {:ok, worktree} <- Workspace.prepare(assignment, root),
         {:ok, runner} <- start_runner(link, assignment, root, worktree) do
      send(link, {:runner, job_id, runner})
      {:ok, result} = Runner.await(runner)

      # The work goes to the branch before anything is reported: the platform records the
      # branch head as the changeset artifact the moment it hears from us, and a job that is
      # stopping must not lose what it did (`docs/decisions.md`).
      {:ok, head} = Workspace.commit_and_push(assignment, worktree, commit_message(assignment))
      terminal = {:ok, result |> upload_transcript(assignment) |> terminal(head)}

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

      terminal
    end
  end

  # A job the platform stopped hibernates: it has committed, and it resumes from the branch
  # and the manifest. A job the wall clock stopped is over, and reports a result like any
  # other ending — the difference is whether anyone intends to continue it.
  defp terminal(%Result{killed: :operator} = result, head),
    do:
      {"hibernated",
       %{"commit" => head, "reason" => "cancelled", "result" => Result.to_map(result)}}

  defp terminal(%Result{} = result, _head), do: {"result", Result.to_map(result)}

  defp start_runner(link, assignment, root, worktree) do
    job_id = assignment["job_id"]
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])

    harness_opts =
      Application.get_env(:forge_worker, :harness_opts, [])
      |> Keyword.merge(resume_opts(assignment))

    slice = assignment["slice"] || %{}

    Runner.start_link(
      spec: spec,
      root: Path.join(root, "jobs"),
      worktree: worktree,
      slice_opts: %{
        memory_max: slice["memory_max"],
        cpu_weight: slice["cpu_weight"]
      },
      sink: fn event -> send(link, {:event, job_id, event}) end,
      harness_opts: harness_opts,
      wall_clock_ms: assignment["wall_clock_ms"] || :timer.hours(1),
      nix_env: Application.get_env(:forge_worker, :nix_env, true),
      extra_env: Application.get_env(:forge_worker, :extra_env, []) ++ git_env(assignment)
    )
  end

  # The agent works in a real clone and may fetch and push on its own, so it gets the same URL
  # and credential the worker uses. Marked secret, which is what keeps it out of argv and out of
  # the runner's state — and out of the slice's `--setenv`, which names a secret without its
  # value (`docs/design/worker-tier.md` § The job slice).
  defp git_env(%{"git" => %{"url" => url, "token" => token}}) when is_binary(token),
    do: [{"FORGE_GIT_URL", url}, {"FORGE_GIT_TOKEN", {:secret, token}}]

  defp git_env(_assignment), do: []

  defp resume_opts(%{"resume_session" => session}) when is_binary(session),
    do: [resume_session: session]

  defp resume_opts(_assignment), do: []

  # Long enough that a job an operator is still thinking about survives, short enough that a
  # machine running for months does not keep every run it ever made. A week.
  defp job_retention_ms,
    do: Application.get_env(:forge_worker, :job_retention_ms, 7 * 24 * 60 * 60 * 1000)

  defp commit_message(assignment) do
    spec = assignment["spec"]
    "#{spec["state"]}: attempt #{spec["attempt"]}\n\nJob #{assignment["job_id"]}.\n"
  end

  # The transcript goes to the store under the key the platform minted a token for, and the
  # result carries the key rather than the bytes. A transcript that will not upload is not
  # worth failing a job over.
  defp upload_transcript(%Result{transcript_path: nil} = result, _assignment), do: result

  defp upload_transcript(%Result{} = result, assignment) do
    store = assignment["store"] || %{}

    if is_nil(Config.platform_url()) or is_nil(store["transcript_key"]) do
      Logger.warning("nowhere to put the transcript: no platform url or no key")
      result
    else
      put_transcript(result, store)
    end
  end

  defp put_transcript(result, store) do
    case Store.put(
           Config.platform_url(),
           store["transcript_key"],
           store["transcript_token"],
           result.transcript_path
         ) do
      {:ok, _info} ->
        %{result | transcript: store["transcript_key"]}

      {:error, reason} ->
        Logger.warning("could not upload the transcript: #{inspect(reason)}")
        result
    end
  end

  # -- bookkeeping --------------------------------------------------------------------------

  # The application version says almost nothing here — every dev-phase release is 0.1.0 — so the
  # build is named by the store path's hash, which is what actually changes when `bin/worker-update`
  # ships one. On anything that is not a Nix store path this degrades to the version alone.
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

  defp build do
    path = List.to_string(:code.root_dir())

    case Regex.run(~r"^/nix/store/([a-z0-9]{32})-", path) do
      [_all, hash] -> binary_part(hash, 0, 12)
      nil -> nil
    end
  end

  defp join_payload(socket) do
    %{
      "running" => running_list(socket),
      "memory_total" => Config.memory_budget(),
      "seeds" => Seed.present(socket.assigns.root),
      "root" => socket.assigns.root
    }
  end

  defp running_list(socket) do
    Enum.map(socket.assigns.jobs, fn {job_id, job} ->
      %{"job_id" => job_id, "attempt" => job.attempt}
    end)
  end

  defp send_terminal(socket, job_id, message, payload) do
    key = {job_id, message}

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
    Enum.reduce(socket.assigns.unacked, socket, fn {{job_id, _message}, {message, payload}},
                                                   socket ->
      send_terminal(socket, job_id, message, payload)
    end)
  end

  defp forget(socket, ref, key) do
    socket
    |> update_in([Access.key!(:assigns), Access.key!(:unacked)], &Map.delete(&1, key))
    |> update_in([Access.key!(:assigns), Access.key!(:acks)], &Map.delete(&1, ref))
  end

  defp update_job(socket, job_id, fun) do
    case socket.assigns.jobs[job_id] do
      nil -> socket
      job -> put_in(socket.assigns.jobs[job_id], fun.(job))
    end
  end
end
