defmodule ForgeWorker.Job.Conversation do
  @moduledoc """
  One running conversation on this worker: the worktree, the long-lived harness process, and a
  commit per turn. `docs/design/conversations.md` is the standard.

  A workflow job runs in a task that blocks on `Runner.await/1` and does everything else once,
  afterwards — prepare, run, commit, report, discard. A conversation cannot be written that way,
  because it has no afterwards until a person says so: it must commit while it is still running,
  and it must take messages in the meantime.

  So this is a process rather than a task, and it is the runner's owner: it hears every turn end,
  commits what the turn wrote, and tells the link. It also holds the git work, which is why it
  exists at all — the link is one process for the whole worker, and a push on the channel process
  is a push that stops every other job's events for as long as it takes.

  It is the first user of `ForgeWorker.Job.Supervisor`, which was declared when the worker was
  written and never started anything.
  """

  use GenServer, restart: :temporary

  alias ForgeCore.Job.Result
  alias ForgeWorker.Config
  alias ForgeWorker.Job.{Dir, Runner, Secrets, Session, Workspace}
  alias ForgeWorker.{Log, Slice, Store}

  require Logger

  # Long enough to think, short enough that a conversation nobody closed does not hold the
  # machine all night. The platform sends its own; this is the fallback.
  @default_idle_ms :timer.minutes(30)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :assignment)))

  @doc "The process running this conversation, if it is on this worker."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(job_id) do
    case Registry.lookup(ForgeWorker.Job.Registry, job_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "Sends a message. `id` is the platform's, and comes back with the delivery."
  @spec send_message(pid(), String.t(), String.t()) :: :ok
  def send_message(pid, id, text), do: GenServer.cast(pid, {:message, id, text})

  @doc "Ends the turn in flight, keeping the process."
  @spec interrupt(pid()) :: :ok
  def interrupt(pid), do: GenServer.cast(pid, :interrupt)

  @doc "Ends the conversation: stdin closes, the last turn finishes, the machine is released."
  @spec close(pid(), String.t()) :: :ok
  def close(pid, reason \\ "closed"), do: GenServer.cast(pid, {:close, reason})

  defp via(assignment), do: {:via, Registry, {ForgeWorker.Job.Registry, assignment["job_id"]}}

  # -- lifecycle ----------------------------------------------------------------------------

  @impl true
  def init(opts) do
    assignment = Keyword.fetch!(opts, :assignment)
    # The runner is linked, and its ending is the conversation's ending rather than a crash.
    Process.flag(:trap_exit, true)
    hold = holds?(assignment)

    {:ok,
     %{
       link: Keyword.fetch!(opts, :link),
       root: Keyword.fetch!(opts, :root),
       assignment: assignment,
       job_id: assignment["job_id"],
       # The job's Unix user, whose tree it is and as whom every turn is committed. Removed once
       # the last git command has run (`docs/design/worker-tier.md` § The job slice).
       user: nil,
       worktree: nil,
       runner: nil,
       turns: 0,
       # The platform's ids for messages written but not yet taken by the harness, oldest
       # first. The harness echoes the text and not the id, so the queue is the correlation:
       # it takes them in the order they were written. The prompt is the first of them, sent
       # by the runner itself — unless it is held, when the first echo is the first message's,
       # the prompt riding with it.
       pending: if(hold, do: [], else: [:prompt]),
       hold: hold,
       # The CLI's version, from its `system/init`: recorded with each session upload, so a
       # reopen restores the file only onto the CLI that wrote it.
       version: nil,
       idle_ms: Keyword.get(opts, :idle_ms) || assignment["idle_ms"] || @default_idle_ms,
       idle_timer: nil,
       closing: nil,
       result: nil
     }, {:continue, :start}}
  end

  # Anything that goes wrong starting up is a conversation that failed, reported as one. A
  # workflow job runs in a task with a catch-all around it for exactly this reason; this is a
  # process, so it needs its own. Without it a preparation that *raises* rather than returning
  # an error — a root that does not exist, a disk that is full — leaves the platform believing
  # the conversation is running, for ever, with a worker's slice held against it.
  @impl true
  def handle_continue(:start, state) do
    # A conversation that names a secret it cannot read does not run without it (`Secrets.check/1`).
    with :ok <- Secrets.check(secrets(state)),
         {:ok, user} <- Slice.enter(state.job_id) do
      prepare(%{state | user: user})
    else
      {:error, :secrets_unopened} -> fail(state, "the conversation's secrets would not open")
      {:error, reason} -> fail(state, "could not make the job's user: #{inspect(reason)}")
    end
  rescue
    error -> fail(state, Exception.format(:error, error, __STACKTRACE__))
  end

  # Sealed, from the assignment, every time: the state keeps nothing it does not already keep.
  defp secrets(state), do: Secrets.from_assignment(state.assignment)

  # Its own rescue, so that what raises here stops a conversation that has a user to remove —
  # `terminate/2` removes it — rather than one the clause above only knows without.
  defp prepare(state) do
    case Workspace.prepare(state.assignment, state.root, state.user) do
      {:ok, worktree} ->
        write_history(state)
        start_runner(%{state | worktree: worktree})

      {:error, reason} ->
        fail(state, "could not prepare the worktree: #{inspect(reason)}")
    end
  rescue
    error -> fail(state, Exception.format(:error, error, __STACKTRACE__))
  end

  defp fail(state, reason) do
    report_failed(state, reason)
    {:stop, :normal, state}
  end

  # Whatever stopped it, the job's user goes. An ending that went through `finish/1` has already
  # removed it and says so by leaving none here.
  @impl true
  def terminate(_reason, %{user: nil}), do: :ok
  def terminate(_reason, state), do: leave(state)

  defp start_runner(state) do
    case Runner.start_link(runner_opts(state)) do
      {:ok, runner} ->
        send(state.link, {:runner, state.job_id, runner})
        {:noreply, reset_idle(%{state | runner: runner})}

      {:error, reason} ->
        fail(state, "could not start the harness: #{inspect(reason)}")
    end
  end

  # What already ran on this ticket, laid out as a folder the agent can read: a metadata document
  # per job and, beside it, that job's transcript fetched from the store.
  #
  # Written before the runner starts, because `Dir.prepare/3` clears `inputs/` and `out/` and
  # nothing else — and because the first message is delivered the moment the harness opens, so a
  # folder written afterwards is a folder that might not be there when it is looked for.
  #
  # A transcript that will not fetch costs a line in a file, not the conversation: it is context,
  # and the conversation is worth having without it.
  # The directory is named after the **spec's** job id, because that is what `Dir.prepare/3`
  # names it after. The assignment carries an id too and in production they are the same value,
  # so writing this beside the assignment's worked — by coincidence. A test whose fixture gave
  # the two different ids found it: the folder was written where the harness would never look.
  defp write_history(%{assignment: assignment, job_id: job_id} = state) do
    case assignment["history"] || [] do
      [] ->
        :ok

      entries ->
        base = Path.join([job_dir(state), "history"])
        File.mkdir_p!(base)
        Enum.each(entries, &write_entry(base, &1, job_id))
        Logger.info("chat #{state.job_id}: wrote #{length(entries)} job(s) of history")
    end
  rescue
    error ->
      Log.line("history.unwritten", :warning, "could not write the history: #{inspect(error)}",
        job_id: job_id
      )
  end

  defp job_dir(%{assignment: assignment, root: root}) do
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])
    Path.join([root, "jobs", spec.job_id])
  end

  defp write_entry(base, entry, job_id) do
    case contained(base, entry["dir"]) do
      {:ok, dir} ->
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "job.md"), entry["metadata"] || "")
        maybe_fetch(dir, entry["transcript"])

      :error ->
        Log.line(
          "history.unwritten",
          :warning,
          "refusing a history entry named #{inspect(entry["dir"])}, which leaves the folder",
          job_id: job_id
        )
    end
  end

  # The name comes over the channel and is joined to a path, so it is checked against the same
  # model the write uses: expanded, then required to be under the folder. A check on the string
  # — "does it contain ..?" — is a different model from the one `File.write!` follows, and
  # CLAUDE.md says that is the trap.
  defp contained(base, name) when is_binary(name) do
    base = Path.expand(base)
    dir = Path.expand(Path.join(base, name))

    if dir != base and String.starts_with?(dir, base <> "/"), do: {:ok, dir}, else: :error
  end

  defp contained(_base, _name), do: :error

  defp maybe_fetch(dir, %{"key" => key, "token" => token}), do: fetch_transcript(dir, key, token)
  defp maybe_fetch(_dir, _none), do: :ok

  defp fetch_transcript(dir, key, token) do
    path = Path.join(dir, "transcript.jsonl")

    case Store.fetch(Config.platform_url(), key, token, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.write!(path <> ".missing", "could not fetch #{key}: #{inspect(reason)}\n")
    end
  end

  # A spec with nothing to open with is a reopened conversation whose last word was the agent's:
  # everything said has been answered, and the new process waits for the person rather than
  # answering its opening message a second time as though it were new. One decision, made here
  # and handed to the runner, because the pending queue above has to agree with it.
  defp holds?(assignment) do
    case assignment["spec"]["prompt"] do
      prompt when is_binary(prompt) -> String.trim(prompt) == ""
      _none -> true
    end
  end

  defp runner_opts(state) do
    me = self()
    assignment = state.assignment
    secrets = secrets(state)
    slice = assignment["slice"] || %{}
    spec = ForgeCore.Job.Spec.from_map(assignment["spec"])

    harness = ForgeWorker.Link.harness()

    # A reopened conversation resumes its session as a fork, when one was carried and passes its
    # check, and starts cold with the replay otherwise (`docs/design/conversations.md` § Lifetime).
    {harness_opts, session} =
      Application.get_env(:forge_worker, :harness_opts, [])
      |> Keyword.put(:mode, :streaming)
      |> Keyword.merge(ForgeWorker.Link.resume_opts(assignment))
      |> put_max_cost(assignment)
      |> put_model(spec)
      |> put_effort(spec)
      |> then(&Session.restore(assignment, job_dir(state), state.worktree, &1, harness))

    harness_opts = ForgeWorker.Job.Credential.put(harness_opts, assignment, harness.driver())

    [
      harness: ForgeWorker.Link.harness(),
      spec: spec,
      root: Path.join(state.root, "jobs"),
      worktree: state.worktree,
      owner: me,
      # Events go through here rather than straight to the link, because a delivery has to be
      # matched to the message it delivers before the platform can be told which one it was.
      # Masked here, before the delivery is matched: the match is by the order messages were
      # written, not by their text, so a masked echo is still the message it echoes.
      sink: fn event -> send(me, {:harness_event, Secrets.mask_event(secrets, event)}) end,
      slice_opts: %{memory_max: slice["memory_max"], cpu_weight: slice["cpu_weight"]},
      harness_opts: harness_opts,
      secrets: secrets,
      backlog: assignment["backlog"],
      session: session,
      hold_prompt: state.hold,
      # A conversation is bounded by going idle, not by the clock: a chat someone is still in
      # is not a runaway. The wall clock stays as a backstop, far out.
      wall_clock_ms: assignment["wall_clock_ms"] || :timer.hours(24),
      nix_env: Application.get_env(:forge_worker, :nix_env, true),
      extra_env: Application.get_env(:forge_worker, :extra_env, []) ++ git_env(assignment)
    ]
  end

  # What is left of the day, decided by the platform and passed through. A turn is refused by
  # the harness at this ceiling rather than by us afterwards — see § Spend.
  defp put_max_cost(opts, %{"max_cost_usd" => cost}) when is_number(cost),
    do: Keyword.put(opts, :max_cost, cost)

  defp put_max_cost(opts, _assignment), do: opts

  # The model the conversation was opened with, or the project's — resolved by the platform,
  # which knows both. A spec that names none leaves the machine's alone.
  defp put_model(opts, %ForgeCore.Job.Spec{model: model}) when is_binary(model),
    do: Keyword.put(opts, :model, model)

  defp put_model(opts, _spec), do: opts

  # The effort the conversation was opened with, or the project's — resolved by the platform, as
  # the model is. A spec that names none leaves the machine's alone.
  defp put_effort(opts, %ForgeCore.Job.Spec{effort: effort}) when is_binary(effort),
    do: Keyword.put(opts, :effort, effort)

  defp put_effort(opts, _spec), do: opts

  defp git_env(%{"git" => %{"url" => url, "token" => token}}) when is_binary(token),
    do: [{"FORGE_GIT_URL", url}, {"FORGE_GIT_TOKEN", {:secret, token}}]

  defp git_env(_assignment), do: []

  # -- what the operator asks for -------------------------------------------------------------

  @impl true
  def handle_cast({:message, id, text}, state) do
    case Runner.send_message(state.runner, text) do
      :ok ->
        {:noreply, reset_idle(%{state | pending: state.pending ++ [id]})}

      {:error, reason} ->
        Log.line(
          "chat.undelivered",
          :warning,
          "the harness would not take a message: #{inspect(reason)}",
          job_id: state.job_id
        )

        {:noreply, state}
    end
  end

  def handle_cast(:interrupt, state) do
    Runner.interrupt(state.runner)
    {:noreply, state}
  end

  def handle_cast({:close, reason}, state) do
    Runner.close(state.runner)
    {:noreply, %{state | closing: reason}}
  end

  # -- what the harness says ------------------------------------------------------------------

  @impl true
  def handle_info({:harness_event, %{type: "job.harness.delivered"} = event}, state) do
    {id, pending} = take_pending(state.pending)

    # The prompt's own echo is not a message anyone is waiting on, so it is not reported as one.
    if is_binary(id) do
      send(state.link, {:event, state.job_id, delivery_event(event, id)})
    end

    {:noreply, %{state | pending: pending}}
  end

  def handle_info(
        {:harness_event, %{type: "job.harness.started", payload: payload} = event},
        state
      ) do
    send(state.link, {:event, state.job_id, event})
    {:noreply, %{state | version: payload[:version] || state.version}}
  end

  def handle_info({:harness_event, event}, state) do
    send(state.link, {:event, state.job_id, event})
    {:noreply, state}
  end

  # A turn ended: commit what it wrote before saying it happened, for the same reason a job
  # pushes before it reports — the platform records the branch head as the changeset the moment
  # it hears from us, and work that is not on the branch is work that was lost.
  def handle_info({:turn, _job_id, index, event}, state) do
    {head, uncommitted} = commit_turn(state, index)

    # Every turn, not at the end. `out/` is never committed, so a proposal or a document
    # reported only when the conversation closes is one a lost machine takes with it — and a
    # conversation can be closed by an idle timeout nobody is present for. The platform records
    # by content, so re-reporting the same file every turn costs nothing.
    proposals = Dir.proposals(job_dir(state))
    documents = Dir.documents(job_dir(state))
    # Read once per turn and removed by the read, so a request is carried exactly once — and
    # only off a turn that ended cleanly (`docs/design/conversations.md` § Taking a transition).
    transition = transition_request(state, event.payload)

    # After every turn and not at the end, because a conversation's end may be its machine's: it
    # goes dormant when its worker is lost, and a reopen resumes what the last turn left.
    session = Session.upload(job_dir(state), event.payload[:session_id], state.assignment, index)

    send(
      state.link,
      {:chat_turn, state.job_id, index,
       Secrets.mask(
         secrets(state),
         %{
           "job_id" => state.job_id,
           "turn" => index,
           "commit" => head,
           # Why the turn has no commit, when it has none: the machine's log is off the machine
           # and the person in the chat never reads it, so this is the only way they learn that
           # what the turn did is not on the branch (`docs/design/conversations.md` § Commits).
           "uncommitted" => uncommitted,
           "interrupted" => event.payload[:interrupted] == true,
           "proposals" =>
             Map.new(proposals.proposals, fn {file, p} ->
               {file, %{"title" => p.title, "body" => p.body, "raw" => p.raw}}
             end),
           "invalid_proposals" => proposals.invalid_proposals,
           "documents" => documents.documents,
           "invalid_documents" => documents.invalid_documents,
           "harness" => turn_summary(event, session, state.version)
         }
         |> Map.merge(transition_keys(transition))
       )}
    )

    {:noreply, %{state | turns: index}}
  end

  def handle_info({:ended, _job_id, result}, state), do: {:noreply, %{state | result: result}}

  def handle_info({:EXIT, runner, _reason}, %{runner: runner} = state) do
    {:stop, :normal, finish(state)}
  end

  def handle_info(:idle, state) do
    Logger.info("chat #{state.job_id} went idle; releasing the machine")
    Runner.close(state.runner)
    {:noreply, %{state | closing: "idle"}}
  end

  def handle_info(message, state) do
    Logger.debug("conversation ignored #{inspect(message)}")
    {:noreply, state}
  end

  # **Only a clean turn's request is read; any other's file is removed unread.** The same gate
  # `invoke.json` has, for the same reason it has it — a run that may not invoke has its file
  # removed "so a stray file cannot turn a finished run into a round of refusals"
  # (`runner.ex`'s `invocations/3`). Here the turn to refuse is the interrupted one above all: the
  # person cut the agent off mid-sentence, a file half-written when that happened is not a request
  # anybody made, and `push_reply/1` — the thing that would have told somebody — is the one step
  # an interrupted turn skips. A turn the harness ended on an error or a budget is no better.
  defp transition_request(state, payload) do
    clean? =
      payload[:interrupted] != true and payload[:subtype] == "success" and
        payload[:is_error] != true

    if clean? do
      Dir.transition_request(job_dir(state))
    else
      File.rm_rf(Dir.transition_path(job_dir(state)))
      :none
    end
  end

  # Absent unless the conversation wrote the file, so a turn that asked for nothing says nothing.
  # Merged before the masking wrap closes, not after: the request carries the agent's own
  # `comment`, which is text it wrote and so is text that could hold a secret.
  defp transition_keys(:none), do: %{}
  defp transition_keys({:ok, request}), do: %{"transition_request" => request}
  defp transition_keys({:error, reason}), do: %{"invalid_transition_request" => reason}

  # -- ending ---------------------------------------------------------------------------------

  # The harness is gone. What is left is what a job's task does after `await`: get the
  # transcript off the machine, give the worktree back, and report.
  defp finish(state) do
    # The last git command in the tree, and then the files come back and the user goes: nothing
    # after this runs git, and the transcript is read as root.
    commit = head(state)
    leave(state)
    state = %{state | user: nil}

    # The runner sends its result before it stops, so it is already here. A conversation whose
    # machine died mid-turn has none, and reports what it can rather than nothing.
    result = state.result || %Result{status: :finished}
    Secrets.mask_file(secrets(state), result.transcript_path)
    result = upload_transcript(result, state.assignment)

    # Masked by the link, as every ending is (`ForgeWorker.Link`'s `report/4`).
    send(
      state.link,
      {:terminal, state.job_id, "hibernated",
       %{
         "job_id" => state.job_id,
         "reason" => state.closing || stopped_why(result) || "ended",
         "commit" => commit,
         "turns" => state.turns,
         "result" => Result.to_map(result)
       }}
    )

    Workspace.discard(state.assignment, state.root)
    Dir.sweep(Path.join(state.root, "jobs"), job_retention_ms())
    state
  end

  # A runner that stopped the harness itself — it never started (`Runner`'s `:start_timeout_ms`)
  # — says why in the result, and the platform records it as how the conversation ended. Anything
  # but `closed` or `idle` leaves it hibernated, so it can be reopened on a machine that works.
  defp stopped_why(%Result{reason: reason}) when is_binary(reason), do: reason
  defp stopped_why(_result), do: nil

  defp report_failed(state, reason) do
    send(
      state.link,
      {:terminal, state.job_id, "failed", %{"job_id" => state.job_id, "reason" => reason}}
    )
  end

  # -- the work -------------------------------------------------------------------------------

  # One commit per turn, and they accumulate: `Checkout.squash/5` resets to `origin/<branch>`,
  # and pushing moves that remote-tracking ref, so turn two is built on turn one rather than
  # replacing it. That was measured before it was relied on, because the opposite reading —
  # every turn rewriting the last into a single amended commit — is equally plausible from the
  # code and would silently lose each turn's history.
  #
  # **As the job's user**, which still owns the tree: the harness is running, and git refuses to
  # work in a repository somebody else owns. Run as root it refused every turn, and each turn's
  # work stayed on the machine until the agent pushed it itself.
  defp commit_turn(state, index) do
    message = commit_message(state, index)

    case Workspace.commit_and_push(state.assignment, state.worktree, message, state.user) do
      {:ok, head} ->
        {head, nil}

      # The turn is still reported, with no commit: its reply and its cost happened whether or
      # not its work reached the branch. What went wrong is a line in the machine's log, and —
      # since ticket 11 — a word with the turn itself, because the machine's log is not read by
      # the person in the chat (`docs/design/worker-log.md`, `conversations.md` § Commits).
      {:error, reason} ->
        Log.line(
          "turn.uncommitted",
          :error,
          # A hook's output, which can print what the agent wrote: the machine's log is read off
          # the machine too (`docs/design/secrets.md` § Masking).
          Secrets.mask(
            secrets(state),
            "could not commit turn #{index}; its work is on this machine only: #{inspect(reason)}"
          ),
          job_id: state.job_id
        )

        {nil, uncommitted(reason)}
    end
  end

  # What the turn carries about the commit it did not make: the kind of failure, and for the one
  # kind a person can act on — a merge the turn left conflicted — the paths it is open in. The
  # words are the platform's, which is where the person reads them; this says which words.
  defp uncommitted({:merge_unresolved, paths}),
    do: %{"reason" => "merge_unresolved", "paths" => paths}

  defp uncommitted(_other), do: %{"reason" => "not_committed"}

  defp commit_message(state, index),
    do: "chat: turn #{index}\n\nConversation #{state.job_id}.\n"

  defp head(%{worktree: nil}), do: nil

  defp head(state) do
    case Workspace.head(state.worktree, state.user) do
      {:ok, head} -> head
      _other -> nil
    end
  end

  # Only what is there: a conversation that stopped before its worktree was made has none.
  defp leave(state) do
    paths = [Workspace.dir(state.assignment, state.root), job_dir(state)]
    Slice.leave(state.user, Enum.filter(paths, &File.exists?/1))
  end

  defp take_pending([]), do: {nil, []}
  defp take_pending([id | rest]), do: {id, rest}

  defp delivery_event(event, id) do
    %{event | type: "job.harness.delivered", payload: Map.put(event.payload, :message_id, id)}
  end

  # String keys: this crosses the channel as JSON, and an atom key here arrives as a string key
  # there. The same trap `harness_summary/3` already carries a comment about.
  defp turn_summary(event, session, version) do
    payload = event.payload

    %{
      "session_id" => payload[:session_id],
      "session_blob" => session,
      "version" => version,
      "subtype" => payload[:subtype],
      "is_error" => payload[:is_error],
      "turns" => payload[:num_turns],
      "cost_usd" => payload[:total_cost_usd],
      "duration_ms" => payload[:duration_ms],
      "usage" => payload[:usage],
      "result" => payload[:result],
      # The job's memory as the turn ended (`docs/design/claude-code-events.md` § Memory).
      "memory" => payload[:memory]
    }
  end

  defp reset_idle(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle, state.idle_ms)}
  end

  defp upload_transcript(%Result{transcript_path: nil} = result, _assignment), do: result

  defp upload_transcript(%Result{} = result, assignment) do
    store = assignment["store"] || %{}

    if is_nil(Config.platform_url()) or is_nil(store["transcript_key"]) do
      result
    else
      case Store.put(
             Config.platform_url(),
             store["transcript_key"],
             store["transcript_token"],
             result.transcript_path
           ) do
        {:ok, _info} -> %{result | transcript: store["transcript_key"]}
        {:error, reason} -> log_transcript(result, reason, assignment["job_id"])
      end
    end
  end

  defp log_transcript(result, reason, job_id) do
    Log.line("upload.failed", :warning, "could not upload the transcript: #{inspect(reason)}",
      job_id: job_id
    )

    result
  end

  defp job_retention_ms,
    do: Application.get_env(:forge_worker, :job_retention_ms, 7 * 24 * 60 * 60 * 1000)
end
