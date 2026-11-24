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
  @spec send_message(pid(), String.t(), String.t(), map()) :: :ok
  def send_message(pid, id, text, files \\ %{}),
    do: GenServer.cast(pid, {:message, id, text, files})

  @doc """
  Ends the turn in flight, keeping the process. **With a message id, only if this worker still holds
  that message** (`docs/design/conversations.md` § Turns): a tap on a queued message that reaches
  here after the message was written interrupts nothing, so it can never stop the turn that is
  answering that very message. Without one it is Stop. Either way, what is held goes next.
  """
  @spec interrupt(pid(), String.t() | nil) :: :ok
  def interrupt(pid, message_id \\ nil), do: GenServer.cast(pid, {:interrupt, message_id})

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
       # **The worker queues** (`docs/design/conversations.md` § Turns): `busy` is a turn in flight,
       # from the write that began it to the turn's report, and `held` the messages that arrived
       # meanwhile — `{platform id, composed text}`, oldest first — written together as one message
       # when the turn has been reported. The prompt is the first write, sent by the runner itself:
       # unless it is held (a reopen whose last word was the agent's), the conversation starts busy.
       busy: not hold,
       held: [],
       # The files a message named whose folder could not show them, `%{"file", "why"}`, until the
       # next turn report says so to the person (`files_lost` in `{:turn, …}`'s report).
       files_lost: [],
       hold: hold,
       # The CLI's version, from its `system/init`: recorded with each session upload, so a
       # reopen restores the file only onto the CLI that wrote it.
       version: nil,
       # What the session this process resumed had already spent, which every turn's total starts
       # from: set when the runner's options are made, once the session has been checked.
       baseline: 0,
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
  defp secrets(state), do: Secrets.from_assignment(state.assignment, job_dir(state))

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
    opts = runner_opts(state)

    case Runner.start_link(opts) do
      {:ok, runner} ->
        send(state.link, {:runner, state.job_id, runner})
        baseline = opts |> Keyword.fetch!(:harness_opts) |> Session.baseline()
        {:noreply, reset_idle(%{state | runner: runner, baseline: baseline})}

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
  # and handed to the runner, because `busy` above has to agree with it: a held prompt is no turn.
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

    harness = ForgeWorker.Link.harness(assignment)

    # A reopened conversation resumes its session as a fork, when one was carried and passes its
    # check, and starts cold with the replay otherwise (`docs/design/conversations.md` § Lifetime).
    {harness_opts, session} =
      Application.get_env(:forge_worker, :harness_opts, [])
      |> ForgeWorker.Harness.machine_opts(harness)
      |> Keyword.put(:mode, :streaming)
      |> Keyword.merge(ForgeWorker.Link.resume_opts(assignment))
      |> put_max_tokens(assignment)
      |> put_model(spec)
      |> put_effort(spec)
      |> then(&Session.restore(assignment, job_dir(state), state.worktree, &1, harness))

    harness_opts = ForgeWorker.Job.Credential.put(harness_opts, assignment, harness.driver())

    [
      harness: harness,
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
      changelog: assignment["changelog"],
      session: session,
      hold_prompt: state.hold,
      # A conversation is bounded by going idle, not by the clock: a chat someone is still in
      # is not a runaway. The wall clock stays as a backstop, far out.
      wall_clock_ms: assignment["wall_clock_ms"] || :timer.hours(24),
      nix_env: Application.get_env(:forge_worker, :nix_env, true),
      archive: ForgeWorker.Archive.grant(assignment),
      attachments: assignment["attachments"],
      extra_env: Application.get_env(:forge_worker, :extra_env, []) ++ git_env(assignment)
    ]
  end

  # What is left of the day, decided by the platform and passed through. Not given to the harness:
  # the runner counts the process's weighted tokens and stops it past this (`ForgeWorker.Job.Meter`).
  defp put_max_tokens(opts, %{"max_tokens" => tokens}) when is_integer(tokens),
    do: Keyword.put(opts, :max_tokens, tokens)

  defp put_max_tokens(opts, _assignment), do: opts

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

  # The folder is brought up to the pool before the turn that reads this message begins, and the
  # message names the files that came with it, and those that did not arrive — here or on the
  # platform's side (`docs/design/attachments.md` § Delivery, `conversations.md` § The wire). A
  # platform that sends no pool leaves the folder as it is. Done when the message arrives, held or
  # not, so that what it names is fresh whenever it goes; a message may be files alone
  # (`ForgeCore.Prompt.with_files/3`).
  #
  # **A file is named as there only if the job's folder shows it**, which is not the same as the
  # worker's directory holding it: the folder is a bind mount of that directory, and a mount that
  # is not there leaves an empty one. So the sync's own failures are not the only way a file is not
  # received — `Mount.shows?/2` is asked of the mount table, and a refused refresh is one too — and
  # every file of the message is then named as not received, with the reason, to the agent here and
  # to the person with the next turn's report (`files_lost`).
  defp compose(state, text, %{"attachments" => entries} = payload) when is_list(entries) do
    job_dir = job_dir(state)
    failed = ForgeWorker.Attachments.sync(job_dir, entries)
    refreshed = ForgeWorker.Attachments.refresh(job_dir)
    shown? = refreshed == :ok and ForgeWorker.Attachments.shows?(job_dir)
    pool = for %{"file" => file} <- entries, do: file

    {files, lost} =
      payload["files"]
      |> List.wrap()
      |> Enum.map(&{&1, why_not_received(&1["file"], failed, pool, shown?)})
      |> Enum.split_with(fn {_file, why} -> why == nil end)

    files = Enum.map(files, &elem(&1, 0))
    lost = for {file, why} <- lost, do: %{"file" => file["file"], "why" => why}
    state = %{state | files_lost: state.files_lost ++ lost}

    # The platform's own names, and the worker's with the reason it has for each.
    {state, ForgeCore.Prompt.with_files(text, files, (payload["not_received"] || []) ++ lost)}
  end

  defp compose(state, text, _payload), do: {state, text || ""}

  # Why the worker cannot say a file is in the folder, or nil when it can.
  defp why_not_received(name, failed, pool, shown?) do
    cond do
      name in failed -> "it could not be downloaded to this machine"
      name not in pool -> "it was not in the pool sent with the message"
      not shown? -> "it could not be put in the folder on this machine"
      true -> nil
    end
  end

  @impl true
  def handle_cast({:message, id, text}, state), do: handle_cast({:message, id, text, %{}}, state)

  # While a turn is in flight the message is held, and nothing is written; otherwise it goes now.
  def handle_cast({:message, id, text, files}, state) do
    {state, composed} = compose(state, text, files)
    message = {id, composed}

    if state.busy do
      {:noreply, reset_idle(%{state | held: state.held ++ [message]})}
    else
      case write_held(state, [message]) do
        {:ok, state} -> {:noreply, reset_idle(state)}
        {:error, state} -> {:noreply, state}
      end
    end
  end

  # Stop, or — with a message id — force: only a message still held can be forced, so a tap that
  # arrives after the message was written stops nothing (`interrupt/2`).
  def handle_cast({:interrupt, nil}, state) do
    Runner.interrupt(state.runner)
    {:noreply, state}
  end

  def handle_cast({:interrupt, id}, state) do
    if Enum.any?(state.held, fn {held, _text} -> held == id end),
      do: Runner.interrupt(state.runner)

    {:noreply, state}
  end

  def handle_cast({:close, reason}, state) do
    Runner.close(state.runner)
    {:noreply, %{state | closing: reason}}
  end

  # -- what the harness says ------------------------------------------------------------------

  @impl true
  # **The harness's echo is not delivery** and says nothing the platform reads: Claude Code writes
  # it with the turn's first complete block, and for a message sent while a tool runs before that
  # turn's result. The worker says delivery itself, when it writes (`write_held/2`). The line it
  # writes after an interrupt, `[Request interrupted by user]`, is dropped with it.
  def handle_info({:harness_event, %{type: "job.harness.delivered"}}, state),
    do: {:noreply, state}

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
    session =
      Session.upload(
        job_dir(state),
        event.payload[:session_id],
        state.assignment,
        index,
        ForgeWorker.Link.harness(state.assignment)
      )

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
           # The files a message named as not received since the last report, with why, so that
           # the person who attached them sees it too. A message held when the chat closes is
           # never written (`flush_held/1`), so this says what became of the files, and not that
           # the agent was told (`docs/design/attachments.md` § Delivery).
           "files_lost" => state.files_lost,
           "interrupted" => event.payload[:interrupted] == true,
           "proposals" =>
             Map.new(proposals.proposals, fn {file, p} ->
               {file, %{"title" => p.title, "body" => p.body, "raw" => p.raw}}
             end),
           "invalid_proposals" => proposals.invalid_proposals,
           "documents" => documents.documents,
           "invalid_documents" => documents.invalid_documents,
           "harness" => turn_summary(event, session, state)
         }
         |> Map.merge(transition_keys(transition))
       )}
    )

    # Everything held while that turn ran goes now, as one message — after the turn's report, so the
    # log reads `chat.turn` before the `delivered` that follows it. Across a reconnect the Link
    # keeps that order when it sends what is unacked again (`Link.resend_unacked/1`).
    {:noreply, flush_held(%{state | turns: index, busy: false, files_lost: []})}
  end

  def handle_info({:ended, _job_id, result}, state), do: {:noreply, %{state | result: result}}

  def handle_info({:EXIT, runner, _reason}, %{runner: runner} = state) do
    {:stop, :normal, finish(state)}
  end

  # **A turn in flight is not idleness.** The timer is set when a message arrives, so one that
  # outlasts it would close the conversation in the middle of the turn, and the messages held behind
  # the turn would never be written (`flush_held/1` takes nothing for a conversation closing). It
  # starts again instead, and the conversation goes idle once the turn is over and the time has
  # passed.
  def handle_info(:idle, %{busy: true} = state), do: {:noreply, reset_idle(state)}

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

  # A conversation being closed takes nothing more: its stdin is closing.
  defp flush_held(%{held: []} = state), do: state
  defp flush_held(%{closing: closing} = state) when closing != nil, do: state
  defp flush_held(state), do: state |> then(&write_held(%{&1 | held: []}, state.held)) |> elem(1)

  # Writes messages to an idle harness, together as one — their texts joined by a blank line, which
  # is how Claude Code takes a queue — and says each was delivered, in the order sent, which is what
  # the platform's *queued* is read from (`docs/design/conversations.md` § The wire). A harness that
  # will not take it leaves the messages undelivered, as the platform's log already says.
  defp write_held(state, messages) do
    text = Enum.map_join(messages, "\n\n", fn {_id, text} -> text end)

    case Runner.send_message(state.runner, text) do
      :ok ->
        for {id, _text} <- messages do
          send(state.link, {:chat_delivered, state.job_id, id})
        end

        {:ok, %{state | busy: true}}

      {:error, reason} ->
        Log.line(
          "chat.undelivered",
          :warning,
          "the harness would not take a message: #{inspect(reason)}",
          job_id: state.job_id
        )

        {:error, state}
    end
  end

  # String keys: this crosses the channel as JSON, and an atom key here arrives as a string key
  # there. The same trap `harness_summary/3` already carries a comment about.
  #
  # `cost_usd` is the turn's total less what the resumed session had already spent, so it is the
  # process's own running total; the platform sets it on the run (`Forge.Jobs.Runs.record/3`) and
  # the next reopen's baseline is `session_cost_usd`, the harness's total as it came.
  defp turn_summary(event, session, state) do
    payload = event.payload
    total = payload[:total_cost_usd]

    %{
      "session_id" => payload[:session_id],
      "session_blob" => session,
      "version" => state.version,
      "subtype" => payload[:subtype],
      "is_error" => payload[:is_error],
      "turns" => payload[:num_turns],
      "cost_usd" => Session.own_cost(total, state.baseline, state.job_id),
      "session_cost_usd" => total,
      "duration_ms" => payload[:duration_ms],
      # The process's running totals, counted by the worker call by call: the platform sets them
      # on the run and does not add them (`Forge.Jobs.Runs.record/3`).
      "usage" => payload[:usage_total] || 0,
      "tokens" => payload[:tokens_total],
      "claude_usage" => payload[:claude_usage],
      # A login Codex rewrote this turn, sealed for this job (`Runner`); nothing otherwise.
      "credential_return" => payload[:credential_return],
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
